import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

/// One resolved vital-sign tile: the latest value across the source precedence, banded against the
/// user's own trailing baseline (population fallback until 14 trusted nights), plus the day + source
/// that supplied it so the caption can name them honestly. The view layer reads only this — all of the
/// source resolution + banding lives in `BodyVitalSigns` so it stays pure and testable.
struct BodyVitalReading: Identifiable {
    let key: String
    let label: String
    let unit: String
    let value: Double?
    let format: (Double) -> String
    let banding: VitalBands.Result
    let metricColor: Color
    let day: String?
    let source: DailyMetricSource?
    let missingCaption: String
    /// Trailing values for this vital (oldest → newest), so the tile can draw a metric-tinted
    /// sparkline with a glowing "now" end-cap like Today's Key-Metrics tiles. Presentation-only:
    /// the resolved value, banding and source are unchanged — this is just the trend for the trail.
    /// Defaulted so existing call sites (previews/tests) keep compiling unchanged.
    var sparkline: [Double]? = nil

    var id: String { key }

    var formattedValue: String? {
        value.map { "\(format($0)) \(unit)" }
    }

    /// Colour communicates state for validated vitals. The experimental candidate is deliberately neutral:
    /// it has no physiological range judgement and must never look like a reassuring in-range result.
    var accent: Color {
        if key == BodyVitalSigns.experimentalSpO2CandidateKey {
            return StrandPalette.textTertiary
        }
        switch banding.band {
        case .noData:     return StrandPalette.textTertiary
        case .inRange:    return metricColor
        case .outOfRange: return StrandPalette.statusWarning
        }
    }

    /// The metric this vital is plotted as on Trends and named by Today's cards, so its symbol, tint and trend page
    /// come from one place. nil for the experimental SpO₂ candidate, which has no trend and no range judgement.
    var trendMetric: ProductionTrendMetric? {
        switch key {
        case "resp": .respiratory
        case "spo2": .spo2
        case "rhr": .restingHR
        case "hrv": .hrv
        case "skin": .skinTemp
        default: nil
        }
    }

    /// The vital's domain tint: the same one Today's card and the Trends chart wear. The candidate is neutral.
    var domainTint: DomainTint {
        trendMetric?.domainTint(latest: nil) ?? .custom(StrandPalette.textTertiary)
    }

    var symbol: String { trendMetric?.symbol ?? "drop.fill" }

    /// What a row says before the state word: "<day> · <source>". For the experimental candidate this is the whole
    /// caption (it carries its own warning), and a vital with no value says why instead.
    var provenanceCaption: String {
        if key == BodyVitalSigns.experimentalSpO2CandidateKey {
            guard let day else { return missingCaption }
            return [
                Self.dayLabel(day),
                String(localized: "WHOOP 5/MG"),
                String(localized: "Experimental; may be inaccurate"),
            ].joined(separator: " · ")
        }
        guard let day else { return missingCaption }
        var parts = [Self.dayLabel(day)]
        if let sourceText = Self.sourceLabel(source, key: key) {
            parts.append(sourceText)
        }
        return parts.joined(separator: " · ")
    }

    /// Which yardstick judged the value, as a word; nil when the caption already says everything (a missing
    /// value, or the candidate).
    var stateWord: String? {
        guard day != nil, key != BodyVitalSigns.experimentalSpO2CandidateKey else { return nil }
        return stateText
    }

    /// The tile caption: "<day> · <source> · <state>". Falls back to a metric-specific "no value"
    /// line when nothing resolved, so an empty tile still says why instead of a bare dash.
    var stateCaption: String {
        guard let stateWord else { return provenanceCaption }
        return provenanceCaption + " · " + stateWord
    }

    var accessibilityText: String {
        guard let v = formattedValue else { return String(localized: "\(label): no data") }
        if key == BodyVitalSigns.experimentalSpO2CandidateKey {
            return String(localized: "\(label): \(v). Experimental WHOOP 5 or MG candidate. It may be inaccurate and is not used for scoring, HealthKit, or medical decisions.")
        }
        return String(localized: "\(label): \(v), \(stateCaption)")
    }

    /// Which yardstick judged the value: your own baseline vs the typical adult range. String(localized:)
    /// — StatTile's caption is a plain String rendered via Text(String), which never consults the catalog.
    private var stateText: String {
        switch (banding.band, banding.basis) {
        case (.noData, _):               return String(localized: "No data")
        case (.inRange, .personal):      return String(localized: "In your range")
        case (.outOfRange, .personal):   return String(localized: "Off baseline")
        case (.inRange, .population):    return String(localized: "Typical range")
        case (.outOfRange, .population): return String(localized: "Outside range")
        }
    }

    /// Short provenance word for the caption. The local-cache fallback stays unnamed (previews/tests),
    /// and computed skin temp reads "Overnight computed" since that figure is a nightly derivation.
    private static func sourceLabel(_ source: DailyMetricSource?, key: String) -> String? {
        guard let source else { return nil }
        switch source {
        case .whoopImport:
            return String(localized: "WHOOP import")
        case .noopComputed:
            if key == "skin" { return String(localized: "Overnight computed") }
            return String(localized: "NOOP computed")
        case .appleHealth:
            return String(localized: "Apple Health")
        case .localCache:
            return nil
        }
    }

    static func dayLabel(_ day: String) -> String {
        if day == BodyVitalSigns.logicalDayKey(Date()) { return String(localized: "Today") }
        guard let date = BodyVitalSigns.localDate(fromDayKey: day) else { return day }
        // A format style, so it follows the device's language and region ("9 Oct", "9. Okt.").
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

/// Builds the body vital-sign readings from source-tagged daily rows. Pure + namespaced so the
/// resolution (per-metric source precedence) and banding can be unit-tested without a Repository.
enum BodyVitalSigns {
    static let experimentalSpO2CandidateKey = "spo2_candidate_82"

    /// Preview/test convenience: wrap plain rows (optionally a separate "today") as local-cache rows.
    static func readings(days: [DailyMetric],
                         today: DailyMetric?,
                         temperatureUnit: TemperatureUnit) -> [BodyVitalReading] {
        var sourceRows = days.map { SourcedDailyMetric(metric: $0, source: .localCache) }
        if let today, !days.contains(where: { $0.day == today.day }) {
            sourceRows.append(SourcedDailyMetric(metric: today, source: .localCache))
        }
        return readings(sourceRows: sourceRows, temperatureUnit: temperatureUnit)
    }

    static func readings(sourceRows: [SourcedDailyMetric],
                         temperatureUnit: TemperatureUnit,
                         now: Date = Date()) -> [BodyVitalReading] {
        let logicalDay = logicalDayKey(now)

        // Resolve one metric to a per-day series (see `resolvedPoints`).
        func points(key: String, _ value: (DailyMetric) -> Double?) -> [VitalPoint] {
            resolvedPoints(sourceRows: sourceRows, key: key, value)
        }

        // Prefer the logical day's value; otherwise the most recent day that has one — so a vital still
        // shows after a day with no wear instead of blanking to "—".
        func latest(_ pts: [VitalPoint]) -> VitalPoint? {
            pts.last(where: { $0.day == logicalDay }) ?? pts.last
        }

        func history(before day: String?, _ pts: [VitalPoint]) -> [Double?] {
            VitalBands.calendarSeries(pts.filter { point in
                guard let day else { return true }
                return point.day < day
            }.map { ($0.day, Optional($0.value)) })
        }

        let respPoints = points(key: "resp", \.respRateBpm)
        let spo2Points = points(key: "spo2", \.spo2Pct)
        // The experimental WHOOP 5/MG value is encoded separately from calibrated SpO₂: the daily red slot
        // carries the candidate percentage and the IR slot carries an impossible negative marker. Ordinary
        // WHOOP 4 raw red/IR ADC pairs never match this helper and remain outside this beta tile.
        let candidateSpO2Points = points(key: experimentalSpO2CandidateKey) {
            Whoop5V18SpO2Candidate.persistedPercentage(red: $0.spo2Red, ir: $0.spo2Ir)
        }
        let rhrPoints = points(key: "rhr") { $0.restingHr.map(Double.init) }
        let hrvPoints = points(key: "hrv", \.avgHrv)
        let skinPoints = points(key: "skin", \.skinTempDevC)

        let respRow = latest(respPoints)
        let spo2Row = latest(spo2Points)
        let candidateSpO2Row = latest(candidateSpO2Points)
        let rhrRow = latest(rhrPoints)
        let hrvRow = latest(hrvPoints)
        let skinRow = latest(skinPoints)

        // Trailing values (oldest → newest) feeding each tile's sparkline trail. A 2+ point series
        // draws; the tile hides the trail otherwise. Presentation-only — built from the same resolved
        // points already used for the value, just kept as a series rather than collapsed to `latest`.
        func trail(_ pts: [VitalPoint], window: Int = 14) -> [Double] {
            pts.suffix(window).map(\.value)
        }

        // Skin temp is bimodal: CSV imports store ABSOLUTE °C, the on-device pipeline a ±°C DEVIATION —
        // partition the history to the displayed value's kind and pick the matching config + population
        // fallback (±0.6 °C mirrors the illness watch's flag threshold).
        let skin = skinRow?.value
        let skinIsAbsolute = skin.map(VitalBands.isAbsoluteSkinTemp) ?? true
        let skinResult: VitalBands.Result
        if let skin {
            skinResult = VitalBands.band(
                value: skin,
                history: VitalBands.skinTempHistory(matching: skin, in: history(before: skinRow?.day, skinPoints)),
                populationRange: skinIsAbsolute ? 33...36 : (-0.6)...0.6,
                cfg: skinIsAbsolute ? Baselines.metricCfg["skin_temp"]! : VitalBands.skinTempDeviationCfg
            )
        } else {
            skinResult = VitalBands.Result(band: .noData, basis: .population, nights: 0)
        }

        // Resolve the skin-temp label + converter once, honouring the °C/°F preference. An ABSOLUTE
        // reading uses the full C→F formula (×9/5 + 32); a ±DEVIATION must omit the offset.
        let skinUnitLabel = UnitFormatter.temperatureUnit(temperatureUnit)
        let skinFormat: (Double) -> String = { c in
            let shown: Double
            switch temperatureUnit {
            case .celsius: shown = c
            case .fahrenheit: shown = skinIsAbsolute ? UnitFormatter.celsiusToFahrenheit(c) : c * 9 / 5
            }
            return shown.formatted(.number.precision(.fractionLength(1)))
        }

        var readings = [
            BodyVitalReading(
                key: "resp",
                label: String(localized: "Resp Rate"),
                unit: "rpm",
                value: respRow?.value,
                format: { $0.formatted(.number.precision(.fractionLength(1))) },
                banding: VitalBands.band(
                    value: respRow?.value,
                    history: history(before: respRow?.day, respPoints),
                    populationRange: 12...20,
                    cfg: Baselines.respCfg
                ),
                metricColor: ProductionTrendMetric.respiratory.tint,
                day: respRow?.day,
                source: respRow?.source,
                missingCaption: String(localized: "No respiratory-rate value"),
                sparkline: trail(respPoints)
            ),
            BodyVitalReading(
                key: "spo2",
                label: String(localized: "Blood O₂"),
                unit: "%",
                value: spo2Row?.value,
                format: { $0.formatted(.number.precision(.fractionLength(0))) },
                // Population-only on purpose: an absolute <95% floor is meaningful regardless of
                // personal baseline (no "spo2" MetricCfg exists).
                banding: VitalBands.band(
                    value: spo2Row?.value,
                    history: [],
                    populationRange: 95...100,
                    cfg: nil
                ),
                metricColor: ProductionTrendMetric.spo2.tint,
                day: spo2Row?.day,
                source: spo2Row?.source,
                missingCaption: String(localized: "No SpO₂ import or Health value"),
                sparkline: trail(spo2Points)
            ),
            BodyVitalReading(
                key: "rhr",
                label: String(localized: "Resting HR"),
                unit: "bpm",
                value: rhrRow?.value,
                format: Self.wholeNumber,
                banding: VitalBands.band(
                    value: rhrRow?.value,
                    history: history(before: rhrRow?.day, rhrPoints),
                    populationRange: 40...60,
                    cfg: Baselines.restingHRCfg
                ),
                metricColor: ProductionTrendMetric.restingHR.tint,
                day: rhrRow?.day,
                source: rhrRow?.source,
                missingCaption: String(localized: "No resting HR value"),
                sparkline: trail(rhrPoints)
            ),
            BodyVitalReading(
                key: "hrv",
                label: String(localized: "HRV"),
                unit: "ms",
                value: hrvRow?.value,
                format: Self.wholeNumber,
                banding: VitalBands.band(
                    value: hrvRow?.value,
                    history: history(before: hrvRow?.day, hrvPoints),
                    populationRange: 40...120,
                    cfg: Baselines.hrvCfg
                ),
                metricColor: ProductionTrendMetric.hrv.tint,
                day: hrvRow?.day,
                source: hrvRow?.source,
                missingCaption: String(localized: "No HRV value"),
                sparkline: trail(hrvPoints)
            ),
            BodyVitalReading(
                key: "skin",
                label: String(localized: "Skin Temp"),
                unit: skinUnitLabel,
                value: skin,
                format: skinFormat,
                banding: skinResult,
                metricColor: ProductionTrendMetric.skinTemp.tint,
                day: skinRow?.day,
                source: skinRow?.source,
                missingCaption: String(localized: "No nightly skin-temp value"),
                // Keep the trail on the displayed value's kind — absolute °C and ±deviation must not
                // mix on one sparkline (matches the banding partition above).
                sparkline: trail(skinPoints.filter { VitalBands.isAbsoluteSkinTemp($0.value) == skinIsAbsolute })
            ),
        ]

        // Never place the candidate into the canonical Blood O₂ tile. It gets its own explicitly-beta tile
        // only when a nightly value exists. `noData` is intentional presentation metadata here: unlike a
        // validated vital, this candidate has no clinical/personal range judgement and must not display as
        // "in range" merely because a byte happened to decode between 70 and 100.
        if let candidateSpO2Row {
            readings.insert(
                BodyVitalReading(
                    key: experimentalSpO2CandidateKey,
                    label: String(localized: "SpO₂ Candidate (Beta)"),
                    unit: "%",
                    value: candidateSpO2Row.value,
                    format: { String(format: "≈%.0f", $0) },
                    banding: VitalBands.Result(band: .noData, basis: .population, nights: 0),
                    metricColor: StrandPalette.textTertiary,
                    day: candidateSpO2Row.day,
                    source: candidateSpO2Row.source,
                    missingCaption: String(localized: "No experimental WHOOP 5/MG candidate"),
                    sparkline: nil
                ),
                at: min(2, readings.count)
            )
        }
        return readings
    }

    /// Where a vital's value sits on its physiological span (0.02…1), matching Today's per-metric `fracOver`
    /// denominators: HRV/120, RHR/100, respiratory/24, SpO₂ across 90…100, absolute skin temp across 33…38 °C
    /// and a small ±deviation around a half-full centre. Keyed by the SAME keys `readings` emits ("resp",
    /// "skin" — not "resp_rate"/"skin_temp"), so every vital reads its own span instead of falling through to
    /// the generic default. nil when there is no value, so a gauge reads empty rather than faked.
    static func gaugeFraction(key: String, value: Double?) -> Double? {
        guard let v = value, v.isFinite else { return nil }
        func over(_ span: Double) -> Double { max(0.02, min(1, v / span)) }
        func across(_ lo: Double, _ hi: Double) -> Double { max(0.02, min(1, (v - lo) / (hi - lo))) }
        switch key {
        case "hrv":  return over(120)
        case "rhr":  return over(100)
        case "resp": return over(24)
        case "spo2": return across(90, 100)
        case "skin":
            // Absolute skin temp (>= 20 °C) maps across a plausible wrist band; a small ±deviation
            // maps around a half-full centre so a normal night reads mid-gauge, not empty.
            return VitalBands.isAbsoluteSkinTemp(v) ? across(33, 38) : max(0.02, min(1, 0.5 + v / 4))
        default: return across(0, max(1, v * 1.5))
        }
    }

    /// Resolve one metric to a per-day series, taking the FIRST source (by precedence) that carries a plausible
    /// value for each day. Imported wins over computed wins over Apple, per `vitalPrecedence`. A finite-but-corrupt
    /// SQLite value must not reach integer formatting, chart geometry, or band math.
    fileprivate static func resolvedPoints(sourceRows: [SourcedDailyMetric], key: String,
                                           _ value: (DailyMetric) -> Double?) -> [VitalPoint] {
        let allowedSources = DailyMetricSource.vitalPrecedence(for: key)
        var byDay: [String: VitalPoint] = [:]
        for source in allowedSources {
            for row in sourceRows where row.source == source {
                guard let v = value(row.metric),
                      isPlausibleVital(v, key: key),
                      byDay[row.metric.day] == nil
                else { continue }
                byDay[row.metric.day] = VitalPoint(day: row.metric.day, value: v, source: row.source)
            }
        }
        return byDay.values.sorted { $0.day < $1.day }
    }

    /// The daily values behind a vital's row, oldest first, in the units the row shows: the series a trend page plots
    /// is the series the row's value was read from, so the two cannot disagree. Skin temperature keeps to the kind of
    /// the newest reading (absolute °C or a ±deviation) and follows the °C/°F preference.
    static func trendPoints(key: String, sourceRows: [SourcedDailyMetric],
                            temperatureUnit: TemperatureUnit) -> [(day: String, value: Double)] {
        let points: [VitalPoint]
        switch key {
        case "resp": points = resolvedPoints(sourceRows: sourceRows, key: key, \.respRateBpm)
        case "spo2": points = resolvedPoints(sourceRows: sourceRows, key: key, \.spo2Pct)
        case "rhr": points = resolvedPoints(sourceRows: sourceRows, key: key) { $0.restingHr.map(Double.init) }
        case "hrv": points = resolvedPoints(sourceRows: sourceRows, key: key, \.avgHrv)
        case "skin":
            let all = resolvedPoints(sourceRows: sourceRows, key: key, \.skinTempDevC)
            guard let newest = all.last?.value else { return [] }
            let absolute = VitalBands.isAbsoluteSkinTemp(newest)
            return all.filter { VitalBands.isAbsoluteSkinTemp($0.value) == absolute }.map { point in
                let shown: Double
                switch temperatureUnit {
                case .celsius: shown = point.value
                case .fahrenheit: shown = absolute ? UnitFormatter.celsiusToFahrenheit(point.value) : point.value * 9 / 5
                }
                return (point.day, shown)
            }
        default: return []
        }
        return points.map { ($0.day, $0.value) }
    }

    /// A day key ("2026-10-09") as that local day's midnight. The app's day keys are local days.
    static func localDate(fromDayKey day: String) -> Date? {
        localDayParser.date(from: day)
    }

    private static let localDayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// The newest day any resolved reading was sourced from, as a key.
    static func latestDayKey(_ readings: [BodyVitalReading]) -> String? {
        readings.compactMap(\.day).max()
    }

    /// The newest day any resolved reading was sourced from — drives the section's "Latest" trailing label.
    static func latestDayLabel(_ readings: [BodyVitalReading]) -> String? {
        readings.compactMap(\.day).max().map(BodyVitalReading.dayLabel)
    }

    /// The LOGICAL local day for `now` (rolls at 04:00 local). Self-contained so this helper stays pure
    /// and independent of the @MainActor Repository — same boundary, mirrored here for the readings build.
    static func logicalDayKey(_ now: Date, rolloverHour: Int = 4) -> String {
        localDayFormatter.string(from: now.addingTimeInterval(-Double(rolloverHour) * 3_600))
    }

    private static func isPlausibleVital(_ value: Double, key: String) -> Bool {
        guard value.isFinite else { return false }
        switch key {
        case "resp":
            return (1...100).contains(value)
        case "spo2":
            return (0...100).contains(value)
        case experimentalSpO2CandidateKey:
            return (70...100).contains(value)
        case "rhr":
            return (20...250).contains(value)
        case "hrv":
            return (0...2_000).contains(value)
        case "skin":
            // Covers both absolute wrist temperature and the signed deviation representation.
            return (-20...60).contains(value)
        default:
            return false
        }
    }

    private static func wholeNumber(_ value: Double) -> String {
        Int(exactly: value.rounded()).map(String.init) ?? "—"
    }

    private static let localDayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

private struct VitalPoint: Equatable {
    let day: String
    let value: Double
    let source: DailyMetricSource
}

private extension DailyMetricSource {
    /// Source precedence for a vital, highest first. Skin temp deliberately omits Apple Health — it
    /// has no 1:1 Apple equivalent for the strap's ±deviation reading, so an Apple absolute value must
    /// not stand in for it. localCache is always last (previews/tests).
    static func vitalPrecedence(for key: String) -> [DailyMetricSource] {
        switch key {
        case "skin":
            return [.whoopImport, .noopComputed, .localCache]
        case BodyVitalSigns.experimentalSpO2CandidateKey:
            // Only the on-device computed row can carry the impossible negative IR marker. Keeping the
            // source list narrow prevents a future import field from being mistaken for this experiment.
            return [.noopComputed, .localCache]
        default:
            return [.whoopImport, .noopComputed, .appleHealth, .localCache]
        }
    }
}
