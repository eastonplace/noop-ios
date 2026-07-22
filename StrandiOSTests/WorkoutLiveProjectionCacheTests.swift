import XCTest
import WhoopProtocol
@testable import NOOP

#if os(iOS)
@MainActor
final class WorkoutLiveProjectionCacheTests: XCTestCase {
    func testSameTimestampTailCorrectionForcesAuthoritativeRebuild() {
        let profile = ProfileStore()
        profile.hrMaxOverride = 190
        var workout = AppModel.ActiveWorkout(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            sport: "Running",
            maxHR: 190
        )
        workout.samples = [
            HRSample(ts: 1_700_000_000, bpm: 100),
            HRSample(ts: 1_700_000_001, bpm: 110),
        ]

        let cache = WorkoutLiveProjectionCache()
        XCTAssertEqual(cache.state(workout: workout, profile: profile).hrTrace, [100, 110])

        workout.samples[1] = HRSample(ts: 1_700_000_001, bpm: 150)
        XCTAssertEqual(cache.state(workout: workout, profile: profile).hrTrace, [100, 150])
    }
}
#endif
