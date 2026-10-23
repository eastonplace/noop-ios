import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Insights
//
// The full Insights page, opened from the foot of Trends ("See all insights") and Explore. Every
// row is one plain sentence about the user's own data, a with/without comparison, how many days it
// rests on and how sure NOOP is. Rows come from InsightsReport: automatic factors from the wearable
// (bedtime, sleep length and debt, late workouts, high-strain and high-step days) and explicit
// Journal answers, tested with one fixed lag and corrected for the number of tests. Association,
// never cause or advice.
//
// Below them, the alcohol and caffeine dose-response cards (DoseResponseEngine) stay as they were.

struct InsightsHubView: View {
    @EnvironmentObject private var repo: Repository
    @StateObject private var model = InsightsHubViewModel()
    @State private var showJournal = false
    /// The ⓘ explainer open from the Dose-response header, if any.
    @State private var metricInfo: MetricInfo?

    var body: some View {
        ScreenScaffold(title: "Insights", subtitle: nil, lazy: true) {
            VStack(alignment: .leading, spacing: 0) {
                Text(introText)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, NoopMetrics.space3)
                if !model.loaded {
                    DataPendingNote(
                        title: "Reading your patterns",
                        message: "NOOP is comparing your nights and days on this device.",
                        symbol: "wand.and.sparkles"
                    )
                } else {
                    findings
                    unclearSection
                    doseSection
                    journalSection
                    methodNote
                }
            }
        }
        .task(id: repo.refreshSeq) { await model.load(repo: repo) }
        .metricInfoSheet($metricInfo)
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

    private var separator: some View { TodaySectionSeparator(above: 10, below: 12) }

    private var introText: String {
        let days = model.report.daysOfData
        guard model.loaded, days >= InsightsReport.minimumDays else {
            return String(localized: "What lines up with your best days, from your own data.")
        }
        return String(localized: "What lines up with your best days, from \(days) days of your own data.")
    }

    // MARK: Findings, grouped by outcome

    @ViewBuilder private var findings: some View {
        let report = model.report
        if !report.hasEnoughData {
            emptyNote(String(localized: "Insights appear after about 2 weeks of wear. NOOP compares your nights with each other, so it needs enough of them first."))
        } else if report.significant.isEmpty {
            emptyNote(String(localized: "No clear patterns yet. NOOP checks again as more nights come in."))
        } else {
            ForEach(Array(InsightOutcome.allCases.filter { !report.significant(for: $0).isEmpty }.enumerated()),
                    id: \.element) { index, outcome in
                if index > 0 { separator }
                FlatSection(verbatim: outcome.title, systemImage: outcome.symbol, tint: tint(outcome),
                            contentSpacing: 0) {
                    let rows = report.significant(for: outcome)
                    ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                        if i > 0 { FlatRowSeparator() }
                        InsightRowView(row: row)
                    }
                }
                .accessibilityIdentifier("insights.outcome.\(outcome.rawValue)")
            }
        }
    }

    @ViewBuilder private var unclearSection: some View {
        let unclear = model.report.hasEnoughData ? model.report.unclear : []
        if !unclear.isEmpty {
            separator
            FlatSection("No clear difference yet", systemImage: "circle.dashed", contentSpacing: 0) {
                ForEach(Array(unclear.enumerated()), id: \.element.id) { i, factor in
                    if i > 0 { FlatRowSeparator() }
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        Text(factor.name)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Spacer(minLength: NoopMetrics.space2)
                        Text(factor.checkedText)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(.vertical, NoopMetrics.space3)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    // MARK: Alcohol / caffeine dose-response

    @ViewBuilder private var doseSection: some View {
        if !model.doseCards.isEmpty {
            separator
            SectionHeader("Dose-response", overline: "Personal curve · prior-shrunk",
                          infoAction: { metricInfo = .doseResponse },
                          infoAccessibilityLabel: MetricInfo.doseResponse.accessibilityLabel)
                .padding(.bottom, NoopMetrics.space2)
            VStack(spacing: NoopMetrics.gap) {
                ForEach(model.doseCards) { card in DoseResponseCardView(card: card) }
            }
        }
    }

    // MARK: Journal and method

    private var journalSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            separator
            SectionEyebrow(title: String(localized: "Add your own"), systemImage: "square.and.pencil", tint: .journal)
            Button { showJournal = true } label: {
                InsightsLinkRow(symbol: "square.and.pencil",
                                title: String(localized: "Journal"),
                                subtitle: String(localized: "Answer a few yes/no questions to test your own habits"))
            }
            .buttonStyle(FlatRowPressStyle())
            .accessibilityHint("Opens your daily journal")
        }
    }

    private var methodNote: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            separator
            SectionEyebrow(title: String(localized: "How this works"), systemImage: "info.circle")
            Text("NOOP splits your days into two groups, for example nights you went to bed before your usual time and nights you did not, and compares the morning after. An insight appears only when the gap is larger than chance would explain, after allowing for how many things were checked. Solid means 10 or more days on each side, Building means 5 to 9. These are patterns, not causes, and everything stays on this iPhone.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, NoopMetrics.space3)
            .accessibilityIdentifier("insights.empty")
    }

    private func tint(_ outcome: InsightOutcome) -> DomainTint {
        switch outcome {
        case .recovery: return .recovery(score: 70)
        case .hrv: return .hrv
        case .sleep: return .sleep
        case .rhr: return .heart
        }
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

// MARK: - Dose-response card
//
// The headline alcohol/caffeine surface: the prior-shrunk curve, the per-unit read,
// the confidence pill, the honesty banner, and an evening "damage forecast" preview
// driven by a tiny dose stepper. The forecast is a what-if on the user's own latest
// Charge — "a 2nd drink tonight tends to line up with about −7 on tomorrow's Charge
// for you" — never a recommendation to drink or abstain.

private struct DoseResponseCardView: View {
    let card: InsightsHubViewModel.DoseCard

    /// The "what if I have one more" preview dose, defaulting to one above the typical
    /// starting point so the headline reads as a 2nd-drink forecast out of the box.
    @State private var previewDose: Int = 2

    private var domain: DomainTheme { card.outcomeName == "HRV" ? .rest : .charge }

    var body: some View {
        let r = card.response
        PaperCard {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                header(r)

                // The engine's honest read sentence (prior / yours / contradicts-prior).
                Text(r.sentence())
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // The prior-shrunk curve (dose on x, modelled outcome Δ on y).
                DoseCurveChart(points: r.curve, accent: domain.color,
                               unitLabel: card.unitLabel, outcomeName: card.outcomeName)
                    .frame(height: 132)
                    .accessibilityLabel(curveAccessibilityLabel(r))

                if r.priorDominated {
                    honestyBanner(String(localized: "Based mostly on typical patterns, not yet yours. Log a few more \(card.unitLabel.lowercased()) days and this becomes yours."),
                        tone: .neutral)
                } else if r.contradictsPrior {
                    honestyBanner(String(localized: "In your data so far, this doesn\u{2019}t move your \(card.outcomeName) the way it typically does."), tone: .positive)
                }

                if card.timingProxy {
                    Text("\u{201C}Dose\u{201D} here is timing (later in the day = stronger), not milligrams.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider().overlay(StrandPalette.hairline)

                damageForecast(r)
            }
        }
    }

    // MARK: Header

    private func header(_ r: DoseResponse) -> some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 8) {
                Image(systemName: card.symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(domain.color)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(card.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer(minLength: 8)
            ScoreStatePill(InsightsHubView.scoreState(r.confidence))
        }
    }

    // MARK: Evening damage forecast (what-if on the user's latest Charge)

    @ViewBuilder private func damageForecast(_ r: DoseResponse) -> some View {
        // The Δ of going from the typical starting dose (1) to the previewed dose, applied
        // to the user's most recent outcome value as an honest "where you'd likely land".
        let fromDose = 1
        let delta = r.delta(fromDose: fromDose, toDose: previewDose)
        let projected = card.latestOutcome.map { max(0, min(card.outcomeCeiling, $0 + delta)) }
        let stepLabel = previewDose <= 1 ? String(localized: "no extra") : card.stepLabel(previewDose)

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            // Overline and the dose stepper each get their own row — sharing one HStack
            // compressed the 0/1/2/3+ stepper and truncated its segments on narrow widths.
            Text(card.forecastOverline).strandOverline()
                .frame(maxWidth: .infinity, alignment: .leading)
            SegmentedPillControl(card.doseChoices, selection: $previewDose) { card.doseChoiceLabel($0) }
                .accessibilityLabel("Preview dose")
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(forecastSentence(delta: delta, projected: projected, stepLabel: stepLabel))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: NoopMetrics.gap)],
                      alignment: .leading, spacing: NoopMetrics.gap) {
                StatTile(label: "Per extra \(card.unitNoun)",
                         value: signed(r.perUnit, suffix: card.outcomeSuffix),
                         caption: r.priorDominated ? String(localized: "typical") : String(localized: "your data"),
                         accent: r.perUnit < 0 ? StrandPalette.statusCritical : StrandPalette.statusPositive)
                StatTile(label: "Tomorrow\u{2019}s \(card.outcomeName)",
                         value: projected.map { "\(Int($0.rounded()))\(card.outcomeSuffix)" } ?? "—",
                         caption: projected != nil ? String(localized: "projected · \(stepLabel)") : String(localized: "needs a recent day"),
                         accent: domain.color)
            }
        }
    }

    /// Whole-phrase variants per direction and basis, so translators never see stitched
    /// lower/higher or basis fragments.
    private func forecastSentence(delta: Double, projected: Double?, stepLabel: String) -> String {
        if previewDose <= 1 {
            return String(localized: "No extra tonight. Your \(card.outcomeName.lowercased()) forecast stays where it is.")
        }
        let magText = "\(Int(abs(delta).rounded()))\(card.outcomeSuffix)"
        let lower = delta <= 0
        if card.response.priorDominated {
            return lower
                ? String(localized: "A \(stepLabel) tonight tends to line up with about \(magText) lower on tomorrow\u{2019}s \(card.outcomeName.lowercased()) for you, based on typical patterns.")
                : String(localized: "A \(stepLabel) tonight tends to line up with about \(magText) higher on tomorrow\u{2019}s \(card.outcomeName.lowercased()) for you, based on typical patterns.")
        }
        return lower
            ? String(localized: "A \(stepLabel) tonight tends to line up with about \(magText) lower on tomorrow\u{2019}s \(card.outcomeName.lowercased()) for you, based on \(card.response.nUser) of your \(card.unitLabel.lowercased()) days.")
            : String(localized: "A \(stepLabel) tonight tends to line up with about \(magText) higher on tomorrow\u{2019}s \(card.outcomeName.lowercased()) for you, based on \(card.response.nUser) of your \(card.unitLabel.lowercased()) days.")
    }

    // MARK: Bits

    private func honestyBanner(_ text: String, tone: StrandTone) -> some View {
        HStack(alignment: .top, spacing: NoopMetrics.space2) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone == .neutral ? StrandPalette.textTertiary : StrandPalette.statusPositive)
            Text(text)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 8))
    }

    private func signed(_ v: Double, suffix: String) -> String {
        let mag = abs(v)
        let rounded = (mag * 10).rounded() / 10
        let sign = v < 0 ? "−" : (v > 0 ? "+" : "")
        // Show whole numbers without a trailing .0 for the small Charge magnitudes.
        let body = rounded == rounded.rounded() ? "\(Int(rounded))" : String(format: "%.1f", rounded)
        return "\(sign)\(body)\(suffix)"
    }

    /// Whole-string key per variant (never a concatenated localized tail on an a11y label).
    private func curveAccessibilityLabel(_ r: DoseResponse) -> String {
        r.priorDominated
            ? String(localized: "Dose-response curve. Each extra \(card.unitNoun) lines up with about \(signed(r.perUnit, suffix: card.outcomeSuffix)) on \(card.outcomeName), typical patterns.")
            : String(localized: "Dose-response curve. Each extra \(card.unitNoun) lines up with about \(signed(r.perUnit, suffix: card.outcomeSuffix)) on \(card.outcomeName), your own data.")
    }
}

// MARK: - Dose curve chart
//
// A compact line+area chart of the prior-shrunk curve: dose on x (0…max), the modelled
// outcome DELTA on y. Drawn with the house Path idiom (no extra dependency) so it sits
// in the design system. Zero-line is marked; the line is tinted to the domain colour.

private struct DoseCurveChart: View {
    let points: [DoseCurvePoint]
    let accent: Color
    let unitLabel: String
    let outcomeName: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let deltas = points.map(\.outcomeDelta)
            let maxAbs = max(1.0, (deltas.map(abs).max() ?? 1.0))
            // Symmetric y range around zero so the sign reads honestly.
            let yFor: (Double) -> CGFloat = { d in
                let t = (d / maxAbs + 1) / 2          // 0 (most negative) … 1 (most positive)
                return h - CGFloat(t) * h
            }
            let n = max(1, points.count - 1)
            let xFor: (Int) -> CGFloat = { i in CGFloat(i) / CGFloat(n) * w }
            let zeroY = yFor(0)

            ZStack(alignment: .topLeading) {
                // Zero baseline.
                Path { p in
                    p.move(to: CGPoint(x: 0, y: zeroY))
                    p.addLine(to: CGPoint(x: w, y: zeroY))
                }
                .stroke(StrandPalette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // Filled area between the curve and the zero line.
                Path { p in
                    guard !points.isEmpty else { return }
                    p.move(to: CGPoint(x: xFor(0), y: zeroY))
                    for (i, pt) in points.enumerated() {
                        p.addLine(to: CGPoint(x: xFor(i), y: yFor(pt.outcomeDelta)))
                    }
                    p.addLine(to: CGPoint(x: xFor(points.count - 1), y: zeroY))
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [accent.opacity(0.22), accent.opacity(0.03)],
                                     startPoint: .top, endPoint: .bottom))

                // The curve line.
                Path { p in
                    for (i, pt) in points.enumerated() {
                        let point = CGPoint(x: xFor(i), y: yFor(pt.outcomeDelta))
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }
                .stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                // Dose markers.
                ForEach(points.indices, id: \.self) { i in
                    Circle()
                        .fill(accent)
                        .frame(width: 5, height: 5)
                        .position(x: xFor(i), y: yFor(points[i].outcomeDelta))
                }
            }
        }
        .accessibilityElement()
    }
}

// MARK: - View-model
//
// Loads the shared InsightsReport (also used by Trends and the Coach) plus the alcohol/caffeine
// dose series for the DoseResponseEngine cards.

@MainActor
final class InsightsHubViewModel: ObservableObject {

    @Published private(set) var loaded = false
    @Published private(set) var report = InsightsReport.empty
    @Published private(set) var doseCards: [DoseCard] = []

    /// The source id dose rows are parked under (mirrors MoodStore's noop-mood isolation).
    static let doseSource = "noop-journal-dose"

    func load(repo: Repository) async {
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
            let latest = outcomeDays.keys.max().flatMap { outcomeDays[$0] }
            cards.append(DoseCard(behavior: behavior, response: response, latestOutcome: latest))
        }

        self.report = await reportLoad
        self.doseCards = cards
        self.loaded = true
    }

    // MARK: Static shaping helpers

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
        /// The user's most recent outcome value (for the evening damage forecast anchor).
        let latestOutcome: Double?

        var id: String { behavior.rawValue }
        var outcomeName: String { response.outcome }

        var title: String {
            switch behavior {
            case .alcohol:  return String(localized: "Alcohol")
            case .caffeine: return String(localized: "Caffeine")
            }
        }
        var symbol: String {
            switch behavior {
            case .alcohol:  return "wineglass"
            case .caffeine: return "cup.and.saucer.fill"
            }
        }
        /// The unit shown in copy ("drink" / "later step").
        var unitNoun: String {
            switch behavior {
            case .alcohol:  return String(localized: "drink")
            case .caffeine: return String(localized: "later step")
            }
        }
        /// The plural-ish label used in "N of your X days".
        var unitLabel: String {
            switch behavior {
            case .alcohol:  return String(localized: "drink")
            case .caffeine: return String(localized: "late-caffeine")
            }
        }
        var timingProxy: Bool { behavior == .caffeine }

        /// Outcome units suffix for the forecast tiles.
        var outcomeSuffix: String { outcomeName == "HRV" ? " ms" : "%" }
        /// Clamp ceiling for the projected outcome (Charge/Sleep are 0–100; HRV uncapped-ish).
        var outcomeCeiling: Double { outcomeName == "HRV" ? 400 : 100 }

        var forecastOverline: String {
            switch behavior {
            case .alcohol:  return String(localized: "Tonight\u{2019}s forecast")
            case .caffeine: return String(localized: "Timing forecast")
            }
        }

        /// The dose choices the evening stepper offers (0/1/2/3 → 0…maxCurveDose).
        var doseChoices: [Int] { Array(0...DoseResponseEngine.maxCurveDose) }
        func doseChoiceLabel(_ d: Int) -> String {
            switch behavior {
            case .alcohol:  return d >= DoseResponseEngine.maxCurveDose ? "\(d)+" : "\(d)"
            case .caffeine:
                // Timing buckets, not counts.
                switch d {
                case 0: return String(localized: "AM")
                case 1: return String(localized: "Noon")
                case 2: return String(localized: "2pm+")
                default: return String(localized: "Eve")
                }
            }
        }
        /// The whole dose phrase for forecast copy (alcohol counts; caffeine keeps the bare bucket
        /// number). Whole-string keys per variant, never a stitched "+ drinks" suffix.
        func stepLabel(_ d: Int) -> String {
            switch behavior {
            case .alcohol:
                return d >= DoseResponseEngine.maxCurveDose ? String(localized: "\(d)+ drinks")
                                                            : String(localized: "\(d) drinks")
            case .caffeine:
                return "\(d)"
            }
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
