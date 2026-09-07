import XCTest
import WhoopProtocol
@testable import NOOP

final class WorkoutZoneTimelineTests: XCTestCase {
    func testGapIsNotCreditedAndGraphSegmentsAreSeparated() {
        let result = WorkoutZoneTimeline.make(samples: [
            HRSample(ts: 100, bpm: 120), HRSample(ts: 101, bpm: 120),
            HRSample(ts: 200, bpm: 180), HRSample(ts: 201, bpm: 180)
        ], start: 100, end: 202, maxHR: 200)
        XCTAssertEqual(result.minutes[1], 2.0 / 60, accuracy: 0.0001)
        XCTAssertEqual(result.minutes[4], 2.0 / 60, accuracy: 0.0001)
        XCTAssertEqual(result.unobservedSeconds, 98)
        XCTAssertEqual(Set(result.points.map(\.segment)).count, 2)
        XCTAssertEqual(result.intervals.count, 2)
    }

    func testDuplicateCorrectionInvalidReadingsAndEndClipping() {
        let result = WorkoutZoneTimeline.make(samples: [
            HRSample(ts: 99, bpm: 140), HRSample(ts: 100, bpm: 100),
            HRSample(ts: 100, bpm: 160), HRSample(ts: 101, bpm: 900),
            HRSample(ts: 102, bpm: 160), HRSample(ts: 103, bpm: 180)
        ], start: 100, end: 103, maxHR: 200)
        XCTAssertEqual(result.points.map(\.bpm), [160, 160])
        XCTAssertEqual(result.minutes[3], 3.0 / 60, accuracy: 0.0001)
        XCTAssertEqual(result.minutes[4], 0)
    }

    func testLongWorkoutRetainsPeakWithBoundedCurveAndExactZoneTime() {
        let samples = (100..<10_100).map { HRSample(ts: $0, bpm: $0 == 5432 ? 200 : 120) }
        let result = WorkoutZoneTimeline.make(samples: samples, start: 100, end: 10_100, maxHR: 200)
        XCTAssertLessThanOrEqual(result.points.count, 1600)
        XCTAssertEqual(result.points.map(\.bpm).max(), 200)
        XCTAssertEqual(result.minutes[4], 1.0 / 60, accuracy: 0.0001)
        XCTAssertEqual(result.unobservedSeconds, 0)
    }

    func testBelowZoneOneIsKeptSeparate() {
        let result = WorkoutZoneTimeline.make(samples: [HRSample(ts: 100, bpm: 70)],
                                             start: 100, end: 110, maxHR: 200)
        XCTAssertEqual(result.belowZoneMinutes, 1.0 / 60, accuracy: 0.0001)
        XCTAssertEqual(result.minutes.reduce(0, +), 0)
        XCTAssertEqual(result.unobservedSeconds, 9)
    }
}

final class WorkoutRealtimeLeasePolicyTests: XCTestCase {
    func testRepeatedViewDismissalsCannotStopWorkoutLease() {
        var count = 3
        for _ in 0..<10 { count = WorkoutRealtimeLeasePolicy.remaining(afterRelease: count, workoutOwnsLease: true) }
        XCTAssertEqual(count, 1)
    }
    func testFinishingWorkoutReleasesFinalLease() {
        XCTAssertEqual(WorkoutRealtimeLeasePolicy.remaining(afterRelease: 1, workoutOwnsLease: false), 0)
        XCTAssertEqual(WorkoutRealtimeLeasePolicy.remaining(afterRelease: 2, workoutOwnsLease: false), 1)
        XCTAssertEqual(WorkoutRealtimeLeasePolicy.remaining(afterRelease: 0, workoutOwnsLease: false), 0)
    }
}

final class WorkoutLiveActivityVisibilityTests: XCTestCase {
    func testDisconnectedWorkoutRemainsVisibleButPassiveHRDoesNot() {
        XCTAssertTrue(WorkoutLiveActivityVisibility.shouldRemainVisible(enabled: true, connected: false, workoutIsActive: true))
        XCTAssertFalse(WorkoutLiveActivityVisibility.shouldRemainVisible(enabled: true, connected: false, workoutIsActive: false))
        XCTAssertFalse(WorkoutLiveActivityVisibility.shouldRemainVisible(enabled: false, connected: true, workoutIsActive: true))
    }
}
