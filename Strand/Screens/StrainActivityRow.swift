import Foundation
import StrandAnalytics
import StrandDesign
import WhoopProtocol
import WhoopStore

// The day's workouts as rows of the Strain screen's Activities section. Pure and tested.

/// A workout of the day as a row: whose number the strain is, and what to say when there is none.
struct StrainActivityRow: Equatable, Identifiable {
    enum Score: Equatable {
        /// NOOP's own score, on the 0...21 display scale.
        case noop(Double)
        /// WHOOP's own number from an export, shown as theirs.
        case whoop(Double)
        case notScored
    }

    /// The workout row, for opening its detail.
    let workout: WorkoutRow
    let id: String
    let sport: String
    let startTs: Int
    let durationSeconds: Double
    let averageHR: Int?
    let score: Score

    init(_ workout: WorkoutRow) {
        self.workout = workout
        id = "\(workout.startTs)|\(workout.sport)|\(workout.source)"
        sport = workout.sport
        startTs = workout.startTs
        durationSeconds = workout.durationS ?? Double(workout.endTs - workout.startTs)
        averageHR = workout.avgHr
        if let shown = StrainResolver.workoutStrainForDisplay(workout) {
            let value = StrainScale.displayValue(fromStored: shown.storedValue)
            score = shown.provenance == .noop ? .noop(value) : .whoop(value)
        } else {
            score = .notScored
        }
    }

    /// Chronological, so the list reads in the order of the curve above it.
    static func rows(for workouts: [WorkoutRow]) -> [StrainActivityRow] {
        workouts.sorted { $0.startTs < $1.startTs }.map(StrainActivityRow.init)
    }
}

