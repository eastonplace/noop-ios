#if DEBUG && os(iOS)
import SwiftUI
import StrandDesign

/// DEBUG-only review surface for the widget design language. Launch with `--noop-widget-gallery`
/// (optionally `--noop-widget-gallery-section <name>` to render one screenful at a time, since a
/// simulator screenshot cannot scroll). Contains synthetic data only.
///
/// Sections: `tints`, `surfaces`, `cards`, `rows`, `flat`, `card`, `coach-a` ... `coach-d`, plus the shared
/// app components `overline`, `stat-tile`, `chart-card` and `score-pill`.
/// `flat` and `card` show the same content composed on the canvas and inside a `WidgetCard`.
/// The Today restyle sections `today-hero`, `today-heart`, `today-stress` and `today-health` render the
/// REAL Today components (full device width, Today's 16pt gutter, the app canvas) with the demo-seed values.
/// Each logs its global frame as `[gallery-metrics] <name> x= y= w= h=` so before/after heights can be
/// compared exactly (`xcrun simctl launch --console ...`).
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
            .padding(.horizontal, isTodaySection ? Self.todayGutter : NoopMetrics.screenHPadding)
            .padding(.vertical, NoopMetrics.space4)
        }
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    private func shows(_ name: String) -> Bool { section == nil || section == name }

    /// Today's side gutter is `ScreenScaffold`'s 16pt, not the 20pt `NoopMetrics.screenHPadding`.
    private static let todayGutter: CGFloat = 16
    private var isTodaySection: Bool { section?.hasPrefix("today-") == true }

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
        if shows("overline") { overlinePage }
        if shows("stat-tile") { statTilePage }
        if shows("chart-card") { chartCardPage }
        if shows("score-pill") { scorePillPage }
        if shows("today-hero") { todayHeroPage }
        if shows("today-heart") { todayHeartPage }
        if shows("today-stress") { todayStressPage }
        if shows("today-health") { todayHealthPage }
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

// MARK: - Shared app components
//
// The components the rest of the app is built from (everything off Today), on the app canvas, with synthetic
// values. Each tile / card logs its global frame as `[gallery-metrics] <name> ...` so a before/after pair can be
// compared by exact height.

extension WidgetGalleryView {
    // MARK: Overline

    /// A raw `.strandOverline()` beside a `SectionEyebrow` title: the 76 call sites of the first must read like
    /// the second.
    var overlinePage: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            caption("Left: raw .strandOverline().  Right: the SectionEyebrow title (no symbol)")
            ForEach(["Heart rate", "Sleep context", "Stress trend"], id: \.self) { title in
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space4) {
                    Text(title).strandOverline()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .galleryMeasured("overline-raw-\(title)")
                    SectionEyebrow(title: title)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .galleryMeasured("overline-eyebrow-\(title)")
                }
            }
        }
    }

    // MARK: StatTile

    private var statTileSparkline: [Double] { [58, 61, 57, 63, 66, 62, 60, 65, 68, 64, 61, 66, 63, 64] }

    var statTilePage: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            caption("Numeric, unit in the value, missing, status word, percent, wrapped label")
            let columns = [GridItem(.flexible(), spacing: NoopMetrics.gap), GridItem(.flexible(), spacing: NoopMetrics.gap)]
            LazyVGrid(columns: columns, spacing: NoopMetrics.gap) {
                StatTile(label: "Average", value: "71.4", caption: "Last 30 days", accent: StrandPalette.metricPurple)
                    .galleryMeasured("stat-tile-number")
                StatTile(label: "Resting HR", value: "54 bpm", accent: StrandPalette.metricRose)
                    .galleryMeasured("stat-tile-unit")
                StatTile(label: "Latest", value: "—", caption: "No reading yet", accent: StrandPalette.metricPurple)
                    .galleryMeasured("stat-tile-missing")
                StatTile(label: "Readiness", value: "Calibrating", caption: "First nights build a baseline",
                         accent: StrandPalette.accent)
                    .galleryMeasured("stat-tile-status")
                StatTile(label: "Calm time", value: "58%", caption: "low-stress days · 30d",
                         accent: StrandPalette.stressAccent)
                    .galleryMeasured("stat-tile-percent")
                StatTile(label: "Distance", value: "14.2 km", caption: "This week", accent: StrandPalette.strainAccent)
                    .galleryMeasured("stat-tile-distance")
                StatTile(label: "Autonomic balance (LF/HF)", value: "0.9", caption: "Sympathetic vs parasympathetic",
                         accent: StrandPalette.metricPurple)
                    .galleryMeasured("stat-tile-wrapped")
                StatTile(label: "HRV", value: "64 ms", accent: StrandPalette.metricPurple,
                         delta: "+4", deltaColor: StrandPalette.statusPositive,
                         sparkline: statTileSparkline, sparkColor: StrandPalette.metricPurple)
                    .galleryMeasured("stat-tile-spark")
            }
            caption("With a domain symbol (optional, in the domain tint)")
            LazyVGrid(columns: columns, spacing: NoopMetrics.gap) {
                StatTile(label: "HRV", value: "64 ms", accent: DomainTint.hrv.accent,
                         systemImage: "waveform.path.ecg", tint: .hrv)
                    .galleryMeasured("stat-tile-icon-hrv")
                StatTile(label: "Resting HR", value: "54 bpm", accent: DomainTint.heart.accent,
                         systemImage: "heart.fill", tint: .heart)
                    .galleryMeasured("stat-tile-icon-heart")
                StatTile(label: "Asleep", value: "7h 42m", caption: "Last night", accent: DomainTint.sleep.accent,
                         systemImage: "moon.stars.fill", tint: .sleep)
                    .galleryMeasured("stat-tile-icon-sleep")
                StatTile(label: "Stress", value: "—", caption: "Calibrating", accent: DomainTint.stress.accent,
                         systemImage: "waveform.path", tint: .stress)
                    .galleryMeasured("stat-tile-icon-missing")
            }
        }
    }

    // MARK: ChartCard

    private var chartCardPoints: [TrendPoint] {
        let values: [Double] = [6.4, 7.1, 6.8, 7.6, 7.2, 6.1, 7.9, 7.4, 6.9, 7.7, 7.0, 6.6, 7.3, 7.8, 6.5, 7.2, 7.5,
                                6.9, 7.1, 8.0, 7.4, 6.7, 7.2, 7.6, 6.8, 7.3, 7.9, 7.0, 7.4, 7.7]
        return values.enumerated().map { index, value in
            TrendPoint(date: sampleNow.addingTimeInterval(Double(index - values.count + 1) * 86_400), value: value)
        }
    }

    var chartCardPage: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            caption("Title + subtitle + trailing value + footer, then a long trailing value, then no footer")
            ChartCard(
                title: "Hours asleep",
                subtitle: "Per night, trailing 30 days",
                trailing: "7.2 h avg",
                tint: StrandPalette.restColor,
                chart: {
                    TrendChart(points: chartCardPoints, gradient: StrandPalette.restGradient, valueRange: 5...9,
                               showsArea: true, height: NoopMetrics.chartHeight, showsHover: false,
                               valueFormat: { String(format: "%.1f h", $0) })
                },
                footer: {
                    ChartFooter([("Avg", "7.2 h"), ("Min", "6.1 h"), ("Max", "8.0 h"), ("Nights", "30")])
                })
                .galleryMeasured("chart-card-footer")
            ChartCard(
                title: "Heart Rate Variability",
                subtitle: "30 readings · 30D",
                trailing: "64 ms · Oct 8",
                tint: StrandPalette.metricPurple,
                chart: {
                    TrendChart(points: chartCardPoints, gradient: DomainTint.hrv.chartGradient, valueRange: 5...9,
                               showsArea: true, height: NoopMetrics.chartHeight, showsHover: false)
                })
                .galleryMeasured("chart-card-plain")
            ChartCard(
                title: "Stress · 30D",
                subtitle: "Daily 0-3 proxy",
                trailing: "—",
                tint: StrandPalette.stressAccent,
                chart: { Color.clear })
                .galleryMeasured("chart-card-missing")
        }
    }

    // MARK: ScoreStatePill

    var scorePillPage: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            caption("ScoreStatePill (top) and the shared StatePill (below), same states")
            HStack(spacing: NoopMetrics.space2) {
                ScoreStatePill(.solid).galleryMeasured("score-pill-solid")
                ScoreStatePill(.building)
                ScoreStatePill(.calibrating)
                ScoreStatePill(.live)
            }
            ScoreStatePill(.calibrating, text: "Calibrating, 2 of 4").galleryMeasured("score-pill-long")
            HStack(spacing: NoopMetrics.space2) {
                StatePill("Solid", tone: .positive).galleryMeasured("state-pill-solid")
                StatePill("Building", tone: .accent)
                StatePill("Calibrating", tone: .neutral)
                StatePill("Live", tone: .accent, pulsing: true)
            }
            StatePill("Calibrating, 2 of 4", tone: .neutral).galleryMeasured("state-pill-long")
        }
    }
}

// MARK: - Today restyle sections
//
// The real Today components fed the values the demo seed produces (Thu, Oct 8: Recovery 63, Strain 3.5,
// Sleep 97, 73 bpm, stress 0.1), so a before/after pair is an honest comparison of the screen itself.
// The surrounding `.contentSurfacePresentation(.flat)` comes from the app root, exactly as on Today.

private extension View {
    /// DEBUG measurement: prints the view's global frame (points) whenever it changes, so a screenshot can
    /// be cropped to the exact layout box and compared by height.
    func galleryMeasured(_ name: String) -> some View {
        onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            NSLog("[gallery-metrics] %@ x=%.2f y=%.2f w=%.2f h=%.2f", name, frame.minX, frame.minY,
                  frame.width, frame.height)
        }
    }
}

extension WidgetGalleryView {
    // MARK: Hero

    private var todayPillars: [TodayPillarModel] {
        [
            TodayPillarModel(
                id: "recovery", label: "Recovery", value: 63, maximum: 100, valueText: "63",
                state: "Moderate", accent: RecoveryBands.color(for: 63), bandTicks: [0.34, 0.67]),
            TodayPillarModel(
                id: "strain", label: "Strain", value: 3.5, maximum: 21, valueText: "3.5",
                state: "Light", detail: "Stale · Oct 8", accent: StrandPalette.strainAccent),
            TodayPillarModel(
                id: "sleep", label: "Sleep", value: 97, maximum: 100, valueText: "97",
                state: "Good", detail: "6h 48m", accent: StrandPalette.sleepAccent)
        ]
    }

    /// Every pillar value missing: the dashed tracks and the "Not rated" / "Not available" states.
    private var todayEmptyPillars: [TodayPillarModel] {
        [
            TodayPillarModel(
                id: "recovery", label: "Recovery", value: nil, maximum: 100, valueText: "—",
                state: "Not rated", accent: StrandPalette.recoveryData, bandTicks: [0.34, 0.67]),
            TodayPillarModel(
                id: "strain", label: "Strain", value: nil, maximum: 21, valueText: "—",
                state: "Not available", accent: StrandPalette.strainAccent),
            TodayPillarModel(
                id: "sleep", label: "Sleep", value: nil, maximum: 100, valueText: "—",
                state: "Not available", accent: StrandPalette.sleepAccent)
        ]
    }

    var todayHeroPage: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.sectionSpacing) {
            TodayHeroCard(
                pillars: todayPillars, glance: "1 workout · 6,856 steps · 528 cal", workoutIsActive: false,
                onPillar: { _ in }, onOpenWorkouts: {}, onWorkoutAction: {})
                .galleryMeasured("today-hero")
            caption("Empty state: all three values missing")
            TodayHeroCard(
                pillars: todayEmptyPillars, glance: "0 workouts · — steps · — cal", workoutIsActive: false,
                onPillar: { _ in }, onOpenWorkouts: {}, onWorkoutAction: {})
                .galleryMeasured("today-hero-empty")
        }
    }

    // MARK: Live heart rate

    /// Two hours of one-minute samples ending now: latest 73, low 72, peak 76, average 74.
    private var todayHeartSamples: [HRTrackPoint] {
        let count = 120
        var values = (0..<count).map { index -> Double in
            let slow = 1.1 * sin(Double(index) / 11.0)
            let fast = 0.7 * sin(Double(index) / 3.3 + 1.0)
            return min(75.6, max(72.4, 74 + slow + fast))
        }
        values[17] = 72
        values[86] = 76
        values[count - 1] = 73
        let midnight = Calendar.current.startOfDay(for: sampleNow)
        let nowSeconds = sampleNow.timeIntervalSince(midnight)
        return values.enumerated().map { index, bpm in
            HRTrackPoint(id: index, t: nowSeconds - Double(count - 1 - index) * 60, bpm: bpm)
        }
    }

    var todayHeartPage: some View {
        let midnight = Calendar.current.startOfDay(for: sampleNow)
        return HRLiveModuleCard(
            samples: todayHeartSamples, restingHR: 55,
            timeLabel: { seconds in
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("jmm")
                return formatter.string(from: midnight.addingTimeInterval(seconds))
            },
            onOpen: {})
            .galleryMeasured("today-heart")
    }

    // MARK: Stress

    /// Hours 6...12 scored: one calm, two moderate, four high (the footer reads 1h / 2h / 4h).
    private var todayStressHours: [Double?] {
        var hours = [Double?](repeating: nil, count: 24)
        for (offset, level) in [0.7, 1.1, 1.5, 2.8, 2.2, 2.1, 2.5].enumerated() { hours[6 + offset] = level }
        return hours
    }

    var todayStressPage: some View {
        StressModuleCard(hours: todayStressHours, value: 0.1, nowHour: 14, presentationMode: .combined, onOpen: {})
            .galleryMeasured("today-stress")
    }

    // MARK: Health monitor

    private func healthTile(
        _ card: DashboardCard, value: String, unit: String? = nil, detail: String? = nil, spark: [Double] = [],
        rail: HealthTileRail = .none, accent: Color
    ) -> HealthDashboardTileModel {
        HealthDashboardTileModel(
            id: card.id, icon: card.icon, label: card.title, value: value, unit: unit, detail: detail,
            spark: spark, rail: rail, accent: accent)
    }

    /// The default nine tiles, in the default order, with the Stress tile missing ("—") and the Respiratory
    /// rail outside its typical range.
    private var todayHealthTiles: [HealthDashboardTileModel] {
        [
            healthTile(.hrv, value: "64", unit: "ms",
                       spark: [58, 61, 57, 63, 66, 62, 60, 65, 68, 64, 61, 66, 63, 64],
                       rail: .typical(position: 0.62, range: 0.30...0.78, inRange: true),
                       accent: DomainTint.hrv.accent),
            healthTile(.restingHr, value: "55", unit: "bpm",
                       spark: [56, 55, 57, 54, 55, 56, 58, 55, 54, 55, 56, 55, 54, 55],
                       rail: .typical(position: 0.38, range: 0.22...0.70, inRange: true),
                       accent: StrandPalette.metricRose),
            healthTile(.respiratory, value: "21.4", unit: "rpm",
                       spark: [15.2, 15.6, 15.1, 16.0, 16.8, 17.5, 18.4, 19.0, 19.9, 20.3, 20.8, 21.0, 21.2, 21.4],
                       rail: .typical(position: 0.94, range: 0.30...0.70, inRange: false),
                       accent: StrandPalette.accent),
            healthTile(.bloodOxygen, value: "97%",
                       spark: [96, 97, 97, 98, 96, 97, 97, 98, 97, 96, 97, 98, 97, 97],
                       rail: .typical(position: 0.72, range: 0.50...0.92, inRange: true),
                       accent: StrandPalette.metricCyan),
            healthTile(.skinTemp, value: "+0.3°", detail: "2d ago",
                       spark: [0.1, 0.0, -0.1, 0.2, 0.1, 0.3, 0.2, 0.0, 0.1, 0.3, 0.4, 0.2, 0.3, 0.3],
                       rail: .typical(position: 0.58, range: 0.30...0.80, inRange: true),
                       accent: StrandPalette.metricAmber),
            healthTile(.sleep, value: "6h 48m",
                       spark: [412, 388, 440, 395, 421, 367, 430, 402, 415, 390, 436, 408, 399, 408],
                       rail: .progress(0.72), accent: StrandPalette.restColor),
            healthTile(.stress, value: "—", accent: DomainTint.stress.accent),
            healthTile(.steps, value: "6,856",
                       spark: [7200, 5400, 8800, 6100, 9300, 4200, 7700, 8100, 5900, 10200, 6400, 7100, 8300, 6856],
                       rail: .progress(0.69), accent: StrandPalette.metricCyan),
            healthTile(.calories, value: "528", unit: "kcal",
                       spark: [610, 480, 720, 540, 690, 430, 580, 650, 500, 760, 520, 590, 640, 528],
                       rail: .progress(0.53), accent: StrandPalette.metricAmber)
        ]
    }

    var todayHealthPage: some View {
        HealthDashboardCard(
            tiles: todayHealthTiles, status: "9 of 9 metrics selected",
            onTile: { _ in }, onCustomize: {}, onShowAll: {}, onDataSources: {})
            .galleryMeasured("today-health")
    }
}
#endif
