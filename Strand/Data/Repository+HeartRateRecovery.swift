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
              HeartRateRecovery.plausibleMaxHeartRateRange.contains(maxHR)
        else { return nil }

        let (eligibilityFloor, lowerOverflow) = workout.endTs.subtractingReportingOverflow(
            HeartRateRecovery.eligibilityLookbackSeconds
        )
        let (readTo, upperOverflow) = workout.endTs.addingReportingOverflow(
            5 * 60 + HeartRateRecovery.measurementToleranceSeconds
        )
        guard !lowerOverflow, !upperOverflow, let store = await storeHandle() else { return nil }

        let readFrom = max(workout.startTs, eligibilityFloor)
        let hrDeviceId = Self.workoutHrDeviceId(
            source: workout.source,
            activeStrapId: deviceId
        )
        // The logical window is ~10 minutes. A 2,000-row cap could truncate the 5-minute recovery tail on
        // a multi-callback-per-second source because the store returns oldest first. Ten thousand remains
        // tightly bounded while covering >16 callbacks/s across the whole window; the pure engine then
        // canonicalizes to one deterministic sample per stored second.
        let samples = (try? await store.hrSamples(
            deviceId: hrDeviceId,
            from: readFrom,
            to: readTo,
            limit: 10_000
        )) ?? []

        return HeartRateRecovery.calculate(
            samples: samples,
            workoutStart: workout.startTs,
            workoutEnd: workout.endTs,
            maxHR: maxHR
        )
    }
}
