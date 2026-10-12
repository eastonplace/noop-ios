import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Health Monitor: vital signs, recovery contributors and the metric trend page
//
// The Health Monitor is a page of flat sections (an eyebrow, one hairline between neighbours), the same as the
// Today drill-ins. The vital signs come first: every number the strap read overnight, each a row that opens its own
// trend page (`HealthMetricTrendView`, the Trends chart). Today's Steps and Calories cards open that same page.

enum HealthFormat {
    /// The date a Health screen's header row names, from a day key ("Fri, Oct 9"), or nil without one.
    static func headerContext(dayKey: String?) -> String? {
        guard let dayKey, let date = BodyVitalSigns.localDate(fromDayKey: dayKey) else { return nil }
        return DrillInFormat.headerDate(date)
    }
}

/// One DomainTint per domain the Health screens touch, read from the same table Today and Trends read.
enum HealthTint {
    /// Fitness Age is the Today card's blue, here and on its detail.
    static let fitnessAge: DomainTint = .custom(StrandPalette.recoveryData)
    /// Vitality is the Today card's rest colour.
    static let vitality: DomainTint = .custom(StrandPalette.restColor)
    /// Hydration is the Today card's teal.
    static let hydration: DomainTint = .custom(StrandPalette.metricCyan)
    /// A small empty-state glyph, quiet.
    static let quiet: DomainTint = .custom(StrandPalette.textTertiary)
}

/// A quiet line for a section with nothing to show yet: a symbol and the sentence, never a bounded card.
struct HealthEmptyNote: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            Image(systemName: symbol)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: WidgetMetrics.metricIconWidth)
                .accessibilityHidden(true)
            Text(text)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The label of a flat row that opens another page: a glyph on its disc, a title and what is behind it, and a chevron.
/// Wrap it in a `Button` or `NavigationLink` with `FlatRowPressStyle`; it reads as one element to VoiceOver.
struct HealthLinkRowLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    var tint: DomainTint = .accent

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            GlyphDisc(symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(verbatim: subtitle)
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NoopMetrics.space2)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(title). \(subtitle)"))
    }
}

// MARK: - Vital signs

/// The latest value of each overnight vital, one row each: its symbol and name, the value, and under it where it came
/// from, how it sits against your own range, and the trail of the last two weeks. Tapping a row opens its trend.
struct HealthVitalsSection: View {
    let readings: [BodyVitalReading]

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                "Vital Signs", systemImage: "waveform.path.ecg", tint: .neutral,
                trailing: BodyVitalSigns.latestDayLabel(readings).map { EyebrowTrailing.text($0) } ?? EyebrowTrailing.none)
            VStack(spacing: 0) {
                ForEach(Array(readings.enumerated()), id: \.element.id) { index, reading in
                    if index > 0 { FlatRowSeparator() }
                    if reading.trendMetric != nil {
                        NavigationLink {
                            HealthMetricTrendView(metric: reading.trendMetric ?? .hrv, reading: reading)
                        } label: {
                            HealthVitalRow(reading: reading, showsChevron: true)
                        }
                        .buttonStyle(FlatRowPressStyle())
                        .accessibilityHint(Text("Opens the trend"))
                    } else {
                        HealthVitalRow(reading: reading, showsChevron: false)
                    }
                }
            }
            Text("Once NOOP has 14 nights of history, in-range compares each vital to your own baseline (approximate, not medical advice); until then, typical adult ranges apply.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct HealthVitalRow: View {
    let reading: BodyVitalReading
    let showsChevron: Bool

    @Environment(\.dynamicTypeSize) private var typeSize

    private var indent: CGFloat { WidgetMetrics.metricIconWidth + NoopMetrics.space2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                MetricValueRow(
                    systemImage: reading.symbol, label: reading.label,
                    value: reading.value.map { reading.format($0) } ?? WidgetMetrics.missingValue,
                    unit: reading.unit, tint: reading.domainTint)
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            detail
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: reading.accessibilityText))
    }

    private var trail: [Double]? {
        #if os(watchOS)
        return nil
        #else
        guard let sparkline = reading.sparkline, sparkline.count > 1 else { return nil }
        return sparkline
        #endif
    }

    @ViewBuilder private var detail: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                caption
                if let trail { sparkline(trail).frame(height: 24) }
            }
            .padding(.leading, indent)
        } else {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                caption
                Spacer(minLength: 0)
                if let trail { sparkline(trail).frame(width: 64, height: 16) }
            }
            .padding(.leading, indent)
        }
    }

    private func sparkline(_ values: [Double]) -> some View {
        Sparkline(values: values,
                  gradient: Gradient(colors: [reading.metricColor.opacity(0.5), reading.metricColor]),
                  lineWidth: 1.6, showsArea: false, showsHead: false, showsHover: false)
            .accessibilityHidden(true)
    }

    /// "<day> · <source>" in the quiet ink, then the state word in the vital's own colour (a warning when it is off
    /// your baseline).
    private var caption: some View {
        var text = AttributedString(reading.provenanceCaption)
        text.foregroundColor = StrandPalette.textTertiary
        if let word = reading.stateWord {
            text += AttributedString(" · ")
            var state = AttributedString(word)
            state.foregroundColor = reading.accent
            text += state
        }
        return Text(text)
            .font(StrandFont.micro)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Recovery contributors

/// The inputs to today's recovery (HRV, resting HR, sleep, respiratory rate), each scored against your own baseline of
/// prior nights. Below the baseline's seed depth the rows say "Calibrating" and draw no fill: no fabricated read.
/// Depends only on `repo`, so the ~1 Hz live HR stream never re-renders it.
struct RecoveryContributorsSection: View {
    @EnvironmentObject var repo: Repository

    /// One contributor row's resolved read-out.
    private struct Contributor {
        let label: String
        let symbol: String
        let strength: Double?      // 0…100, nil while calibrating / no value
        let word: String
        let value: String
        let unit: String?
        let tint: DomainTint
    }

    var body: some View {
        let latest = repo.days.last
        // A contributor needs at least the recovery seed depth of prior nights to score against a baseline; below that
        // the rows say Calibrating and leave the bars unfilled but honest.
        let priorCount = repo.days.dropLast().compactMap(\.avgHrv).filter { $0 > 0 }.count
        let ready = priorCount >= Baselines.minNightsSeed
        let contributors = buildContributors(latest)

        VStack(alignment: .leading, spacing: WidgetMetrics.headerSpacing) {
            SectionEyebrow(
                "Contributors", systemImage: "slider.horizontal.3", tint: .recovery(score: latest?.recovery),
                trailing: ready
                    ? .pill("Solid", tone: .positive)
                    : .pill("Calibrating (\(priorCount) of \(Baselines.minNightsSeed))", tone: .warning))
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                ForEach(Array(contributors.enumerated()), id: \.offset) { _, contributor in
                    row(contributor, ready: ready)
                }
            }
            Text("Baselines are learned on-device over your first 14 days. Until then, typical ranges apply.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ contributor: Contributor, ready: Bool) -> some View {
        let strength = ready ? contributor.strength : nil
        let word = ready ? contributor.word : String(localized: "Calibrating")
        return VStack(alignment: .leading, spacing: 5) {
            MetricValueRow(systemImage: contributor.symbol, label: contributor.label, value: contributor.value,
                           unit: contributor.unit, tint: contributor.tint)
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                Text(verbatim: word)
                    .font(StrandFont.micro)
                    .foregroundStyle(strength == nil ? StrandPalette.textTertiary : contributor.tint.accent)
                    .lineLimit(1)
                    .fixedSize()
                HealthStrengthBar(strength: strength, tint: contributor.tint.accent)
            }
            .padding(.leading, WidgetMetrics.metricIconWidth + NoopMetrics.space2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(contributor.label), \(contributor.value)\(contributor.unit.map { " " + $0 } ?? ""), \(word)"))
    }

    /// Resolve each contributor from the latest day against the baseline mean of prior nights. HRV and Sleep score
    /// higher when above baseline; Resting HR and Respiratory score higher when at or below it (lower is better).
    /// Strength is a centred 0–100 (baseline ≈ 70).
    private func buildContributors(_ latest: DailyMetric?) -> [Contributor] {
        let hrvBase = baseline { $0.avgHrv }
        let rhrBase = baseline { $0.restingHr.map(Double.init) }
        let sleepBase = baseline { $0.totalSleepMin }
        let respBase = baseline { $0.respRateBpm }
        let missing = WidgetMetrics.missingValue

        let hrv = higherIsBetter(latest?.avgHrv, base: hrvBase)
        let rhr = lowerIsBetter(latest?.restingHr.map(Double.init), base: rhrBase)
        let sleep = higherIsBetter(latest?.totalSleepMin, base: sleepBase)
        let resp = lowerIsBetter(latest?.respRateBpm, base: respBase)
        return [
            Contributor(label: String(localized: "HRV"), symbol: ProductionTrendMetric.hrv.symbol,
                        strength: hrv, word: word(hrv),
                        value: latest?.avgHrv.map { DrillInFormat.number($0) } ?? missing, unit: "ms",
                        tint: ProductionTrendMetric.hrv.domainTint(latest: nil)),
            Contributor(label: String(localized: "Resting HR"), symbol: ProductionTrendMetric.restingHR.symbol,
                        strength: rhr, word: word(rhr),
                        value: latest?.restingHr.map { String($0) } ?? missing, unit: "bpm",
                        tint: ProductionTrendMetric.restingHR.domainTint(latest: nil)),
            Contributor(label: String(localized: "Sleep"), symbol: ProductionTrendMetric.sleepDuration.symbol,
                        strength: sleep, word: word(sleep),
                        value: latest?.totalSleepMin.map { sleepText($0) } ?? missing, unit: nil,
                        tint: ProductionTrendMetric.sleepDuration.domainTint(latest: nil)),
            Contributor(label: String(localized: "Respiratory"), symbol: ProductionTrendMetric.respiratory.symbol,
                        strength: resp, word: word(resp),
                        value: latest?.respRateBpm.map { DrillInFormat.number($0, fractionDigits: 1) } ?? missing,
                        unit: "rpm", tint: ProductionTrendMetric.respiratory.domainTint(latest: nil)),
        ]
    }

    /// Mean of a per-day column across prior nights (excludes the latest day so "vs baseline" compares the latest
    /// reading against history). nil until enough nights exist.
    private func baseline(_ key: (DailyMetric) -> Double?) -> Double? {
        let prior = repo.days.dropLast().compactMap(key).filter { $0 > 0 }
        guard prior.count >= Baselines.minNightsSeed else { return nil }
        return prior.reduce(0, +) / Double(prior.count)
    }

    /// Centre a "higher is better" reading on a 0…100 strength: at baseline → 70, scaling up to 100 by ~+30% above and
    /// down to 0 by ~-40% below. nil inputs return nil (no bar fill).
    private func higherIsBetter(_ value: Double?, base: Double?) -> Double? {
        guard let value, let base, base > 0 else { return nil }
        return clampStrength(70 + (value / base - 1) * 100)
    }

    /// Centre a "lower is better" reading (RHR, respiratory): at baseline → 70, better as it falls.
    private func lowerIsBetter(_ value: Double?, base: Double?) -> Double? {
        guard let value, let base, base > 0 else { return nil }
        return clampStrength(70 - (value / base - 1) * 200)
    }

    private func clampStrength(_ v: Double) -> Double { min(100, max(0, v)) }

    /// The qualitative word beside the bar, banded like the contributor strengths.
    private func word(_ strength: Double?) -> String {
        guard let strength else { return WidgetMetrics.missingValue }
        switch strength {
        case ..<40: return String(localized: "Low")
        case ..<60: return String(localized: "Fair")
        case ..<78: return String(localized: "Good")
        default: return String(localized: "Strong")
        }
    }

    private func sleepText(_ minutes: Double) -> String {
        let m = max(0, Int(minutes.rounded()))
        return String(localized: "\(m / 60)h \(m % 60)m")
    }
}

/// A flat strength bar: an inset track with the domain tint filling to a 0…100 strength. nil (calibrating) is an
/// empty track, never a made-up fill.
struct HealthStrengthBar: View {
    let strength: Double?
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous).fill(StrandPalette.surfaceInset)
                if let strength {
                    Capsule(style: .continuous).fill(tint)
                        .frame(width: max(6, proxy.size.width * CGFloat(min(max(strength, 0), 100) / 100)))
                }
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - Metric trend page

extension ProductionTrendMetric {
    /// The title of a metric's page: Today's card title, so the card and the screen it opens read the same.
    var healthPageTitle: LocalizedStringKey {
        switch self {
        case .hrv: "HRV"
        case .restingHR: "Resting HR"
        case .respiratory: "Respiratory"
        case .spo2: "Blood Oxygen"
        case .skinTemp: "Skin Temp"
        case .steps: "Steps"
        case .calories: "Calories"
        case .recovery: "Recovery"
        case .strain: "Strain"
        case .sleepPerformance, .sleepDuration: "Sleep"
        case .stress: "Stress"
        }
    }

    /// The same title as plain text, for an eyebrow.
    var healthEyebrowTitle: String {
        switch self {
        case .hrv: String(localized: "HRV")
        case .restingHR: String(localized: "Resting HR")
        case .respiratory: String(localized: "Respiratory")
        case .spo2: String(localized: "Blood Oxygen")
        case .skinTemp: String(localized: "Skin Temp")
        case .steps: String(localized: "Steps")
        case .calories: String(localized: "Calories")
        case .recovery: String(localized: "Recovery")
        case .strain: String(localized: "Strain")
        case .sleepPerformance, .sleepDuration: String(localized: "Sleep")
        case .stress: String(localized: "Stress")
        }
    }
}

/// One metric over time, on the page every Health card opens: its latest value, how the last weeks average, and the
/// Trends range chart (hold and drag to read a day). Steps and Calories (Today's cards) land here, and so does each
/// vital row of the Health Monitor, so a metric has one page wherever it is tapped.
struct HealthMetricTrendView: View {
    let metric: ProductionTrendMetric
    /// The vital this page was opened from, whose caption (day, source, state) it repeats. nil for Steps and Calories.
    var reading: BodyVitalReading? = nil

    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""

    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: temperatureRaw)
    }

    /// The daily values, oldest first, in the units shown.
    private var series: [(day: String, value: Double)] {
        switch metric {
        case .hrv, .restingHR, .respiratory, .spo2, .skinTemp:
            return BodyVitalSigns.trendPoints(
                key: Self.vitalKey(metric), sourceRows: repo.vitalMetricRows, temperatureUnit: temperatureUnit)
        case .steps:
            return repo.days.compactMap { day in day.steps.map { (day.day, Double($0)) } }
        case .calories:
            return repo.days.compactMap { day in day.activeKcalEst.map { (day.day, $0) } }
        default:
            return []
        }
    }

    private static func vitalKey(_ metric: ProductionTrendMetric) -> String {
        switch metric {
        case .hrv: "hrv"
        case .restingHR: "rhr"
        case .respiratory: "resp"
        case .spo2: "spo2"
        default: "skin"
        }
    }

    /// Skin temperature follows the °C/°F preference; every other metric is shown as Trends shows it.
    private var display: (unit: String, format: (Double) -> String)? {
        guard metric == .skinTemp else { return nil }
        return (UnitFormatter.temperatureUnit(temperatureUnit),
                { $0.formatted(.number.precision(.fractionLength(1))) })
    }

    var body: some View {
        // Skin temperature is already range-checked by the vital resolution (absolute °C and ±deviation both pass).
        let points = metric == .skinTemp ? series : series.filter { metric.acceptsForDisplay($0.value) }
        let observations: [CalendarMetricDay] = points.compactMap { point in
            BodyVitalSigns.localDate(fromDayKey: point.day).map { CalendarMetricDay(date: $0, value: point.value) }
        }
        let latest = observations.last
        let tint = metric.domainTint(latest: latest?.value)
        ScreenScaffold(
            title: metric.healthPageTitle, lazy: true,
            headerContext: latest.map { DrillInFormat.headerDate($0.date) }
        ) {
            VStack(alignment: .leading, spacing: 0) {
                hero(latest: latest, observations: observations, tint: tint)
                DrillInSeparator()
                DrillInTrendSection(
                    title: String(localized: "\(metric.healthEyebrowTitle) trend"), metric: metric,
                    observations: observations, referenceDate: Repository.logicalDay(Date()),
                    latest: latest?.value, display: display)
                if metric == .calories {
                    DrillInSeparator()
                    Text("An estimate from your heart rate, not a measured burn.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func hero(latest: CalendarMetricDay?, observations: [CalendarMetricDay], tint: DomainTint) -> some View {
        let unit = display?.unit ?? metric.unit
        let format = display?.format ?? metric.format
        let text = latest?.value.map(format) ?? WidgetMetrics.missingValue
        return VStack(alignment: .leading, spacing: WidgetMetrics.contentSpacing) {
            SectionEyebrow(title: metric.healthEyebrowTitle, systemImage: metric.symbol, tint: tint)
            HeroValue(value: text, unit: unit.isEmpty ? nil : unit,
                      caption: latest.map { BodyVitalReading.dayLabel(Self.dayKey($0.date)) },
                      captionPlacement: .below)
            if let reading, reading.key != BodyVitalSigns.experimentalSpO2CandidateKey {
                Text(verbatim: reading.stateCaption)
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            averages(observations, format: format, unit: unit)
        }
        .accessibilityElement(children: .contain)
    }

    /// The last week's and the last month's average, so today's number has something to sit against.
    private func averages(_ observations: [CalendarMetricDay], format: (Double) -> String, unit: String) -> some View {
        let end = Repository.logicalDay(Date())
        let calendar = Calendar.current
        func average(days: Int) -> Double? {
            guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: end)) else { return nil }
            let values = observations.filter { $0.date >= start }.compactMap(\.value)
            return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        func text(_ value: Double?) -> String {
            guard let value else { return WidgetMetrics.missingValue }
            return format(value) + TrendsUnitSuffix.text(for: unit)
        }
        return FactStrip(facts: [
            .init("7-day avg", value: text(average(days: 7))),
            .init("30-day avg", value: text(average(days: 30))),
        ])
    }

    private static func dayKey(_ date: Date) -> String { Repository.localDayKey(date) }
}
