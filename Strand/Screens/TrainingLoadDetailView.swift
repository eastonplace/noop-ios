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
        .accessibilityHint("Opens dated training load, coverage and calculation details")
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
            default: return String(localized: "Not ready")
            }
        }
    }

    static func tone(_ state: TrainingLoadEngine.State) -> StrandTone {
        state == .established ? .positive : .neutral
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
/// Flat #55 drill-in: the load section leads with its eyebrow, state pill and the chronic value, then the chart, the
/// period control, a flat inspector and the dated values; coverage, the method and the workout link follow, one
/// hairline between each.
struct TrainingLoadDetailView: View {
    let request: TrainingLoadDetailRequest
    /// Gregorian, in the Trends source time zone. Built once rather than on every body pass.
    private let calendar: Calendar
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
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
                statusSection(trailing: eyebrowPill(result),
                              caption: TrainingLoadCopy.unavailableTitle(result.unavailableReason),
                              detail: Text(verbatim: unavailableDetail(result)), showsRail: true)
            }
            DrillInSeparator()
            coverageSection(result)
            DrillInSeparator()
            methodSection
            DrillInSeparator()
            workoutsLink
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
        let chronic = result.chronicLoad.map { number(StrainScale.displayValue(fromStored: $0)) }
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Load over time", systemImage: "flame.fill", tint: .effort, trailing: eyebrowPill(result))
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HeroValue(value: chronic ?? WidgetMetrics.missingValue,
                          caption: String(localized: "Chronic · 42d"), captionPlacement: .below)
                Text("See how recent effort compares with your longer baseline.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            TrainingLoadChart(points: points, domain: rangeStart...anchor, calendar: calendar, focus: focus,
                              marker: selectedDay, selection: $selection, summary: chartSummary(focus))
            legend
            TrendsControlRow(
                leading: { _ in
                    Text("Last \(period) days")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                },
                trailing: { periodPicker }
            )
            inspector(focus)
            datedValues(points)
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

    /// The same encoding as the Trends card: acute bright, chronic at 45%.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: NoopMetrics.space3) { legendKeys }
            VStack(alignment: .leading, spacing: NoopMetrics.space1) { legendKeys }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var legendKeys: some View {
        legendKey("Acute · 7-day", opacity: 1)
        legendKey("Chronic · 42-day", opacity: 0.45)
    }

    private func legendKey(_ title: LocalizedStringKey, opacity: Double) -> some View {
        HStack(spacing: NoopMetrics.space1) {
            Capsule(style: .continuous)
                .fill(StrandPalette.strainAccent.opacity(opacity))
                .frame(width: 12, height: 3)
            Text(title).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// The canonical segmented pill, announced as one adjustable control (the Trends range treatment).
    private var periodPicker: some View {
        SegmentedPillControl(TrainingLoadLayout.periods, selection: $period) { "\($0)D" }
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

    /// The scrubbed (or newest) day, flat: its date, the card's three values in the card's order, and its Effort.
    private func inspector(_ focus: TrainingLoadDay?) -> some View {
        let day = selectedDay ?? focus?.date ?? anchor
        let missing = WidgetMetrics.missingValue
        let chronic: String = focus.map { number($0.chronic) } ?? missing
        let acute: String = focus.map { number($0.acute) } ?? missing
        let balance: String = focus.map { signed($0.balance) } ?? missing
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(verbatim: day.formatted(weekdayFormat))
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            StatFooter(items: [
                (String(localized: "Chronic · 42d"), chronic),
                (String(localized: "Acute · 7d"), acute),
                (String(localized: "Balance"), balance),
            ], style: .prominent)
            if let focus {
                Text("Recorded Effort \(number(StrainScale.displayValue(fromStored: focus.point.load)))")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            } else {
                Text("No modeled observation for this day. Missing values stay separate from recorded zero Effort.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
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
                        Text("Chronic \(number(day.chronic)) · Acute \(number(day.acute)) · Balance \(signed(day.balance))")
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

    // MARK: Coverage

    /// Observed days, calendar span and coverage as one flat strip ("—" when nothing was modeled), plus progress
    /// toward the next threshold while the model is still building.
    private func coverageSection(_ result: TrainingLoadEngine.Result) -> some View {
        let modeled = result.spanDays > 0
        let missing = WidgetMetrics.missingValue
        let observed: String = modeled ? result.contiguousDays.formatted() : missing
        let span: String = modeled ? result.spanDays.formatted() : missing
        var coverage: String = missing
        if let share = result.coverage { coverage = share.formatted(.percent.precision(.fractionLength(0))) }
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("History coverage", systemImage: "calendar", tint: .neutral)
            StatFooter(items: [
                (String(localized: "Observed days"), observed),
                (String(localized: "Calendar days"), span),
                (String(localized: "Coverage"), coverage),
            ])
            if let target = thresholdTarget(result) {
                thresholdProgress(observed: result.contiguousDays, target: target)
            }
            Text("The model needs 14 observed days to begin and 42 to reach its established state. Gaps of up to two days can remain in the modeled span.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The threshold the model is working toward: 14 observed days to begin, 42 to be established. Nil once it is
    /// established, or when the run itself is not measured (no data, no value on the end date).
    private func thresholdTarget(_ result: TrainingLoadEngine.Result) -> Int? {
        let standard = TrainingLoadEngine.Configuration.standard
        switch result.state {
        case .established: return nil
        case .building: return standard.establishedDays
        case .unavailable: return result.unavailableReason == .notEnoughContiguousDays ? standard.minimumDays : nil
        }
    }

    private func thresholdProgress(observed: Int, target: Int) -> some View {
        let fraction = min(1, max(0, Double(observed) / Double(max(target, 1))))
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("Building · \(observed) of \(target) observed days")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous).fill(StrandPalette.chipFill)
                    Capsule(style: .continuous).fill(StrandPalette.strainAccent)
                        .frame(width: proxy.size.width * CGFloat(fraction))
                }
            }
            .frame(height: 4)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Method and links

    private var methodSection: some View {
        TrainingLoadDisclosure("How this is calculated", isExpanded: $showMethod) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Both lines use exponentially weighted daily Effort. Recent values carry more weight. Seven and 42 days are model time constants; the chart range does not change them.")
                Text("Balance is chronic load minus acute load. The first seven observed days seed both lines.")
                Text("For gaps up to two days, the existing model decays its state with zero load internally. Those gap days are not measurements and have no observed chart point. A longer gap starts a new run.")
                Text("Dates use the Trends source time zone: \(request.key.timeZoneIdentifier)")
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var workoutsLink: some View {
        NavigationLink { WorkoutsView() } label: {
            HealthLinkRowLabel(title: String(localized: "Workout history"),
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
        case .notEnoughContiguousDays: String(localized: "This history has \(result.contiguousDays) observed days. The model needs 14 before it can show a load estimate.")
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

/// Acute and chronic load in the Trends card's encoding (acute 2.4pt in the strain tint, chronic 2pt at 45% under it),
/// on hairline axes with at most four date labels. The labels sit in the overlay so the first and last are pinned flush
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
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                // Reserves the label row only; the visible labels are drawn in the overlay below.
                AxisValueLabel {
                    Text(verbatim: "Mmm 00").opacity(0).accessibilityHidden(true)
                }
                .font(StrandFont.footnote)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                AxisValueLabel()
                    .foregroundStyle(StrandPalette.textTertiary)
                    .font(StrandFont.footnote)
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                ZStack(alignment: .topLeading) {
                    ForEach(shownLabels(axisDays), id: \.index) { item in
                        if let x = proxy.position(forX: item.date) {
                            Text(verbatim: axisLabel(for: item.date))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize()
                                .frame(width: 0, alignment: Self.labelAlignment(item.index, of: axisDays.count))
                                .offset(x: x + plot.minX, y: plot.maxY + 4)
                        }
                    }
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

    @ChartContentBuilder private var chronicLines: some ChartContent {
        ForEach(points) { day in
            LineMark(x: .value("Day", day.date), y: .value("Load", day.chronic),
                     series: .value("Series", "chronic-\(day.run)"))
                .foregroundStyle(StrandPalette.strainAccent.opacity(0.45))
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
    }

    @ChartContentBuilder private var acuteLines: some ChartContent {
        ForEach(points) { day in
            LineMark(x: .value("Day", day.date), y: .value("Load", day.acute),
                     series: .value("Series", "acute-\(day.run)"))
                .foregroundStyle(StrandPalette.strainAccent)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
        }
    }

    /// A day observed on its own between gaps: a small dot on each line, since a one-point line draws nothing.
    @ChartContentBuilder private var loneDays: some ChartContent {
        ForEach(points.filter(\.standsAlone)) { day in
            PointMark(x: .value("Day", day.date), y: .value("Load", day.chronic))
                .foregroundStyle(StrandPalette.strainAccent.opacity(0.45))
                .symbolSize(18)
            PointMark(x: .value("Day", day.date), y: .value("Load", day.acute))
                .foregroundStyle(StrandPalette.strainAccent)
                .symbolSize(24)
        }
    }

    /// The scrubbed day's rule, and the endpoint dot (with its canvas ring) on the day the inspector reads.
    @ChartContentBuilder private var focusMarks: some ChartContent {
        if let marker {
            RuleMark(x: .value("Selected day", marker))
                .foregroundStyle(StrandPalette.hairlineStrong)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }
        if let focus {
            PointMark(x: .value("Day", focus.date), y: .value("Load", focus.acute))
                .foregroundStyle(StrandPalette.appCanvas)
                .symbolSize(110)
            PointMark(x: .value("Day", focus.date), y: .value("Load", focus.acute))
                .foregroundStyle(StrandPalette.strainAccent)
                .symbolSize(56)
        }
    }

    /// The data's own range with some air, never below zero, so the two lines use the plot instead of its top third.
    private var yDomain: ClosedRange<Double> {
        let values = points.flatMap { [$0.acute, $0.chronic] }.filter(\.isFinite)
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let pad = max(high - low, 1) * 0.15
        let lower = max(0, low - pad)
        return lower...max(lower + 1, high + pad)
    }

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
