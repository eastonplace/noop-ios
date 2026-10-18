import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore

struct TrainingLoadDetailRequest {
    let key: TrendsScreenSnapshotKey
    let sourceID: String
    let rangeDays: Int
}

/// Capture source ownership at the link, rather than after a destination's asynchronous read starts.
///
/// The whole Trends section is the tap target, the way a #55 tappable section is (its eyebrow carries the chevron).
/// VoiceOver hears one short element, the caller's summary, kept as a heading so the rotor still finds the section.
struct TrainingLoadDetailLink<Label: View>: View {
    let key: TrendsScreenSnapshotKey
    let rangeDays: Int
    let voiceOverSummary: String
    let label: () -> Label
    @EnvironmentObject private var repo: Repository

    init(key: TrendsScreenSnapshotKey, rangeDays: Int, voiceOverSummary: String,
         @ViewBuilder label: @escaping () -> Label) {
        self.key = key; self.rangeDays = rangeDays; self.voiceOverSummary = voiceOverSummary; self.label = label
    }

    var body: some View {
        let request = TrainingLoadDetailRequest(key: key, sourceID: TrainingLoadDetailView.sourceID(repo), rangeDays: rangeDays)
        NavigationLink {
            TrainingLoadDetailView(request: request)
                .environment(\.screenScaffoldNavigationRole, .detail)
        } label: {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: voiceOverSummary))
        }
        .buttonStyle(PaperPressStyle())
        .accessibilityAddTraits(.isHeader)
        .accessibilityHint("Opens dated training load and how it is calculated")
        .accessibilityIdentifier("trends.trainingLoad.open")
    }
}

/// The words the Trends card and the detail share for each model state, so the card and the page it opens agree.
enum TrainingLoadCopy {
    /// The eyebrow pill: "Established", "Building 20/42", or why there is no estimate yet.
    static func status(_ state: TrainingLoadEngine.State, reason: TrainingLoadEngine.UnavailableReason?,
                       observedDays: Int) -> String {
        switch state {
        case .established:
            return String(localized: "Established")
        case .building:
            return String(localized: "Building \(observedDays)/42")
        case .unavailable:
            switch reason {
            case .notEnoughContiguousDays: return String(localized: "Building")
            case .noData: return String(localized: "No history")
            default: return String(localized: "Building")
            }
        }
    }

    static func tone(_ state: TrainingLoadEngine.State) -> StrandTone {
        state == .established ? .positive : .neutral
    }

    /// How many more days of Effort the model needs before it can show a load estimate.
    static func remainingDays(contiguousDays: Int) -> Int {
        max(0, TrainingLoadEngine.Configuration.standard.minimumDays - contiguousDays)
    }

    /// The one explicit insufficient-history state, shared by the Trends card and the page it opens.
    static func needsMoreDays(_ remaining: Int) -> String {
        remaining == 1
            ? String(localized: "Needs 1 more day of workouts")
            : String(localized: "Needs \(remaining) more days of workouts")
    }

    /// The one-line reason there is no load estimate.
    static func unavailableTitle(_ reason: TrainingLoadEngine.UnavailableReason?) -> String {
        switch reason {
        case .notEnoughContiguousDays: return String(localized: "Building your load history")
        case .missingTargetDay: return String(localized: "Today's Effort is not ready")
        default: return String(localized: "Training load is not ready")
        }
    }
}

/// A bounded read of the same canonical Trends projection. TrainingLoadEngine remains the only calculator.
///
/// Flat #55 drill-in, built like the Recovery trend: the eyebrow carries the state pill, "Last N days" and the quiet
/// range control sit under it, then the acute hero with its change against the 42-day baseline, the trend chart (acute
/// in the metric colour, chronic as the grey dashed baseline) and the selected day's Acute | Chronic | Balance strip.
/// The workout link and two plain-language disclosure rows follow, one hairline above them.
struct TrainingLoadDetailView: View {
    let request: TrainingLoadDetailRequest
    /// Gregorian, in the Trends source time zone. Built once rather than on every body pass.
    private let calendar: Calendar
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var result: TrainingLoadEngine.Result?
    @State private var failure: String?
    /// The read that produced the result on screen. Coming back from Workout history re-runs `.task` with the same
    /// trigger, which keeps the page (and its scroll position) instead of flashing the loading state.
    @State private var loadedTrigger: ReadTrigger?
    @State private var period = 42
    @State private var selection: Date?
    @State private var showMethod = false
    @State private var showRows = false
    @State private var readID = UUID()

    init(request: TrainingLoadDetailRequest) {
        self.request = request
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: request.key.timeZoneIdentifier) ?? .autoupdatingCurrent
        self.calendar = calendar
    }

    @MainActor static func sourceID(_ repo: Repository) -> String {
        repo.todayHealthSnapshotScopeId + "|" + repo.liveSourceState.lineageComponent
            + "|" + String(repo.externalSurfaceInvalidationEpoch)
    }

    /// Only a different source, or a fenced repository, ends this page. A routine refresh (a strap sync, a foreground
    /// refresh, pull to refresh) only moves the revision, and the page re-reads in place.
    private var sourceIsCurrent: Bool {
        request.sourceID == Self.sourceID(repo) && !repo.verifiedExternalSurfaceFenced
    }
    private var liveRevision: Int {
        Int(truncatingIfNeeded: repo.refreshSeq &+ Int(repo.canonicalHealth.trendsRevision))
    }
    /// Changes only for a genuine reason to read again: a retry, a repository refresh or a different request.
    private var trigger: ReadTrigger {
        ReadTrigger(readID: readID, revision: liveRevision, sourceID: request.sourceID, anchorDay: request.key.anchorDay,
                    timeZoneIdentifier: request.key.timeZoneIdentifier, rangeDays: request.rangeDays,
                    weekOffset: request.key.weekOffset)
    }
    private var dayFormat: Date.FormatStyle {
        .init(date: .abbreviated, time: .omitted, locale: .autoupdatingCurrent,
              calendar: calendar, timeZone: calendar.timeZone)
    }
    /// "Thu, Oct 15": the day format every #55 drill-in header uses, here in the Trends source time zone.
    private var weekdayFormat: Date.FormatStyle {
        Date.FormatStyle(locale: .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day()
    }
    private var headerContext: String? {
        date(request.key.anchorDay).map { $0.formatted(weekdayFormat) }
    }
    private var anchor: Date { date(request.key.anchorDay) ?? Date() }
    private var rangeStart: Date { calendar.date(byAdding: .day, value: 1 - period, to: anchor) ?? anchor }
    /// The scrubbed position, snapped to the nearest calendar day.
    private var selectedDay: Date? {
        selection.map { calendar.startOfDay(for: $0.addingTimeInterval(12 * 60 * 60)) }
    }

    var body: some View {
        ScreenScaffold(title: "Training load", lazy: true, headerContext: headerContext) {
            if !sourceIsCurrent {
                sourceChangedState
            } else if let result {
                content(result)
            } else if let failure {
                failedState(failure)
            } else {
                loadingState
            }
        }
        .segmentedPillSelectionStyle(.quiet)
        .task(id: trigger) { await load() }
        .onChange(of: period) { _, _ in selection = nil }
        .accessibilityIdentifier("trends.trainingLoad.detail")
    }

    // MARK: Page

    @ViewBuilder private func content(_ result: TrainingLoadEngine.Result) -> some View {
        let points = loadDays(result)
        VStack(alignment: .leading, spacing: 0) {
            if result.isAvailable {
                loadSection(result, points: points)
            } else {
                unavailableSection(result)
            }
            DrillInSeparator()
            VStack(alignment: .leading, spacing: 0) {
                workoutsLink
                if result.isAvailable {
                    FlatRowSeparator()
                    datedValues(points)
                }
                FlatRowSeparator()
                methodSection
            }
            Text("These values describe recorded daily Effort. They do not change Readiness or provide medical clearance.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, NoopMetrics.space2)
        }
    }

    // MARK: Load

    private func loadSection(_ result: TrainingLoadEngine.Result, points: [TrainingLoadDay]) -> some View {
        let focus = focusDay(in: points)
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Load over time", systemImage: "flame.fill", tint: .effort, trailing: eyebrowPill(result))
            TrendsControlRow(
                leading: { _ in
                    Text("Last \(period) days")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                },
                trailing: { periodPicker }
            )
            hero(focus)
            TrainingLoadChart(points: points, domain: rangeStart...anchor, calendar: calendar, focus: focus,
                              marker: selectedDay, selection: $selection, summary: chartSummary(focus))
            TrainingLoadLegend()
            dayStrip(focus)
        }
    }

    private func eyebrowPill(_ result: TrainingLoadEngine.Result) -> EyebrowTrailing {
        .pill(LocalizedStringKey(TrainingLoadCopy.status(result.state, reason: result.unavailableReason,
                                                         observedDays: result.contiguousDays)),
              tone: TrainingLoadCopy.tone(result.state))
    }

    /// The scrubbed day when it has an observation, else the newest observed day.
    private func focusDay(in points: [TrainingLoadDay]) -> TrainingLoadDay? {
        guard let day = selectedDay else { return points.last }
        return points.first { calendar.isDate($0.date, inSameDayAs: day) }
    }

    // MARK: Hero

    /// Acute load for the scrubbed (or newest) day, with its change against the 42-day baseline beside it. At the
    /// accessibility sizes the pill drops under the value so neither is squeezed onto a second line.
    private func hero(_ focus: TrainingLoadDay?) -> some View {
        let value = HeroValue(value: focus.map { number($0.acute) } ?? WidgetMetrics.missingValue,
                              caption: heroCaption(focus), captionPlacement: .below)
        return Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    value
                    deltaPill(focus)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    value
                    Spacer(minLength: NoopMetrics.space2)
                    deltaPill(focus)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trends.trainingLoad.hero")
    }

    private func heroCaption(_ focus: TrainingLoadDay?) -> String {
        let acute = String(localized: "Acute · 7d")
        guard let day = selectedDay else { return acute }
        let label = day.formatted(weekdayFormat)
        return focus == nil ? String(localized: "No data · \(label)") : "\(acute) · \(label)"
    }

    /// Acute against chronic, from the engine's own balance (chronic minus acute, so the sign flips): up when recent
    /// effort is above the baseline. Load has no good direction, so the pill stays neutral.
    @ViewBuilder private func deltaPill(_ focus: TrainingLoadDay?) -> some View {
        if let focus {
            let delta = -focus.balance
            let magnitude = number(abs(delta))
            if !delta.isFinite || trendsDeltaIsZero(magnitude) {
                StatePill("Level with 42-day", tone: .neutral, showsDot: false)
            } else if delta > 0 {
                StatePill("▲ \(magnitude) vs 42-day", tone: .neutral, showsDot: false)
                    .accessibilityLabel(Text("up \(magnitude) vs 42-day"))
            } else {
                StatePill("▼ \(magnitude) vs 42-day", tone: .neutral, showsDot: false)
                    .accessibilityLabel(Text("down \(magnitude) vs 42-day"))
            }
        }
    }

    /// The canonical segmented pill, announced as one adjustable control (the Trends range treatment).
    private var periodPicker: some View {
        SegmentedPillControl(TrainingLoadLayout.periods, selection: $period) { TrainingLoadLayout.label($0) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Displayed history")
            .accessibilityValue("\(period) days")
            .accessibilityAdjustableAction { direction in
                let all = TrainingLoadLayout.periods
                guard let index = all.firstIndex(of: period) else { return }
                switch direction {
                case .increment: period = all[min(index + 1, all.count - 1)]
                case .decrement: period = all[max(index - 1, 0)]
                default: break
                }
            }
            // Direct choices for Voice Control and Switch Control, which cannot swipe an adjustable.
            .accessibilityActions {
                ForEach(TrainingLoadLayout.periods, id: \.self) { option in
                    Button(String(localized: "Last \(option) days")) { period = option }
                }
            }
    }

    /// The scrubbed (or newest) day under the chart: Acute | Chronic | Balance in the three-column strip, then that
    /// day's recorded Effort. A day with no observation says so rather than showing zeros.
    private func dayStrip(_ focus: TrainingLoadDay?) -> some View {
        let missing = WidgetMetrics.missingValue
        let acute: String = focus.map { number($0.acute) } ?? missing
        let chronic: String = focus.map { number($0.chronic) } ?? missing
        let balance: String = focus.map { signed($0.balance) } ?? missing
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            StatFooter(items: [
                (String(localized: "Acute · 7d"), acute),
                (String(localized: "Chronic · 42d"), chronic),
                (String(localized: "Balance"), balance),
            ], style: .prominent)
            if let focus {
                Text("Recorded Effort \(number(StrainScale.displayValue(fromStored: focus.point.load)))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("No modeled observation for this day. Missing values stay separate from recorded zero Effort.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("trends.trainingLoad.inspector")
    }

    private func chartSummary(_ focus: TrainingLoadDay?) -> String {
        guard let focus else { return String(localized: "No observation on the selected day") }
        let day = focus.date.formatted(weekdayFormat)
        return String(localized: "\(day): chronic \(number(focus.chronic)), acute \(number(focus.acute)), balance \(signed(focus.balance))")
    }

    // MARK: Dated values

    private func datedValues(_ points: [TrainingLoadDay]) -> some View {
        TrainingLoadDisclosure("Dated values", isExpanded: $showRows) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(points.reversed().enumerated()), id: \.element.id) { index, day in
                    if index > 0 { FlatRowSeparator() }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: day.date.formatted(dayFormat))
                            .font(StrandFont.footnote.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Acute \(number(day.acute)) · Chronic \(number(day.chronic)) · Balance \(signed(day.balance))")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, NoopMetrics.space2)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Method and links

    /// Plain words, no model names. The 14 and 42 are the engine's own thresholds (`Configuration.standard`).
    private var methodSection: some View {
        let standard = TrainingLoadEngine.Configuration.standard
        return TrainingLoadDisclosure("How this is calculated", isExpanded: $showMethod) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Acute load is a weighted average of your daily Effort that leans on the last 7 days. Chronic load does the same over about 42 days, so it moves more slowly. Changing the chart range never changes these numbers.")
                Text("Balance is chronic load minus acute load.")
                Text("Load appears after \(standard.minimumDays) days of recorded Effort and settles after \(standard.establishedDays).")
                Text("A gap of up to two days is smoothed over and is not drawn as a measurement. A longer gap starts the history again.")
                Text("Dates use the Trends source time zone: \(request.key.timeZoneIdentifier)")
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, NoopMetrics.space2)
        }
    }

    private var workoutsLink: some View {
        NavigationLink { WorkoutsView() } label: {
            TrainingLoadLinkRow(title: String(localized: "Workout history"),
                                subtitle: String(localized: "The sessions behind your daily Effort"),
                                symbol: "figure.run", tint: .workout)
        }
        .buttonStyle(FlatRowPressStyle())
        .accessibilityIdentifier("trends.trainingLoad.workouts")
    }

    // MARK: States

    /// Loading, unavailable and error keep the load section's shape: eyebrow and pill, "—" for the value, a ghost rail
    /// where the chart goes, and one line of copy. Nothing is invented.
    private func statusSection(trailing: EyebrowTrailing, caption: String, detail: Text, showsRail: Bool) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Load over time", systemImage: "flame.fill", tint: .effort, trailing: trailing)
            HeroValue(value: WidgetMetrics.missingValue, caption: caption, captionPlacement: .below)
            if showsRail { TrendsGhostRail(height: TrainingLoadLayout.plotHeight) }
            detail
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// No estimate yet: the load section's shape with "—" and a ghost rail. When it is only a matter of days, say how
    /// many more (the one explicit insufficient-history state), with a quiet progress rule; otherwise the reason.
    private func unavailableSection(_ result: TrainingLoadEngine.Result) -> some View {
        let needsDays = result.unavailableReason == .notEnoughContiguousDays
        let remaining = TrainingLoadCopy.remainingDays(contiguousDays: result.contiguousDays)
        let target = TrainingLoadEngine.Configuration.standard.minimumDays
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            statusSection(trailing: eyebrowPill(result),
                          caption: TrainingLoadCopy.unavailableTitle(result.unavailableReason),
                          detail: Text(verbatim: needsDays ? TrainingLoadCopy.needsMoreDays(remaining)
                                                           : unavailableDetail(result)),
                          showsRail: true)
            if needsDays {
                TrainingLoadProgressRule(fraction: Double(result.contiguousDays) / Double(max(target, 1)))
            }
        }
    }

    private var loadingState: some View {
        statusSection(trailing: .pill("Loading", tone: .neutral),
                      caption: String(localized: "Reading dated load history"),
                      detail: Text("Using the same source and date as Trends."), showsRail: true)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Reading dated load history")
    }

    private func failedState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            statusSection(trailing: .pill("Unavailable", tone: .warning),
                          caption: String(localized: "Could not read this history"),
                          detail: Text(verbatim: message), showsRail: true)
            Button { readID = UUID() } label: {
                Label("Try again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryPillButtonStyle())
        }
    }

    /// The one dead end: the records now belong to another source, so these values cannot be shown as current.
    private var sourceChangedState: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            statusSection(trailing: .pill("Out of date", tone: .warning),
                          caption: String(localized: "The source records changed"),
                          detail: Text("Return to Trends and open Training load again to use the current records."),
                          showsRail: false)
            Button("Back to Trends") { dismiss() }
                .buttonStyle(SecondaryPillButtonStyle())
        }
    }

    private func unavailableDetail(_ result: TrainingLoadEngine.Result) -> String {
        switch result.unavailableReason {
        case .missingTargetDay: String(localized: "There is no usable Effort value for the selected end date.")
        case .notEnoughContiguousDays: TrainingLoadCopy.needsMoreDays(
            TrainingLoadCopy.remainingDays(contiguousDays: result.contiguousDays))
        case .noData: String(localized: "No daily Effort history is available for this source.")
        default: String(localized: "The source history cannot produce a valid load estimate. Check the records in Trends.")
        }
    }

    // MARK: Data

    /// Observed days inside the displayed period. A calendar gap starts a new run, so no line crosses a day that was
    /// not measured; a run of one day is flagged so the chart can draw it as a dot.
    private func loadDays(_ result: TrainingLoadEngine.Result) -> [TrainingLoadDay] {
        let start = rangeStart
        var observed: [(point: TrainingLoadEngine.Point, date: Date, run: Int)] = []
        var run = 0
        var previous: Date?
        for point in result.points {
            guard let day = date(point.day), day >= start else { continue }
            if let previous, (calendar.dateComponents([.day], from: previous, to: day).day ?? 0) > 1 { run += 1 }
            previous = day
            observed.append((point: point, date: day, run: run))
        }
        var runLengths: [Int: Int] = [:]
        for item in observed { runLengths[item.run, default: 0] += 1 }
        return observed.map {
            TrainingLoadDay(point: $0.point, date: $0.date, run: $0.run, standsAlone: runLengths[$0.run] == 1)
        }
    }

    private func date(_ key: String) -> Date? {
        let values = key.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2]))
    }
    private func number(_ value: Double) -> String { DrillInFormat.number(value, fractionDigits: 1) }
    /// Never "-0.0" or "+0.0": a balance that rounds to nothing reads "0.0".
    private func signed(_ value: Double) -> String { DrillInFormat.signed(value, fractionDigits: 1) }

    @MainActor private func load() async {
        let trigger = self.trigger
        guard trigger != loadedTrigger, sourceIsCurrent else { return }
        // Another source, day, zone, range or week is a different page: its old values never sit under the new header.
        if let loadedTrigger, !trigger.rereads(loadedTrigger) {
            result = nil
            selection = nil
            // Forget what was loaded too: if the request returns to it before this read finishes, it is read again
            // rather than skipped as already on screen (with nothing on screen).
            self.loadedTrigger = nil
        }
        // Only the first read shows the loading state; a refresh re-reads behind the values already on screen.
        if result == nil { failure = nil }
        let data = await repo.loadCanonicalTrendsData(anchorDay: request.key.anchorDay,
            timeZoneIdentifier: request.key.timeZoneIdentifier, rangeDays: request.rangeDays,
            weekOffset: request.key.weekOffset)
        guard !Task.isCancelled, trigger == self.trigger, sourceIsCurrent else { return }
        guard let data else {
            if result == nil { failure = String(localized: "Try reading the selected source again.") }
            return
        }
        guard data.anchorDay == request.key.anchorDay,
              data.timeZoneIdentifier == request.key.timeZoneIdentifier,
              let identity = data.loadIdentity,
              identity.anchorDay == request.key.anchorDay,
              identity.timeZoneIdentifier == request.key.timeZoneIdentifier,
              identity.rangeDays == request.rangeDays,
              identity.weekOffset == request.key.weekOffset else {
            if result == nil {
                failure = String(localized: "The returned history belongs to another range. Return to Trends and try again.")
            }
            return
        }
        let history = Array(data.canonicalDays.filter { $0.day <= request.key.anchorDay }.suffix(TrainingLoadTrendsWindow.days))
        result = TrainingLoadEngine.evaluate(days: history.map { .init(day: $0.day, load: $0.strain) },
                                             through: request.key.anchorDay)
        failure = nil
        loadedTrigger = trigger
    }

    private struct ReadTrigger: Equatable {
        let readID: UUID
        let revision: Int
        let sourceID: String
        let anchorDay: String
        let timeZoneIdentifier: String
        let rangeDays: Int
        let weekOffset: Int

        /// The same request read again (a retry or a refresh), as opposed to another source, day, zone, range or week.
        func rereads(_ other: ReadTrigger) -> Bool {
            sourceID == other.sourceID && anchorDay == other.anchorDay
                && timeZoneIdentifier == other.timeZoneIdentifier
                && rangeDays == other.rangeDays && weekOffset == other.weekOffset
        }
    }
}

// MARK: - Parts

private enum TrainingLoadLayout {
    /// The hero plot height of the #55 widget recipe.
    static let plotHeight: CGFloat = 148
    /// Room under the plot for the date labels.
    static let axisLabelHeight: CGFloat = 24
    static let periods = [28, 42, 90, 180]

    /// Trends' range vocabulary for the same spans (W, M, 3M, 6M): "180D" wrapped to two lines in a segment. VoiceOver
    /// still hears the days ("Last 180 days").
    static func label(_ days: Int) -> String {
        switch days {
        case 28: "4W"
        case 42: "6W"
        case 90: "3M"
        case 180: "6M"
        default: "\(days)D"
        }
    }
}

private struct TrainingLoadDay: Identifiable {
    let point: TrainingLoadEngine.Point
    let date: Date
    /// Observed days with no calendar gap between them share a run; a gap starts the next one.
    let run: Int
    /// The only observed day in its run. A one-point line draws nothing, so the chart marks it with a dot.
    let standsAlone: Bool
    var id: String { point.day }
    var acute: Double { StrainScale.displayValue(fromStored: point.acuteLoad) }
    var chronic: Double { StrainScale.displayValue(fromStored: point.chronicLoad) }
    var balance: Double { StrainScale.displayDelta(fromStored: point.balance) }
}

/// The two roles, drawn the way the #55 chart draws "the value" and "typical": acute is the metric-coloured line, chronic
/// the grey dashed baseline. One definition so the Trends card and the page agree.
private enum TrainingLoadInk {
    static let acute = StrandPalette.strainAccent
    static let chronic = StrandPalette.textSecondary.opacity(0.8)
    static let acuteWidth: CGFloat = 2.4
    static let chronicWidth: CGFloat = 1.6
    static let chronicDash: [CGFloat] = [4, 3]

    static var acuteStyle: StrokeStyle { StrokeStyle(lineWidth: acuteWidth, lineCap: .round, lineJoin: .round) }
    static var chronicStyle: StrokeStyle {
        StrokeStyle(lineWidth: chronicWidth, lineCap: .butt, lineJoin: .round, dash: chronicDash)
    }
    static var wash: LinearGradient {
        LinearGradient(colors: [acute.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom)
    }
}

/// Acute load (metric colour, over a soft wash) against chronic load (grey, dashed), on hairline rails at the recorded high and low with their values on
/// knocked-out plates, and at most four date labels. The labels sit in the overlay so the first and last are pinned flush
/// with the plot's edges rather than truncated.
private struct TrainingLoadChart: View {
    let points: [TrainingLoadDay]
    let domain: ClosedRange<Date>
    let calendar: Calendar
    let focus: TrainingLoadDay?
    let marker: Date?
    @Binding var selection: Date?
    let summary: String
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Room under the plot for the date labels, grown with the text so the plot keeps its height at every size.
    @ScaledMetric(relativeTo: .footnote) private var axisLabelHeight: CGFloat = TrainingLoadLayout.axisLabelHeight

    var body: some View {
        let axisDays = Self.ticks(in: domain, calendar: calendar)
        Chart {
            acuteWash
            chronicLines
            acuteLines
            loneDays
            focusMarks
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartXSelection(value: $selection)
        .chartXAxis {
            AxisMarks(values: axisDays) { _ in
                // Reserves the label row only; the visible labels are drawn in the overlay below.
                AxisValueLabel {
                    Text(verbatim: "Mmm 00").opacity(0).accessibilityHidden(true)
                }
                .font(StrandFont.micro)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: rails.map { [$0.low, $0.high] } ?? []) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.7)).foregroundStyle(StrandPalette.hairline.opacity(0.9))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    ForEach(shownLabels(axisDays), id: \.index) { item in
                        if let x = proxy.position(forX: item.date) {
                            Text(verbatim: axisLabel(for: item.date))
                                .font(StrandFont.micro)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize()
                                .frame(width: 0, alignment: Self.labelAlignment(item.index, of: axisDays.count))
                                .offset(x: x + plot.minX, y: plot.maxY + 4)
                        }
                    }
                    railLabels(proxy: proxy, plot: plot)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .frame(height: TrainingLoadLayout.plotHeight + axisLabelHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Acute and chronic load from observed daily Effort")
        .accessibilityValue(Text(verbatim: summary))
        .accessibilityIdentifier("trends.trainingLoad.chart")
    }

    /// The soft wash under the acute line, as in the #55 chart.
    @ChartContentBuilder private var acuteWash: some ChartContent {
        ForEach(points) { day in
            AreaMark(x: .value("Day", day.date), yStart: .value("Floor", yDomain.lowerBound),
                     yEnd: .value("Load", day.acute), series: .value("Series", "wash-\(day.run)"))
                .foregroundStyle(TrainingLoadInk.wash)
                .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder private var chronicLines: some ChartContent {
        ForEach(points) { day in
            LineMark(x: .value("Day", day.date), y: .value("Load", day.chronic),
                     series: .value("Series", "chronic-\(day.run)"))
                .foregroundStyle(TrainingLoadInk.chronic)
                .lineStyle(TrainingLoadInk.chronicStyle)
                .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder private var acuteLines: some ChartContent {
        ForEach(points) { day in
            LineMark(x: .value("Day", day.date), y: .value("Load", day.acute),
                     series: .value("Series", "acute-\(day.run)"))
                .foregroundStyle(TrainingLoadInk.acute)
                .lineStyle(TrainingLoadInk.acuteStyle)
                .interpolationMethod(.monotone)
        }
    }

    /// A day observed on its own between gaps: a small dot on each line, since a one-point line draws nothing.
    @ChartContentBuilder private var loneDays: some ChartContent {
        ForEach(points.filter(\.standsAlone)) { day in
            PointMark(x: .value("Day", day.date), y: .value("Load", day.chronic))
                .foregroundStyle(TrainingLoadInk.chronic)
                .symbolSize(18)
            PointMark(x: .value("Day", day.date), y: .value("Load", day.acute))
                .foregroundStyle(TrainingLoadInk.acute)
                .symbolSize(24)
        }
    }

    /// The scrubbed day's rule, and the endpoint dot (with its canvas ring) on the day the hero reads. While scrubbing,
    /// the chronic line gets a small dot too, so both strip values can be found on the chart.
    @ChartContentBuilder private var focusMarks: some ChartContent {
        if let marker {
            RuleMark(x: .value("Selected day", marker))
                .foregroundStyle(StrandPalette.hairlineStrong)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        if let focus {
            if marker != nil {
                PointMark(x: .value("Day", focus.date), y: .value("Load", focus.chronic))
                    .foregroundStyle(StrandPalette.appCanvas)
                    .symbolSize(60)
                PointMark(x: .value("Day", focus.date), y: .value("Load", focus.chronic))
                    .foregroundStyle(TrainingLoadInk.chronic)
                    .symbolSize(26)
            }
            PointMark(x: .value("Day", focus.date), y: .value("Load", focus.acute))
                .foregroundStyle(StrandPalette.appCanvas)
                .symbolSize(110)
            PointMark(x: .value("Day", focus.date), y: .value("Load", focus.acute))
                .foregroundStyle(TrainingLoadInk.acute)
                .symbolSize(56)
        }
    }

    // MARK: Scale and rails

    /// The recorded low and high across both lines: where the rails sit.
    private var rails: (low: Double, high: Double)? {
        let values = points.flatMap { [$0.acute, $0.chronic] }.filter(\.isFinite)
        guard let low = values.min(), let high = values.max() else { return nil }
        return (low, high)
    }

    /// The data's own range with room above the high rail and below the low rail for their values, never below zero, so
    /// the lines use the plot instead of its top third.
    private var yDomain: ClosedRange<Double> {
        guard let rails else { return 0...1 }
        let pad = max(rails.high - rails.low, 1) * 0.2
        let lower = max(0, rails.low - pad)
        return lower...max(lower + 1, rails.high + pad)
    }

    /// The high value rides above its rail and the low value under its own, at the trailing edge, so neither lands on a
    /// line (the data sits between the rails). Hidden at the accessibility sizes, where the plate is as tall as the
    /// air around the rail; the page's strip and the hero carry the values there.
    @ViewBuilder
    private func railLabels(proxy: ChartProxy, plot: CGRect) -> some View {
        if !typeSize.isAccessibilitySize, let rails,
           let highY = proxy.position(forY: rails.high), let lowY = proxy.position(forY: rails.low) {
            railLabel(rails.high)
                .frame(width: plot.width, height: max(plot.minY + highY - 2, 0), alignment: .bottomTrailing)
                .offset(x: plot.minX)
            if lowY - highY > 16 {
                railLabel(rails.low)
                    .frame(width: plot.width, height: max(plot.maxY - plot.minY - lowY, 0) + 2, alignment: .topTrailing)
                    .offset(x: plot.minX, y: plot.minY + lowY + 2)
            }
        }
    }

    private func railLabel(_ value: Double) -> some View {
        Text(verbatim: DrillInFormat.number(value, fractionDigits: 1))
            .font(StrandFont.micro)
            .monospacedDigit()
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize()
            .background {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(StrandPalette.appCanvas.opacity(0.88))
                    .padding(.horizontal, -3)
                    .padding(.vertical, -1)
            }
            .padding(.trailing, 10)
    }

    // MARK: Date axis

    /// "Today" for the anchor day when it is today, else "Oct 15", in the Trends source time zone.
    private func axisLabel(for date: Date) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        return date.formatted(Date.FormatStyle(locale: .autoupdatingCurrent, calendar: calendar,
                                               timeZone: calendar.timeZone).month(.abbreviated).day())
    }

    /// At most `WidgetMetrics.maxXAxisLabels` days, spread evenly from the first day to the last, each on a midnight.
    private static func ticks(in domain: ClosedRange<Date>, calendar: Calendar) -> [Date] {
        let count = WidgetMetrics.maxXAxisLabels
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return [domain.upperBound] }
        var ticks: [Date] = []
        for index in 0..<count {
            let raw = domain.lowerBound.addingTimeInterval(span * Double(index) / Double(max(count - 1, 1)))
            let day = min(max(calendar.startOfDay(for: raw.addingTimeInterval(12 * 60 * 60)), domain.lowerBound),
                          domain.upperBound)
            if let last = ticks.last, calendar.isDate(last, inSameDayAs: day) { continue }
            ticks.append(day)
        }
        return ticks
    }

    /// The labels drawn: all of them, or at the accessibility sizes only the first and last, which are what fit side by
    /// side at that size (the Trends hero chart's rule).
    private func shownLabels(_ ticks: [Date]) -> [(index: Int, date: Date)] {
        let all = ticks.enumerated().map { (index: $0.offset, date: $0.element) }
        guard typeSize.isAccessibilitySize, all.count > 2, let first = all.first, let last = all.last else { return all }
        return [first, last]
    }

    /// The first label starts at its tick and the last ends at it, so neither runs past the plot.
    private static func labelAlignment(_ index: Int, of count: Int) -> Alignment {
        if index == 0 { return .leading }
        if index == count - 1 { return .trailing }
        return .center
    }
}

/// The Trends card's chart: the same two roles as the page's chart, with no axes. Acute in the metric colour over a wash,
/// chronic grey and dashed. Decorative: the card's one VoiceOver summary carries the figures.
struct TrainingLoadSparkChart: View {
    let acute: [Double]
    let chronic: [Double]

    var body: some View {
        Chart {
            ForEach(Array(acute.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("Day", index), yStart: .value("Floor", yDomain.lowerBound),
                         yEnd: .value("Load", value))
                    .foregroundStyle(TrainingLoadInk.wash)
                    .interpolationMethod(.monotone)
            }
            ForEach(Array(chronic.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("Day", index), y: .value("Load", value), series: .value("Series", "chronic"))
                    .foregroundStyle(TrainingLoadInk.chronic)
                    .lineStyle(TrainingLoadInk.chronicStyle)
                    .interpolationMethod(.monotone)
            }
            ForEach(Array(acute.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("Day", index), y: .value("Load", value), series: .value("Series", "acute"))
                    .foregroundStyle(TrainingLoadInk.acute)
                    .lineStyle(TrainingLoadInk.acuteStyle)
                    .interpolationMethod(.monotone)
            }
            if let last = acute.last {
                PointMark(x: .value("Day", acute.count - 1), y: .value("Load", last))
                    .foregroundStyle(StrandPalette.appCanvas)
                    .symbolSize(90)
                PointMark(x: .value("Day", acute.count - 1), y: .value("Load", last))
                    .foregroundStyle(TrainingLoadInk.acute)
                    .symbolSize(44)
            }
        }
        .chartXScale(domain: 0...max(acute.count - 1, 1))
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 76)
        .accessibilityHidden(true)
    }

    private var yDomain: ClosedRange<Double> {
        let values = (acute + chronic).filter(\.isFinite)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max(high - low, 1) * 0.12
        let lower = max(0, low - pad)
        return lower...max(lower + 1, high + pad)
    }
}

/// What the two lines are: a solid metric-coloured key and a dashed grey one, so they read apart before a word is read.
struct TrainingLoadLegend: View {
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space3) { keys }
            VStack(alignment: .leading, spacing: NoopMetrics.space1) { keys }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var keys: some View {
        key("Acute · 7-day", dashed: false)
        key("Chronic · 42-day", dashed: true)
    }

    private func key(_ title: LocalizedStringKey, dashed: Bool) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            Path { path in
                path.move(to: CGPoint(x: 1, y: 1.5))
                path.addLine(to: CGPoint(x: 15, y: 1.5))
            }
            .stroke(dashed ? TrainingLoadInk.chronic : TrainingLoadInk.acute,
                    style: dashed ? TrainingLoadInk.chronicStyle : TrainingLoadInk.acuteStyle)
            .frame(width: 16, height: 3)
            Text(title).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

/// A thin rule filling toward the days a load estimate needs. Decorative: the line of words beside it says the same.
private struct TrainingLoadProgressRule: View {
    let fraction: Double

    var body: some View {
        let shown = min(1, max(0, fraction))
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(StrandPalette.chipFill)
                Capsule(style: .continuous).fill(StrandPalette.strainAccent)
                    .frame(width: proxy.size.width * CGFloat(shown))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}

/// A flat row that opens another page: an inline glyph in its metric colour (no disc), a title and what is behind it, and
/// a chevron, on a row at least 44pt tall. Reads as one element to VoiceOver.
private struct TrainingLoadLinkRow: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint: DomainTint = .accent

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(tint.accent)
                .frame(width: WidgetMetrics.metricIconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NoopMetrics.space2)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title). \(subtitle)"))
    }
}

/// A #55 disclosure row: a subhead-semibold title and a tertiary chevron that turns, on a row at least 44pt tall. The
/// body folds in with the interactive spring, or at once under Reduce Motion.
private struct TrainingLoadDisclosure<Content: View>: View {
    let title: LocalizedStringKey
    @Binding var isExpanded: Bool
    let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: LocalizedStringKey, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : StrandMotion.interactive) { isExpanded.toggle() }
            } label: {
                HStack(spacing: NoopMetrics.space2) {
                    Text(title)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: NoopMetrics.space2)
                    Image(systemName: "chevron.down")
                        .font(StrandFont.micro.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("Expanded") : Text("Collapsed"))
            if isExpanded {
                content()
                    .padding(.bottom, NoopMetrics.space1)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            }
        }
    }
}
