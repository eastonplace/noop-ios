import SwiftUI
import StrandDesign
import os

// MARK: - How the catalog looks
//
// One place that says which domain colour a metric wears and which symbol heads its category, so the metric list,
// a metric's own page and its correlations agree. Before this the list and the detail each had a private colour
// switch that did not use `DomainTint` (sleep metrics came out teal, Strain a constant mid-strain blue).

extension MetricDescriptor {
    /// The domain tint of this metric: its symbol, its chart ink and its accents all read from this. Recovery follows
    /// the band of its latest score when one is given, exactly as Today's dial does; without one it wears the
    /// Recovery data colour, never the grey of a missing score.
    func domainTint(latest: Double? = nil) -> DomainTint {
        switch key {
        case "recovery":
            return latest.map { DomainTint.recovery(score: $0) } ?? .custom(StrandPalette.recoveryData)
        case "hrv":
            return .hrv
        case "rhr", "avg_hr", "max_hr":
            return .heart
        case "stress":
            return .stress
        case "strain":
            return .strain
        case "spo2", "steps", "steps_est":
            return .custom(StrandPalette.metricCyan)
        case "energy_kcal", "active_kcal", "skin_temp":
            return .custom(StrandPalette.metricAmber)
        case "resp_rate":
            return .accent
        case "vo2max", "vo2max_est", "fitness_age", "vitality", "body_age":
            return .custom(StrandPalette.metricPurple)
        default:
            return MetricCatalog.categoryTint(category)
        }
    }
}

extension MetricCatalog {
    /// The tint of a category's header, and of any metric in it that has no colour of its own.
    static func categoryTint(_ category: String) -> DomainTint {
        switch category {
        case "Heart": return .heart
        case "Charge": return .custom(StrandPalette.recoveryData)
        case "Rest": return .sleep
        case "Effort": return .strain
        case "Health": return .accent
        case "Nutrition": return .custom(StrandPalette.metricAmber)
        case "Mind": return .journal
        default: return .neutral
        }
    }

    /// The symbol on a category's header.
    static func categorySymbol(_ category: String) -> String {
        switch category {
        case "Heart": return "heart.fill"
        case "Charge": return "bolt.heart.fill"
        case "Rest": return "moon.stars.fill"
        case "Effort": return "flame.fill"
        case "Health": return "figure.stand"
        case "Nutrition": return "fork.knife"
        case "Mind": return "face.smiling"
        default: return "chart.xyaxis.line"
        }
    }
}

extension CorrelationStrength {
    /// The word for how strong a relationship is ("moderate"), in the person's language.
    var word: String {
        switch self {
        case .negligible: return String(localized: "negligible")
        case .weak: return String(localized: "weak")
        case .moderate: return String(localized: "moderate")
        case .strong: return String(localized: "strong")
        case .veryStrong: return String(localized: "very strong")
        }
    }
}

// MARK: - What a metric can be, and how its number reads

extension MetricDescriptor {
    /// The values this metric can physically take, in its stored units. A chart axis never runs past it (a blood
    /// oxygen of 104%) and the "typical" band is held inside it (no 101% blood oxygen, no negative sleep debt, no 6 out
    /// of 5 mood). Only the percentages that are truly capped stop at 100: Hours vs Needed is a ratio and reads 112%
    /// on a long night, so it has a floor and no ceiling. Skin temperature is a signed deviation as often as an
    /// absolute reading, so it has neither.
    var validRange: ClosedRange<Double> {
        let unbounded = -Double.greatestFiniteMagnitude...Double.greatestFiniteMagnitude
        switch key {
        case "recovery", "sleep_performance", "spo2", "sleep_efficiency", "restorative_pct", "body_fat",
             "sleep_consistency", "noop_sleep_performance_v2", "sleep_score", "strain":
            return 0...100
        case "mood":
            return 1...5
        case "stress":
            return 0...(unit == "/3" ? 3 : 100)
        case "skin_temp":
            return unbounded
        default:
            return 0...Double.greatestFiniteMagnitude
        }
    }

    /// A stored value as the person reads it, split so the unit can be set apart and muted: "62" and "bpm", "74.2" and
    /// "kg" (or "lb" in pounds), "5.4" and "/21". A metric with no unit returns an empty one.
    func displayParts(_ value: Double, system: UnitSystem, temperature: TemperatureUnit,
                      effortScale: EffortScale) -> (number: String, unit: String) {
        let text = format(value, system: system, temperature: temperature, effortScale: effortScale)
        let unit = displayUnit(system: system, temperature: temperature, effortScale: effortScale)
        guard !unit.isEmpty, text.hasSuffix(unit) else { return (text, unit) }
        return (String(text.dropLast(unit.count)).trimmingCharacters(in: .whitespaces), unit)
    }
}

/// The "typical" band and baseline held inside what the metric can be, so the band's row, its shading on the chart and
/// the spoken summary all say the same numbers.
enum ExploreTypicalBand {
    static func clamped(baseline: Double, typical: ClosedRange<Double>, to valid: ClosedRange<Double>)
        -> (baseline: Double, typical: ClosedRange<Double>) {
        func hold(_ value: Double) -> Double { min(max(value, valid.lowerBound), valid.upperBound) }
        return (hold(baseline), hold(typical.lowerBound)...hold(typical.upperBound))
    }
}

/// How the repository's day keys become dates. A key ("yyyy-MM-dd") names a civil day in the Gregorian calendar and
/// the person's own time zone, whatever calendar the device displays in: a Buddhist-calendar device reads "2026" as
/// 2026, never as year 2026 of its own era. Every window on the page (slice, history span, chart window) uses this one
/// calendar; the device's calendar and locale are for display only.
enum ExploreDayKey {
    /// One Gregorian calendar per time zone, made once: a screen that turns thousands of day keys into dates (a Compare
    /// overlay over years of readings) asks for it per key, and building a `Calendar` each time was most of that cost.
    private static let calendars = OSAllocatedUnfairLock(initialState: [String: Calendar]())

    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        calendars.withLock { cache in
            if let cached = cache[timeZone.identifier] { return cached }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            calendar.locale = .autoupdatingCurrent
            cache[timeZone.identifier] = calendar
            return calendar
        }
    }

    /// The start of the key's day, or nil when the key is not a real calendar day.
    static func date(for key: String, timeZone: TimeZone = .current) -> Date? {
        guard let parts = civilParts(of: key) else { return nil }
        return calendar(timeZone: timeZone).date(from: DateComponents(year: parts.year, month: parts.month, day: parts.day))
    }

    /// The key's day as a count of days since 1970-01-01 in the proleptic Gregorian calendar, with no calendar, locale or
    /// time zone involved, so windows and lags over thousands of days are plain integer arithmetic. nil when the key is
    /// not a real day.
    static func dayNumber(for key: String) -> Int? {
        civilParts(of: key).map { daysFromCivil(year: $0.year, month: $0.month, day: $0.day) }
    }

    /// The key ("yyyy-MM-dd") of a day number from `dayNumber(for:)`.
    static func key(forDayNumber number: Int) -> String {
        let parts = civilFromDays(number)
        return String(format: "%04d-%02d-%02d", parts.year, parts.month, parts.day)
    }

    /// The key of the day a date falls on in the person's time zone.
    static func key(for date: Date, timeZone: TimeZone = .current) -> String {
        let parts = calendar(timeZone: timeZone).dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 1, parts.day ?? 1)
    }

    /// Year, month and day of a real "yyyy-MM-dd" key; nil for anything else (a lenient reader would roll
    /// "2026-13-40" into a later day).
    private static func civilParts(of key: String) -> (year: Int, month: Int, day: Int)? {
        let pieces = key.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        let (year, month, day) = (pieces[0], pieces[1], pieces[2])
        guard (1...12).contains(month), day >= 1 else { return nil }
        let back = civilFromDays(daysFromCivil(year: year, month: month, day: day))
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return (year, month, day)
    }

    // Howard Hinnant's days-from-civil and civil-from-days, exact for every Gregorian date.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    private static func civilFromDays(_ number: Int) -> (year: Int, month: Int, day: Int) {
        let z = number + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (year, month, day)
    }
}

/// How often a metric is recorded, so a weekly or sparse series draws one connected line. The rule itself lives with
/// the charts (`TrendCadence`), so Explore and Compare bridge the same gaps.
enum ExploreCadence {
    /// The longest stretch the chart's line bridges for a daily metric.
    static let dailyGapLimit = TrendCadence.dailyGapLimit

    /// The gap limit for a series recorded on these day offsets (ascending): three times the usual spacing between
    /// readings, never under the daily limit.
    static func gapLimitDays(dayOffsets: [Int]) -> Int { TrendCadence.gapLimitDays(dayOffsets: dayOffsets) }
}

/// How a change against the earlier readings is worded.
enum ExploreChange {
    /// "+4.2%" or "−1.5%": the sign, then the size to one decimal place in `locale`'s percent format. A change that
    /// rounds to nothing carries no sign.
    static func signedPercent(_ pct: Double, locale: Locale = .autoupdatingCurrent) -> String {
        let magnitude = (abs(pct) / 100).formatted(.percent.precision(.fractionLength(0...1)).locale(locale))
        guard (abs(pct) * 10).rounded() > 0 else { return magnitude }
        return (pct >= 0 ? "+" : "\u{2212}") + magnitude
    }
}
