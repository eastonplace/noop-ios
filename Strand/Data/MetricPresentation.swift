import SwiftUI
import StrandDesign

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
    static func calendar(timeZone: TimeZone = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = .autoupdatingCurrent
        return calendar
    }

    /// The start of the key's day, or nil when the key is not a real calendar day.
    static func date(for key: String, timeZone: TimeZone = .current) -> Date? {
        let pieces = key.split(separator: "-").compactMap { Int($0) }
        guard pieces.count == 3 else { return nil }
        let calendar = calendar(timeZone: timeZone)
        let components = DateComponents(year: pieces[0], month: pieces[1], day: pieces[2])
        guard let date = calendar.date(from: components) else { return nil }
        // A lenient calendar rolls "2026-13-40" into a later day; a real key reads back as itself.
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == pieces[0], back.month == pieces[1], back.day == pieces[2] else { return nil }
        return date
    }
}

/// How often a metric is recorded, so a weekly or sparse series draws one connected line.
enum ExploreCadence {
    /// The longest stretch the chart's line bridges for a daily metric.
    static let dailyGapLimit = 3

    /// The gap limit for a series recorded on these day offsets (ascending): three times the usual spacing between
    /// readings, never under the daily limit. Daily data keeps three days; weekly data bridges up to three weeks.
    static func gapLimitDays(dayOffsets: [Int]) -> Int {
        let gaps = zip(dayOffsets.dropFirst(), dayOffsets).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        guard !gaps.isEmpty else { return dailyGapLimit }
        return max(dailyGapLimit, gaps[gaps.count / 2] * 3)
    }
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
