import SwiftUI
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
    /// The eyebrow pill: "Established · 180 days", "Building · 20/42", or why there is no estimate yet. The 42 is the
    /// engine's own constant, never typed here.
    static func status(state: TrainingLoadEngine.State, gap: TrainingLoadPageModel.Gap?, observedDays: Int,
                       configuration: TrainingLoadEngine.Configuration = .standard) -> String {
        switch state {
        case .established:
            return String(localized: "Established · \(observedDays) days")
        case .building:
            return String(localized: "Building · \(observedDays)/\(configuration.establishedDays)")
        case .unavailable:
            switch gap {
            case .noHistory?: return String(localized: "No history")
            case .needsMoreDays?:
                return observedDays > 0
                    ? String(localized: "Building · \(observedDays)/\(configuration.establishedDays)")
                    : String(localized: "Building")
            case .effortNotReady?, .unusable?, nil: return String(localized: "Not ready")
            }
        }
    }

    static func tone(_ state: TrainingLoadEngine.State) -> StrandTone { .neutral }

    /// The one-line reason there is no load estimate.
    static func unavailableTitle(_ gap: TrainingLoadPageModel.Gap?) -> String {
        switch gap {
        case .noHistory?: return String(localized: "No Effort history yet")
        case .needsMoreDays(let remaining)?:
            return remaining == 1
                ? String(localized: "Needs 1 more day of daily Effort")
                : String(localized: "Needs \(remaining) more days of daily Effort")
        case .effortNotReady?: return String(localized: "Today's Effort is not ready")
        case .unusable?, nil: return String(localized: "Training load is not ready")
        }
    }

    static func unavailableDetail(_ gap: TrainingLoadPageModel.Gap?,
                                  configuration: TrainingLoadEngine.Configuration = .standard) -> String {
        switch gap {
        case .noHistory?: return String(localized: "No daily Effort history is available for this source.")
        case .needsMoreDays?:
            return String(localized: "Training load starts after \(configuration.minimumDays) days of recorded Effort.")
        case .effortNotReady?: return String(localized: "There is no usable Effort value for the selected end date.")
        case .unusable?, nil:
            return String(localized: "The source history cannot produce a valid load estimate. Check the records in Trends.")
        }
    }
}

/// A bounded read of the same canonical Trends projection. TrainingLoadEngine remains the only calculator.
///
/// The Training load page: a headline and gauge for where recent load sits against the fitness base, the three numbers
/// explained, where tomorrow could land, the load over time (scrubbable, with the daily Effort that feeds it), the last
/// six weeks, what drove this week, where the load came from, the last four weeks against the four before, and the
/// method. Every derived number comes from `TrainingLoadPageModel`; this view reads, lays out and draws.
struct TrainingLoadDetailView: View {
    let request: TrainingLoadDetailRequest
    /// Gregorian, in the Trends source time zone, with the person's first weekday. Built once rather than on every body pass.
    private let calendar: Calendar
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var result: TrainingLoadEngine.Result?
    @State private var model: TrainingLoadPageModel?
    /// Why there is no estimate, when there is none.
    @State private var gap: TrainingLoadPageModel.Gap?
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
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    /// The strip's caption size: the mockup's 11.5pt at the default text size, growing with Dynamic Type.
    @ScaledMetric(relativeTo: .caption2) private var captionSize: CGFloat = 11.5

    init(request: TrainingLoadDetailRequest) {
        self.request = request
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: request.key.timeZoneIdentifier) ?? .autoupdatingCurrent
        // Weeks start where this person's calendar starts them; a day's bucket is still the source time zone's.
        calendar.firstWeekday = Calendar.autoupdatingCurrent.firstWeekday
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
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var dayFormat: Date.FormatStyle {
        .init(date: .abbreviated, time: .omitted, locale: .autoupdatingCurrent,
              calendar: calendar, timeZone: calendar.timeZone)
    }
    /// "Thu, Oct 15": the day format every #55 drill-in header uses, here in the Trends source time zone.
    private var weekdayFormat: Date.FormatStyle {
        Date.FormatStyle(locale: .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
            .weekday(.abbreviated).month(.abbreviated).day()
    }
    /// "Oct 15".
    private var monthDayFormat: Date.FormatStyle {
        Date.FormatStyle(locale: .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
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
            if result.isAvailable, let model {
                heroSection(model, result: result)
                DrillInSeparator()
                TrainingLoadNumbers(model: model)
                DrillInSeparator()
                tomorrowSection(model)
                DrillInSeparator()
                loadSection(model, points: points)
                if !model.weeks.isEmpty {
                    DrillInSeparator()
                    weeksSection(model)
                }
                if !model.workouts.isEmpty {
                    DrillInSeparator()
                    driversSection(model)
                    if let mix = mixSlices(model) {
                        DrillInSeparator()
                        mixSection(mix)
                    }
                }
                if let cells = comparisonCells(model) {
                    DrillInSeparator()
                    compareSection(cells)
                }
            } else {
                unavailableSection(result)
            }
            DrillInSeparator()
            methodSection
            if result.isAvailable {
                FlatRowSeparator()
                datedValues(points)
            }
            FlatRowSeparator()
            workoutsLink
            Text("Descriptive only. Training load never changes your Readiness score.")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, NoopMetrics.space2)
        }
    }

    /// One titled section: the #55 eyebrow, then its content.
    private func section<Content: View>(_ title: LocalizedStringKey, symbol: String, trailing: EyebrowTrailing = .none,
                                        spacing: CGFloat = WidgetMetrics.headerSpacing,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            SectionEyebrow(title, systemImage: symbol, tint: .strain, trailing: trailing)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Hero

    private func heroSection(_ model: TrainingLoadPageModel, result: TrainingLoadEngine.Result) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(title: heroEyebrow, systemImage: "flame.fill", tint: .strain, trailing: eyebrowPill(result))
            TrainingLoadHero(model: model)
        }
    }

    /// "Today" for the newest day, else the day it is ("Fri, Oct 9").
    private var heroEyebrow: String {
        let day = model?.latest?.date ?? anchor
        return calendar.isDateInToday(day) ? String(localized: "Today") : day.formatted(weekdayFormat)
    }

    private func eyebrowPill(_ result: TrainingLoadEngine.Result) -> EyebrowTrailing {
        .pill(LocalizedStringKey(TrainingLoadCopy.status(state: result.state, gap: gap, observedDays: result.contiguousDays)),
              tone: TrainingLoadCopy.tone(result.state))
    }

    // MARK: Tomorrow

    private func tomorrowSection(_ model: TrainingLoadPageModel) -> some View {
        section("Where tomorrow could land", symbol: "sun.max", spacing: 6) {
            TrainingLoadTomorrow(projections: model.projections)
        }
        .accessibilityIdentifier("trends.trainingLoad.tomorrow")
    }

    // MARK: Load over time

    /// The scrub readout, the chart, the daily Effort that feeds it, the key and the range, in the mockup's order.
    private func loadSection(_ model: TrainingLoadPageModel, points: [TrainingLoadDay]) -> some View {
        let focus = focusDay(in: points)
        return section("Load over time", symbol: "chart.xyaxis.line", trailing: .text(String(localized: "Effort, 0–21")),
                       spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                readout(focus)
                    .padding(.top, 12)
                loadChart(points, focus: focus)
                    .padding(.top, 10)
                effortStrip(points)
                    .padding(.top, 16)
                TrendsLoadLegend(tint: .strain)
                    .padding(.top, 12)
                TrendsControlRow(
                    leading: { _ in
                        Text("Last \(period) days")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                    },
                    trailing: { periodPicker }
                )
                .padding(.top, 16)
            }
        }
    }

    /// The scrubbed day when it has a modeled value, else the newest modeled day while nothing is scrubbed.
    private func focusDay(in points: [TrainingLoadDay]) -> TrainingLoadDay? {
        guard let day = selectedDay else { return points.last }
        return points.first { calendar.isDate($0.date, inSameDayAs: day) }
    }

    /// Selected / Effort / Recent / Base for the day under the finger (the newest day until the chart is touched).
    private func readout(_ focus: TrainingLoadDay?) -> some View {
        let missing = WidgetMetrics.missingValue
        let day = focus?.date ?? selectedDay ?? anchor
        let dayText = calendar.isDateInToday(day) ? String(localized: "Today") : day.formatted(weekdayFormat)
        return TrainingLoadReadout(cells: [
            .init(id: 0, label: "Selected", value: dayText, color: StrandPalette.textPrimary),
            .init(id: 1, label: "Effort", value: focus.map { number($0.effort) } ?? missing, color: StrandPalette.textPrimary),
            .init(id: 2, label: "Recent", value: focus.map { number($0.acute) } ?? missing, color: TrainingLoadInk.recent),
            .init(id: 3, label: "Base", value: focus.map { number($0.chronic) } ?? missing, color: TrainingLoadInk.baseText),
        ])
        .contentTransition(reduceMotion ? .identity : .numericText())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: focus?.id)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: chartSummary(focus)))
        .accessibilityIdentifier("trends.trainingLoad.inspector")
    }

    /// The Trends card's chart (recent solid over a wash where it is above the base, base at 45%), taller, on the real
    /// calendar and scrubbable.
    private func loadChart(_ points: [TrainingLoadDay], focus: TrainingLoadDay?) -> some View {
        let axis = Self.ticks(in: rangeStart...anchor, calendar: calendar).map {
            TrendsLoadChart.Timeline.AxisLabel(date: $0, text: axisLabel(for: $0))
        }
        let timeline = TrendsLoadChart.Timeline(days: points.map(\.date), domain: chartDomain, calendar: calendar,
                                                axisLabels: axis, valueLabel: { number($0) })
        return TrendsLoadChart(chronic: points.map(\.chronic), acute: points.map(\.acute), tint: .strain,
                               startLabel: "", endLabel: "", plotHeight: TrainingLoadLayout.plotHeight,
                               timeline: timeline, selection: snappedSelection,
                               // The readout above already speaks the newest day; the chart speaks once a day is picked.
                               accessibilitySummary: selectedDay == nil ? nil : chartSummary(focus),
                               showsLegend: false)
            .accessibilityIdentifier("trends.trainingLoad.chart")
    }

    /// What feeds the load: each day's recorded Effort on the chart's own days. A recorded zero is a rest day (a small
    /// dot); a day with nothing recorded has no mark.
    private func effortStrip(_ points: [TrainingLoadDay]) -> some View {
        let marks = points.map { TrainingLoadDailyStrip.Mark(date: $0.date, effort: $0.effort) }
        let highlight = selectedDay
        let spoken: String = {
            guard let day = highlight ?? points.last?.date else { return "" }
            let name = day.formatted(weekdayFormat)
            guard let effort = points.first(where: { calendar.isDate($0.date, inSameDayAs: day) })?.effort else {
                return String(localized: "\(name): no Effort recorded")
            }
            if effort <= 0 { return String(localized: "\(name): rest day, no Effort") }
            return name + ", " + String(localized: "Recorded Effort \(number(effort))")
        }()
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    stripHeading
                    Spacer(minLength: 8)
                    stripNote
                }
                VStack(alignment: .leading, spacing: 2) {
                    stripHeading
                    stripNote
                }
            }
            .accessibilityHidden(true)
            TrainingLoadDailyStrip(marks: marks, domain: chartDomain, calendar: calendar, highlight: highlight, summary: spoken,
                                   selection: snappedSelection)
        }
    }

    private var stripHeading: some View {
        Text("Daily effort · what feeds it")
            .font(.system(size: min(captionSize, 24), weight: .semibold))
            .tracking(1)
            .textCase(.uppercase)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stripNote: some View {
        Text("dot = rest day")
            .font(.system(size: min(captionSize, 24)))
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Half a day of air on each side, so the first and last days' marks are whole.
    private var chartDomain: ClosedRange<Date> {
        rangeStart.addingTimeInterval(-TrainingLoadLayout.halfDay)...anchor.addingTimeInterval(TrainingLoadLayout.halfDay)
    }

    /// The chart scrubs this day: this binding reads the snapped day and writes whatever the chart picks.
    private var snappedSelection: Binding<Date?> {
        Binding(get: { selectedDay }, set: { selection = $0 })
    }

    /// The canonical segmented pill, announced as one adjustable control (the Trends range treatment).
    private var periodPicker: some View {
        SegmentedPillControl(TrainingLoadLayout.periods, selection: $period) { TrainingLoadLayout.label($0) }
            .segmentedPillTint(StrandPalette.strainAccent)
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
        let day = calendar.isDateInToday(focus.date) ? String(localized: "Today") : focus.date.formatted(weekdayFormat)
        return String(localized: "\(day): Effort \(number(focus.effort)), recent load \(number(focus.acute)), fitness base \(number(focus.chronic)), form \(signed(focus.balance))")
    }

    /// "Today" for the anchor day when it is today, else "Oct 15", in the Trends source time zone.
    private func axisLabel(for date: Date) -> String {
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        return date.formatted(monthDayFormat)
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

    // MARK: Weeks

    private func weeksSection(_ model: TrainingLoadPageModel) -> some View {
        let entries = model.weeks.map {
            TrainingLoadWeeks.Entry(id: $0.start, label: $0.start.formatted(monthDayFormat), isCurrent: $0.isCurrent,
                                    average: $0.averageEffort, base: $0.baseAtEnd)
        }
        return section("Week by week", symbol: "calendar", trailing: .text(String(localized: "avg Effort per day")),
                       spacing: 14) {
            TrainingLoadWeeks(entries: entries)
        }
    }

    // MARK: Drivers

    private func driversSection(_ model: TrainingLoadPageModel) -> some View {
        let end = selectedDay ?? model.latest?.date ?? anchor
        let week = model.driverWeek(endingOn: end)
        let isLatest = model.latest.map { calendar.isDate($0.date, inSameDayAs: end) } ?? true
        let range = Date.IntervalFormatStyle(locale: .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone)
            .month(.abbreviated).day()
        let rangeText = week.first < week.last ? (week.first..<week.last).formatted(range) : week.last.formatted(monthDayFormat)
        let weekday = Date.FormatStyle(locale: .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone).weekday(.abbreviated)
        let dayNumber = Date.FormatStyle(locale: .autoupdatingCurrent, calendar: calendar, timeZone: calendar.timeZone).day()
        let rows = week.drivers.enumerated().map { index, driver in
            TrainingLoadDrivers.Row(
                id: index, weekday: driver.workout.start.formatted(weekday), dayNumber: driver.workout.start.formatted(dayNumber),
                title: driver.workout.sport, symbol: sportSymbol(driver.workout.sport), meta: driverMeta(driver.workout),
                fraction: driver.fraction, effort: driver.effort)
        }
        return section(isLatest ? "What drove this week" : "What drove the week to the selected day", symbol: "bolt.fill",
                       trailing: .text(rangeText), spacing: 6) {
            if rows.isEmpty {
                Text(isLatest ? "No scored workouts this week." : "No scored workouts in these 7 days.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, NoopMetrics.space2)
            } else {
                TrainingLoadDrivers(rows: rows, trainingDaysText: trainingDaysText(week.trainingDays, isLatest: isLatest))
            }
        }
        .accessibilityIdentifier("trends.trainingLoad.drivers")
    }

    private func trainingDaysText(_ count: Int, isLatest: Bool) -> String {
        switch (count, isLatest) {
        case (0, true): String(localized: "No training days this week")
        case (1, true): String(localized: "1 training day this week")
        case (_, true): String(localized: "\(count) training days this week")
        case (0, false): String(localized: "No training days in these 7 days")
        case (1, false): String(localized: "1 training day in these 7 days")
        default: String(localized: "\(count) training days in these 7 days")
        }
    }

    /// Duration, energy and distance when the session has them, never a placeholder for one it lacks.
    private func driverMeta(_ workout: TrainingLoadPageModel.Workout) -> String {
        var facts: [String] = []
        if let seconds = workout.durationSeconds { facts.append(WorkoutFormat.duration(seconds)) }
        if let kcal = workout.energyKcal { facts.append(WorkoutFormat.energy(kcal)) }
        if let meters = workout.distanceMeters { facts.append(UnitFormatter.distanceFromMeters(meters, system: unitSystem)) }
        return WorkoutFormat.joined(facts)
    }

    // MARK: Mix

    private func mixSlices(_ model: TrainingLoadPageModel) -> [TrainingLoadMix.Slice]? {
        let shares = model.sportMix()
        guard !shares.isEmpty else { return nil }
        return shares.enumerated().map { index, share in
            TrainingLoadMix.Slice(
                id: index, name: share.isOther ? String(localized: "Other") : share.name, fraction: share.fraction,
                percent: share.percent,
                color: share.isOther ? TrainingLoadMix.colors[3] : TrainingLoadMix.colors[min(index, 2)])
        }
    }

    private func mixSection(_ slices: [TrainingLoadMix.Slice]) -> some View {
        section("Where the load came from", symbol: "square.grid.2x2", trailing: .text(String(localized: "last 6 weeks")),
                spacing: 16) {
            TrainingLoadMix(slices: slices)
        }
    }

    // MARK: Compare

    private func comparisonCells(_ model: TrainingLoadPageModel) -> [TrainingLoadComparisonStrip.Cell]? {
        guard let comparison = model.comparison else { return nil }
        let missing = WidgetMetrics.missingValue
        let average = comparison.averageDelta
        let averageDelta: TrainingLoadComparisonStrip.Delta = (abs(average) * 10).rounded() > 0
            ? .change(up: average > 0, text: number(abs(average)))
            : .plain(String(localized: "No change"))
        let biggestDay = comparison.biggestDay.date.formatted(weekdayFormat)

        var days = TrainingLoadComparisonStrip.Cell(
            id: 1, label: String(localized: "Training days"), value: comparison.trainingDays.map(String.init) ?? missing,
            delta: nil, spoken: String(localized: "Training days"))
        if let current = comparison.trainingDays, let change = comparison.trainingDaysDelta {
            let delta: TrainingLoadComparisonStrip.Delta = change == 0
                ? .plain(String(localized: "No change"))
                : .change(up: change > 0, text: String(abs(change)))
            days = .init(id: 1, label: String(localized: "Training days"), value: String(current), delta: delta,
                         spoken: String(localized: "Training days \(current), \(spokenChange(Double(change), whole: true)) from the 4 weeks before"))
        }
        return [
            .init(id: 0, label: String(localized: "Avg Effort / day"), value: number(comparison.averageEffort), delta: averageDelta,
                  spoken: String(localized: "Average Effort per day \(number(comparison.averageEffort)), \(spokenChange(average, whole: false)) from the 4 weeks before")),
            days,
            .init(id: 2, label: String(localized: "Biggest day"), value: number(comparison.biggestDay.effort),
                  delta: .plain(biggestDay),
                  spoken: String(localized: "Biggest day, Effort \(number(comparison.biggestDay.effort)), \(biggestDay)")),
        ]
    }

    /// "up 1.4", "down 2", "no change": how VoiceOver says a delta.
    private func spokenChange(_ delta: Double, whole: Bool) -> String {
        let magnitude = abs(delta)
        guard (magnitude * (whole ? 1 : 10)).rounded() > 0 else { return String(localized: "no change") }
        let value = whole ? String(Int(magnitude.rounded())) : number(magnitude)
        return delta > 0 ? String(localized: "up \(value)") : String(localized: "down \(value)")
    }

    private func compareSection(_ cells: [TrainingLoadComparisonStrip.Cell]) -> some View {
        section("Compared with the 4 weeks before", symbol: "clock.arrow.circlepath", spacing: 14) {
            TrainingLoadComparisonStrip(cells: cells)
        }
    }

    // MARK: Dated values

    private func datedValues(_ points: [TrainingLoadDay]) -> some View {
        TrainingLoadDisclosure("Dated values", isExpanded: $showRows) {
            // Its own equatable view, so a scrub (which rewrites `selection` on every tick) does not rebuild up to
            // 180 rows that did not change.
            TrainingLoadDatedRows(points: points, dayFormat: dayFormat).equatable()
        }
    }

    // MARK: Method and links

    private var methodSection: some View {
        TrainingLoadDisclosure("How this is calculated", isExpanded: $showMethod) {
            TrainingLoadMethod(configuration: model?.configuration ?? .standard,
                               timeZoneIdentifier: request.key.timeZoneIdentifier)
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

    /// Not enough history: one explicit state in the page's own eyebrow, in place of the numbers and the charts. The
    /// words come from the same place the Trends card's do, so the card and this page agree.
    private func unavailableSection(_ result: TrainingLoadEngine.Result) -> some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow("Training load", systemImage: "flame.fill", tint: .strain, trailing: eyebrowPill(result))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: TrainingLoadCopy.unavailableTitle(gap))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(verbatim: TrainingLoadCopy.unavailableDetail(gap))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
    /// Never "-0.0" or "+0.0": a form that rounds to nothing reads "0.0".
    private func signed(_ value: Double) -> String { DrillInFormat.signed(value, fractionDigits: 1) }

    /// The sessions the page needs, read once, with the sport named the way the Workouts screens name it. They span the whole
    /// modeled window plus the six days before its oldest day: any day the chart can scrub to has its full seven-day window
    /// of "what drove the week" behind it, and the 28 against 28 days and the 42 of the mix sit inside it too.
    @MainActor private func readWorkouts() async -> [TrainingLoadPageModel.Workout] {
        let days = TrainingLoadTrendsWindow.days + TrainingLoadPageModel.driverWindowDays - 1
        guard let first = calendar.date(byAdding: .day, value: 1 - days, to: anchor),
              let end = calendar.date(byAdding: .day, value: 1, to: anchor) else { return [] }
        let rows = await repo.workoutRows(from: Int(first.timeIntervalSince1970), to: Int(end.timeIntervalSince1970),
                                          reconcileHR: false)
        return rows.map { row in
            TrainingLoadPageModel.Workout(
                row: row, sportName: WorkoutCatalog.sport(named: row.sport)?.name ?? WorkoutSource.displaySport(row.sport))
        }
    }

    @MainActor private func load() async {
        let trigger = self.trigger
        guard trigger != loadedTrigger, sourceIsCurrent else { return }
        // Another source, day, zone, range or week is a different page: its old values never sit under the new header.
        if let loadedTrigger, !trigger.rereads(loadedTrigger) {
            result = nil
            model = nil
            gap = nil
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
        let loads = history.map { TrainingLoadEngine.DailyLoad(day: $0.day, load: $0.strain) }
        let evaluated = TrainingLoadEngine.evaluate(days: loads, through: request.key.anchorDay)
        let evaluatedGap = TrainingLoadPageModel.gap(result: evaluated, history: loads, targetDay: request.key.anchorDay)

        var built: TrainingLoadPageModel?
        if evaluated.isAvailable {
            // The one workouts read, in this same load path, then the model off the main actor.
            let workouts = await readWorkouts()
            guard !Task.isCancelled, trigger == self.trigger, sourceIsCurrent else { return }
            let modelDays: [TrainingLoadPageModel.Day] = evaluated.points.compactMap { point in
                date(point.day).map {
                    .init(date: $0, acute: point.acuteLoad, chronic: point.chronicLoad, load: point.load)
                }
            }
            // Every recorded day of the run, the six before the engine's seed day included (they have a load but no
            // modeled state), so the weeks, the comparison and the biggest day are not short of those days.
            let startDay = evaluated.startDay
            let recorded: [TrainingLoadPageModel.Recorded] = loads.compactMap { item in
                guard let load = item.load, let startDay, item.day >= startDay else { return nil }
                return date(item.day).map { .init(date: $0, load: load) }
            }
            let modelCalendar = calendar
            built = await Task.detached(priority: .userInitiated) {
                TrainingLoadPageModel(days: modelDays, workouts: workouts, calendar: modelCalendar, recorded: recorded)
            }.value
            guard !Task.isCancelled, trigger == self.trigger, sourceIsCurrent else { return }
        }
        result = evaluated
        model = built
        gap = evaluatedGap
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

/// Selected / Effort / Recent / Base for the day under the finger, in one quiet box. Two by two at the accessibility sizes.
private struct TrainingLoadReadout: View {
    struct Cell: Identifiable {
        let id: Int
        let label: LocalizedStringKey
        let value: String
        let color: Color
    }

    let cells: [Cell]
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .callout) private var valueSize: CGFloat = 16
    @ScaledMetric(relativeTo: .caption2) private var labelSize: CGFloat = 11.5

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: NoopMetrics.space3) {
                    ForEach(cells) { cell in column(cell) }
                }
            } else {
                HStack(alignment: .top, spacing: NoopMetrics.space2) {
                    ForEach(cells) { cell in
                        column(cell)
                        if cell.id != cells.last?.id { Spacer(minLength: 0) }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(StrandPalette.card))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(StrandPalette.hairline, lineWidth: 1))
    }

    private func column(_ cell: Cell) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(cell.label)
                .font(.system(size: min(labelSize, 24), weight: .medium))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
            Text(verbatim: cell.value)
                .font(.system(size: min(valueSize, 28), weight: .semibold).monospacedDigit())
                .foregroundStyle(cell.value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : cell.color)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// What feeds the load, one mark per recorded day on the chart's own days: a bar scaled against the 0...21 Effort range
/// (orange from 18, full strain blue from 14, translucent below), a small grey dot for a recorded zero (a rest day), and
/// nothing for a day with no Effort recorded. Inset like the chart above it, so each mark sits under its day.
///
/// It is a second scrub surface, the way the chart above it is: a horizontal drag along it picks the nearest recorded day
/// and writes the same selection, so the readout, the chart's hairline and "what drove this week" all follow.
private struct TrainingLoadDailyStrip: View {
    struct Mark {
        let date: Date
        /// Display-scale Effort. Zero is a recorded rest day.
        let effort: Double
    }

    let marks: [Mark]
    let domain: ClosedRange<Date>
    let calendar: Calendar
    /// The scrubbed day, drawn as a hairline; nil when nothing is scrubbed.
    let highlight: Date?
    let summary: String
    /// The page's scrub selection. The strip writes the nearest recorded day and clears it when the finger lifts.
    let selection: Binding<Date?>
    @GestureState private var isScrubbing = false
    @State private var dragAxis: Axis?

    static let height: CGFloat = 44
    /// A drag that begins this close to the leading edge is the navigation back swipe's, not a scrub (the chart's own rule).
    static let leadingEdgeInset: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                let width = max(size.width - TrendsLoadChart.valueAxisInset, 1)
                let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
                guard span > 0 else { return }
                let x = { (date: Date) -> CGFloat in
                    width * CGFloat(min(max(date.timeIntervalSince(domain.lowerBound) / span, 0), 1))
                }
                let perDay = width * CGFloat(86_400 / span)
                let barWidth = max(1.5, min(4.6, perDay * 0.6))
                let usable = size.height - 4
                if let highlight {
                    var line = Path()
                    line.move(to: CGPoint(x: x(highlight), y: 0))
                    line.addLine(to: CGPoint(x: x(highlight), y: size.height))
                    context.stroke(line, with: .color(StrandPalette.textPrimary.opacity(0.35)), lineWidth: 1)
                }
                for mark in marks {
                    let centre = x(mark.date)
                    if mark.effort <= 0 {
                        let dot = CGRect(x: centre - 1.6, y: size.height - 2 - 1.6, width: 3.2, height: 3.2)
                        context.fill(Path(ellipseIn: dot), with: .color(StrandPalette.textTertiary))
                        continue
                    }
                    let barHeight = max(CGFloat(min(mark.effort / 21, 1)) * usable, 2)
                    let rect = CGRect(x: centre - barWidth / 2, y: size.height - barHeight, width: barWidth, height: barHeight)
                    let color: Color = mark.effort >= 18 ? TrainingLoadInk.spike
                        : mark.effort >= 14 ? TrainingLoadInk.recent : TrainingLoadInk.recent.opacity(0.5)
                    context.fill(Path(roundedRect: rect, cornerRadius: min(1.6, barWidth / 2)), with: .color(color))
                }
            }
            .contentShape(Rectangle())
            // Horizontal drags scrub; a mostly vertical one is the page scrolling and is left alone.
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .local)
                    .updating($isScrubbing) { _, state, _ in state = true }
                    .onChanged { value in
                        if dragAxis == nil {
                            dragAxis = abs(value.translation.width) > abs(value.translation.height) ? .horizontal : .vertical
                        }
                        guard dragAxis == .horizontal, value.startLocation.x > Self.leadingEdgeInset else { return }
                        select(nearestTo: value.location.x, width: max(proxy.size.width - TrendsLoadChart.valueAxisInset, 1))
                    }
            )
        }
        .frame(height: Self.height)
        .onChange(of: isScrubbing) { _, scrubbing in
            if !scrubbing {
                dragAxis = nil
                selection.wrappedValue = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily Effort over the selected range")
        .accessibilityValue(Text(verbatim: summary))
        .accessibilityIdentifier("trends.trainingLoad.effort")
    }

    /// The recorded day nearest the touch, on the same domain and width the marks are drawn on.
    private func select(nearestTo x: CGFloat, width: CGFloat) {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0, !marks.isEmpty else { return }
        let target = domain.lowerBound.addingTimeInterval(span * Double(min(max(x / width, 0), 1)))
        guard let nearest = marks.map(\.date).min(by: {
            abs($0.timeIntervalSince(target)) < abs($1.timeIntervalSince(target))
        }) else { return }
        if selection.wrappedValue != nearest { selection.wrappedValue = nearest }
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

/// The dated rows, newest first. Equal when they would show the same days and figures.
private struct TrainingLoadDatedRows: View, Equatable {
    let points: [TrainingLoadDay]
    let dayFormat: Date.FormatStyle

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.dayFormat == rhs.dayFormat && lhs.points.count == rhs.points.count
            && zip(lhs.points, rhs.points).allSatisfy {
                $0.id == $1.id && $0.acute == $1.acute && $0.chronic == $1.chronic
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(points.reversed().enumerated()), id: \.element.id) { index, day in
                if index > 0 { FlatRowSeparator() }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: day.date.formatted(dayFormat))
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Recent load \(DrillInFormat.number(day.acute, fractionDigits: 1)) · Fitness base \(DrillInFormat.number(day.chronic, fractionDigits: 1)) · Form \(DrillInFormat.signed(day.balance, fractionDigits: 1))")
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
