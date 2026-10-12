import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Explore (Metric Explorer + Detail)
//
// The catalog-driven "Explore" surface. The root is a flat list: one section per MetricCatalog.category, a row per
// metric, each pushing a MetricDetailView. The detail is a drill-in in the same language as the Today drill-ins and
// Trends: flat sections opened by an eyebrow, the Trends hero chart for the selected range, Low / Average / High,
// and what correlates, all with the metric's own domain tint.
//
// Sparse-metric rule (owner saw "no data" on metrics that HAVE data): a series may
// be sampled weekly (weight / body fat). The window is taken RELATIVE TO THE LATEST
// data point — not "now" — so a stale-but-present series still resolves. If the
// selected window holds ≥1 point we SHOW THAT WINDOW (so W/M/3M stay visibly
// distinct); only when it holds ZERO points do we auto-expand to the smallest larger
// range that does. The hero always shows the latest available point + "as of <date>".

// MARK: - Range

/// The W/M/3M/6M/1Y/ALL window, driving the single SegmentedPillControl.
enum ExploreRange: Int, CaseIterable, Identifiable, Hashable {
    case week = 7, month = 30, quarter = 90, half = 180, year = 365, all = 0
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .week: return String(localized: "W"); case .month: return String(localized: "M"); case .quarter: return String(localized: "3M")
        case .half: return String(localized: "6M"); case .year: return String(localized: "1Y"); case .all: return String(localized: "ALL")
        }
    }
    var name: String {
        switch self {
        case .week: return String(localized: "week"); case .month: return String(localized: "month"); case .quarter: return String(localized: "quarter")
        case .half: return String(localized: "6 months"); case .year: return String(localized: "year"); case .all: return String(localized: "all time")
        }
    }
    /// "Last 30 days", or "All time" for ALL: what the range control beside it selects.
    var title: String {
        guard let days else { return String(localized: "All time") }
        return String(localized: "Last \(days) days")
    }
    /// Trailing days the window spans (nil = everything).
    var days: Int? { self == .all ? nil : rawValue }

    /// Why a sparse window shows this range instead of the one picked, as a whole phrase per range so a language can
    /// inflect the range name. nil for the week, which no window widens to.
    var widenedPhrase: String? {
        switch self {
        case .week: return nil
        case .month: return String(localized: "sparse, widened to a month")
        case .quarter: return String(localized: "sparse, widened to 3 months")
        case .half: return String(localized: "sparse, widened to 6 months")
        case .year: return String(localized: "sparse, widened to a year")
        case .all: return String(localized: "sparse, widened to all time")
        }
    }

    /// This range plus every LARGER range, ascending — the auto-expand search order
    /// when the selected window holds zero points. ALW always terminates the chain.
    var widening: [ExploreRange] {
        let order: [ExploreRange] = [.week, .month, .quarter, .half, .year, .all]
        guard let i = order.firstIndex(of: self) else { return [.all] }
        return Array(order[i...])
    }
}

/// Pure #943 chip-coercion rule, extracted so it can be pinned by a test (the Swift twin of Android's
/// `coercedVitalRange` in HealthScreen.kt). Resolves a stored selection NON-DESTRUCTIVELY: an unlocked
/// selection is kept verbatim; a LOCKED one renders as the largest unlocked range with a real finite
/// window (`days != nil`, so never ALL) whose rawValue is <= the selection, else `.week`. Coercing a
/// locked default to ALL would jump a calibrating user to the everything view, so it is excluded.
enum ExploreRangeGating {
    static func coerced(selection: ExploreRange, isUnlocked: (ExploreRange) -> Bool) -> ExploreRange {
        if isUnlocked(selection) { return selection }
        return [ExploreRange.year, .half, .quarter, .month, .week]
            .first { $0.days != nil && $0.rawValue <= selection.rawValue && isUnlocked($0) } ?? .week
    }
}

// MARK: - Root: categorized list

/// What the first pass over the catalog learned about one metric: it has no series at all, or this latest reading.
private enum MetricProbe: Equatable {
    case empty
    case latest(Double)
}

/// The "Explore" picker — categories as sections, metrics as rows, each pushing a
/// MetricDetailView. Every row ends the same way: the latest reading with its unit set apart and muted, or a muted
/// "No data" when the series is empty.
struct MetricExplorerView: View {
    @EnvironmentObject var repo: Repository
    /// metric.id → what the probe found. Filled INCREMENTALLY by `probeEmptiness()`; a metric absent from the map
    /// simply shows nothing at its trailing edge yet (rows never wait on it — see `MetricRow`).
    @State private var probeByID: [String: MetricProbe] = [:]
    @State private var probedRefreshSeq: Int?
    /// True once a pass has read every metric for `probedRefreshSeq`. A pass the list's `.task` cancelled part-way (a row was
    /// tapped while it ran) leaves this false, so the next pass carries on where it stopped.
    @State private var probeComplete = false
    /// True while the empty-series probe is still running its first pass. Drives a small inline progress
    /// hint at the top, never gating the rows: the catalog is static, so every row's label/icon/unit
    /// must paint immediately even before any series read returns (#199).
    @State private var probing = true

    /// The categories that have at least one metric, in catalog order.
    private let categories = MetricCatalog.categories.filter { !MetricCatalog.inCategory($0).isEmpty }

    var body: some View {
        #if os(macOS)
        // macOS: Explore is a standalone detail pane, so it owns its NavigationStack.
        NavigationStack { exploreScaffold }
            .task(id: repo.refreshSeq) { await probeEmptiness(refreshSeq: repo.refreshSeq) }
        #else
        // iOS: Explore is pushed INSIDE the More tab's NavigationStack. A nested NavigationStack made
        // tapping a metric bounce straight back to the More list (#199) — so use the ambient stack; the
        // rows push their detail with a direct closure-based NavigationLink (#38).
        exploreScaffold
            .task(id: repo.refreshSeq) { await probeEmptiness(refreshSeq: repo.refreshSeq) }
        #endif
    }

    private var exploreScaffold: some View {
        // PERF (scroll): lazy column. Explore's content is a flat list of sibling sections (the probe hint, the Deep
        // Timeline row, then a long per-category ForEach of metric rows), so the LazyVStack genuinely builds the
        // off-screen categories on demand.
        ScreenScaffold(title: "All metrics",
                       onRefresh: { _ = await repo.refresh(.currentDay) }, lazy: true,
                       topBackground: nil) {
            LazyVStack(alignment: .leading, spacing: 0) {
                // A quiet, non-blocking hint while the empty-series probe runs its first pass. The rows below
                // render in full immediately regardless — this only reassures during the scan, and never
                // leaves the screen reading as a bare/empty list before the probe lands (#199).
                if probing {
                    HStack(spacing: NoopMetrics.space2) {
                        ProgressView().controlSize(.small)
                        Text("Scanning your data…")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, NoopMetrics.space2)
                }
                // The headline tap-through (#575): a full-day, full-resolution, zoomable timeline. Sits above
                // the per-metric catalog because it's a different kind of view — every second of one day rather
                // than one number per day. Closure-based NavigationLink, matching the metric rows below (#38/#199).
                NavigationLink {
                    FullDayChartView()
                } label: {
                    ExploreFlatRow(
                        symbol: "waveform.path.ecg", tint: .heart,
                        title: Text("Deep Timeline"),
                        subtitle: Text("Every second of your day, zoomable."),
                        spoken: String(localized: "Deep Timeline, every second of your day, zoomable"))
                }
                .exploreRowPress()
                FlatSectionSeparator.afterExploreRows

                ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                    let metrics = MetricCatalog.inCategory(category)
                    VStack(alignment: .leading, spacing: 0) {
                        // Localized at the render site only; `category` itself stays the raw
                        // English identifier that `inCategory` filters on.
                        FlatSection(
                            verbatim: MetricCatalog.categoryDisplayName(category),
                            systemImage: MetricCatalog.categorySymbol(category),
                            tint: MetricCatalog.categoryTint(category),
                            trailing: .text(metrics.count.formatted()),
                            contentSpacing: 0
                        ) {
                            VStack(spacing: 0) {
                                ForEach(Array(metrics.enumerated()), id: \.element.id) { row, metric in
                                    if row > 0 { ExploreRowSeparator() }
                                    // Push the detail directly (closure-based), like every other More-tab
                                    // screen. The old value + .navigationDestination(for:) pairing resolved
                                    // against TWO registered destinations and double-pushed — the detail
                                    // flashed then popped straight back (#38).
                                    NavigationLink {
                                        MetricDetailView(metric: metric)
                                    } label: {
                                        MetricRow(metric: metric, probe: probeByID[metric.id])
                                    }
                                    .exploreRowPress()
                                }
                            }
                        }
                        if index < categories.count - 1 { FlatSectionSeparator.afterExploreRows }
                    }
                }
            }
        }
        // Rows push MetricDetailView directly (closure-based NavigationLink above) — no value/destination
        // pairing, which is what double-pushed (#38). Nothing else registers a MetricDescriptor destination.
    }

    /// One lightweight pass to learn which metrics have no series and, for the rest, their latest reading, so each
    /// row can end in a value or a muted "No data". The series is read for emptiness anyway; its last point is free.
    /// Failures default to "has data" (nothing shown yet).
    ///
    /// Crucially this assigns into `probeByID` PER METRIC, not in one final batch (#199): the previous
    /// version ran ~35 sequential `exploreSeries` reads — each hopping back to the @MainActor Repository
    /// — before publishing a single result, so on iOS the main thread stayed busy and the freshly-pushed
    /// list painted blank until the whole sweep finished. Publishing each result (with a `Task.yield()`
    /// between reads so the run loop can lay the rows out) lets the catalog rows render immediately and
    /// the values fill in as the probe lands. Rows already render their label/icon without waiting on
    /// this — the map only ever ADDS a trailing value.
    private func probeEmptiness(refreshSeq: Int) async {
        guard probedRefreshSeq != refreshSeq || !probeComplete else { probing = false; return }
        if probedRefreshSeq != refreshSeq {
            // New data: start again. The same data after an interrupted pass: keep what was read and finish the rest.
            probedRefreshSeq = refreshSeq
            probeByID = [:]
            probeComplete = false
        }
        probing = true
        for metric in MetricCatalog.all {
            guard !Task.isCancelled else { return }
            if probeByID[metric.id] != nil { continue }
            let s = metric.key == "strain"
                ? repo.canonicalDays.compactMap { day in
                    repo.canonicalStrain(for: day.day).map { (day: day.day, value: $0.storedValue) }
                }
                : await repo.exploreSeries(key: metric.key, source: metric.source)
            guard !Task.isCancelled else { return }
            probeByID[metric.id] = s.last.map { .latest($0.value) } ?? .empty
            await Task.yield()
        }
        probeComplete = true
        probing = false
    }
}

// MARK: - One catalog row

private struct MetricRow: View {
    let metric: MetricDescriptor
    /// nil until the probe has read this metric.
    let probe: MetricProbe?

    // The value and its unit follow the Imperial/Metric preference (kg→lb, °C→°F) and the Strain scale (/100→/21, #268).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue

    /// The latest reading as the person reads it, split so the unit can sit apart and muted.
    private var latestParts: (number: String, unit: String)? {
        guard case .latest(let value)? = probe else { return nil }
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        let temperature = UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
        let effort = UnitPrefs.resolveEffortScale(effortScaleRaw)
        return metric.displayParts(value, system: system, temperature: temperature, effortScale: effort)
    }

    /// What VoiceOver says: a whole string per variant, never a concatenated localized tail.
    private var spoken: String {
        if let parts = latestParts {
            let value = parts.unit.isEmpty ? parts.number : "\(parts.number) \(parts.unit)"
            return String(localized: "\(metric.title), latest \(value)")
        }
        if probe == .empty { return String(localized: "\(metric.title), no data") }
        return metric.title
    }

    var body: some View {
        ExploreFlatRow(
            symbol: metric.icon,
            tint: metric.domainTint(),
            title: Text(verbatim: metric.title),
            subtitle: Text(verbatim: metric.sourceLabel),
            spoken: spoken
        ) {
            // One rule for every row: the latest value with a muted unit, a muted "No data" when there is none, and
            // nothing at all while the probe is still reading. Never a unit with no number.
            if let parts = latestParts {
                ExploreLatestValue(number: parts.number, unit: parts.unit)
            } else if probe == .empty {
                Text("No data")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

// MARK: - Detail / drill-down

/// One metric's page: the metric's tint, the Trends hero chart for the selected range (the hero value, its
/// distance from the range average, a tinted line over a wash and a typical band, touch and hold to read a day),
/// Low / Average / High, and what correlates with it.
struct MetricDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let metric: MetricDescriptor
    @EnvironmentObject var repo: Repository

    // Imperial/Metric display preference (D#103). Display-only: weight (kg) and skin temp (°C) re-label
    // here; everything else is unit-agnostic and renders unchanged.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    // Strain display scale (#268) — routes the Strain metric's numbers + unit; display-only, the plotted
    // series stays 0–100. Every other metric is scale-agnostic (see MetricDescriptor.format).
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    /// A stored value as the person reads it, unit included ("54 ms", "74.2 kg", "5.4 /21").
    private func fmt(_ v: Double) -> String {
        metric.format(v, system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }
    /// The unit the person reads this metric in ("lb" for a weight in pounds), or "" for a bare number.
    private var displayUnit: String {
        metric.displayUnit(system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }
    /// A stored value's number alone: `fmt` without its unit, for a hero and chart labels that set the unit apart.
    private func number(_ v: Double) -> String {
        let text = fmt(v)
        guard !displayUnit.isEmpty, text.hasSuffix(displayUnit) else { return text }
        return String(text.dropLast(displayUnit.count)).trimmingCharacters(in: .whitespaces)
    }

    @State private var range: ExploreRange = .month
    /// Full ascending series for this metric — ALL history.
    @State private var series: [(day: String, value: Double)] = []
    /// The start of each series day (Gregorian, local time zone), row for row with `series`.
    @State private var seriesDates: [Date] = []
    /// Each row's day as a number of days since 1970-01-01 (`ExploreDayKey.dayNumber`), parallel to `series`: the window and
    /// the history span are counted on these, never on `seriesDates`, which a day with no local midnight would skew.
    @State private var seriesDayNumbers: [Int] = []
    /// Every OTHER catalog series, loaded once for the correlation scan.
    @State private var others: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
    @State private var loaded = false
    @State private var correlationsLoaded = false

    /// Cached correlation scan, keyed by its inputs (selected range + the metric id),
    /// so the full cross-catalog Pearson sweep runs ONLY when those change — not on
    /// every body re-eval (hover / 1 Hz HR ticks / animation). Recomputed from
    /// `recomputeCorrelations(...)` after load and on range change.
    @State private var correlationCache: [CorrRow] = []
    /// The (metricID, range) the cache was built for; nil means "not yet computed".
    @State private var correlationKey: String? = nil
    private var loadTaskID: String { "\(metric.id)|\(repo.refreshSeq)" }
    /// The Gregorian calendar in the person's time zone: day keys and the chart's window use it (the window slice and the
    /// history span count day numbers instead, see `ExploreWindow`). The device's own calendar and locale are for display
    /// only (`dateText`).
    private let calendar = ExploreDayKey.calendar()

    // MARK: Derived

    /// The trailing-N-days slice for a given range, taken RELATIVE TO THE LATEST data
    /// point (not "now") — `.all` returns everything.
    private func slice(for r: ExploreRange) -> [(day: String, value: Double)] {
        guard let days = r.days else { return series }
        guard let first = ExploreWindow.firstIndex(dayNumbers: seriesDayNumbers, days: days),
              series.indices.contains(first) || first == series.count else { return [] }
        return Array(series[first...])
    }

    /// The range actually shown: the SELECTED range whenever its window holds ≥1
    /// point, otherwise the smallest LARGER range that does. So switching ranges is
    /// always visibly distinct when data allows, and only sparse windows widen.
    /// The range the chips + caption ACTUALLY describe, resolved NON-DESTRUCTIVELY from the stored
    /// `range` (#943, true cross-platform lockstep with Android's effectiveVitalRange). We never
    /// overwrite the @State selection - a locked default (`range == .month` with under a week of
    /// history) simply RENDERS as the largest unlocked range with a real finite window that is <= the
    /// selection, else `.week`. NOT `.all`: coercing a locked default to ALL would jump a calibrating
    /// user to the everything view. When the stored range is itself unlocked it is used verbatim, so
    /// once history grows the selection un-coerces on its own with no snap-back.
    private var coercedSelection: ExploreRange {
        ExploreRangeGating.coerced(selection: range, isUnlocked: isUnlocked)
    }

    /// The pill's selection binding: it HIGHLIGHTS the coerced selection (so a locked default shows the
    /// unlocked chip that is actually rendering) but a user tap writes straight to the stored @State
    /// `range`. Reads never mutate state, so this stays non-destructive.
    private var selectionBinding: Binding<ExploreRange> {
        Binding(get: { coercedSelection }, set: { range = $0 })
    }

    private var effectiveRange: ExploreRange {
        guard !series.isEmpty else { return coercedSelection }
        return MetricDetailWindowResolver.resolve(
            selection: coercedSelection,
            widening: coercedSelection.widening,
            rows: series,
            slice: { candidate, _ in slice(for: candidate) }
        ).range
    }

    /// Whole days between the first and last reading (0 for a single point).
    private var historySpanDays: Int {
        ExploreWindow.spanDays(dayNumbers: seriesDayNumbers)
    }

    /// Whether a range chip is selectable (#943, reimplemented from ryanbr's PR): a longer
    /// range only unlocks once the history span EXCEEDS the previous window, i.e. once it
    /// would actually show more than the range below it. Before that, every window is taken
    /// relative to the latest point, so thin history sat inside all of them and the six chips
    /// drew byte-identical charts (a week of data stretched full-width under a 1Y label).
    /// W (the shortest) and ALL (the honest everything view) are never gated, so a calibrating
    /// user always has a selectable range; until the series loads (or with no history at all)
    /// nothing is gated, since the empty state deliberately keeps the full range bar for context.
    private func isUnlocked(_ r: ExploreRange) -> Bool {
        guard loaded, !series.isEmpty else { return true }
        switch r {
        case .week, .all: return true
        case .month:   return historySpanDays > ExploreRange.week.rawValue
        case .quarter: return historySpanDays > ExploreRange.month.rawValue
        case .half:    return historySpanDays > ExploreRange.quarter.rawValue
        case .year:    return historySpanDays > ExploreRange.half.rawValue
        }
    }

    /// True when at least one range chip is locked; drives the one-line unlock hint under
    /// the caption, so the dimmed chips read as "not yet" rather than broken.
    private var hasLockedRanges: Bool { !ExploreRange.allCases.allSatisfy(isUnlocked) }

    /// The window immediately preceding the active one (equal length, by day count).
    private func previousWindow(effectiveRange: ExploreRange,
                                windowed: [(day: String, value: Double)]) -> [(day: String, value: Double)] {
        guard effectiveRange != .all else { return [] }
        let size = windowed.count
        guard size > 0 else { return [] }
        // Index of the active window's first row, then step back `size` rows.
        guard let firstDay = windowed.first?.day,
              let lo = series.firstIndex(where: { $0.day == firstDay }) else { return [] }
        let prevLo = max(0, lo - size)
        guard prevLo < lo else { return [] }
        return Array(series[prevLo..<lo])
    }

    private var latest: (day: String, value: Double)? { series.last }
    private var latestDate: Date? { seriesDates.last }

    // MARK: Body

    /// What the pushed header row says beside the title: the category (unless it only repeats the title) and the source
    /// the numbers come from, so Whoop's resting heart rate and a Mi Band's are never the same page. Data text, shown
    /// verbatim.
    static func headerContext(category: String, title: String, source: String) -> String {
        category.caseInsensitiveCompare(title) == .orderedSame ? source : "\(category) \u{00B7} \(source)"
    }

    var body: some View {
        // Compute the heavy window derivations ONCE per body eval, then hand them to
        // the subviews — instead of every subview re-deriving `effectiveRange` /
        // `windowed` (each of which re-filters the full history).
        let effRange = effectiveRange
        let win = slice(for: effRange)
        let fellBack = effRange != coercedSelection
        let tint = metric.domainTint(latest: latest?.value)
        return ScreenScaffold(title: LocalizedStringKey(dataText: metric.title),
                              subtitle: LocalizedStringKey(dataText: MetricCatalog.categoryDisplayName(metric.category)),
                              topBackground: nil,
                              backAction: { dismiss() },
                              // Pushed, the header row carries the category the subtitle used to name (and says
                              // nothing when it would only repeat the title: "Recovery" under "Recovery").
                              headerContext: Self.headerContext(category: MetricCatalog.categoryDisplayName(metric.category),
                                                                title: metric.title, source: metric.sourceLabel)) {
            VStack(alignment: .leading, spacing: 0) {
                if loaded && series.isEmpty {
                    // No data in the entire history — keep the range bar for context, then the honest empty
                    // state. Deliberately NOT gated by the #943 chip locking: with zero data there is no chart for
                    // the ranges to misrepresent, and hiding the bar here would regress this "for context" intent.
                    VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
                        SectionEyebrow("Trend", systemImage: metric.icon, tint: tint)
                        rangeControls(caption: nil)
                    }
                    ExploreMessage(
                        symbol: "tray", title: Text("No data"),
                        message: Text("Import your history first. A WHOOP export in Data Sources fills every metric you can explore here in about a minute."))
                } else if !loaded {
                    VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
                        SectionEyebrow("Trend", systemImage: metric.icon, tint: tint)
                        rangeControls(caption: nil)
                    }
                    ExploreMessage(isLoading: true, title: Text("Reading your \(metric.title.lowercased())…"))
                } else {
                    trendSection(effectiveRange: effRange, windowed: win, windowFellBack: fellBack, tint: tint)
                    FlatSectionSeparator()
                    correlationSection
                    if let about = metric.description {
                        FlatSectionSeparator()
                        FlatSection("How this is computed", systemImage: "function") {
                            Text(verbatim: about)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        // A 24-letter German metric name is scaled to the row at the accessibility sizes, never broken mid-word.
        .headerTitleKeepsWordsWhole(of: metric.title)
        #if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
        #endif
        .task(id: loadTaskID) { await load() }
        // Range changes the window, hence the correlation inputs — recompute the
        // cached scan rather than letting `correlationSection` run it inside body.
        .onChangeCompat(of: range) { _ in recomputeCorrelations() }
    }

    // MARK: Baseline and typical band

    /// What the chart shades as "typical", and whether the latest reading sits inside it. Metrics the Baselines
    /// engine backs (HRV, resting HR, respiration, skin temperature, Effort) use its rolling baseline and spread
    /// (σ × 1.253, the mean absolute deviation to a standard deviation), and say whether the latest reading is in
    /// range. Every other metric shades the window's mean ± one standard deviation and says nothing about "in range".
    private struct TypicalBand {
        let baseline: Double
        let typical: ClosedRange<Double>
        /// nil when the metric has no baseline model to judge the latest reading against.
        let latestInRange: Bool?
    }

    private func typicalBand(values: [Double]) -> TypicalBand? {
        guard let raw = rawTypicalBand(values: values) else { return nil }
        // Held inside what the metric can be, so the row, the chart's shading and the spoken summary agree.
        let held = ExploreTypicalBand.clamped(baseline: raw.baseline, typical: raw.typical, to: metric.validRange)
        return TypicalBand(baseline: held.baseline, typical: held.typical, latestInRange: raw.latestInRange)
    }

    private func rawTypicalBand(values: [Double]) -> TypicalBand? {
        let key: String
        switch metric.key {
        case "rhr": key = "resting_hr"
        case "resp_rate": key = "resp"
        default: key = metric.key
        }
        if let cfg = Baselines.metricCfg[key] {
            let state = Baselines.rollingMeanSD(values.map(Optional.some), cfg: cfg)
            if state.usable, let current = latest?.value {
                let sigma = state.spread * 1.253
                return TypicalBand(
                    baseline: state.baseline,
                    typical: (state.baseline - sigma)...(state.baseline + sigma),
                    latestInRange: Baselines.deviation(current, state: state).inNormalRange)
            }
        }
        return DrillInTrendStats.baselineAndTypical(of: values)
            .map { TypicalBand(baseline: $0.baseline, typical: $0.typical, latestInRange: nil) }
    }

    // MARK: Trend section

    /// What a metric can physically be, so a chart axis never runs past it (a blood oxygen of 104%).
    private var valueBounds: ClosedRange<Double> { metric.validRange }

    private var chartDirection: TrendPanelChart.Direction {
        switch metric.higherIsBetter {
        case true?: return .higherIsBetter
        case false?: return .lowerIsBetter
        case nil: return .contextual
        }
    }

    @ViewBuilder
    private func trendSection(effectiveRange: ExploreRange,
                              windowed: [(day: String, value: Double)],
                              windowFellBack: Bool,
                              tint: DomainTint) -> some View {
        let values = windowed.map(\.value)
        let band = typicalBand(values: values)
        let caption = rangeCaption(effectiveRange: effectiveRange, windowed: windowed, windowFellBack: windowFellBack)
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Trend"),
                systemImage: metric.icon,
                tint: tint,
                trailing: eyebrowTrailing(band: band))
            if let latestDate, values.count >= 2, let band {
                // Value first: the hero (the latest reading and how it sits against the average), the chart, then the
                // range control beneath it and one caption, then the numbers behind the chart.
                trendChart(effectiveRange: effectiveRange, windowed: windowed, band: band,
                           latestDate: latestDate, tint: tint)
                rangeControls(caption: caption)
                statFooter(values: values)
                comparisonRows(effectiveRange: effectiveRange, windowed: windowed, band: band)
            } else if let latest, let latestDate {
                // One reading in the window: a dot is not a trend, so the value stands alone with its change against
                // the reading before it.
                HeroValue(
                    value: number(latest.value),
                    unit: displayUnit.isEmpty ? nil : displayUnit,
                    caption: String(localized: "latest \u{00B7} \(dateText(latestDate))"),
                    captionPlacement: .below)
                rangeControls(caption: caption)
                // A typed key, so the ternary's two literals are looked up in the catalog like any other string.
                let note: LocalizedStringKey = longerRangeShowsMore(effectiveRange: effectiveRange, windowedCount: windowed.count)
                    ? "Only one reading in this range. Choose a longer range to see a trend."
                    : "Only one reading so far. A trend appears once there are more."
                Text(note)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                comparisonRows(effectiveRange: effectiveRange, windowed: windowed, band: nil)
            }
        }
    }

    /// Whether a longer range the person can pick holds more readings than the window on screen, so "choose a longer
    /// range" is only said when it would help.
    private func longerRangeShowsMore(effectiveRange: ExploreRange, windowedCount: Int) -> Bool {
        effectiveRange.widening.dropFirst().contains { isUnlocked($0) && slice(for: $0).count > windowedCount }
    }

    /// The date of the latest reading, and — for a metric the Baselines engine backs — whether it is in range.
    private func eyebrowTrailing(band: TypicalBand?) -> EyebrowTrailing {
        guard let latestDate else { return .none }
        let asOf = String(localized: "as of \(dateText(latestDate))")
        switch band?.latestInRange {
        case true?: return .pillAndText("In range", tone: .positive, text: asOf)
        case false?: return .pillAndText("Outside range", tone: .warning, text: asOf)
        case nil: return .text(asOf)
        }
    }

    /// "9 Jun" this year, "9 Jun 2025" before it, in the person's language and order.
    private func dateText(_ date: Date) -> String {
        let sameYear = calendar.isDate(date, equalTo: Date(), toGranularity: .year)
        return sameYear
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// What the range control selects ("Last 30 days") with the control beside it, then the one caption under both. A
    /// range the history is too short for stays visible but dimmed and inert (#943).
    @ViewBuilder
    private func rangeControls(caption: (text: String, widened: Bool)?) -> some View {
        ExploreRangeControl(selection: selectionBinding, isEnabled: isUnlocked)
        if let caption {
            Text(caption.text)
                .font(StrandFont.micro)
                .foregroundStyle(caption.widened ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func trendChart(effectiveRange: ExploreRange,
                            windowed: [(day: String, value: Double)],
                            band: TypicalBand,
                            latestDate: Date,
                            tint: DomainTint) -> some View {
        let rangeDays: Int = {
            if let days = effectiveRange.days { return days }
            // ALL starts at the first reading (never a window shorter than a month, so a short history is not
            // stretched across the whole chart).
            return max(historySpanDays + 1, 30)
        }()
        let observations = zip(windowed, windowDates(windowed)).compactMap { row, date in
            date.map { CalendarMetricDay(date: $0, value: row.value) }
        }
        let days = TrendCalendar.buildRollingWindow(
            observations: observations, through: latestDate, count: rangeDays, calendar: calendar)
        if let domain = TrendCalendar.dateDomain(through: latestDate, count: rangeDays, calendar: calendar) {
            TrendsHeroChart(
                days: days,
                dateDomain: domain,
                referenceDate: latestDate,
                calendar: calendar,
                baseline: band.baseline,
                typical: band.typical,
                tint: tint,
                colorsLineByBand: metric.key == "recovery",
                unit: displayUnit,
                valueFormat: number,
                valueBounds: valueBounds,
                direction: chartDirection,
                metricName: metric.title,
                longRange: effectiveRange == .year || effectiveRange == .all,
                // A weekly or sparse series still draws one connected line; the chip tone follows the typical band,
                // not the sign of the move; and the pill drops under the value at the accessibility sizes.
                maxGapDays: ExploreCadence.gapLimitDays(
                    dayOffsets: days.indices.filter { days[$0].value != nil }),
                neutralInsideTypical: true,
                stacksPillAtAccessibilitySizes: true
            )
            .id("\(metric.id)-\(effectiveRange.rawValue)")
        }
    }

    /// The start of each windowed row's day, found by walking the series from the window's first row.
    private func windowDates(_ windowed: [(day: String, value: Double)]) -> [Date?] {
        let offset = series.count - windowed.count
        return windowed.indices.map { seriesDates.indices.contains(offset + $0) ? seriesDates[offset + $0] : nil }
    }

    private func statFooter(values: [Double]) -> some View {
        let stats = ComparisonEngine.stat(values)
        return StatFooter(items: [
            (String(localized: "Low"), fmt(stats.min)),
            (String(localized: "Average"), fmt(stats.mean)),
            (String(localized: "High"), fmt(stats.max)),
        ])
    }

    /// The typical band's numbers and the change against what came before, as quiet metric rows. A window with one
    /// reading has no band, and compares that reading with the one before it.
    @ViewBuilder
    private func comparisonRows(effectiveRange: ExploreRange,
                                windowed: [(day: String, value: Double)],
                                band: TypicalBand?) -> some View {
        let comparison = ComparisonEngine.compare(
            current: windowed.map(\.value),
            previous: previousWindow(effectiveRange: effectiveRange, windowed: windowed).map(\.value))
        let hasDelta = comparison.current.n > 0 && comparison.previous.n > 0
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            if let band {
                MetricValueRow(
                    systemImage: "arrow.left.and.right",
                    label: String(localized: "Typical range"),
                    value: "\(number(band.typical.lowerBound))\u{2013}\(number(band.typical.upperBound))",
                    unit: displayUnit.isEmpty ? nil : displayUnit,
                    tint: .neutral)
            }
            if hasDelta {
                MetricValueRow(
                    systemImage: comparison.direction > 0 ? "arrow.up.right" : (comparison.direction < 0 ? "arrow.down.right" : "arrow.right"),
                    label: windowed.count == 1
                        ? String(localized: "vs previous reading")
                        : String(localized: "vs prev \(effectiveRange.name)"),
                    value: signed(comparison.delta),
                    unit: comparison.pctChange.map { ExploreChange.signedPercent($0) },
                    tint: deltaTint(deltaPositive(direction: comparison.direction)))
            }
        }
    }

    private func deltaPositive(direction: Int) -> Bool? {
        guard direction != 0, let better = metric.higherIsBetter else { return nil }
        return (direction > 0) == better
    }

    /// The tint of a comparison row's glyph: green for a change in the good direction, red for the other, quiet for
    /// anything that has no good direction.
    private func deltaTint(_ positive: Bool?) -> DomainTint {
        switch positive {
        case true?: return .custom(StrandPalette.statusPositive)
        case false?: return .custom(StrandPalette.statusCritical)
        case nil: return .neutral
        }
    }

    /// One caption under the range control: "N readings", then why the range is not what was picked (a sparse window
    /// widened to a longer one) or, while some ranges are still locked, that longer ones unlock as history builds.
    /// Each tail is a whole phrase per range, so a language that inflects the range name (Russian, German) can.
    private func rangeCaption(effectiveRange: ExploreRange,
                              windowed: [(day: String, value: Double)],
                              windowFellBack: Bool) -> (text: String, widened: Bool)? {
        guard loaded, !series.isEmpty else { return nil }
        let readings = String(localized: "\(windowed.count) readings")
        if windowFellBack, let widened = effectiveRange.widenedPhrase {
            return ("\(readings) \u{00B7} \(widened)", true)
        }
        if hasLockedRanges {
            return ("\(readings) \u{00B7} \(String(localized: "longer ranges unlock as history builds"))", false)
        }
        return (readings, false)
    }

    private func load() async {
        #if DEBUG
        // QA: hold the detail in its loading state so that state can be captured (`--noop-qa-hold-load`).
        if ProcessInfo.processInfo.arguments.contains("--noop-qa-hold-load") { return }
        #endif
        let loadSeq = repo.refreshSeq
        let primary = metric.key == "strain"
            ? repo.canonicalDays.compactMap { day in
                repo.canonicalStrain(for: day.day).map { (day: day.day, value: $0.storedValue) }
            }
            : await repo.exploreSeries(key: metric.key, source: metric.source)
        guard !Task.isCancelled, loadSeq == repo.refreshSeq else { return }

        // First useful commit. The selected metric owns the hero, chart, stats, and range controls.
        // Correlations are secondary and should never hold the whole detail page behind their catalog scan.
        let dated = primary.compactMap { row in ExploreDayKey.date(for: row.day).map { (row: row, date: $0) } }
        series = dated.map(\.row)
        seriesDates = dated.map(\.date)
        seriesDayNumbers = dated.map { ExploreDayKey.dayNumber(for: $0.row.day) ?? 0 }
        loaded = true
        correlationsLoaded = false
        others = []
        correlationCache = []
        correlationKey = nil

        var loadedOthers: [(metric: MetricDescriptor, series: [(day: String, value: Double)])] = []
        for other in MetricCatalog.all where other.id != metric.id {
            guard !Task.isCancelled, loadSeq == repo.refreshSeq else { return }
            let s = other.key == "strain"
                ? repo.canonicalDays.compactMap { day in
                    repo.canonicalStrain(for: day.day).map { (day: day.day, value: $0.storedValue) }
                }
                : await repo.exploreSeries(key: other.key, source: other.source)
            if !s.isEmpty { loadedOthers.append((other, s)) }
        }
        guard !Task.isCancelled, loadSeq == repo.refreshSeq else { return }
        others = loadedOthers
        correlationsLoaded = true
        // #943 selection seam: a locked default (.month with under a week of history) no longer
        // OVERWRITES @State range - it renders through `coercedSelection` instead (non-destructive,
        // recomputed every body eval), so a shrinking history re-coerces and a growing one un-coerces
        // with no snap-back. See `coercedSelection`.
        // First correlation build, now that `series`/`others` exist.
        recomputeCorrelations()
    }

    // MARK: Correlations

    private struct CorrRow: Identifiable {
        let id: String
        let metric: MetricDescriptor
        let r: Double
        let n: Int
    }

    /// Top |r| catalog metrics over a given window (|r| ≥ 0.30, n ≥ 10). Pure — takes
    /// the window so the heavy scan can be driven from `recomputeCorrelations()` into
    /// the `@State` cache instead of running inside `body`.
    private func computeCorrelationRows(windowed: [(day: String, value: Double)]) -> [CorrRow] {
        let myDays = Set(windowed.map(\.day))
        guard !myDays.isEmpty else { return [] }
        var rows: [CorrRow] = []
        for entry in others {
            let otherWindowed = entry.series.filter { myDays.contains($0.day) }
            let pairs = CorrelationEngine.alignByDay(windowed, otherWindowed)
            guard pairs.count >= 10, let c = CorrelationEngine.pearson(pairs) else { continue }
            if abs(c.r) >= 0.3 {
                rows.append(CorrRow(id: entry.metric.id, metric: entry.metric, r: c.r, n: c.n))
            }
        }
        rows.sort { abs($0.r) > abs($1.r) }
        return Array(rows.prefix(6))
    }

    /// Rebuild the cached correlation scan for the CURRENT effective window, but only
    /// when its key (metric id + selected range) actually changed — so re-evals that
    /// don't alter the inputs (hover / HR ticks) are no-ops.
    private func recomputeCorrelations() {
        guard correlationsLoaded else { return }
        let key = "\(metric.id)|\(range.rawValue)"
        guard correlationKey != key else { return }
        correlationKey = key
        correlationCache = computeCorrelationRows(windowed: slice(for: effectiveRange))
    }

    private var correlationSection: some View {
        let rows = correlationCache
        return FlatSection("What correlates", systemImage: "link", contentSpacing: NoopMetrics.space1) {
            Text("Pearson r over the visible window · |r| ≥ 0.30, n ≥ 10")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !correlationsLoaded {
                HStack(spacing: NoopMetrics.space2) {
                    ProgressView().controlSize(.small)
                    Text("Reading related metrics…")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            } else if rows.isEmpty {
                Text("Nothing in the catalog moves clearly with \(metric.title.lowercased()) over this window. Widen the range to surface relationships.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { ExploreRowSeparator() }
                        correlationRowView(row)
                    }
                }
            }
        }
    }

    private func correlationRowView(_ row: CorrRow) -> some View {
        let strength = CorrelationStrength(r: row.r)
        let color = CorrelationStrength.color(for: row.r)
        let value = CorrelationStrength.signedText(row.r)
        return ExploreFlatRow(
            symbol: row.metric.icon,
            tint: row.metric.domainTint(),
            title: Text(verbatim: row.metric.title),
            subtitle: Text(verbatim: correlationSubtitle(row)),
            showsChevron: false,
            spoken: String(localized: "\(row.metric.title), \(strength.word) correlation \(value), \(row.n) days")
        ) {
            // Direction by sign and colour, strength by the word beside the number; no bar encodes |r| twice.
            CorrelationTrailing(value: value, word: strength.word, color: color)
        }
    }

    /// What sits under a correlated metric's name: its category when that is not just the name again, its source when
    /// it differs from this page's, then how many days the figure rests on.
    private func correlationSubtitle(_ row: CorrRow) -> String {
        var parts: [String] = []
        let category = MetricCatalog.categoryDisplayName(row.metric.category)
        if category.caseInsensitiveCompare(row.metric.title) != .orderedSame { parts.append(category) }
        if row.metric.source != metric.source { parts.append(row.metric.sourceLabel) }
        parts.append(String(localized: "n = \(row.n)"))
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Helpers

    private func signed(_ delta: Double) -> String {
        // A difference between two readings: route through the delta formatter so a temperature Δ
        // scales without the +32 offset.
        (delta >= 0 ? "+" : "−") + metric.formatDelta(abs(delta), system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func explorerPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Explore") {
    MetricExplorerView()
        .environmentObject(explorerPreviewRepo())
        .frame(width: 900, height: 820)
        .preferredColorScheme(.dark)
}

#Preview("Metric Detail") {
    NavigationStack {
        MetricDetailView(metric: MetricCatalog.all.first { $0.key == "recovery" }!)
    }
    .environmentObject(explorerPreviewRepo())
    .frame(width: 900, height: 820)
    .preferredColorScheme(.dark)
}
#endif
