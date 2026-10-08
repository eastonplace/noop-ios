#if DEBUG && os(iOS)
import SwiftUI
import StrandDesign

/// DEBUG-only review surface for the widget design language. Launch with `--noop-widget-gallery`
/// (optionally `--noop-widget-gallery-section <name>` to render one screenful at a time, since a
/// simulator screenshot cannot scroll). Contains synthetic data only.
///
/// Sections: `tints`, `surfaces`, `cards`, `rows`, `flat`, `card`, `coach-a` ... `coach-d`.
/// `flat` and `card` show the same content composed on the canvas and inside a `WidgetCard`.
struct WidgetGalleryView: View {
    private let section: String?

    init() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--noop-widget-gallery-section"),
           arguments.indices.contains(index + 1) {
            section = arguments[index + 1]
        } else {
            section = nil
        }
    }

    /// Sample "now" rounded to the hour so before/after renders of the Coach cards are byte-comparable.
    private var sampleNow: Date {
        Calendar.current.dateInterval(of: .hour, for: Date())?.start ?? Date()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                Text("Widget gallery\(section.map { " · \($0)" } ?? "")").strandOverline()
                pages
            }
            .padding(.horizontal, NoopMetrics.screenHPadding)
            .padding(.vertical, NoopMetrics.space4)
        }
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func shows(_ name: String) -> Bool { section == nil || section == name }

    @ViewBuilder private var pages: some View {
        if shows("tints") { tintPage }
        if shows("surfaces") { surfacePage }
        if shows("cards") { cardPage }
        if shows("rows") { rowPage }
        if shows("flat") { flatPage }
        if shows("card") { cardCompositionPage }
        let samples = LocalCoachCard.previewSamples(now: sampleNow)
        if shows("coach-a") { coachStack(samples.readiness) }
        if shows("coach-b") { coachStack(Array(samples.training.prefix(2))) }
        if shows("coach-c") { coachStack(Array(samples.training.suffix(2))) }
        if shows("coach-d") { coachStack(samples.coverage) }
    }

    // MARK: Coach cards

    private func coachStack(_ cards: [LocalCoachCard]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            ForEach(cards) { LocalCoachCardView(card: $0) }
        }
    }

    // MARK: Tints

    private let tintSamples: [(String, String, DomainTint)] = [
        ("Recovery high", "heart.fill", .recovery(score: 82)),
        ("Recovery moderate", "heart.fill", .recovery(score: 55)),
        ("Recovery low", "heart.fill", .recovery(score: 20)),
        ("Recovery missing", "heart.fill", .recovery(score: nil)),
        ("Sleep", "moon.stars.fill", .sleep),
        ("Effort", "flame.fill", .strain),
        ("Stress", "waveform.path", .stress),
        ("HRV", "waveform.path.ecg", .hrv),
        ("Heart", "heart.fill", .heart),
        ("Journal", "book.closed.fill", .journal),
        ("Workout", "figure.run", .workout),
        ("Accent", "sparkles", .accent),
        ("Neutral", "circle.grid.2x2", .neutral)
    ]

    private var tintPage: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            caption("Eyebrow per tint, on the canvas")
            ForEach(Array(tintSamples.enumerated()), id: \.offset) { _, sample in
                SectionEyebrow(title: sample.0, systemImage: sample.1, tint: sample.2, trailing: .text("Today"))
            }
        }
    }

    private var surfacePage: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            caption("Card surface per tint")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: NoopMetrics.space3) {
                ForEach(Array(tintSamples.enumerated()), id: \.offset) { _, sample in
                    Text(sample.0).font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                        .widgetCardSurface(tint: sample.2, padding: NoopMetrics.space3, cornerRadius: NoopMetrics.radius3)
                }
            }
        }
    }

    // MARK: WidgetCard

    private var cardPage: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.interCardSpacing) {
            WidgetCard(title: "No trailing", systemImage: "heart.fill", tint: .recovery(score: 82)) {
                Text("A card with only an eyebrow.").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            WidgetCard(title: "Date", systemImage: "moon.stars.fill", tint: .sleep, trailing: .text("Today")) {
                HeroValue(value: "7h 42m", caption: "last night")
            }
            WidgetCard(title: "Pill", systemImage: "flame.fill", tint: .strain,
                       trailing: .pill("Live", tone: .positive)) {
                HeroValue(value: "12.2", unit: "of 21")
            }
            WidgetCard(title: "Stale", systemImage: "heart.fill", tint: .recovery(score: 82),
                       trailing: .record(date: "Oct 5", isStale: true)) {
                HeroValue(value: "82", unit: "/100", caption: "11 recorded days")
            }
            WidgetCard(title: "Custom", systemImage: "waveform.path", tint: .stress,
                       trailing: .custom(AnyView(Image(systemName: "ellipsis").foregroundStyle(StrandPalette.textTertiary)))) {
                MetricValueRow(systemImage: "clock", label: "Calm", value: "1h 20m", tint: .stress)
            }
            WidgetCard(title: "Tappable", systemImage: "waveform.path.ecg", tint: .hrv,
                       trailing: .text("Details"), action: {}) {
                HeroValue(value: "64", unit: "ms")
            }
            WidgetCard(title: "Neutral", systemImage: "circle.grid.2x2") {
                Text("Neutral tint: graphite surface, no wash.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        }
    }

    // MARK: Rows

    private var rowPage: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            caption("Hero value")
            HeroValue(value: "82", unit: "/100", caption: "11 recorded days")
            HeroValue(value: "7h 42m", caption: "last night", captionPlacement: .below)
            HeroValue(value: "—", unit: "ms", caption: "not recorded")
            caption("Metric rows")
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                MetricValueRow(systemImage: "waveform.path.ecg", label: "HRV", value: "64", unit: "ms", tint: .hrv)
                MetricValueRow(systemImage: "heart.fill", label: "Resting HR", value: "52", unit: "bpm", tint: .heart)
                MetricValueRow(systemImage: "moon.zzz.fill", label: "Sleep", value: "7h 42m", tint: .sleep)
                MetricValueRow(systemImage: "figure.run", label: "Workouts", value: "—", unit: "in 7 d", tint: .strain)
            }
            caption("Stat footer, compact")
            StatFooter(items: [("Low", "65"), ("Average", "75"), ("High", "83")])
            caption("Stat footer, prominent")
            StatFooter(items: [("Latest record", "Oct 8"), ("Earliest record", "Aug 22, 2025"), ("History span", "413 days")],
                       style: .prominent)
            caption("Gauge layout")
            GaugeLayout {
                RecoveryRing(score: 82, diameter: 96, lineWidth: 7, showsLabel: true, showsWordmark: false, showsHover: false)
            } rows: {
                MetricValueRow(systemImage: "waveform.path.ecg", label: "HRV", value: "64", unit: "ms", tint: .hrv)
                MetricValueRow(systemImage: "heart.fill", label: "Resting HR", value: "52", unit: "bpm", tint: .heart)
                MetricValueRow(systemImage: "moon.zzz.fill", label: "Sleep", value: "7h 42m", tint: .sleep)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
    }

    // MARK: Flat vs card composition

    private var trendPoints: [TrendPoint] {
        let values: [Double] = [65, 72, 68, 79, 74, 80, 71, 77, 83, 76, 82, 74, 79, 82]
        return values.enumerated().map { index, value in
            TrendPoint(date: sampleNow.addingTimeInterval(Double(index - values.count + 1) * 86_400), value: value)
        }
    }

    /// The same recovery-trend content used by both compositions.
    private var recoveryTrendBody: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            HeroValue(value: "82", unit: "/100", caption: "14 recorded days")
            TrendChart(points: trendPoints, gradient: DomainTint.recovery(score: 82).chartGradient,
                       valueRange: 0...100, showsArea: true, height: WidgetMetrics.chartHeight, showsHover: false,
                       accessibilityLabel: "Recovery trend", yDomain: 60...90,
                       xAxisLabelCount: WidgetMetrics.maxXAxisLabels)
            StatFooter(items: [("Low", "65"), ("Average", "75"), ("High", "83")])
        }
    }

    private var sleepBody: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            MetricValueRow(systemImage: "moon.zzz.fill", label: "Asleep", value: "7h 42m", tint: .sleep)
            MetricValueRow(systemImage: "bed.double.fill", label: "Efficiency", value: "91", unit: "%", tint: .sleep)
            MetricValueRow(systemImage: "waveform.path.ecg", label: "HRV", value: "64", unit: "ms", tint: .hrv)
        }
    }

    private var flatPage: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.sectionSpacing) {
            caption("Sections composed flat on the canvas: no box, eyebrow + content, hairline between")
            VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
                SectionEyebrow(title: "Recovery trend", systemImage: "heart.fill", tint: .recovery(score: 82),
                               trailing: .record(date: "Oct 5", isStale: true))
                recoveryTrendBody
            }
            Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
                SectionEyebrow(title: "Sleep", systemImage: "moon.stars.fill", tint: .sleep, trailing: .text("Today"))
                sleepBody
            }
        }
    }

    private var cardCompositionPage: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.interCardSpacing) {
            caption("The same content in WidgetCard, for where a bounded card is the right shape")
            WidgetCard(title: "Recovery trend", systemImage: "heart.fill", tint: .recovery(score: 82),
                       trailing: .record(date: "Oct 5", isStale: true)) {
                recoveryTrendBody
            }
            WidgetCard(title: "Sleep", systemImage: "moon.stars.fill", tint: .sleep, trailing: .text("Today")) {
                sleepBody
            }
        }
    }
}
#endif
