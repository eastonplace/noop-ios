import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Insights
//
// The full Insights page, opened from the foot of Trends and from Explore, built in the Heads-Up detail page's
// language: a hero naming the strongest finding, sections per outcome of signal-style rows (icon, factor, the two
// averages, the signed change and one thin rail), the factors that showed nothing folded into one row, alcohol and
// late caffeine drink by drink, then a numbered "How insights work" and the on-device line.
//
// Rows come from InsightsReport: automatic factors from the wearable and explicit Journal answers, tested at one
// fixed lag and corrected for the number of tests. Association, never cause or advice.

struct InsightsHubView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = InsightsHubViewModel()
    @State private var showJournal = false
    @State private var showUnclear = false

    private static let iconColumn = InsightFindingRow.iconColumn

    var body: some View {
        ScreenScaffold(title: "Insights", lazy: true) {
            VStack(alignment: .leading, spacing: 0) {
                hero
                if model.loaded {
                    findings
                    unclearSection
                    ForEach(model.doseCards) { card in
                        DrillInSeparator()
                        DoseSection(card: card)
                    }
                    DrillInSeparator()
                    moreSection
                    DrillInSeparator()
                    howSection
                    DrillInSeparator()
                    footer
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("insights.detail")
        }
        .task(id: InsightsLoadIdentity(repo: repo)) { await model.load(repo: repo) }
        .sheet(isPresented: $showJournal) {
            #if os(iOS)
            CoachingRootView()
                .sheetScreenScaffoldEnvironment(onClose: { showJournal = false })
            #else
            CoachingRootView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showJournal = false }
                    }
                }
            #endif
        }
    }

    // MARK: Hero

    private var hero: some View {
        let report = model.report
        let top = report.significant.first
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(StrandFont.body.weight(.semibold))
                    .foregroundStyle(top.map(InsightInk.tint) ?? StrandPalette.textSecondary)
                    .accessibilityHidden(true)
                Text(verbatim: overline)
                    .strandOverline()
            }
            Text(verbatim: headline(top))
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: heroBody(top))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, NoopMetrics.space2)
        .accessibilityIdentifier("insights.hero")
    }

    private var overline: String {
        let days = model.report.daysOfData
        guard model.loaded, model.report.hasEnoughData else { return String(localized: "From your own data") }
        return String(localized: "From \(days) days of your data")
    }

    private func headline(_ top: InsightRow?) -> String {
        guard model.loaded else { return String(localized: "Reading your patterns") }
        guard model.report.hasEnoughData else { return String(localized: "Insights need about 2 weeks of wear") }
        return top?.headline ?? String(localized: "No clear patterns yet")
    }

    private func heroBody(_ top: InsightRow?) -> String {
        guard model.loaded else { return String(localized: "NOOP is comparing your nights and days on this device.") }
        guard model.report.hasEnoughData else {
            return String(localized: "NOOP compares your nights with each other, so it needs enough of them first.")
        }
        return top?.sentence ?? String(localized: "Nothing you do lines up with a clear difference yet. NOOP checks again as more nights come in.")
    }

    // MARK: Findings, one section per outcome

    @ViewBuilder private var findings: some View {
        let report = model.report
        ForEach(InsightOutcome.allCases.filter { !report.significant(for: $0).isEmpty }, id: \.self) { outcome in
            let rows = report.significant(for: outcome)
            DrillInSeparator()
            FlatSection(verbatim: sectionTitle(outcome), systemImage: outcome.symbol, tint: tint(outcome),
                        contentSpacing: 4) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { FlatRowSeparator() }
                        InsightFindingRow(row: row, scale: Self.scale(rows))
                    }
                }
            }
            .accessibilityIdentifier("insights.outcome.\(outcome.rawValue)")
        }
    }

    /// One shared range for a section's rails: every average in it, padded a little each side.
    static func scale(_ rows: [InsightRow]) -> ClosedRange<Double> {
        let values = rows.flatMap { [$0.effect.effect.meanWith, $0.effect.effect.meanWithout] }
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max((hi - lo) * 0.25, 1)
        return (lo - pad)...(hi + pad)
    }

    private func sectionTitle(_ outcome: InsightOutcome) -> String {
        switch outcome {
        case .recovery: return String(localized: "Patterns in your recovery")
        case .hrv: return String(localized: "Patterns in your HRV")
        case .sleep: return String(localized: "Patterns in your sleep")
        case .rhr: return String(localized: "Patterns in your resting HR")
        }
    }

    private func tint(_ outcome: InsightOutcome) -> DomainTint {
        switch outcome {
        case .recovery: return .recovery(score: 70)
        case .hrv: return .hrv
        case .sleep: return .sleep
        case .rhr: return .heart
        }
    }

    // MARK: No clear difference, folded

    @ViewBuilder private var unclearSection: some View {
        let unclear = model.report.hasEnoughData ? model.report.unclear : []
        if !unclear.isEmpty {
            DrillInSeparator()
            VStack(alignment: .leading, spacing: 0) {
                Button { withAnimation(.easeInOut(duration: 0.2)) { showUnclear.toggle() } } label: {
                    HStack(spacing: NoopMetrics.space3) {
                        InsightRowIcon(symbol: "circle.dashed", tint: StrandPalette.textTertiary)
                        Text(unclear.count == 1
                             ? String(localized: "1 more checked, no clear difference yet")
                             : String(localized: "\(unclear.count) more checked, no clear difference yet"))
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: NoopMetrics.space2)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .rotationEffect(.degrees(showUnclear ? 90 : 0))
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(showUnclear ? Text("Expanded") : Text("Collapsed"))
                .accessibilityIdentifier("insights.unclear")
                if showUnclear {
                    ForEach(unclear) { factor in
                        FlatRowSeparator()
                        InsightUnclearFactorRow(factor: factor)
                    }
                }
            }
        }
    }

    // MARK: Add your own, and the older views

    private var moreSection: some View {
        FlatSection("Add your own", systemImage: "square.and.pencil", tint: .journal, contentSpacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Log a habit in the Journal and NOOP tests it the same way.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NoopMetrics.space1)
                HeadsUpTextButton(action: { showJournal = true }) { Text("Open Journal") }
                    .padding(.vertical, NoopMetrics.space2)
                    .accessibilityIdentifier("insights.openJournal")
                FlatRowSeparator()
                NavigationLink { InsightsView() } label: {
                    InsightsLinkRow(symbol: "chart.xyaxis.line",
                                    title: String(localized: "Mind, caffeine log and workouts"),
                                    subtitle: String(localized: "Check-ins, caffeine timing and what each sport costs you"))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("insights.more")
            }
        }
    }

    // MARK: How it works

    private var howSection: some View {
        FlatSection("How insights work", systemImage: "questionmark.circle", tint: .neutral) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                howStep(1, title: "Compares your nights with and without",
                        detail: "For each habit, the mornings after nights you did it against the mornings after nights you did not.")
                howStep(2, title: "Needs enough of both",
                        detail: "At least 5 nights on each side. Solid means 10 or more, Building means 5 to 9.")
                howStep(3, title: "Checks it isn't chance",
                        detail: "A gap shows only when it is bigger than chance would explain, after allowing for how many things were checked.")
            }
        }
    }

    private func howStep(_ number: Int, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Text(verbatim: "\(number)")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: Self.iconColumn, alignment: .leading)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.body.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Label {
                Text("Worked out on your phone. Never uploaded, never synced.")
            } icon: {
                Image(systemName: "lock.fill")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            Text("Patterns in your own data, not causes and not medical advice.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, NoopMetrics.space6)
    }

    /// Map the engine's ScoreConfidence tier to the design-system ScoreState pill.
    static func scoreState(_ c: ScoreConfidence) -> ScoreState {
        switch c {
        case .solid:       return .solid
        case .building:    return .building
        case .calibrating: return .calibrating
        }
    }
}

// MARK: - Alcohol and late caffeine, step by step
//
// One plain sentence, then one flat row per step (0, 1, 2, 3+ drinks; morning, noon, after 2 pm, evening) with the
// next-morning value it lines up with. Each value starts from the person's own typical morning on a clear day and
// adds the engine's curve, so the rows and the sentence always agree. A what-if, never advice.

private struct DoseSection: View {
    let card: InsightsHubViewModel.DoseCard

    private static let iconColumn = InsightFindingRow.iconColumn

    var body: some View {
        let r = card.response
        FlatSection(verbatim: card.sectionTitle, systemImage: card.symbol, tint: .journal, contentSpacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: card.sentence)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, NoopMetrics.space1)
                Text(verbatim: card.basis)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
                    .padding(.bottom, NoopMetrics.space2)
                ForEach(card.doseChoices, id: \.self) { dose in
                    FlatRowSeparator()
                    stepRow(dose, response: r)
                }
            }
        }
        .accessibilityIdentifier("insights.dose.\(card.id)")
    }

    private func stepRow(_ dose: Int, response r: DoseResponse) -> some View {
        let change = r.delta(fromDose: 0, toDose: dose)
        return HStack(spacing: NoopMetrics.space3) {
            Text(verbatim: card.stepName(dose))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: NoopMetrics.space2)
            if dose > 0 {
                Text(verbatim: card.signed(change))
                    .font(StrandFont.footnote)
                    .monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text(verbatim: card.typical.map { card.format($0 + change) } ?? "—")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(minWidth: 56, alignment: .trailing)
        }
        .frame(minHeight: 40)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - View-model
//
// Loads the shared InsightsReport (also used by Trends and the Coach) plus the alcohol/caffeine
// dose series for the DoseResponseEngine cards.

/// Journal writes and source replacement can change inputs without a wearable refresh.
/// Both mounted Insights surfaces must reload when any part of their read identity changes.
struct InsightsLoadIdentity: Equatable, Hashable {
    let sourceContext: String
    let refreshSeq: Int
    let journalRevision: Int

    @MainActor init(repo: Repository) {
        sourceContext = repo.notificationSourceContext
        refreshSeq = repo.refreshSeq
        journalRevision = repo.journalRevision
    }
}

@MainActor
final class InsightsHubViewModel: ObservableObject {

    @Published private(set) var loaded = false
    @Published private(set) var report = InsightsReport.empty
    @Published private(set) var doseCards: [DoseCard] = []

    /// The source id dose rows are parked under (mirrors MoodStore's noop-mood isolation).
    static let doseSource = "noop-journal-dose"

    private var loadID: UUID?

    struct LoadedContent {
        let report: InsightsReport
        let doseCards: [DoseCard]
    }

    func load(repo: Repository) async {
        await load(repo: repo) { await Self.read(repo: repo) }
    }

    /// Keep publication separate from reads so a cancelled or replaced request cannot restore old data.
    func load(repo: Repository, read: @MainActor () async -> LoadedContent) async {
        let requestID = UUID()
        loadID = requestID
        // Opening the store resolves its initially unavailable source context. Capture only after
        // that legitimate hydration, while retaining request ownership across the suspension.
        guard await repo.prepareInsightsRead(), !Task.isCancelled, loadID == requestID else { return }
        let identity = InsightsLoadIdentity(repo: repo)
        let content = await read()
        guard !Task.isCancelled, loadID == requestID,
              identity == InsightsLoadIdentity(repo: repo) else { return }
        report = content.report
        doseCards = content.doseCards
        loaded = true
    }

    private static func read(repo: Repository) async -> LoadedContent {
        async let reportLoad = InsightsLoader.load(repo: repo)
        async let entriesLoad = repo.journalEntries()
        async let recoveryLoad = repo.series(key: "recovery", source: "my-whoop")
        async let hrvLoad = repo.series(key: "hrv", source: "my-whoop")
        async let alcoholDoseLoad = repo.series(key: Self.doseKey(for: .alcohol), source: Self.doseSource)
        async let caffeineDoseLoad = repo.series(key: Self.doseKey(for: .caffeine), source: Self.doseSource)

        let mergedDays = repo.days
        var byKey: [String: [String: Double]] = [:]
        let loadedOutcomes: [String: [(day: String, value: Double)]] = [
            "recovery": await recoveryLoad, "hrv": await hrvLoad,
        ]
        for (key, rows) in loadedOutcomes {
            var dict: [String: Double] = [:]
            for row in rows { dict[row.day] = row.value }
            for d in mergedDays where dict[d.day] == nil {
                let v: Double? = key == "recovery" ? d.recovery : d.avgHrv
                if let v { dict[d.day] = v }
            }
            byKey[key] = dict
        }

        // A logged "yes" with no dose row reads as dose = 1; explicit dose rows win.
        let entries = await entriesLoad
        let loadedDoses: [DosedBehavior: [(day: String, value: Double)]] = [
            .alcohol: await alcoholDoseLoad,
            .caffeine: await caffeineDoseLoad,
        ]
        var cards: [DoseCard] = []
        for behavior in DosedBehavior.allCases {
            var doses: [String: Int] = [:]
            for e in entries where e.answeredYes && Self.matches(behavior, question: e.question) {
                doses[e.day] = max(doses[e.day] ?? 0, 1)
            }
            for row in loadedDoses[behavior] ?? [] { doses[row.day] = Int(row.value.rounded()) }
            guard !doses.isEmpty else { continue }
            let outcomeName = DoseResponsePriors.defaultOutcome(for: behavior)
            let outcomeDays = byKey[Self.outcomeKey(forEngineName: outcomeName)] ?? [:]
            guard let response = DoseResponseEngine.estimate(behavior: behavior,
                                                             doseByDay: doses,
                                                             outcomeByDay: outcomeDays) else { continue }
            cards.append(DoseCard(behavior: behavior, response: response,
                                  typical: Self.typicalClearDay(outcomeDays, doses: doses)))
        }

        return LoadedContent(report: await reportLoad, doseCards: cards)
    }

    // MARK: Static shaping helpers

    /// The person's typical next morning on a clear day: the median outcome over the last 60 days with no dose logged
    /// (all of them when fewer than 5 are clear). The dose rows build on this, so they start from the person, not zero.
    nonisolated static func typicalClearDay(_ outcomeDays: [String: Double], doses: [String: Int]) -> Double? {
        let recent = outcomeDays.keys.sorted().suffix(60)
        let clear = recent.filter { (doses[$0] ?? 0) == 0 }.compactMap { outcomeDays[$0] }
        let pool = clear.count >= 5 ? clear : recent.compactMap { outcomeDays[$0] }
        guard !pool.isEmpty else { return nil }
        let sorted = pool.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// The metricSeries key a DoseResponsePriors outcome NAME maps to ("Charge"→recovery, "HRV"→hrv).
    static func outcomeKey(forEngineName name: String) -> String {
        switch name {
        case "HRV": return "hrv"
        default:    return "recovery"
        }
    }

    /// The dose storage key for a behaviour (its raw enum value — the stable, cross-platform key).
    static func doseKey(for behavior: DosedBehavior) -> String { "dose_\(behavior.rawValue)" }

    /// Whether a journal question is the dosed behaviour (so its yes-days back-fill dose = 1).
    static func matches(_ behavior: DosedBehavior, question: String) -> Bool {
        let q = question.lowercased()
        switch behavior {
        case .alcohol:  return q.contains("alcohol") || q.contains("drink")
        case .caffeine: return q.contains("caffeine") || q.contains("coffee")
        }
    }

    // MARK: Dose card view-data

    struct DoseCard: Identifiable {
        let behavior: DosedBehavior
        let response: DoseResponse
        /// The person's typical next-morning value on a clear day, the base the step rows build on.
        let typical: Double?

        var id: String { behavior.rawValue }
        private var isHRV: Bool { response.outcome == "HRV" }

        var symbol: String {
            switch behavior {
            case .alcohol:  return "wineglass"
            case .caffeine: return "cup.and.saucer"
            }
        }

        var sectionTitle: String {
            switch behavior {
            case .alcohol:  return String(localized: "Alcohol, drink by drink")
            case .caffeine: return String(localized: "Late caffeine")
            }
        }

        /// The steps shown as rows (0…3+ drinks; morning…evening).
        var doseChoices: [Int] { Array(0...DoseResponseEngine.maxCurveDose) }

        func stepName(_ d: Int) -> String {
            switch behavior {
            case .alcohol:
                switch d {
                case 0: return String(localized: "No drinks")
                case 1: return String(localized: "1 drink")
                case DoseResponseEngine.maxCurveDose...: return String(localized: "\(d)+ drinks")
                default: return String(localized: "\(d) drinks")
                }
            case .caffeine:
                switch d {
                case 0: return String(localized: "Morning only")
                case 1: return String(localized: "By noon")
                case 2: return String(localized: "After 2 pm")
                default: return String(localized: "Evening")
                }
            }
        }

        /// "62%" or "71 ms"
        func format(_ v: Double) -> String {
            isHRV ? "\(Int(max(0, v).rounded())) ms" : "\(Int(min(100, max(0, v)).rounded()))%"
        }

        /// "−4 pts" or "−3 ms"
        func signed(_ v: Double) -> String {
            let n = Int(abs(v).rounded())
            let sign = n == 0 ? "" : (v < 0 ? "\u{2212}" : "+")
            return isHRV ? "\(sign)\(n) ms" : String(localized: "\(sign)\(n) pts")
        }

        /// One plain sentence. Alcohol reads per drink; caffeine reads as after 2 pm against by noon.
        var sentence: String {
            switch behavior {
            case .alcohol:
                let n = Int(abs(response.perUnit).rounded())
                if n == 0 { return String(localized: "Drinks haven\u{2019}t lined up with a change in your recovery so far.") }
                return response.perUnit < 0
                    ? String(localized: "Each extra drink lines up with about \(n) points lower recovery the next morning.")
                    : String(localized: "Each extra drink lines up with about \(n) points higher recovery the next morning.")
            case .caffeine:
                let d = response.delta(fromDose: 1, toDose: 2)
                let n = Int(abs(d).rounded())
                if n == 0 { return String(localized: "Late caffeine hasn\u{2019}t lined up with a change in your HRV so far.") }
                return d < 0
                    ? String(localized: "Caffeine after 2 pm lines up with about \(n) ms lower HRV the next morning.")
                    : String(localized: "Caffeine after 2 pm lines up with about \(n) ms higher HRV the next morning.")
            }
        }

        /// How much this rests on, in words.
        var basis: String {
            if response.priorDominated {
                return String(localized: "Mostly typical patterns so far, not yet yours. Log a few more nights and it becomes yours.")
            }
            if response.contradictsPrior {
                return String(localized: "Based on \(response.nUser) nights. Yours runs against the typical pattern.")
            }
            return response.confidence == .solid
                ? String(localized: "Based on \(response.nUser) nights.")
                : String(localized: "Based on \(response.nUser) nights, still learning.")
        }
    }
}

// MARK: - Preview

#if DEBUG
@MainActor
private func hubPreviewRepo() -> Repository {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    return repo
}

#Preview("Insights Hub") {
    InsightsHubView()
        .environmentObject(hubPreviewRepo())
        .frame(width: 920, height: 980)
        .preferredColorScheme(.dark)
}
#endif
