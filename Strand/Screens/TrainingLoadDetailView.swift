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
        .accessibilityHint("Opens the load chart, daily effort and how it is calculated")
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
/// Flat #55 drill-in: the Trends training load card, zoomed in. Its eyebrow, prominent Chronic | Acute | Balance strip
/// and chart in the card's order (the strip reads the day under the finger), the range control, the recorded Effort
/// each day, the workout link, and the dated values and method behind disclosures, one hairline between each.
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                DrillInSeparator()
                effortSection(points)
            } else {
                unavailableSection(result)
            }
            DrillInSeparator()
            workoutsLink
            if result.isAvailable {
                DrillInSeparator()
                datedValues(points)
            }
            FlatRowSeparator()
            methodSection
            Text("These values describe recorded daily Effort. They do not change Readiness or provide medical clearance.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, NoopMetrics.space2)
        }
    }

    // MARK: Load

    /// The Trends card, zoomed in: its eyebrow, its prominent Chronic | Acute | Balance strip and its chart, in the
    /// same order, each reading the day under the finger (the newest day until the chart is touched).
    private func loadSection(_ result: TrainingLoadEngine.Result, points: [TrainingLoadDay]) -> some View {
        let focus = focusDay(in: points)
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(title: eyebrowTitle(focus), systemImage: "flame.fill", tint: .strain,
                           trailing: eyebrowPill(result))
            VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
                hero(focus)
                loadChart(points, focus: focus)
            }
            TrendsControlRow(
                leading: { _ in
                    Text("Last \(period) days")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                },
                trailing: { periodPicker }
            )
        }
    }

    /// "Today" for the newest day, else the scrubbed day ("Fri, Oct 9").
    private func eyebrowTitle(_ focus: TrainingLoadDay?) -> String {
        let day = selectedDay ?? focus?.date ?? anchor
        return calendar.isDateInToday(day) ? String(localized: "Today") : day.formatted(weekdayFormat)
    }

    private func eyebrowPill(_ result: TrainingLoadEngine.Result) -> EyebrowTrailing {
        .pill(LocalizedStringKey(TrainingLoadCopy.status(result.state, reason: result.unavailableReason,
                                                         observedDays: result.contiguousDays)),
              tone: TrainingLoadCopy.tone(result.state))
    }

    /// The scrubbed day when it has a modeled value, else the newest modeled day while nothing is scrubbed.
    private func focusDay(in points: [TrainingLoadDay]) -> TrainingLoadDay? {
        guard let day = selectedDay else { return points.last }
        return points.first { calendar.isDate($0.date, inSameDayAs: day) }
    }

    /// The card's strip, with its values changing in place while the chart is scrubbed.
    private func hero(_ focus: TrainingLoadDay?) -> some View {
        let missing = WidgetMetrics.missingValue
        let chronic: String = focus.map { number($0.chronic) } ?? missing
        let acute: String = focus.map { number($0.acute) } ?? missing
        let balance: String = focus.map { signed($0.balance) } ?? missing
        return StatFooter(items: [
            (String(localized: "Chronic · 42d"), chronic),
            (String(localized: "Acute · 7d"), acute),
            (String(localized: "Balance"), balance),
        ], style: .prominent)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focus?.id)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: chartSummary(focus)))
            .accessibilityIdentifier("trends.trainingLoad.inspector")
    }

    /// The Trends card's chart (acute solid over a wash, chronic at 45%), taller, on the real calendar and scrubbable.
    private func loadChart(_ points: [TrainingLoadDay], focus: TrainingLoadDay?) -> some View {
        let axis = Self.ticks(in: rangeStart...anchor, calendar: calendar).map {
            TrendsLoadChart.Timeline.AxisLabel(date: $0, text: axisLabel(for: $0))
        }
        let timeline = TrendsLoadChart.Timeline(days: points.map(\.date), domain: chartDomain, calendar: calendar,
                                                axisLabels: axis, valueLabel: { number($0) })
        return TrendsLoadChart(chronic: points.map(\.chronic), acute: points.map(\.acute), tint: .strain,
                               startLabel: "", endLabel: "", plotHeight: TrainingLoadLayout.plotHeight,
                               timeline: timeline, selection: snappedSelection,
                               accessibilitySummary: chartSummary(focus))
            .accessibilityIdentifier("trends.trainingLoad.chart")
    }

    /// Half a day of air on each side, so the first and last days' bars below are whole.
    private var chartDomain: ClosedRange<Date> {
        rangeStart.addingTimeInterval(-TrainingLoadLayout.halfDay)...anchor.addingTimeInterval(TrainingLoadLayout.halfDay)
    }

    /// Both charts scrub the same day: this binding reads the snapped day and writes whatever either chart picks.
    private var snappedSelection: Binding<Date?> {
        Binding(get: { selectedDay }, set: { selection = $0 })
    }

    /// The canonical segmented pill, announced as one adjustable control (the Trends range treatment).
    private var periodPicker: some View {
        // Tint pending the range lane: `.segmentedPillTint(StrandPalette.strainAccent)` goes on this control.
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

    private func chartSummary(_ focus: TrainingLoadDay?) -> String {
        guard let focus else { return String(localized: "No observation on the selected day") }
        let day = focus.date.formatted(weekdayFormat)
        return String(localized: "\(day): chronic \(number(focus.chronic)), acute \(number(focus.acute)), balance \(signed(focus.balance))")
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

    // MARK: Daily effort

    /// What the load is built from: each day's recorded Effort over the same range, on the same days as the chart
    /// above, sharing its scrub. Only values this page already read; a day with none is a faint tick.
    private func effortSection(_ points: [TrainingLoadDay]) -> some View {
        let byDay = Dictionary(points.map { ($0.date, $0.effort) }, uniquingKeysWith: { _, last in last })
        let bars: [TrainingLoadEffortBars.Bar] = (0..<period).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: rangeStart) else { return nil }
            return .init(date: day, effort: byDay[day])
        }
        let average: Double? = points.isEmpty ? nil : points.map(\.effort).reduce(0, +) / Double(points.count)
        let highlight = selectedDay ?? points.last?.date
        let spoken: String = {
            guard let day = highlight else { return "" }
            let name = day.formatted(weekdayFormat)
            guard let effort = byDay.first(where: { calendar.isDate($0.key, inSameDayAs: day) })?.value else {
                return String(localized: "\(name): no Effort recorded")
            }
            return name + ", " + String(localized: "Recorded Effort \(number(effort))")
        }()
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Daily effort", systemImage: "flame.fill", tint: .strain,
                           trailing: average.map { EyebrowTrailing.text(String(localized: "avg \(number($0))")) } ?? .none)
            TrainingLoadEffortBars(bars: bars, domain: chartDomain, calendar: calendar, highlight: highlight,
                                   selection: $selection, summary: spoken)
        }
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

    // MARK: Method and links

    /// In plain words, and checked against `TrainingLoadEngine`: both lines are exponentially weighted averages of
    /// daily Effort with 7- and 42-day time constants, seeded by the mean of the first seven recorded days;
    /// balance is chronic minus acute; up to two missing days in a row decay the lines as zero-load days.
    private var methodSection: some View {
        TrainingLoadDisclosure("How this is calculated", isExpanded: $showMethod) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Both lines are running averages of your daily Effort. Each new day pulls the line toward it and older days fade gradually, so recent days count most.")
                Text("Acute fades over about a week and reacts quickly. Chronic fades over about six weeks and moves slowly. The range you pick changes what is drawn, never these numbers.")
                Text("Balance is chronic minus acute. Above zero, recent effort is lighter than your longer-term level; below zero, it is heavier.")
                Text("The first seven recorded days are averaged to start both lines. Load appears after 14 recorded days and is marked Established at 42.")
                Text("Up to two missing days in a row count as zero Effort and are not drawn. A longer gap starts the history over. A recorded zero is a real rest day.")
                Text("Based on daily Effort. Descriptive only; it does not change Readiness.")
                Text("Dates use the Trends source time zone: \(request.key.timeZoneIdentifier)")
            }
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A flat #55 link row: an inline glyph in the workout colour, what is behind it, a chevron. No disc.
    private var workoutsLink: some View {
        NavigationLink { WorkoutsView() } label: {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: "figure.run")
                    .font(StrandFont.caption)
                    .foregroundStyle(DomainTint.workout.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Workout history")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("The sessions behind your daily Effort")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
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
            .accessibilityLabel(Text(verbatim: String(localized: "Workout history") + ". " + String(localized: "The sessions behind your daily Effort")))
        }
        .buttonStyle(FlatRowPressStyle())
        .accessibilityIdentifier("trends.trainingLoad.workouts")
    }

    // MARK: States

    /// Not enough history: one explicit state in the card's own eyebrow, in place of the numbers and the charts.
    private func unavailableSection(_ result: TrainingLoadEngine.Result) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Training load", systemImage: "flame.fill", tint: .strain, trailing: eyebrowPill(result))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: unavailableTitle(result))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: unavailableDetail(result))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func unavailableTitle(_ result: TrainingLoadEngine.Result) -> String {
        guard result.unavailableReason == .notEnoughContiguousDays else {
            return TrainingLoadCopy.unavailableTitle(result.unavailableReason)
        }
        let remaining = max(1, TrainingLoadEngine.Configuration.standard.minimumDays - result.contiguousDays)
        return remaining == 1
            ? String(localized: "Needs 1 more day of workouts")
            : String(localized: "Needs \(remaining) more days of workouts")
    }

    private func unavailableDetail(_ result: TrainingLoadEngine.Result) -> String {
        switch result.unavailableReason {
        case .missingTargetDay: String(localized: "There is no usable Effort value for the selected end date.")
        case .notEnoughContiguousDays: String(localized: "Training load starts after 14 days of recorded Effort.")
        case .noData: String(localized: "No daily Effort history is available for this source.")
        default: String(localized: "The source history cannot produce a valid load estimate. Check the records in Trends.")
        }
    }

    /// Loading and error keep the load section's shape: the eyebrow and pill, "—" for the value, a ghost rail where
    /// the chart goes, and one line of copy. Nothing is invented.
    private func statusSection(trailing: EyebrowTrailing, caption: String, detail: Text, showsRail: Bool) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Training load", systemImage: "flame.fill", tint: .strain, trailing: trailing)
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
    /// The Trends card's chart, zoomed in: about 200pt against the card's 76.
    static let plotHeight: CGFloat = 200
    static let barsHeight: CGFloat = 96
    static let halfDay: TimeInterval = 12 * 60 * 60
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
    /// The day's recorded Effort on the 0...21 display scale.
    var effort: Double { StrainScale.displayValue(fromStored: point.load) }
}

/// One bar per calendar day of the range, in the strain colour: the day the strip above reads is solid, the rest are
/// quiet, and a day with no Effort is a faint tick on the baseline. Drag to scrub, sharing the chart above's selection.
private struct TrainingLoadEffortBars: View {
    struct Bar: Identifiable {
        let date: Date
        /// Display-scale Effort, nil when nothing was recorded that day.
        let effort: Double?
        var id: Date { date }
    }

    let bars: [Bar]
    let domain: ClosedRange<Date>
    let calendar: Calendar
    let highlight: Date?
    @Binding var selection: Date?
    let summary: String

    /// A bar is 70% of its day, centred on it, so it sits exactly under that day's point on the chart above.
    private let halfBar: TimeInterval = 0.35 * 24 * 60 * 60

    var body: some View {
        let top = max(bars.compactMap(\.effort).max() ?? 1, 1) * 1.08
        let tick = top * 0.035
        Chart {
            RuleMark(y: .value("Baseline", 0))
                .foregroundStyle(StrandPalette.hairline)
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(bars) { bar in
                let isHighlighted = highlight.map { calendar.isDate(bar.date, inSameDayAs: $0) } ?? false
                if let effort = bar.effort, effort > 0 {
                    RectangleMark(xStart: .value("Day", bar.date.addingTimeInterval(-halfBar)),
                                  xEnd: .value("Day end", bar.date.addingTimeInterval(halfBar)),
                                  yStart: .value("Floor", 0), yEnd: .value("Effort", effort))
                        .cornerRadius(1.5)
                        .foregroundStyle(StrandPalette.strainAccent.opacity(isHighlighted ? 1 : 0.4))
                } else {
                    RectangleMark(xStart: .value("Day", bar.date.addingTimeInterval(-halfBar)),
                                  xEnd: .value("Day end", bar.date.addingTimeInterval(halfBar)),
                                  yStart: .value("Floor", 0), yEnd: .value("Tick", tick))
                        .foregroundStyle(isHighlighted ? StrandPalette.textTertiary : StrandPalette.hairlineStrong)
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...top)
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXSelection(value: $selection)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .frame(height: TrainingLoadLayout.barsHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily Effort over the selected range")
        .accessibilityValue(Text(verbatim: summary))
        .accessibilityIdentifier("trends.trainingLoad.effort")
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
