import XCTest
import WhoopProtocol
import StrandAnalytics
@testable import NOOP

final class WorkoutZoneTimelineTests: XCTestCase {
    func testGapIsNotCreditedAndStretchesAreSeparated() {
        let result = WorkoutZoneTimeline.make(samples: [
            HRSample(ts: 100, bpm: 120), HRSample(ts: 101, bpm: 120),
            HRSample(ts: 200, bpm: 180), HRSample(ts: 201, bpm: 180)
        ], start: 100, end: 202, maxHR: 200)
        XCTAssertEqual(result.minutes[1], 2.0 / 60, accuracy: 0.0001)
        XCTAssertEqual(result.minutes[4], 2.0 / 60, accuracy: 0.0001)
        XCTAssertEqual(result.unobservedSeconds, 98)
        XCTAssertEqual(result.intervals.count, 2)
    }

    func testDuplicateCorrectionInvalidReadingsAndEndClipping() {
        let result = WorkoutZoneTimeline.make(samples: [
            HRSample(ts: 99, bpm: 140), HRSample(ts: 100, bpm: 100),
            HRSample(ts: 100, bpm: 160), HRSample(ts: 101, bpm: 900),
            HRSample(ts: 102, bpm: 160), HRSample(ts: 103, bpm: 180)
        ], start: 100, end: 103, maxHR: 200)
        // The duplicate second keeps its last reading and the invalid one is dropped, so one stretch in zone 4 remains.
        XCTAssertEqual(result.intervals.map(\.zone), [4])
        XCTAssertEqual(result.intervals.map(\.start), [100])
        XCTAssertEqual(result.intervals.map(\.end), [103])
        XCTAssertEqual(result.minutes[3], 3.0 / 60, accuracy: 0.0001)
        XCTAssertEqual(result.minutes[4], 0)
    }

    func testLongWorkoutKeepsOneSecondPeakAsItsOwnStretchAndExactZoneTime() {
        let samples = (100..<10_100).map { HRSample(ts: $0, bpm: $0 == 5432 ? 200 : 120) }
        let result = WorkoutZoneTimeline.make(samples: samples, start: 100, end: 10_100, maxHR: 200)
        XCTAssertEqual(result.intervals.count, 3)
        XCTAssertEqual(result.minutes[4], 1.0 / 60, accuracy: 0.0001)
        XCTAssertEqual(result.unobservedSeconds, 0)
    }

    func testSpansMarkWhereAZoneFellInSecondsFromTheStart() {
        let samples = (100..<400).map { HRSample(ts: $0, bpm: ($0 >= 200 && $0 < 250) || $0 >= 350 ? 190 : 120) }
        let result = WorkoutZoneTimeline.make(samples: samples, start: 100, end: 400, maxHR: 200)
        XCTAssertEqual(result.spans(inZone: 5, from: 100), [100...150, 250...300])
        let easy = HRZones.zones(maxHR: 200).zoneNumber(forBPM: 120)
        XCTAssertEqual(result.spans(inZone: easy, from: 100), [0...100, 150...250])
        // A stretch is never narrower than a second, so a single reading is still something to draw.
        let single = WorkoutZoneTimeline.make(samples: [HRSample(ts: 100, bpm: 190)], start: 100, end: 101, maxHR: 200)
        XCTAssertEqual(single.spans(inZone: 5, from: 100), [0...1])
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
