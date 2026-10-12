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
