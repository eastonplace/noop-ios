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
    public static func band(for score: Double) -> RecoveryBand {
        let value = score.isFinite ? min(max(score, 0), 100) : 0
        if value >= 67 { return .high }
        if value >= 34 { return .medium }
        return .low
    }

    public static func color(for score: Double) -> Color {
        switch band(for: score) {
        case .high: return StrandPalette.recoveryHigh
        case .medium: return StrandPalette.recoveryMed
        case .low: return StrandPalette.recoveryLow
        }
    }
}
