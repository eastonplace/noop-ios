import Foundation
import StrandAnalytics
import WhoopStore

@MainActor
extension Repository {
    /// Derive post-workout heart-rate recovery from the narrow local HR window surrounding one session.
    ///
    /// The stored workout row remains unchanged: HRR is independent of NOOP iOS's authoritative Strain and
    /// Sleep models and needs no schema migration. Missing post-workout coverage returns nil rather than an
    /// interpolated value. Detected sessions read the raw strap namespace encoded in their computed source;
    /// other sessions use the active strap read path, matching the existing workout-detail trace behavior.
    func workoutHeartRateRecovery(
        for workout: WorkoutRow,
        maxHR: Double
    ) async -> HeartRateRecovery.Result? {
        guard workout.endTs > workout.startTs,
              maxHR.isFinite,
              maxHR > 0,
              let store = await storeHandle()
        else { return nil }

        let readFrom = max(
            workout.startTs,
            workout.endTs - HeartRateRecovery.eligibilityLookbackSeconds
        )
        let readTo = workout.endTs
            + 5 * 60
            + HeartRateRecovery.measurementToleranceSeconds
        let hrDeviceId = Self.workoutHrDeviceId(
            source: workout.source,
            activeStrapId: deviceId
        )
        let samples = (try? await store.hrSamples(
            deviceId: hrDeviceId,
            from: readFrom,
            to: readTo,
            limit: 2_000
        )) ?? []

        return HeartRateRecovery.calculate(
            samples: samples,
            workoutStart: workout.startTs,
            workoutEnd: workout.endTs,
            maxHR: maxHR
        )
    }
}
