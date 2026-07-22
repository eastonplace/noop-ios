#if os(iOS)
import Foundation
import StrandAnalytics
import WhoopProtocol

/// Reference-owned cache for the expensive Live Activity workout projection. It incrementally consumes only
/// newly appended samples; the authoritative `AppModel.ActiveWorkout` and final save calculations are unchanged.
@MainActor
final class WorkoutLiveProjectionCache {
    private struct Signature: Equatable {
        let start: Date
        let sport: String
        let weightKg: Double
        let heightCm: Double
        let age: Int
        let sex: String
        let maxHR: Int
    }

    private var signature: Signature?
    private var accumulator: WorkoutLiveProjectionAccumulator?
    private var snapshot: WorkoutLiveProjectionAccumulator.Snapshot?

    func reset() {
        signature = nil
        accumulator = nil
        snapshot = nil
    }

    func state(workout: AppModel.ActiveWorkout, profile: ProfileStore) -> WorkoutLiveActivityState {
        let nextSignature = Signature(
            start: workout.start,
            sport: workout.sport,
            weightKg: profile.weightKg,
            heightCm: profile.heightCm,
            age: profile.age,
            sex: profile.sex,
            maxHR: profile.hrMax
        )
        let userProfile = UserProfile(
            weightKg: profile.weightKg,
            heightCm: profile.heightCm,
            age: Double(profile.age),
            sex: profile.sex
        )
        let zoneSet = HRZones.zones(maxHR: Double(profile.hrMax), source: "profile")

        if signature != nextSignature || accumulator == nil {
            rebuild(
                samples: workout.samples,
                signature: nextSignature,
                profile: userProfile,
                maxHR: Double(profile.hrMax),
                zoneSet: zoneSet
            )
        } else {
            appendNewSamplesOrRebuild(
                workout.samples,
                signature: nextSignature,
                profile: userProfile,
                maxHR: Double(profile.hrMax),
                zoneSet: zoneSet
            )
        }

        let projection = snapshot ?? WorkoutLiveProjectionAccumulator(
            profile: userProfile,
            hrmax: Double(profile.hrMax),
            restingHR: nil,
            zoneSet: zoneSet
        ).snapshot()

        let strain: Double?
        let building: Bool
        switch workout.liveStrainState {
        case .building:
            strain = nil
            building = true
        case .scored(let storedValue):
            strain = StrainScale.displayValue(fromStored: storedValue)
            building = false
        }

        return WorkoutLiveActivityState(
            sport: workout.sport,
            startedAt: workout.start,
            strain: strain,
            strainBuilding: building,
            calories: projection.sampleCount >= 2 && projection.caloriesKcal > 0
                ? Int(projection.caloriesKcal.rounded()) : nil,
            hrTrace: projection.hrTrace,
            zoneSeconds: projection.zoneSeconds.map { Int($0.rounded()) }
        )
    }

    private func appendNewSamplesOrRebuild(
        _ samples: [HRSample],
        signature: Signature,
        profile: UserProfile,
        maxHR: Double,
        zoneSet: HRZoneSet
    ) {
        guard var accumulator, let snapshot else {
            rebuild(samples: samples, signature: signature, profile: profile, maxHR: maxHR, zoneSet: zoneSet)
            return
        }
        guard samples.count >= snapshot.sampleCount else {
            rebuild(samples: samples, signature: signature, profile: profile, maxHR: maxHR, zoneSet: zoneSet)
            return
        }
        if snapshot.sampleCount > 0,
            samples[snapshot.sampleCount - 1].ts != snapshot.lastTimestamp
        {
            rebuild(samples: samples, signature: signature, profile: profile, maxHR: maxHR, zoneSet: zoneSet)
            return
        }
        for sample in samples.dropFirst(snapshot.sampleCount) {
            guard accumulator.append(sample) else {
                rebuild(samples: samples, signature: signature, profile: profile, maxHR: maxHR, zoneSet: zoneSet)
                return
            }
        }
        self.accumulator = accumulator
        self.snapshot = accumulator.snapshot()
    }

    private func rebuild(
        samples: [HRSample],
        signature: Signature,
        profile: UserProfile,
        maxHR: Double,
        zoneSet: HRZoneSet
    ) {
        let rebuilt = WorkoutLiveProjectionAccumulator(
            samples: samples,
            profile: profile,
            hrmax: maxHR,
            restingHR: nil,
            zoneSet: zoneSet
        )
        self.signature = signature
        accumulator = rebuilt
        snapshot = rebuilt.snapshot()
    }
}
#endif
