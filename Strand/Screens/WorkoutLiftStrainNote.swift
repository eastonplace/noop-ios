import Foundation
import ReceiptLiftFeature

// MARK: - What a lift's detail says about the sets in its Strain
//
// Strength Strain counts the working sets a person logs on top of heart rate. A Strength Training session's detail shows
// the split under its Strain band when the sets were counted, and a calm one-line state when they were not. Pure and
// tested: the view only draws it. The numbers come from stored values (`LiftStrainSnapshot`), never recomputed here.

enum WorkoutLiftStrainNote: Equatable {
    /// The sets were counted: heart rate alone, and with the sets, both on the 0...21 display scale.
    case split(heartRate: Double, combined: Double)
    /// The sets were not counted (yet), or the lift is an import that only has totals.
    case state(State)

    enum State: Equatable {
        /// The session has no working sets logged.
        case noSets
        /// No heart rate scored the session, so the sets have nothing to add to.
        case notScored
        /// The sets are being scored, or the stored Strain is catching up with them.
        case scoring
        /// An imported (Hevy / Liftosaur) lift: totals only, heart rate only.
        case imported
    }

    /// nil when there is nothing to add to the plain heart-rate view: another sport, or no lift row for the session.
    static func make(sport: String, source: String, snapshot: LiftStrainSnapshot?) -> WorkoutLiftStrainNote? {
        if WorkoutSource.classify(source) == .lifting { return .state(.imported) }
        guard sport == StrengthStrainIntegration.sport, let snapshot else { return nil }
        switch snapshot.state {
        case .scored:
            guard let heartRate = snapshot.heartRateDisplay, let combined = snapshot.combinedDisplay else { return nil }
            return .split(heartRate: heartRate, combined: combined)
        case .noSets: return .state(.noSets)
        case .notScored: return .state(.notScored)
        case .pending: return .state(.scoring)
        }
    }

    /// The figures as the line prints them (one decimal) and what the sets add between those printed figures, so the
    /// spoken text always agrees with what is on screen.
    private func printed(_ heartRate: Double, _ combined: Double) -> (hr: Double, combined: Double, add: Double) {
        let hr = (heartRate * 10).rounded() / 10
        let both = (combined * 10).rounded() / 10
        return (hr, both, ((both - hr) * 10).rounded() / 10)
    }

    /// The "Heart rate only 10.0 → With your sets 15.1" line, nil for the states that only have a caption.
    var line: String? {
        guard case .split(let heartRate, let combined) = self else { return nil }
        let figures = printed(heartRate, combined)
        return StrainCopy.liftSplit(heartRate: DrillInFormat.number(figures.hr, fractionDigits: 1),
                                    combined: DrillInFormat.number(figures.combined, fractionDigits: 1))
    }

    /// The small line under it (or the only line, for a state).
    var caption: String {
        switch self {
        case .split: return StrainCopy.liftIncluded
        case .state(.noSets): return StrainCopy.liftNoSets
        case .state(.notScored): return StrainCopy.liftNotScored
        case .state(.scoring): return StrainCopy.liftScoring
        case .state(.imported): return StrainCopy.liftImported
        }
    }

    /// What VoiceOver reads for the whole note.
    var spoken: String {
        guard case .split(let heartRate, let combined) = self else { return caption }
        let figures = printed(heartRate, combined)
        return StrainCopy.liftSpoken(combined: DrillInFormat.number(figures.combined, fractionDigits: 1),
                                     heartRate: DrillInFormat.number(figures.hr, fractionDigits: 1),
                                     add: DrillInFormat.number(figures.add, fractionDigits: 1))
    }
}
