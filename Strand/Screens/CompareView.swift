import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Compare
//
// The "overlay metrics & draw conclusions" screen, in the widget language: flat sections opened by an eyebrow, the
// selected metrics as glyph rows, one overlay chart with a touch-and-hold reading, and the verdict as a hero value and a
// couple of plain sentences. Pick 2-4 metrics from the catalog, choose a window, and read them on a single overlay where
// each metric is scaled to its own range so different units share an axis. Two metrics get the promoted pair experience
// (a lag choice, the verdict, and what the second metric did on high and low days of the first); three or four get every
// pair's relationship. Pure read-side: each metric loads from repo.resolvedSeries (freshest-wins across imported /
// NOOP-computed / compatible Apple Health, PR#196); everything else is derived in-view. The correlation word and colour
// are the shared `CorrelationStrength` rule, the same one the Metric Explorer and Lab Book read.

// MARK: - Per-series model

/// One selected metric, resolved over the active window: its descriptor, the windowed (day, value) rows, a stable
/// display colour, and its real min/max (found once, so the read-outs never rescan the rows).
private struct ResolvedCompareSeries: Identifiable {
    let metric: MetricDescriptor
    let color: Color
    let rows: [(day: String, value: Double)]
    let realMin: Double
    let realMax: Double

    var id: String { metric.id }

    init(metric: MetricDescriptor, color: Color, rows: [(day: String, value: Double)]) {
        self.metric = metric
        self.color = color
        self.rows = rows
        let values = rows.map(\.value)
        self.realMin = values.min() ?? 0
        self.realMax = values.max() ?? 0
    }
}

/// Which choice the picker sheet makes: a metric for one of the selected slots, or one more metric to add.
private enum CompareSlot: Hashable, Identifiable {
    case slot(Int)
    case add

    var id: String {
        switch self {
        case .slot(let index): return "slot-\(index)"
        case .add: return "add"
        }
    }
}

// MARK: - Root

struct CompareView: View {
    @EnvironmentObject var repo: Repository

    // Units follow the person's setting. Strain (#268) is routed onto WHOOP's 0-21 axis when that scale is chosen; this is
    // display-only, the scaled overlay shape is untouched.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit { UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw) }
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    private func format(_ metric: MetricDescriptor, _ value: Double) -> String {
        metric.format(value, system: unitSystem, temperature: temperatureUnit, effortScale: effortScale)
    }

    /// Trends-compatible categorical series colours. Recovery and Sleep keep their canonical blue and slate; further
    /// series take the next colour no other line has.
    private static let seriesPalette: [Color] = [
        StrandPalette.recoveryData,  // canonical Recovery blue
        StrandPalette.sleepAccent,   // canonical Sleep slate
        StrandPalette.metricPurple,  // purple
        StrandPalette.metricAmber,   // amber
    ]

    private static func canonicalColorIndex(_ key: String) -> Int? {
        let lowered = key.lowercased()
        if lowered.contains("sleep") { return 1 }
        if lowered.contains("recovery") { return 0 }
        return nil
    }

    /// The colour of each selected metric, by id, in pick order.
    private var seriesColors: [String: Color] {
        let indices = CompareLogic.colorIndices(
            keys: selected.map(\.key), canonical: Self.canonicalColorIndex, paletteCount: Self.seriesPalette.count)
        return Dictionary(uniqueKeysWithValues: zip(selected.map(\.id), indices.map { Self.seriesPalette[$0] }))
    }

    /// Default starter selection (falls back gracefully if a key is missing).
    private static let defaultKeys = ["recovery", "sleep_performance"]

    @State private var range: ExploreRange = .year
    /// Ordered selection (max 4). Drives both the read-out order and the colour mapping.
    @State private var selected: [MetricDescriptor] = []
    /// Full-history series per selected metric id (ascending by day).
    @State private var fullSeries: [String: [(day: String, value: Double)]] = [:]
    @State private var loadedOnce = false

    /// Cache of the last pairwise-correlation scan + the inputs it was computed for. The scan (alignByDay + Pearson over
    /// full windows) is expensive, so it is recomputed only when the windowed series content actually changes.
    @State private var pairCache: [PairResult] = []
    @State private var pairCacheKey: String = ""
    /// Real lag supplied directly to CorrelationEngine.lagged. Zero = same day; one = A today against B next morning.
    @State private var lagDays = 0
    @State private var pickerSlot: CompareSlot?
    /// The day under the finger on the overlay, nil when none.
    @State private var scrubDay: Date?

    private let maxSelection = 4
    private let minSelection = 2
    private var loadTaskID: String { "\(selectionKey)|\(repo.refreshSeq)" }

    var body: some View {
        ScreenScaffold(title: "Compare", subtitle: "Overlay signals, draw conclusions.",
                       // PERF (scroll): lazy column. The content is one inner eager VStack, with no staggered reveals,
                       // so nothing depends on eager layout of the scroll column.
                       lazy: true,
                       topBackground: nil) {
            VStack(alignment: .leading, spacing: 0) {
                metricsSection
                FlatSectionSeparator()
                results
            }
        }
        .task {
            await loadIfNeeded()
            #if DEBUG
            // Screenshot harness only: `--noop-qa-compare-picker` opens the metric picker on launch.
            if ProcessInfo.processInfo.arguments.contains("--noop-qa-compare-picker") { pickerSlot = .slot(0) }
            #endif
        }
        .task(id: loadTaskID) {
            await loadSelected()
            refreshPairCache(activeSeries)
        }
        // Recompute the pairwise scan only when the windowed series content changes, never on scrub or animation
        // re-renders that don't touch these inputs.
        .onChangeCompat(of: correlationKey(activeSeries)) { _ in
            refreshPairCache(activeSeries)
        }
        .sheet(item: $pickerSlot) { slot in
            CompareMetricPickerSheet(
                selected: selected,
                slot: slot,
                colorFor: { seriesColors[$0.id] },
                onSelect: { metric in
                    switch slot {
                    case .slot(let index): replaceMetric(at: index, with: metric)
                    case .add: toggle(metric)
                    }
                    pickerSlot = nil
                }
            )
            .sheetScreenScaffoldEnvironment(onClose: { pickerSlot = nil })
            #if os(iOS)
            .noopSheetPresentation(largeFirst: true)
            #else
            .frame(width: 560, height: 640)
            #endif
        }
    }

    // MARK: - What the selection shows

    @ViewBuilder
    private var results: some View {
        if selected.count < minSelection {
            let title: LocalizedStringKey = selected.isEmpty ? "Nothing selected yet." : "Add a second metric"
            ExploreMessage(
                symbol: "chart.xyaxis.line",
                title: Text(title),
                message: Text("Compare needs at least two metrics with history. Import your WHOOP export in Data Sources first."))
        } else {
            let series = activeSeries
            if series.allSatisfy({ $0.rows.isEmpty }) {
                if loadedOnce {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        ExploreRangeControl(selection: $range)
                        ExploreMessage(
                            symbol: "tray", title: Text("No data"),
                            message: Text("No data for these metrics in this range. Widen the range or pick metrics you've logged."))
                    }
                } else {
                    ExploreMessage(isLoading: true, title: Text("Reading your history…"))
                }
            } else if series.count == 2 {
                pairExperience(series[0], series[1])
            } else {
                // The established overlay remains the 3-4 metric experience.
                overlaySection(series)
                FlatSectionSeparator()
                correlationSection(series)
            }
        }
    }

    // MARK: - Selection key (re-loads when the set of metrics changes)

    private var selectionKey: String { selected.map(\.id).sorted().joined(separator: "|") }

    // MARK: - Active windowed series

    /// The range actually used for a series: the SELECTED range when its window holds at least one point, else the
    /// smallest LARGER range that does. So sparse metrics still overlay against dense ones, and switching ranges stays
    /// visibly distinct.
    private func effectiveRange(_ full: [(day: String, value: Double)]) -> ExploreRange {
        guard !full.isEmpty else { return range }
        for candidate in range.widening where !CompareLogic.slice(full, days: candidate.days).isEmpty { return candidate }
        return .all
    }

    /// Selected metrics resolved to windowed rows + stable colours, in pick order.
    private var activeSeries: [ResolvedCompareSeries] {
        let colors = seriesColors
        return selected.map { metric in
            let full = fullSeries[metric.id] ?? []
            return ResolvedCompareSeries(
                metric: metric,
                color: colors[metric.id] ?? StrandPalette.textSecondary,
                rows: CompareLogic.slice(full, days: effectiveRange(full).days))
        }
    }

    /// True if any selected series had to auto-widen past the selected range.
    private var anyWidened: Bool {
        selected.contains { metric in
            let full = fullSeries[metric.id] ?? []
            return !full.isEmpty && effectiveRange(full) != range
        }
    }

    /// "N readings" under the range control, flagging any auto-widen. One plural key, so each language picks its own
    /// form.
    private func rangeCaption(_ series: [ResolvedCompareSeries]) -> (text: String, widened: Bool) {
        let total = series.reduce(0) { $0 + $1.rows.count }
        let base = String(localized: "\(total) readings")
        guard anyWidened else { return (base, false) }
        return ("\(base) \u{00B7} \(String(localized: "sparse series widened"))", true)
    }

    // MARK: - Loading

    private func loadIfNeeded() async {
        guard selected.isEmpty else { return }
        #if DEBUG
        // Screenshot harness only: `--noop-qa-compare-metrics key[:source],…` opens Compare with those metrics chosen
        // (one, to see the "needs two" state; three or four, for the overlay; a metric with no data, for the empty state).
        if let qa = Self.qaRequestedSelection() { selected = qa; return }
        #endif
        // Seed the default selection from whichever default keys exist.
        var picks: [MetricDescriptor] = []
        for key in Self.defaultKeys {
            if let m = MetricCatalog.all.first(where: { $0.key == key }) { picks.append(m) }
        }
        if picks.isEmpty { picks = Array(MetricCatalog.all.prefix(2)) }
        selected = Array(picks.prefix(maxSelection))
    }

    #if DEBUG
    private static func qaRequestedSelection() -> [MetricDescriptor]? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--noop-qa-compare-metrics"),
              arguments.indices.contains(index + 1) else { return nil }
        let picks = arguments[index + 1].split(separator: ",").compactMap { item -> MetricDescriptor? in
            let parts = item.split(separator: ":").map(String.init)
            return MetricCatalog.all.first { $0.key == parts[0] && (parts.count < 2 || $0.source == parts[1]) }
        }
        return picks.isEmpty ? nil : Array(picks.prefix(4))
    }
    #endif

    /// Load the full history for the selected metrics. Selection is capped at four, so a repository refresh can safely
    /// replace cached rows instead of leaving Compare on a stale pre-sync snapshot.
    private func loadSelected() async {
        let loadSeq = repo.refreshSeq
        let requests = selected.map { (id: $0.id, key: $0.key, source: $0.source) }
        let fetched = await withTaskGroup(
            of: (String, [(day: String, value: Double)]).self,
            returning: [String: [(day: String, value: Double)]].self
        ) { group in
            for request in requests {
                group.addTask {
                    let values = await repo.resolvedSeries(
                        key: request.key,
                        source: request.source
                    ).values
                    return (request.id, values)
                }
            }
            var result: [String: [(day: String, value: Double)]] = [:]
            result.reserveCapacity(requests.count)
            for await (id, values) in group { result[id] = values }
            return result
        }
        guard !Task.isCancelled,
              loadSeq == repo.refreshSeq,
              requests.map(\.id).sorted() == selected.map(\.id).sorted()
        else { return }
        for request in requests { fullSeries[request.id] = fetched[request.id] ?? [] }
        loadedOnce = true
    }

    // MARK: - Metrics (the selection and what changes it)

    private var metricsSection: some View {
        FlatSection(
            "Metrics", systemImage: "chart.xyaxis.line", tint: .accent,
            trailing: .text("\(selected.count)/\(maxSelection)"),
            contentSpacing: 0
        ) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(selected.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 { ExploreRowSeparator() }
                    selectedRow(metric, index: index)
                }
                ChipRow {
                    let atMax = selected.count >= maxSelection
                    let addTitle: LocalizedStringKey = atMax ? "Max 4" : "Add metric"
                    WidgetChipButton(
                        title: addTitle, systemImage: "plus",
                        accessibilityLabel: "Add a metric to compare",
                        action: { pickerSlot = .add })
                        .disabled(atMax)
                        .opacity(atMax ? 0.5 : 1)
                    if selected.count == 2 {
                        WidgetChipButton(
                            title: "Swap", systemImage: "arrow.left.arrow.right",
                            accessibilityLabel: "Swap comparison axes",
                            action: swapPair)
                    }
                }
                .padding(.top, selected.isEmpty ? NoopMetrics.space3 : NoopMetrics.space2)
            }
        }
    }

    /// One selected metric: tap to choose a different one for its slot, the cross to take it off.
    private func selectedRow(_ metric: MetricDescriptor, index: Int) -> some View {
        let color = seriesColors[metric.id] ?? StrandPalette.textSecondary
        // With two metrics the rows are the pair: A and B.
        let role = selected.count == 2 ? (index == 0 ? "A" : "B") : nil
        let subtitle = role.map { "\($0) \u{00B7} \(metric.sourceLabel)" } ?? metric.sourceLabel
        return HStack(spacing: 0) {
            Button {
                pickerSlot = .slot(index)
            } label: {
                ExploreFlatRow(
                    symbol: metric.icon, tint: .custom(color),
                    title: Text(verbatim: metric.title), subtitle: Text(verbatim: subtitle),
                    showsChevron: false,
                    spoken: "\(metric.title), \(subtitle)")
            }
            .exploreRowPress()
            .accessibilityHint("Opens the metric picker")
            Button {
                remove(metric)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(metric.title)")
        }
    }

    private func toggle(_ metric: MetricDescriptor) {
        if selected.contains(metric) {
            remove(metric)
        } else if selected.count < maxSelection {
            withAnimation(StrandMotion.gentle) { selected.append(metric) }
        }
    }

    private func remove(_ metric: MetricDescriptor) {
        withAnimation(StrandMotion.gentle) { selected.removeAll { $0 == metric } }
        scrubDay = nil
    }

    private func replaceMetric(at index: Int, with metric: MetricDescriptor) {
        guard selected.indices.contains(index) else { return }
        if let existing = selected.firstIndex(of: metric), existing != index {
            selected.swapAt(index, existing)
        } else {
            selected[index] = metric
        }
        scrubDay = nil
        StrandHaptic.selection.play()
    }

    private func swapPair() {
        guard selected.count == 2 else { return }
        withAnimation(StrandMotion.interactive) { selected.swapAt(0, 1) }
        StrandHaptic.selection.play()
    }

    // MARK: - Overlay (the chart, its read-outs, the range)

    @ViewBuilder
    private func overlaySection(_ series: [ResolvedCompareSeries]) -> some View {
        let shown = series.filter { !$0.rows.isEmpty }
        let caption = rangeCaption(series)
        FlatSection(
            "Overlay", systemImage: "waveform.path.ecg", tint: .accent,
            trailing: .text(String(localized: "\(shown.count) series"))
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                // The reading's day (or how to read one), then each metric's real value on it.
                Text(scrubDay.map { dayText($0) } ?? String(localized: "Touch and hold, then drag, to read a day"))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: NoopMetrics.space2) {
                    ForEach(shown) { entry in
                        CompareReadoutRow(
                            color: entry.color,
                            title: entry.metric.title,
                            value: readoutValue(entry),
                            range: "\(format(entry.metric, entry.realMin)) \u{2013} \(format(entry.metric, entry.realMax))")
                    }
                }
                CompareOverlayChart(
                    series: shown.map(chartSeries),
                    selection: $scrubDay,
                    calendar: ExploreDayKey.calendar(),
                    summary: String(localized: "Overlay chart of \(ListFormatter.localizedString(byJoining: shown.map(\.metric.title)))"),
                    spokenValue: { spokenReadout($0, shown) }
                )
                ExploreRangeControl(selection: $range)
                Text(caption.text)
                    .font(StrandFont.micro)
                    .foregroundStyle(caption.widened ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chartSeries(_ entry: ResolvedCompareSeries) -> CompareSeries {
        CompareSeries(
            title: entry.metric.title,
            // The descriptor formatter already includes the unit.
            unit: "",
            tint: entry.color,
            points: entry.rows.compactMap { row in
                ExploreDayKey.date(for: row.day).map { ComparePoint(date: $0, value: row.value) }
            },
            format: { format(entry.metric, $0) }
        )
    }

    /// The metric's value on the day under the finger, else its latest.
    private func readoutValue(_ entry: ResolvedCompareSeries) -> String {
        if let day = scrubDay {
            guard let value = CompareLogic.value(in: entry.rows, onDay: ExploreDayKey.key(for: day)) else {
                return WidgetMetrics.missingValue
            }
            return format(entry.metric, value)
        }
        return entry.rows.last.map { format(entry.metric, $0.value) } ?? WidgetMetrics.missingValue
    }

    /// What VoiceOver says for the day the chart is stepped to: the date, then each metric's value.
    private func spokenReadout(_ day: Date, _ shown: [ResolvedCompareSeries]) -> String {
        let key = ExploreDayKey.key(for: day)
        let values = shown.map { entry -> String in
            let text = CompareLogic.value(in: entry.rows, onDay: key)
                .map { format(entry.metric, $0) } ?? String(localized: "no reading")
            return "\(entry.metric.title) \(text)"
        }
        return "\(dayText(day)), \(values.joined(separator: ", "))"
    }

    /// "Mon, 12 Oct" in the person's language and order.
    private func dayText(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    // MARK: - Promoted A/B pair experience

    @ViewBuilder
    private func pairExperience(_ a: ResolvedCompareSeries, _ b: ResolvedCompareSeries) -> some View {
        let correlation = CorrelationEngine.lagged(x: a.rows, y: b.rows, lagDays: lagDays)
        let paired = CompareLogic.lagPairs(a.rows, b.rows, lagDays: lagDays)
        overlaySection([a, b])
        FlatSectionSeparator()
        FlatSection("The verdict", systemImage: "scalemass", tint: .accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                SegmentedPillControl([0, 1], selection: $lagDays) {
                    $0 == 0 ? String(localized: "Same day") : String(localized: "Next morning")
                }
                .accessibilityLabel("Pairing")
                if a.rows.isEmpty || b.rows.isEmpty {
                    quietNote("Not enough dated readings for this pair in this range. Widen the range.")
                } else if let correlation {
                    verdict(a: a, b: b, r: correlation.r, n: correlation.n, paired: paired)
                } else {
                    quietNote("At least three overlapping, varying days are required for Pearson correlation.")
                }
            }
        }
    }

    private func quietNote(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func verdict(a: ResolvedCompareSeries, b: ResolvedCompareSeries, r: Double, n: Int,
                         paired: [(x: Double, y: Double)]) -> some View {
        let titleA = a.metric.title
        let titleB = b.metric.title
        let link = CompareLogic.Link(r: r)
        let pairing = lagDays == 0 ? String(localized: "same day") : String(localized: "next-morning lag")
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            CorrelationHero(r: r, caption: String(localized: "\(n) paired days"))
            Text(verbatim: headline(link, a: titleA, b: titleB))
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: sentence(link, a: titleA, b: titleB))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let split = CompareLogic.splitMeans(paired) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    MetricValueRow(
                        systemImage: "arrow.up.right",
                        label: String(localized: "\(titleB) on high \(titleA) days"),
                        value: format(b.metric, split.high),
                        tint: .custom(b.color),
                        labelLines: 2)
                    MetricValueRow(
                        systemImage: "arrow.down.right",
                        label: String(localized: "\(titleB) on low \(titleA) days"),
                        value: format(b.metric, split.low),
                        tint: .custom(b.color),
                        labelLines: 2)
                }
            }
            Text(verbatim: "\(pairing) \u{00B7} \(String(localized: "correlation, not causation"))")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }

    private func headline(_ link: CompareLogic.Link, a: String, b: String) -> String {
        switch link {
        case .none: return String(localized: "No clear \(a)-\(b) link")
        case .rises: return String(localized: "Higher \(a), higher \(b)")
        case .falls: return String(localized: "Higher \(a), lower \(b)")
        }
    }

    private func sentence(_ link: CompareLogic.Link, a: String, b: String) -> String {
        switch link {
        case .none: return String(localized: "Across this window, \(a) and \(b) mostly move independently.")
        case .rises: return String(localized: "When \(a) rises, \(b) tends to rise in the selected pairing.")
        case .falls: return String(localized: "When \(a) rises, \(b) tends to fall in the selected pairing.")
        }
    }

    // MARK: - Pairwise correlations (three or four metrics)

    private struct PairResult: Identifiable {
        let id: String
        let a: ResolvedCompareSeries
        let b: ResolvedCompareSeries
        let r: Double
        let n: Int
    }

    /// A stable fingerprint of the inputs the correlation scan depends on: the non-empty series (in order) and their
    /// windowed content. Row content only changes when `selected`, `range`, or fetched `fullSeries` change, so this
    /// covers every case that alters the scan result. Used to invalidate `pairCache`.
    private func correlationKey(_ series: [ResolvedCompareSeries]) -> String {
        series
            .filter { !$0.rows.isEmpty }
            .map { s in "\(s.id):\(s.rows.count):\(s.rows.first?.day ?? "")>\(s.rows.last?.day ?? "")" }
            .joined(separator: "|")
    }

    /// Cached accessor used by the body. Returns the memoized scan when the inputs match `pairCacheKey`; otherwise
    /// computes once for THIS render (without mutating state, which would be illegal mid-body) so the visible result is
    /// never stale by a frame. The matching `.onChange`/`.task` then persists the same result into `@State`.
    private func pairResults(_ series: [ResolvedCompareSeries]) -> [PairResult] {
        correlationKey(series) == pairCacheKey ? pairCache : computePairResults(series)
    }

    /// The actual (expensive) pairwise scan. Pure: no view state read or written.
    private func computePairResults(_ series: [ResolvedCompareSeries]) -> [PairResult] {
        var out: [PairResult] = []
        let s = series.filter { !$0.rows.isEmpty }
        guard s.count >= 2 else { return out }
        for i in 0..<(s.count - 1) {
            for j in (i + 1)..<s.count {
                let pairs = CorrelationEngine.alignByDay(s[i].rows, s[j].rows)
                guard pairs.count >= 3, let c = CorrelationEngine.pearson(pairs) else { continue }
                out.append(PairResult(id: "\(s[i].id)~\(s[j].id)", a: s[i], b: s[j], r: c.r, n: c.n))
            }
        }
        // Strongest relationships first.
        out.sort { abs($0.r) > abs($1.r) }
        return out
    }

    /// Recompute the pair cache if (and only if) the correlation inputs changed.
    private func refreshPairCache(_ series: [ResolvedCompareSeries]) {
        let key = correlationKey(series)
        guard key != pairCacheKey else { return }
        pairCacheKey = key
        pairCache = computePairResults(series)
    }

    @ViewBuilder
    private func correlationSection(_ series: [ResolvedCompareSeries]) -> some View {
        let pairs = pairResults(series)
        FlatSection(
            "How They Move Together", systemImage: "link", tint: .accent,
            trailing: pairs.isEmpty ? .none
                : .text(pairs.count == 1 ? String(localized: "1 pair") : String(localized: "\(pairs.count) pairs")),
            contentSpacing: NoopMetrics.space1
        ) {
            Text("Pearson r over the visible window")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if pairs.isEmpty {
                Text("Not enough overlapping days between these metrics in this range. Widen the range.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(pairs.enumerated()), id: \.element.id) { index, pair in
                        if index > 0 { ExploreRowSeparator() }
                        pairRow(pair)
                    }
                }
            }
        }
    }

    /// One pairwise relationship: the two names, one plain sentence, how many days it rests on, and r with its word.
    private func pairRow(_ pair: PairResult) -> some View {
        let strength = CorrelationStrength(r: pair.r)
        let color = CorrelationStrength.color(for: pair.r)
        let value = CorrelationStrength.signedText(pair.r)
        let titleA = pair.a.metric.title
        let titleB = pair.b.metric.title
        let sentence: String
        switch CompareLogic.Link(r: pair.r) {
        case .none: sentence = String(localized: "No clear relationship. They move largely independently.")
        case .rises: sentence = String(localized: "When \(titleA) rises, \(titleB) tends to rise.")
        case .falls: sentence = String(localized: "When \(titleA) rises, \(titleB) tends to fall.")
        }
        let days = String(localized: "\(pair.n) overlapping days")
        return ExploreFlatRow(
            symbol: "arrow.left.arrow.right",
            tint: .custom(color),
            title: Text(verbatim: "\(titleA) \u{2194} \(titleB)"),
            subtitle: Text(verbatim: sentence),
            detail: Text(verbatim: days),
            showsChevron: false,
            spoken: String(localized: "\(titleA) versus \(titleB), \(strength.word) correlation \(value), \(pair.n) days")
        ) {
            // Direction by sign and colour, strength by the word beside the number.
            CorrelationTrailing(value: value, word: strength.word, color: color)
        }
    }
}

// MARK: - A metric's read-out under the overlay

/// One line under the overlay: the line's colour, the metric's name, its value on the day shown and the span it covered
/// in the window. At the accessibility sizes the value drops under the name.
private struct CompareReadoutRow: View {
    let color: Color
    let title: String
    let value: String
    let range: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    nameLine
                    valueText
                    rangeText
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        nameLine
                        Spacer(minLength: NoopMetrics.space2)
                        valueText
                    }
                    rangeText.padding(.leading, 8 + NoopMetrics.space2)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title), \(value), \(range)"))
    }

    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(verbatim: title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
                .minimumScaleFactor(0.8)
        }
    }

    private var valueText: some View {
        Text(verbatim: value)
            .font(StrandFont.bodyNumber)
            .foregroundStyle(value == WidgetMetrics.missingValue ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var rangeText: some View {
        Text(verbatim: range)
            .font(StrandFont.micro)
            .foregroundStyle(StrandPalette.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

// MARK: - Full-catalog metric picker

/// The picker sheet: the whole catalog by category with search. It chooses the metric for one of the selected slots, or
/// one more to add; a metric already chosen shows a tick.
private struct CompareMetricPickerSheet: View {
    let selected: [MetricDescriptor]
    let slot: CompareSlot
    let colorFor: (MetricDescriptor) -> Color?
    let onSelect: (MetricDescriptor) -> Void
    @State private var query = ""

    private var filtered: [MetricDescriptor] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return MetricCatalog.all }
        return MetricCatalog.all.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.category.localizedCaseInsensitiveContains(q)
                || MetricCatalog.categoryDisplayName($0.category).localizedCaseInsensitiveContains(q)
                || $0.sourceLabel.localizedCaseInsensitiveContains(q)
        }
    }

    /// The metric the slot being replaced holds now.
    private var current: MetricDescriptor? {
        if case .slot(let index) = slot, selected.indices.contains(index) { return selected[index] }
        return nil
    }

    private var slotTitle: LocalizedStringKey {
        switch slot {
        case .add: return "Add a metric"
        case .slot(let index):
            // The rows carry the letters A and B only for a pair; with three or four metrics the title names no letter.
            guard selected.count == 2 else { return "Replace metric" }
            return index == 0 ? "Metric A" : "Metric B"
        }
    }

    var body: some View {
        ScreenScaffold(title: slotTitle, lazy: true, topBackground: nil) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                PaperSearchField("Search metrics", text: $query, height: 44, cornerRadius: 10,
                                 inputConfiguration: .searchQuery)
                    .accessibilityLabel("Search metrics")
                let rows = filtered
                if rows.isEmpty {
                    ExploreMessage(symbol: "magnifyingglass", title: Text("No metrics match"))
                } else {
                    ForEach(MetricCatalog.categories, id: \.self) { category in
                        let inCategory = rows.filter { $0.category == category }
                        if !inCategory.isEmpty {
                            // Localized at the render site only; `category` itself stays the raw English identifier.
                            FlatSection(
                                verbatim: MetricCatalog.categoryDisplayName(category),
                                systemImage: MetricCatalog.categorySymbol(category),
                                tint: MetricCatalog.categoryTint(category),
                                trailing: .text(inCategory.count.formatted()),
                                contentSpacing: 0
                            ) {
                                VStack(spacing: 0) {
                                    ForEach(Array(inCategory.enumerated()), id: \.element.id) { index, metric in
                                        if index > 0 { ExploreRowSeparator() }
                                        row(metric)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ metric: MetricDescriptor) -> some View {
        let isChosen = selected.contains(metric)
        let isAdding = slot == .add
        return Button {
            onSelect(metric)
        } label: {
            ExploreFlatRow(
                symbol: metric.icon, tint: metric.domainTint(),
                title: Text(verbatim: metric.title), subtitle: Text(verbatim: metric.sourceLabel),
                showsChevron: false,
                spoken: metric.title + ", " + metric.sourceLabel
            ) {
                if isChosen {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(colorFor(metric) ?? StrandPalette.accent)
                        .accessibilityHidden(true)
                }
            }
        }
        .exploreRowPress()
        // Adding a metric that is already chosen would only take it off again; leave it showing its tick.
        .disabled(isAdding && isChosen)
        .accessibilityAddTraits(current == metric ? .isSelected : [])
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func comparePreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Compare") {
    CompareView()
        .environmentObject(comparePreviewRepo())
        .frame(width: 920, height: 860)
        .preferredColorScheme(.dark)
}
#endif
