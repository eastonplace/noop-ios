import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class SleepAwareStepCounterTests: XCTestCase {
    private func sleep(_ start: Int = 0, _ end: Int = 100, stages: [StageSegment] = []) -> SleepSession {
        .init(start: start, end: end, efficiency: 1, stages: stages, restingHR: nil, avgHRV: nil)
    }
    private func steps(_ times: [Int]) -> [StepSample] {
        times.enumerated().map { .init(ts: $0.element, counter: 100 + $0.offset * 2, activityClass: 1) }
    }
    func testIsolatedSleepMotionIsExcluded() {
        XCTAssertNil(SleepAwareStepCounter.stepsInWindow(steps([0, 1, 20, 40]), sleepSessions: [sleep()]))
    }
    func testSustainedGaitInSleepIsRetained() {
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow(steps(Array(0...5)), sleepSessions: [sleep()]), 10)
    }
    func testSeparateShortBoutsDoNotAccumulateIntoWalking() {
        XCTAssertNil(SleepAwareStepCounter.stepsInWindow(steps([0, 1, 2, 10, 11, 12]), sleepSessions: [sleep()]))
    }
    func testAwakeSleepStageCountsWithoutBoutThreshold() {
        let stages = [StageSegment(start: 0, end: 10, stage: "wake")]
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow(steps([0, 1]), sleepSessions: [sleep(stages: stages)]), 2)
    }
    func testOverlappingUnstagedSessionCannotMaskExplicitWake() {
        let broad = sleep(0, 100)
        let awake = sleep(10, 50, stages: [StageSegment(start: 10, end: 30, stage: "awake")])
        let rows = steps([10, 11])
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow(rows, sleepSessions: [broad, awake]), 2)
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow(rows, sleepSessions: [awake, broad]), 2)
    }
    func testWakeInAnOverlappingSessionRemainsHalfOpen() {
        let broad = sleep(0, 100)
        let awake = sleep(10, 50, stages: [StageSegment(start: 10, end: 20, stage: "wake")])
        XCTAssertNil(SleepAwareStepCounter.stepsInWindow(steps([19, 20]), sleepSessions: [broad, awake]))
    }
    func testSleepContextWitnessTracksBoundsAndWakeSpansIndependentlyOfInputOrder() {
        let broad = sleep(0, 100)
        let awake = sleep(10, 50, stages: [StageSegment(start: 10, end: 30, stage: "wake")])
        let fingerprint = SleepAwareStepCounter.sleepContextFingerprint([broad, awake])
        XCTAssertEqual(fingerprint, SleepAwareStepCounter.sleepContextFingerprint([awake, broad]))
        XCTAssertNotEqual(fingerprint, SleepAwareStepCounter.sleepContextFingerprint([broad]))
        XCTAssertNotEqual(fingerprint, SleepAwareStepCounter.sleepContextFingerprint([
            broad, sleep(10, 50, stages: [StageSegment(start: 10, end: 31, stage: "wake")])]))
    }
    func testSleepEndIsExclusive() {
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow(steps([98, 99, 100, 101]), sleepSessions: [sleep()]), 4)
    }
    func testCounterConflictCannotJoinSleepBouts() {
        var rows = steps(Array(0...6))
        rows.append(.init(ts: 3, counter: 999, activityClass: 1))
        XCTAssertNil(SleepAwareStepCounter.stepsInWindow(rows, sleepSessions: [sleep()]))
    }
    func testAdjacentSleepSessionsCannotJoinShortBouts() {
        XCTAssertNil(SleepAwareStepCounter.stepsInWindow(steps(Array(0...6)), sleepSessions: [sleep(0, 4), sleep(4, 10)]))
    }
    func testNoSleepUsesTheSameClassAndRateRules() {
        let rows = [StepSample(ts: 0, counter: 100, activityClass: 0),
                    StepSample(ts: 1, counter: 130, activityClass: 1),
                    StepSample(ts: 2, counter: 132, activityClass: 1)]
        XCTAssertEqual(SleepAwareStepCounter.stepsInWindow(rows, sleepSessions: []), 2)
    }
}
