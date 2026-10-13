import SwiftUI
import Foundation
import StrandDesign
import StrandImport
import StrandAnalytics
import WhoopStore

// MARK: - Marker detail (history + trend + "compare with a signal")
//
// One marker's page, in the flat widget language: the latest reading as a hero value over a touch-and-hold chart of
// every reading, a plain description of the trend, then "Compare with a signal" and the history. NOOP states what the
// numbers do, never what they mean: no word here calls a value normal, high or low, and any reference range is exactly
// what the person typed from their own report.

struct MarkerDetailView: View {
    let markerKey: String
    let readings: [LabMarkerRow]
    let onDelete: (_ id: String) async -> Void

    @EnvironmentObject var repo: Repository
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The wearable metric chosen to correlate against (nil until the user picks one).
    @State private var signal: MetricDescriptor?
    /// The trailing-window width for the windowed-aggregate pairing.
    @State private var window: LabWindow = .fortnight
    /// The computed correlation result, recomputed when signal/window change.
    @State private var pairs: [WindowedPair] = []
    @State private var correlation: Correlation?
    @State private var computing = false
    /// The reading under the finger on the chart (an index into `chartReadings`), nil when none.
    @State private var scrubIndex: Int?
    /// The reading the person asked to delete, until they confirm.
    @State private var pendingDelete: LabMarkerRow?

    private let accent = DomainTint.custom(StrandPalette.metricCyan)

    private var displayName: String { LabBookView.displayName(for: markerKey) }
    private var unit: String { readings.last?.unit ?? MarkerCatalog.definition(for: markerKey)?.canonicalUnit ?? "" }
    private var numericReadings: [LabMarkerRow] { readings.filter { $0.value != nil } }
    private var symbol: String {
        LabMarkerCategory(rawValue: readings.last?.category ?? "")?.symbol
            ?? MarkerCatalog.definition(for: markerKey)?.category.symbol ?? "flask"
    }

    /// The numeric readings that have a real day, oldest first, with that day: what the chart draws and the hero reads.
    private var chartReadings: [(row: LabMarkerRow, date: Date, value: Double)] {
        numericReadings.compactMap { row in
            guard let value = row.value, let date = ExploreDayKey.date(for: row.day) else { return nil }
            return (row, date, value)
        }
    }

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(dataText: displayName),
                       // Whole-phrase variants per count (never a stitched plural).
                       subtitle: readings.count == 1 ? "1 reading · your own entries"
                                                     : "\(readings.count) readings · your own entries",
                       // PERF: a chart plus a row-per-reading history list. The LazyVStack path builds the off-screen
                       // history rows on demand, so a marker with many readings doesn't materialise its whole list
                       // before the chart is on screen.
                       lazy: true) {
            VStack(alignment: .leading, spacing: 0) {
                trendSection
                if !numericReadings.isEmpty {
                    FlatSectionSeparator()
                    compareSection
                }
                FlatSectionSeparator()
                historySection
                Text("These are your own numbers shown back to you. NOOP doesn't decide whether any value is normal, high or low.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NoopMetrics.space4)
            }
        }
        // A long marker name is scaled to the row at the accessibility sizes, never broken mid-word.
        .headerTitleKeepsWordsWhole(of: displayName)
        #if os(iOS)
        .presentationDragIndicator(.visible)
        #else
        // Fixed frame — a macOS sheet around a ScrollView needs a definite height or its rows
        // collapse to the top and overlap (the "Add a reading" layout bug).
        .frame(width: 520, height: 720)
        #endif
        .background(StrandPalette.surfaceBase)
        .confirmationDialog("Delete this reading?", isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let row = pendingDelete { Task { await onDelete(row.id) } }
                pendingDelete = nil
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        }
        #if DEBUG
        .onAppear(perform: qaPickSignal)
        #endif
    }

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
    }

    #if DEBUG
    /// Screenshot harness only: `--noop-qa-marker-signal <metric key>` picks the comparison's signal on open.
    private func qaPickSignal() {
        let arguments = ProcessInfo.processInfo.arguments
        guard signal == nil, let index = arguments.firstIndex(of: "--noop-qa-marker-signal"),
              arguments.indices.contains(index + 1) else { return }
        let key = arguments[index + 1]
        signal = LabBookSignals.options.first { $0.key == key }
    }
    #endif

    // MARK: - Trend (descriptive arithmetic, never interpretation)

    private var trendSection: some View {
        let points = chartReadings
        let shown = scrubIndex.flatMap { points.indices.contains($0) ? points[$0] : nil } ?? points.last
        return VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                title: String(localized: "Trend"),
                systemImage: symbol,
                tint: accent,
                trailing: asOf(points.last?.row))
            if let shown {
                // Value first: the reading (the latest, or the one under the finger), then the chart of them all.
                HeroValue(
                    value: LabBookFormat.value(shown.value, key: markerKey),
                    unit: shown.row.unit.isEmpty ? nil : shown.row.unit,
                    caption: scrubIndex == nil
                        ? String(localized: "latest \u{00B7} \(LabBookFormat.dayFromKey(shown.row.day))")
                        : LabBookFormat.dayFromKey(shown.row.day),
                    captionPlacement: .below)
            }
            if points.count > 1, let first = points.first, let last = points.last {
                ScrubChart(
                    points: points.map { ScrubChartPoint(date: $0.date, value: $0.value) },
                    domain: first.date...last.date,
                    tint: accent,
                    selection: $scrubIndex,
                    // A marker is taken weeks or months apart: one connected line, never a break at a long gap.
                    maxGapDays: 36_500,
                    calendar: ExploreDayKey.calendar(),
                    summary: String(localized: "\(displayName) readings over time"),
                    stepHint: "Swipe up or down to step through readings",
                    spokenValue: { point in
                        "\(LabBookFormat.value(point.value, key: markerKey)) \(unit), \(point.date.formatted(.dateTime.day().month(.abbreviated).year()))"
                    })
            }
            Text(trendSentence)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let ref = latestReferenceText {
                referenceRow(ref)
            }
        }
    }

    /// The date of the latest reading, at the eyebrow's trailing edge.
    private func asOf(_ row: LabMarkerRow?) -> EyebrowTrailing {
        guard let row else { return .none }
        return .text(String(localized: "as of \(LabBookFormat.dayFromKey(row.day))"))
    }

    /// What the person typed from their own report, shown back exactly.
    private func referenceRow(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            Image(systemName: "doc.text")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: WidgetMetrics.metricIconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("from your report")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                Text(verbatim: text)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Your last 3 LDL readings: 3.4 → 3.1 → 2.9 mmol/L, trending down." — descriptive only.
    /// Whole-phrase variants per direction so translators never see a stitched trend fragment.
    private var trendSentence: String {
        let nums = numericReadings
        guard let last = nums.last?.value else {
            return readings.last?.valueText.map { String(localized: "Latest entry: \($0).") } ?? String(localized: "No numeric readings yet.")
        }
        guard nums.count >= 2 else {
            return String(localized: "One reading so far: \(LabBookFormat.value(last, key: markerKey)) \(unit). Log a few more to see a trend.")
        }
        let shown = nums.suffix(3).compactMap { $0.value }
        let arrowed = shown.map { LabBookFormat.value($0, key: markerKey) }.joined(separator: " → ")
        let first = shown.first ?? last
        if last > first {
            return String(localized: "Your last \(shown.count) readings: \(arrowed) \(unit), trending up.")
        }
        if last < first {
            return String(localized: "Your last \(shown.count) readings: \(arrowed) \(unit), trending down.")
        }
        return String(localized: "Your last \(shown.count) readings: \(arrowed) \(unit), holding steady.")
    }

    private var latestReferenceText: String? {
        readings.last(where: { ($0.referenceText?.isEmpty == false) })?.referenceText
    }

    // MARK: - Compare with a signal (the shared correlation rule + the mandatory markers clause)

    private var compareSection: some View {
        FlatSection("Compare with a signal", systemImage: "link", tint: accent) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                // Signal picker + window control.
                TrendsControlRow(
                    leading: { _ in signalMenu },
                    trailing: {
                        SegmentedPillControl(LabWindow.allCases, selection: $window) { $0.label }
                            .accessibilityLabel("Trailing window")
                    })
                Text("side by side · \(window.phrase) before each reading")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if signal == nil {
                    Text("Pick a wearable signal (resting HR, HRV, sleep, Recovery, weight…) to line it up against this marker. NOOP averages the signal over the \(window.phrase) before each reading.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    resultBlock
                }
            }
        }
        .task(id: "\(signal?.id ?? "")|\(window.rawValue)|\(repo.refreshSeq)") {
            await recompute()
        }
    }

    @ViewBuilder
    private var signalMenu: some View {
        if typeSize.isAccessibilitySize {
            // The chip keeps its name on one line, which at these sizes is wider than the screen: the choice is a
            // wrapping menu label instead.
            Menu {
                signalItems
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Text(verbatim: signal?.title ?? String(localized: "Choose a signal"))
                        .font(StrandFont.headline)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(accent.accent)
                .frame(minHeight: 44, alignment: .leading)
            }
            .accessibilityLabel("Choose a wearable signal to compare")
            .accessibilityValue(Text(verbatim: signal?.title ?? ""))
        } else {
            ChipMenu(
                verbatimTitle: signal?.title ?? String(localized: "Choose a signal"),
                systemImage: signal == nil ? "plus" : nil,
                isSelected: signal != nil,
                accessibilityLabel: "Choose a wearable signal to compare",
                accessibilityValue: signal?.title ?? ""
            ) {
                signalItems
            }
        }
    }

    @ViewBuilder
    private var signalItems: some View {
        ForEach(LabBookSignals.options) { metric in
            Button {
                signal = metric
            } label: {
                Label {
                    Text(verbatim: metric.title)
                } icon: {
                    Image(systemName: signal?.id == metric.id ? "checkmark" : metric.icon)
                }
            }
        }
        if signal != nil {
            Divider()
            Button(role: .destructive) { signal = nil } label: { Label("Clear", systemImage: "xmark") }
        }
    }

    @ViewBuilder
    private var resultBlock: some View {
        let n = pairs.count
        if computing {
            quietNote(Text("Lining them up…"))
        } else if n < LabBookSignals.floor {
            // Below the floor: show the points exist, withhold the conclusion sentence.
            // Whole-phrase variants per count (never a stitched plural).
            let note: LocalizedStringKey = n == 1
                ? "1 reading lines up so far, not enough to read a trend yet (NOOP waits for \(LabBookSignals.floor))."
                : "\(n) readings line up so far, not enough to read a trend yet (NOOP waits for \(LabBookSignals.floor))."
            if n == 0 {
                quietNote(Text("No overlap yet between this marker and \(signal?.title ?? String(localized: "that signal")). Log a few more readings (and keep wearing your strap)."))
            } else {
                quietNote(Text(note))
            }
        } else if let c = correlation {
            pairResult(c, n: n)
        } else {
            quietNote(Text("\(n) readings line up, but there isn't enough variation to compute a relationship."))
        }
    }

    private func quietNote(_ text: Text) -> some View {
        text
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// One correlation read-out: r as a hero value with its word, the two names, one plain sentence, and the mandatory
    /// markers clause. The word and colour are the shared `CorrelationStrength` rule.
    private func pairResult(_ c: Correlation, n: Int) -> some View {
        let signalName = signal?.title ?? ""
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            CorrelationHero(r: c.r, caption: String(localized: "\(n) readings"))
            Text(verbatim: "\(displayName) \u{2194} \(signalName)")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: LabBookSignals.insightSentence(markerName: displayName, signalName: signalName, r: c.r))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: LabBookSignals.associationClause(n: n, r: c.r))
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - History

    private var historySection: some View {
        FlatSection(
            "History", systemImage: "list.bullet", tint: accent,
            trailing: .text(readings.count.formatted()),
            contentSpacing: NoopMetrics.space1
        ) {
            Text("every reading you've entered")
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                let rows = Array(readings.reversed())
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { ExploreRowSeparator() }
                    historyRow(row)
                }
            }
        }
    }

    /// One reading: its value, its date and note, and a separate delete button (asked to confirm first).
    private func historyRow(_ row: LabMarkerRow) -> some View {
        let value = valueLabel(row)
        let date = LabBookFormat.dayFromKey(row.day)
        let note = row.note.flatMap { $0.isEmpty ? nil : $0 }
        return HStack(spacing: 0) {
            ExploreFlatRow(
                symbol: "calendar", tint: accent,
                title: Text(verbatim: value),
                subtitle: Text(verbatim: date),
                detail: note.map { Text(verbatim: $0) },
                showsChevron: false,
                spoken: [value, date, note].compactMap { $0 }.joined(separator: ", "))
            Button {
                pendingDelete = row
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .foregroundStyle(StrandPalette.statusCritical)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete this reading")
        }
    }

    private func valueLabel(_ row: LabMarkerRow) -> String {
        if let v = row.value { return "\(LabBookFormat.value(v, key: markerKey)) \(row.unit)" }
        return row.valueText ?? WidgetMetrics.missingValue
    }

    // MARK: - Correlation compute (windowed-aggregate pairing → Pearson)

    private func recompute() async {
        guard let signal else { pairs = []; correlation = nil; return }
        computing = true
        defer { computing = false }
        let loadSeq = repo.refreshSeq
        // The marker series, read from the projected `lab-book` daily series (numeric only).
        async let markerLoad = repo.series(key: markerKey, source: WhoopStore.labBookSourceId)
        // The wearable series, freshest-wins through the Explore read path.
        async let wearableLoad = repo.exploreSeries(key: signal.key, source: signal.source)
        let markerSeries = await markerLoad
        let wearable = await wearableLoad
        guard !Task.isCancelled, loadSeq == repo.refreshSeq else { return }
        let built = LabBookProjection.pairMarkerToWearable(marker: markerSeries,
                                                           wearable: wearable,
                                                           windowDays: window.days)
        pairs = built
        correlation = built.count >= LabBookSignals.floor
            ? CorrelationEngine.pearson(LabBookProjection.correlationInput(built))
            : nil
    }
}
