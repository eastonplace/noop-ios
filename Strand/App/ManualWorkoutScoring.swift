import Foundation
import StrandAnalytics
import WhoopProtocol

/// What Finish saves for a live-tracked workout, worked out from its active heart-rate readings and its pauses.
///
/// A workout that was never paused takes exactly the single-stretch path it always did. One that was paused is scored
/// stretch by stretch, so a pause is never credited as time at the last reading's rate, and its duration is the time it
/// actually ran.
enum ManualWorkoutScoring {
    struct Result: Equatable {
        let strain: Double?
        let kcal: Double
        let durationS: Double
    }

    static func score(
        samples: [HRSample],
        pauses: WorkoutPauseLedger,
        start: Date,
        end: Date,
        maxHR: Double,
        profile: UserProfile
    ) -> Result {
        let wallClock = end.timeIntervalSince(start)
        guard samples.count >= 2 else {
            return Result(strain: nil, kcal: 0,
                          durationS: pauses.hasPauses
                              ? pauses.activeSeconds(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970)
                              : wallClock)
        }
        guard pauses.hasPauses else {
            return Result(
                strain: StrainScorerV2.strain(samples, maxHR: maxHR, mode: .activity),
                kcal: Calories.estimateBoutCalories(samples, profile: profile, hrmax: maxHR, restingHR: nil).0,
                durationS: wallClock)
        }
        let stretches = pauses.segments(of: samples)
        return Result(
            strain: StrainScorerV2.activityStrain(segments: stretches, maxHR: maxHR),
            kcal: Calories.estimateBoutCalories(segments: stretches, profile: profile, hrmax: maxHR, restingHR: nil).0,
            durationS: pauses.activeSeconds(from: start.timeIntervalSince1970, to: end.timeIntervalSince1970))
    }
}
