import Foundation
import StrandDesign

// The Strain hero's guidance: how the day sits against the target, and where the target came from. Pure and tested.

/// How the day's strain sits against the target band, on the figures the hero prints: the value is compared at the
/// one decimal it is shown with, so a 13.96 that reads "14.0" is on target and never "0.0 below".
enum StrainTargetGuidance: Equatable {
    case below(Double)
    case onTarget
    case above(Double)

    static func make(value: Double?, target: ClosedRange<Double>?) -> StrainTargetGuidance? {
        guard let value, value.isFinite, let target else { return nil }
        let shown = oneDecimal(value)
        if shown < target.lowerBound { return .below(oneDecimal(target.lowerBound - shown)) }
        if shown > target.upperBound { return .above(oneDecimal(shown - target.upperBound)) }
        return .onTarget
    }

    /// Rounded half away from zero to one decimal, the way every score label rounds.
    private static func oneDecimal(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    var text: String {
        switch self {
        case .below(let distance):
            return String(localized: "\(DrillInFormat.number(distance, fractionDigits: 1)) below target")
        case .onTarget:
            return String(localized: "On target")
        case .above(let distance):
            return String(localized: "\(DrillInFormat.number(distance, fractionDigits: 1)) above target")
        }
    }
}

/// Where the target came from, in one quiet line: the recovery that sets the band.
enum StrainTargetSource: Equatable {
    case today(recovery: Int)
    case pastDay(recovery: Int)
    case notYetScored
    case noRecovery

    static func make(recovery: Double?, isToday: Bool) -> StrainTargetSource {
        guard let recovery, recovery.isFinite else { return isToday ? .notYetScored : .noRecovery }
        let score = Int(recovery.rounded())
        return isToday ? .today(recovery: score) : .pastDay(recovery: score)
    }

    var text: String {
        switch self {
        case .today(let score): return String(localized: "Target set by your recovery today (\(score))")
        case .pastDay(let score): return String(localized: "Target set by that day's recovery (\(score))")
        case .notYetScored: return String(localized: "The target appears once today's recovery is scored.")
        case .noRecovery: return String(localized: "No recovery was scored that day, so it had no target.")
        }
    }
}

