import Foundation
import SwiftUI

/// The user-facing Strain status bands on the canonical 0...21 display scale.
public enum StrainBand: String, CaseIterable, Sendable {
    case light
    case moderate
    case high
    case allOut

    public var title: String {
        switch self {
        case .light: return String(localized: "Light", bundle: .module)
        case .moderate: return String(localized: "Moderate", bundle: .module)
        case .high: return String(localized: "High", bundle: .module)
        case .allOut: return String(localized: "All Out", bundle: .module)
        }
    }
}

/// The single display-boundary conversion for stored 0...100 strain values.
/// Storage/import values remain unchanged; every user-facing surface converts through this type.
public enum StrainScale {
    public static let storedRange: ClosedRange<Double> = 0...100
    public static let displayRange: ClosedRange<Double> = 0...21
    public static let storedToDisplayFactor = displayRange.upperBound / storedRange.upperBound

    public static func displayValue(fromStored storedValue: Double) -> Double {
        let stored = clamp(storedValue, to: storedRange)
        return stored * storedToDisplayFactor
    }

    public static func storedValue(fromDisplay displayValue: Double) -> Double {
        let display = clamp(displayValue, to: displayRange)
        return display * storedRange.upperBound / displayRange.upperBound
    }

    /// Convert a signed stored-axis difference without clamping away negative movement.
    public static func displayDelta(fromStored storedDelta: Double) -> Double {
        guard storedDelta.isFinite else { return 0 }
        return storedDelta * storedToDisplayFactor
    }

    public static func formattedDelta(_ storedDelta: Double) -> String {
        String(format: "%.1f", displayDelta(fromStored: storedDelta))
    }

    /// Format a stored value on the 0...21 display scale with one decimal place.
    public static func formatted(_ storedValue: Double) -> String {
        String(format: "%.1f", displayValue(fromStored: storedValue))
    }

    /// Canonical compact row/badge text for an optional stored strain value.
    /// Keeping the empty-state glyph here lets workout rows, widgets, and tests share the same
    /// presentation boundary without importing a view type.
    public static func badgeText(fromStored storedValue: Double?) -> String {
        storedValue.map(formatted) ?? "–"
    }

    /// Resolve a status from a value that is already on the 0...21 display scale.
    public static func band(_ displayValue: Double) -> StrainBand {
        switch clamp(displayValue, to: displayRange) {
        case ..<10: return .light
        case ..<14: return .moderate
        case ..<18: return .high
        default: return .allOut
        }
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        guard value.isFinite else { return range.lowerBound }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

public enum RecoveryBand: String, CaseIterable, Sendable {
    case low
    case medium
    case high
}

/// WHOOP-compatible Recovery valuation boundaries and their Paper-aware colors.
public enum RecoveryBands {
    /// Inside the red band a score under this is "Depleted", the rest of the band "Low".
    private static let depletedBelow = 25.0
    /// Inside the green band a score from this is "Peak", the rest of the band "Primed".
    private static let peakFrom = 88.0

    /// The score as the screens print it: whole points (rounded half away from zero, like every score label), kept
    /// inside 0...100. The bands cut that number, so a 66.6 that is drawn "67" is a "67" and never a yellow one.
    /// A score that is not a number reads as 0, the depleted end, never as a good one.
    private static func displayed(_ score: Double) -> Double {
        score.isFinite ? min(max(score.rounded(), 0), 100) : 0
    }

    public static func band(for score: Double) -> RecoveryBand {
        let value = displayed(score)
        if value >= 67 { return .high }
        if value >= 34 { return .medium }
        return .low
    }

    /// The one word for a recovery score, in Title Case: Depleted, Low, Moderate, Primed or Peak. Every screen that
    /// names a score gets it from here (the pillar cards, the drill-in, the ring, the heat-strip tooltip). The two
    /// extra cut points sit inside a colour band, so each word wears exactly one colour: Depleted and Low are the
    /// red band, Moderate the yellow one, Primed and Peak the green one. A ring that draws caps uppercases it there.
    public static func word(for score: Double) -> String {
        let value = displayed(score)
        switch band(for: value) {
        case .low:
            return value < depletedBelow
                ? String(localized: "Depleted", bundle: .module)
                : String(localized: "Low", bundle: .module)
        case .medium:
            return String(localized: "Moderate", bundle: .module)
        case .high:
            return value < peakFrom
                ? String(localized: "Primed", bundle: .module)
                : String(localized: "Peak", bundle: .module)
        }
    }

    public static func color(for score: Double) -> Color {
        switch band(for: score) {
        case .high: return StrandPalette.recoveryHigh
        case .medium: return StrandPalette.recoveryMed
        case .low: return StrandPalette.recoveryLow
        }
    }
}
