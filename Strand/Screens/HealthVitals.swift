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

/// The icon column of a flat row. Its width follows the type size, so a symbol that grows with Dynamic Type never runs
/// into the words beside it (a fixed 18 pt column overlaps at the accessibility sizes).
struct HealthGlyph: View {
    let systemImage: String
    let color: Color
    @ScaledMetric(relativeTo: .caption) private var width = WidgetMetrics.metricIconWidth

    var body: some View {
        Image(systemName: systemImage)
            .font(StrandFont.caption)
            .foregroundStyle(color)
            .frame(width: width)
            .accessibilityHidden(true)
    }
}

private struct HealthIconIndent: ViewModifier {
    let gap: CGFloat
    @ScaledMetric(relativeTo: .caption) private var width = WidgetMetrics.metricIconWidth

    func body(content: Content) -> some View {
        content.padding(.leading, width + gap)
    }
}

extension View {
    /// Lines a row's second line up under the words of the row above, whose icon column is a `HealthGlyph`.
    func healthIconIndent(gap: CGFloat = NoopMetrics.space2) -> some View {
        modifier(HealthIconIndent(gap: gap))
    }
}

/// `MetricValueRow` for the Health screens: the same icon, label and value, with the icon column scaled and, at the
/// accessibility sizes, the value on its own line under the label so a long figure never truncates against it.
struct HealthValueRow: View {
    let systemImage: String
    let label: String
    let value: String
    var unit: String?
    var tint: DomainTint = .neutral

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // One VoiceOver element ("Logged today, 1,237 ml"), not three stops; a caller that already merges the row
        // under its own label keeps overriding this.
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                        HealthGlyph(systemImage: systemImage, color: tint.accent)
                        Text(label).foregroundStyle(StrandPalette.textSecondary)
                            .captionLabelFit(lines: 3)
                    }
                    reading.healthIconIndent()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    HealthGlyph(systemImage: systemImage, color: tint.accent)
                    Text(label).foregroundStyle(StrandPalette.textSecondary)
                        .captionLabelFit(lines: 2, standardLines: 1)
                    Spacer(minLength: NoopMetrics.space1)
                    reading.lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
    }

    /// What VoiceOver reads: the name, then the value with its unit.
    private var spoken: String {
        guard value != WidgetMetrics.missingValue else { return "\(label), \(String(localized: "no data"))" }
        return "\(label), \(value)" + (unit.map { " \($0)" } ?? "")
    }

    private var reading: some View {
        let missing = value == WidgetMetrics.missingValue
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value).font(StrandFont.bodyNumber)
                .foregroundStyle(missing ? StrandPalette.textTertiary : StrandPalette.textPrimary)
            if let unit, !missing {
                Text(unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

/// A quiet line for a section with nothing to show yet: a symbol and the sentence, never a bounded card.
struct HealthEmptyNote: View {
    let symbol: String
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            HealthGlyph(systemImage: symbol, color: StrandPalette.textTertiary)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                HealthValueRow(
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
            .healthIconIndent()
        } else {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                caption
                Spacer(minLength: 0)
                if let trail { sparkline(trail).frame(width: 64, height: 16) }
            }
            .healthIconIndent()
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
            state.foregroundColor = reading.stateColor
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
    @Environment(\.dynamicTypeSize) private var typeSize

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
                    // The pill is one fixed line, which a long label overhangs the gutter with at accessibility sizes:
                    // there the same words are plain trailing text, which wraps.
                    : (typeSize.isAccessibilitySize
                        ? .text(String(localized: "Calibrating (\(priorCount) of \(Baselines.minNightsSeed))"))
                        : .pill("Calibrating (\(priorCount) of \(Baselines.minNightsSeed))", tone: .warning)))
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
            HealthValueRow(systemImage: contributor.symbol, label: contributor.label, value: contributor.value,
                           unit: contributor.unit, tint: contributor.tint)
            HStack(alignment: .center, spacing: NoopMetrics.space2) {
                Text(verbatim: word)
                    .font(StrandFont.micro)
                    .foregroundStyle(Self.wordColor(strength: strength))
                    .lineLimit(1)
                    .fixedSize()
                HealthStrengthBar(strength: strength, tint: contributor.tint.accent)
            }
            .healthIconIndent()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(contributor.label), \(contributor.value)\(contributor.unit.map { " " + $0 } ?? ""), \(word)"))
    }

    /// The strength word's ink: quiet unless the contributor is low enough to need a look. The bar keeps the metric's
    /// colour.
    static func wordColor(strength: Double?) -> Color {
        guard let strength else { return StrandPalette.textTertiary }
        return strength < 40 ? StrandPalette.statusWarning : StrandPalette.textSecondary
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

/// How the trend pages pick ONE number for a day from the sources Today's cards read, in the card's order, so a page
/// opens on the number its card showed. Pure, so the order is pinned by tests.
enum HealthDailyPick {
    /// The Steps card: the strap's count, else the phone's, else the on-device estimate a WHOOP 4.0 has instead.
    static func steps(strap: Int?, phone: Int?, estimate: Double?) -> Double? {
        strap.map(Double.init) ?? phone.map(Double.init) ?? estimate
    }

    // MARK: Calories: TOTAL energy for the whole day (owner decision D3), on the card and on the page

    /// What the calorie rule needs besides a day's own rows: the strap's worn time per day (how much of the day the
    /// strap's estimate covered), the profile's resting energy, and the clock that tells today from a finished day.
    struct CalorieContext {
        var strapWornSecondsByDay: [String: Double] = [:]
        var bmrKcalPerDay: Double?
        var timeZone: TimeZone = .current
        var now: Date = Date()
    }

    /// The context Trends, the Coupled view and the widgets resolve calories with.
    @MainActor
    static func calorieContext(repo: Repository) -> CalorieContext {
        CalorieContext(strapWornSecondsByDay: repo.strapWornSecondsByDay, bmrKcalPerDay: ProfileStore.storedBmrKcalPerDay())
    }

    /// One day's calories: TOTAL energy (resting + active) for the whole day, never active energy alone. The order of
    /// sources is `DailyCalories`'s (the one rule Trends, the Coupled view and the widgets share); this only hands it
    /// the day's rows and reports whether the answer is the strap's heart-rate estimate (`isStrapEstimate`), so a
    /// screen only calls the number an estimate when it is one. The Today card, its sparkline and the Calories page
    /// all read this one function, so they cannot drift apart.
    static func calories(
        day: String, strapKcal: Double?, phoneActiveKcal: Double?, phoneBasalKcal: Double?, context: CalorieContext
    ) -> (value: Double, isStrapEstimate: Bool)? {
        calories(day: day, strapKcal: strapKcal, phoneActiveKcal: phoneActiveKcal, phoneBasalKcal: phoneBasalKcal,
                 context: context, calendar: DailyCalories.gregorianCalendar(in: context.timeZone))
    }

    /// The same, measuring the day with a calendar the caller built once for the whole series. A multi-year
    /// history otherwise built two `Calendar`s per day, which was most of the cost of resolving it.
    private static func calories(
        day: String, strapKcal: Double?, phoneActiveKcal: Double?, phoneBasalKcal: Double?, context: CalorieContext,
        calendar: Calendar
    ) -> (value: Double, isStrapEstimate: Bool)? {
        let timing = DailyCalories.dayTiming(day: day, calendar: calendar, now: context.now)
        return DailyCalories.resolve(
            strapKcal: strapKcal, strapWornSeconds: context.strapWornSecondsByDay[day],
            appleActiveKcal: phoneActiveKcal, appleBasalKcal: phoneBasalKcal,
            bmrKcalPerDay: context.bmrKcalPerDay,
            daySeconds: timing?.daySeconds, elapsedSeconds: timing?.elapsedSeconds
        ).map { ($0.kcal, $0.source == .strap) }
    }

    /// One day's calories with the day it is for.
    struct CaloriesDay: Equatable {
        let day: String
        let value: Double
        let isStrapEstimate: Bool
    }

    /// Every day that has a calories number, oldest first, from the strap's daily rows and the phone's.
    static func caloriesByDay(
        strap: [DailyMetric], phone: [AppleDaily], context: CalorieContext = CalorieContext()
    ) -> [CaloriesDay] {
        caloriesByDay(
            strapKcalByDay: Dictionary(strap.map { ($0.day, $0.activeKcalEst) }, uniquingKeysWith: { _, last in last })
                .compactMapValues { $0 },
            phone: phone, context: context)
    }

    /// The same, from the strap's whole-day totals by day (a day with no strap total is simply absent). All metrics
    /// reads this too, so its Calories row is this series.
    static func caloriesByDay(
        strapKcalByDay: [String: Double], phone: [AppleDaily], context: CalorieContext = CalorieContext()
    ) -> [CaloriesDay] {
        let phoneByDay = Dictionary(phone.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        let calendar = DailyCalories.gregorianCalendar(in: context.timeZone)
        return Set(strapKcalByDay.keys).union(phoneByDay.keys).sorted().compactMap { day in
            calories(
                day: day, strapKcal: strapKcalByDay[day],
                phoneActiveKcal: phoneByDay[day]?.activeKcal, phoneBasalKcal: phoneByDay[day]?.basalKcal,
                context: context, calendar: calendar
            ).map { CaloriesDay(day: day, value: $0.value, isStrapEstimate: $0.isStrapEstimate) }
        }
    }

    /// Whether any of the days in `days` that fall within `window` days of the newest one is a strap estimate: the
    /// range a page shows and averages. A note about estimates must hold for every day it covers, not only the last.
    static func usesStrapEstimate(in days: [CaloriesDay], window: Int, dayDate: (String) -> Date?) -> Bool {
        guard let newest = days.last.flatMap({ dayDate($0.day) }) else { return false }
        let calendar = Calendar.current
        return days.contains { day in
            guard day.isStrapEstimate, let date = dayDate(day.day) else { return false }
            return (calendar.dateComponents([.day], from: date, to: newest).day ?? 0) < window
        }
    }

    /// What Today's Calories card shows for the day on screen: that day's number and, for the sparkline, the last
    /// `window` days with a number up to it. Keyed to `dayKey`, never to "the newest phone row".
    struct CaloriesCard: Equatable {
        let value: Double?
        let isStrapEstimate: Bool
        let sparkline: [Double]
    }

    /// How far back from the shown day the card looks for its sparkline's days: the card needs that day plus the
    /// last `window` days with a number, and 45 calendar days holds those unless the history is sparse.
    static let caloriesCardLookBackDays = 45

    static func caloriesCard(
        dayKey: String, strap: [DailyMetric], phone: [AppleDaily], context: CalorieContext = CalorieContext(),
        window: Int = 14
    ) -> CaloriesCard {
        // Resolve only the days the card shows. Resolving the whole Apple Health history (up to 4,000 days) per
        // card, up to three times per Today snapshot, was a visible hitch on every remount. The windowed answer
        // is the full answer whenever it holds `window` numbered days, because the card is the newest `window`
        // numbered days up to `dayKey`; a sparse history (fewer found, with older rows left out) resolves it all.
        if let first = Self.dayKey(dayKey, minusDays: caloriesCardLookBackDays - 1) {
            let upToDay = caloriesByDay(
                strap: strap.filter { $0.day >= first && $0.day <= dayKey },
                phone: phone.filter { $0.day >= first && $0.day <= dayKey }, context: context)
            let leftOutOlderRows = strap.contains { $0.day < first } || phone.contains { $0.day < first }
            if upToDay.count >= window || !leftOutOlderRows {
                return card(upToDay: upToDay, dayKey: dayKey, window: window)
            }
        }
        return card(upToDay: caloriesByDay(strap: strap, phone: phone, context: context).filter { $0.day <= dayKey },
                    dayKey: dayKey, window: window)
    }

    private static func card(upToDay: [CaloriesDay], dayKey: String, window: Int) -> CaloriesCard {
        let shown = upToDay.last(where: { $0.day == dayKey })
        return CaloriesCard(
            value: shown?.value, isStrapEstimate: shown?.isStrapEstimate ?? false,
            sparkline: upToDay.suffix(window).map(\.value))
    }

    /// `yyyy-MM-dd` `n` days before `dayKey`, by civil-date arithmetic (UTC, so no daylight-saving gap can
    /// land on the wrong day). nil for a key that is not a date.
    static func dayKey(_ dayKey: String, minusDays n: Int) -> String? {
        let parts = dayKey.split(separator: "-").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
              let earlier = calendar.date(byAdding: .day, value: -n, to: date) else { return nil }
        let c = calendar.dateComponents([.year, .month, .day], from: earlier)
        guard let year = c.year, let month = c.month, let day = c.day else { return nil }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// What a trend page draws, built from plain values so it can be built off the main actor: the daily values (oldest
/// first, in the units shown), already range-checked and dated, and whether any day the Calories page covers is the
/// strap's heart-rate estimate. The sources and their order are the Today cards' (`HealthDailyPick`).
struct HealthTrendPage: Equatable, Sendable {
    let observations: [CalendarMetricDay]
    let showsStrapEstimate: Bool
    /// The °C/°F unit the values were built in, for the metric that has a temperature in it (nil for the others). The
    /// page draws its numbers under the live unit's label, so a page built in the other unit must not be drawn.
    let temperatureUnit: TemperatureUnit?

    struct Inputs: Sendable {
        let metric: ProductionTrendMetric
        let vitalRows: [SourcedDailyMetric]
        let days: [DailyMetric]
        let appleByDay: [String: AppleDaily]
        let stepsEstByDay: [String: Double]
        let calorieContext: HealthDailyPick.CalorieContext
        let temperatureUnit: TemperatureUnit
    }

    static func build(_ inputs: Inputs) -> HealthTrendPage {
        let metric = inputs.metric
        // The calories per day (total energy), from the strap's rows and the phone's, by `DailyCalories`'s one rule.
        let caloriesDays = metric == .calories
            ? HealthDailyPick.caloriesByDay(
                strap: inputs.days, phone: Array(inputs.appleByDay.values), context: inputs.calorieContext)
            : []
        let series: [(day: String, value: Double)]
        switch metric {
        case .hrv, .restingHR, .respiratory, .spo2, .skinTemp:
            series = BodyVitalSigns.trendPoints(
                key: vitalKey(metric), sourceRows: inputs.vitalRows, temperatureUnit: inputs.temperatureUnit)
        case .steps:
            // The order of Today's Steps card: the strap's count, else the phone's, else the on-device estimate.
            series = merged(inputs.days, inputs.appleByDay, inputs.stepsEstByDay) { strap, phone, estimate in
                HealthDailyPick.steps(strap: strap?.steps, phone: phone?.steps, estimate: estimate)
            }
        case .calories:
            // Total energy for the whole day, as Today's Calories card shows it.
            series = caloriesDays.map { ($0.day, $0.value) }
        default:
            series = []
        }
        // Skin temperature is already range-checked by the vital resolution (absolute °C and ±deviation both pass).
        let points = metric == .skinTemp ? series : series.filter { metric.acceptsForDisplay($0.value) }
        let observations: [CalendarMetricDay] = points.compactMap { point in
            BodyVitalSigns.localDate(fromDayKey: point.day).map { CalendarMetricDay(date: $0, value: point.value) }
        }
        // Whether any day this page shows or averages (its chart reaches back 6 months) is the strap's heart-rate
        // estimate rather than the phone's measured energy.
        let showsStrapEstimate = metric == .calories
            && HealthDailyPick.usesStrapEstimate(
                in: caloriesDays, window: 180, dayDate: BodyVitalSigns.localDate(fromDayKey:))
        return HealthTrendPage(
            observations: observations, showsStrapEstimate: showsStrapEstimate,
            temperatureUnit: metric == .skinTemp ? inputs.temperatureUnit : nil)
    }

    /// The page to draw: the stored one while its values are in the unit the label shows, else `fallback()`. After a
    /// °C/°F change the stored page is the other unit's until the rebuild lands, and drawing it would put °C numbers
    /// under a °F label for a frame or two.
    static func resolve(stored: HealthTrendPage?, temperature: TemperatureUnit,
                        fallback: () -> HealthTrendPage) -> HealthTrendPage {
        if let stored, stored.temperatureUnit == nil || stored.temperatureUnit == temperature { return stored }
        return fallback()
    }

    /// One value per day, oldest first, picked from the strap's row, the phone's row and an estimate in the order the
    /// caller's Today card uses, so the page opens on the number the card showed.
    private static func merged(
        _ days: [DailyMetric], _ apple: [String: AppleDaily], _ estimate: [String: Double],
        pick: (DailyMetric?, AppleDaily?, Double?) -> Double?
    ) -> [(day: String, value: Double)] {
        let strapByDay = Dictionary(days.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
        return Set(strapByDay.keys).union(apple.keys).union(estimate.keys).sorted().compactMap { day in
            pick(strapByDay[day], apple[day], estimate[day]).map { (day, $0) }
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
    /// What Today's cards read besides the strap's own daily row: the phone-imported daily steps and active energy, and
    /// the on-device steps estimate a WHOOP 4.0 has instead of a measured count.
    @State private var appleByDay: [String: AppleDaily] = [:]
    @State private var stepsEstByDay: [String: Double] = [:]
    /// The series, observations and estimate note this page draws, built by the `.task` below.
    @State private var page: HealthTrendPage?

    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: temperatureRaw)
    }

    /// Skin temperature follows the °C/°F preference; every other metric is shown as Trends shows it.
    private var display: (unit: String, format: (Double) -> String)? {
        guard metric == .skinTemp else { return nil }
        return (UnitFormatter.temperatureUnit(temperatureUnit),
                { $0.formatted(.number.precision(.fractionLength(1))) })
    }

    /// The page the body draws. Building it walks the whole Apple Health history for Calories and Steps, so it is
    /// built once per refresh in the `.task` below, off the main actor, and the body only reads it. Until that first
    /// build lands the body builds it from what is already loaded (the strap's own rows, which is cheap).
    private var currentPage: HealthTrendPage {
        HealthTrendPage.resolve(stored: page, temperature: temperatureUnit) {
            HealthTrendPage.build(pageInputs(appleByDay: appleByDay, stepsEstByDay: stepsEstByDay))
        }
    }

    private func pageInputs(appleByDay: [String: AppleDaily], stepsEstByDay: [String: Double]) -> HealthTrendPage.Inputs {
        HealthTrendPage.Inputs(
            metric: metric, vitalRows: repo.vitalMetricRows, days: repo.days, appleByDay: appleByDay,
            stepsEstByDay: stepsEstByDay, calorieContext: HealthDailyPick.calorieContext(repo: repo),
            temperatureUnit: temperatureUnit)
    }

    /// What re-builds the page: a repository refresh, or the °C/°F preference the skin-temperature series is in.
    private struct PageKey: Hashable {
        let refreshSeq: Int
        let temperature: TemperatureUnit
    }

    var body: some View {
        let trendPage = currentPage
        let observations = trendPage.observations
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
                if metric == .calories, trendPage.showsStrapEstimate {
                    DrillInSeparator()
                    Text("An estimate from your heart rate, not a measured burn.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .task(id: PageKey(refreshSeq: repo.refreshSeq, temperature: temperatureUnit)) {
            var apple = appleByDay
            var estimates = stepsEstByDay
            if metric == .steps || metric == .calories {
                let rows = await repo.appleDailyRows()
                apple = Dictionary(rows.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last })
                if metric == .steps {
                    let estimate = await repo.exploreSeries(key: "steps_est", source: "my-whoop")
                    estimates = Dictionary(estimate.map { ($0.day, $0.value.rounded()) }, uniquingKeysWith: { _, last in last })
                }
            }
            // The resolvers are pure: the series, the display filter, the day parsing and the estimate note are
            // all computed off the main actor and handed back as one value.
            let inputs = pageInputs(appleByDay: apple, stepsEstByDay: estimates)
            let built = await Task.detached(priority: .userInitiated) { HealthTrendPage.build(inputs) }.value
            guard !Task.isCancelled else { return }
            appleByDay = apple
            stepsEstByDay = estimates
            page = built
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
