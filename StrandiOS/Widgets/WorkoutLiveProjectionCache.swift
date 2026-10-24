#if os(iOS)
import Foundation
import StrandAnalytics
import StrandDesign
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

        let pauses = workout.pauseLedger
        if signature != nextSignature || accumulator == nil {
            rebuild(
                samples: workout.samples,
                signature: nextSignature,
                profile: userProfile,
                maxHR: Double(profile.hrMax),
                zoneSet: zoneSet,
                pauses: pauses
            )
        } else {
            appendNewSamplesOrRebuild(
                workout.samples,
                signature: nextSignature,
                profile: userProfile,
                maxHR: Double(profile.hrMax),
                zoneSet: zoneSet,
                pauses: pauses
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

        // The timer's anchor moves forward by the pauses already over, and a pause still open freezes it where it began:
        // the Lock Screen clock counts the time the workout ran, exactly as the app's own does.
        // Once a finish is pending the clock stops where the save will end the workout (`frozenAt`), so the pauses are
        // counted up to that moment, not to now.
        let now = workout.clockEnd(at: Date())
        let closedPause = pauses.pausedSeconds(
            from: workout.start.timeIntervalSince1970,
            to: pauses.openSince ?? now.timeIntervalSince1970)
        return WorkoutLiveActivityState(
            sport: workout.sport,
            startedAt: workout.start.addingTimeInterval(closedPause),
            pausedAt: pauses.openSince.map(Date.init(timeIntervalSince1970:)),
            strain: strain,
            strainBuilding: building,
            calories: projection.sampleCount >= 2 && projection.caloriesKcal > 0
                ? Int(projection.caloriesKcal.rounded()) : nil,
            hrTrace: projection.hrTrace,
            zoneSeconds: projection.zoneSeconds.map { Int($0.rounded()) },
            maxHR: Double(profile.hrMax),
            frozenAt: workout.frozenAt
        )
    }

    private func appendNewSamplesOrRebuild(
        _ samples: [HRSample],
        signature: Signature,
        profile: UserProfile,
        maxHR: Double,
        zoneSet: HRZoneSet,
        pauses: WorkoutPauseLedger
    ) {
        guard var accumulator, let snapshot else {
            rebuild(samples: samples, signature: signature, profile: profile, maxHR: maxHR, zoneSet: zoneSet,
                    pauses: pauses)
            return
        }
        guard samples.count >= snapshot.sampleCount else {
            rebuild(samples: samples, signature: signature, profile: profile, maxHR: maxHR, zoneSet: zoneSet,
                    pauses: pauses)
            return
        }
        if snapshot.sampleCount > 0 {
            let cachedTail = samples[snapshot.sampleCount - 1]
            guard cachedTail.ts == snapshot.lastTimestamp else {
                rebuild(samples: samples, signature: signature, profile: profile, maxHR: maxHR, zoneSet: zoneSet,
                        pauses: pauses)
                return
            }
            // ActiveWorkout may replace its canonical last reading within the same second. Only that
            // reading's representative second changes; the existing accumulator already corrects it
            // exactly and uses the corrected rate for the next interval, including after a pause.
            if cachedTail.bpm != snapshot.lastBPM,
               !accumulator.replaceCurrentSecond(with: cachedTail) {
                rebuild(samples: samples, signature: signature, profile: profile, maxHR: maxHR, zoneSet: zoneSet,
                        pauses: pauses)
                return
            }
        }
        var previousTs = snapshot.lastTimestamp
        for sample in samples.dropFirst(snapshot.sampleCount) {
            guard Self.append(sample, after: previousTs, to: &accumulator, pauses: pauses) else {
                rebuild(samples: samples, signature: signature, profile: profile, maxHR: maxHR, zoneSet: zoneSet,
                        pauses: pauses)
                return
            }
            previousTs = sample.ts
        }
        self.accumulator = accumulator
        self.snapshot = accumulator.snapshot()
    }

    /// The first reading after a pause starts a new stretch: nothing is credited across the pause before it.
    private static func append(
        _ sample: HRSample,
        after previousTs: Int?,
        to accumulator: inout WorkoutLiveProjectionAccumulator,
        pauses: WorkoutPauseLedger
    ) -> Bool {
        if let previousTs, pauses.separates(previousTs, sample.ts) {
            return accumulator.appendAfterPause(sample)
        }
        return accumulator.append(sample)
    }

    private func rebuild(
        samples: [HRSample],
        signature: Signature,
        profile: UserProfile,
        maxHR: Double,
        zoneSet: HRZoneSet,
        pauses: WorkoutPauseLedger
    ) {
        var rebuilt = WorkoutLiveProjectionAccumulator(
            profile: profile,
            hrmax: maxHR,
            restingHR: nil,
            zoneSet: zoneSet
        )
        var previousTs: Int?
        for sample in samples.sorted(by: { $0.ts < $1.ts }) {
            _ = Self.append(sample, after: previousTs, to: &rebuilt, pauses: pauses)
            previousTs = sample.ts
        }
        self.signature = signature
        accumulator = rebuilt
        snapshot = rebuilt.snapshot()
    }
}
#endif
