import XCTest
import WhoopProtocol
import StrandAnalytics
@testable import NOOP

#if os(iOS)
@MainActor
final class WorkoutLiveProjectionCacheTests: XCTestCase {
    func testActiveWorkoutSampleBufferIsReferenceOwned() {
        let session = AppModel.ActiveWorkout(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            sport: "Running",
            maxHR: 190
        )
        let retained = session
        XCTAssertTrue(session.ingest(HRSample(ts: 1_700_000_000, bpm: 120)))

        XCTAssertTrue(session === retained)
        XCTAssertEqual(retained.samples, [HRSample(ts: 1_700_000_000, bpm: 120)])
    }

    func testSameTimestampTailCorrectionPreservesCanonicalProjection() {
        let profile = ProfileStore()
        // ProfileStore writes UserDefaults.standard, which the app host shares with the simulator's app: put the
        // override back, or every screen that reads the personal maximum shows 190 afterwards.
        let original = profile.hrMaxOverride
        defer { profile.hrMaxOverride = original }
        profile.hrMaxOverride = 190
        let workout = AppModel.ActiveWorkout(
            start: Date(timeIntervalSince1970: 1_700_000_000),
            sport: "Running",
            maxHR: 190
        )
        workout.restore(samples: [
            HRSample(ts: 1_700_000_000, bpm: 100),
            HRSample(ts: 1_700_000_001, bpm: 110),
        ])

        let cache = WorkoutLiveProjectionCache()
        XCTAssertEqual(cache.state(workout: workout, profile: profile).hrTrace, [100, 110])

        XCTAssertTrue(workout.ingest(HRSample(ts: 1_700_000_001, bpm: 150)))
        XCTAssertEqual(cache.state(workout: workout, profile: profile).hrTrace, [100, 150])
    }

    func testRepeatedTailCorrectionsAndAppendsMatchFreshProjectionAcrossPause() {
        let profile = ProfileStore()
        let original = profile.hrMaxOverride
        defer { profile.hrMaxOverride = original }
        profile.hrMaxOverride = 190
        let start = 1_700_000_000
        let workout = AppModel.ActiveWorkout(
            start: Date(timeIntervalSince1970: Double(start)), sport: "Running", maxHR: 190)
        let pauses = WorkoutPauseLedger(intervals: [.init(start: Double(start + 1), end: Double(start + 180))])
        workout.restore(samples: [
            HRSample(ts: start, bpm: 100),
            HRSample(ts: start + 1, bpm: 110),
            HRSample(ts: start + 180, bpm: 120),
        ], pauses: pauses)
        let cache = WorkoutLiveProjectionCache()
        _ = cache.state(workout: workout, profile: profile)

        for index in 0..<40 {
            let timestamp = start + 180 + index * 10
            XCTAssertTrue(workout.ingest(HRSample(ts: timestamp, bpm: index.isMultiple(of: 2) ? 80 : 180)))
            // Exercise correction by itself and correction followed by a new interval.
            assertMatchesFreshProjection(cache, workout: workout, profile: profile)
            for offset in 1...10 {
                XCTAssertTrue(workout.ingest(HRSample(ts: timestamp + offset, bpm: 100 + index)))
            }
            assertMatchesFreshProjection(cache, workout: workout, profile: profile)
        }
    }

    func testTailCorrectionBeforeAppendAndRebuildFallbacksPreserveProjection() {
        let profile = ProfileStore()
        let original = profile.hrMaxOverride
        defer { profile.hrMaxOverride = original }
        profile.hrMaxOverride = 190
        let start = 1_700_000_000
        let workout = AppModel.ActiveWorkout(
            start: Date(timeIntervalSince1970: Double(start)), sport: "Cycling", maxHR: 190)
        workout.restore(samples: (0..<3_600).map { HRSample(ts: start + $0, bpm: 100 + $0 % 80) })
        let cache = WorkoutLiveProjectionCache()
        _ = cache.state(workout: workout, profile: profile)
        XCTAssertTrue(workout.ingest(HRSample(ts: start + 3_599, bpm: 90)))
        XCTAssertTrue(workout.ingest(HRSample(ts: start + 3_610, bpm: 150)))
        assertMatchesFreshProjection(cache, workout: workout, profile: profile)

        // A changed profile, shortened restore, or replaced timestamp still requires a full replay.
        profile.hrMaxOverride = 175
        assertMatchesFreshProjection(cache, workout: workout, profile: profile)
        workout.restore(samples: [HRSample(ts: start, bpm: 80), HRSample(ts: start + 10, bpm: 180)])
        assertMatchesFreshProjection(cache, workout: workout, profile: profile)
        workout.restore(samples: [HRSample(ts: start, bpm: 80), HRSample(ts: start + 30, bpm: 130)])
        assertMatchesFreshProjection(cache, workout: workout, profile: profile)
        workout.restore(samples: [])
        assertMatchesFreshProjection(cache, workout: workout, profile: profile)
    }

    private func assertMatchesFreshProjection(
        _ cache: WorkoutLiveProjectionCache,
        workout: AppModel.ActiveWorkout,
        profile: ProfileStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = cache.state(workout: workout, profile: profile)
        let expected = WorkoutLiveProjectionCache().state(workout: workout, profile: profile)
        XCTAssertEqual(actual.calories, expected.calories, file: file, line: line)
        XCTAssertEqual(actual.zoneSeconds, expected.zoneSeconds, file: file, line: line)
        XCTAssertEqual(actual.hrTrace, expected.hrTrace, file: file, line: line)
        XCTAssertEqual(actual.startedAt, expected.startedAt, file: file, line: line)
        XCTAssertEqual(actual.pausedAt, expected.pausedAt, file: file, line: line)
    }
}
#endif
