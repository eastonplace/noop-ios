import XCTest
@testable import StrandAnalytics

final class SmartAlarmEvaluatorTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let end = Date(timeIntervalSince1970: 2_800)

    func testNeverWakesBeforeWindowOrAfterEndpoint() {
        let before = SmartAlarmEvaluator.evaluate(.init(mode: .sleepGoal,
            now: Date(timeIntervalSince1970: 999), windowStart: start, windowEnd: end,
            bankedSleepMinutes: 500, sleepNeedMinutes: 400))
        XCTAssertEqual(before.decision, .wait)
        let endpoint = SmartAlarmEvaluator.evaluate(.init(mode: .inTheGreen,
            now: end, windowStart: start, windowEnd: end, recoveryForecastLow: 100))
        XCTAssertEqual(endpoint.decision, .endpoint)
    }

    func testSleepGoalRequiresRealCanonicalInputs() {
        XCTAssertEqual(SmartAlarmEvaluator.evaluate(.init(mode: .sleepGoal, now: start,
            windowStart: start, windowEnd: end, inputObservedAt: start)).decision, .unavailable)
        XCTAssertEqual(SmartAlarmEvaluator.evaluate(.init(mode: .sleepGoal, now: start,
            windowStart: start, windowEnd: end, bankedSleepMinutes: 479,
            sleepNeedMinutes: 480, inputObservedAt: start)).decision, .wait)
        XCTAssertEqual(SmartAlarmEvaluator.evaluate(.init(mode: .sleepGoal, now: start,
            windowStart: start, windowEnd: end, bankedSleepMinutes: 480,
            sleepNeedMinutes: 480, inputObservedAt: start)).decision, .wakeNow)
    }

    func testGreenUsesConservativeForecastLowBound() {
        XCTAssertEqual(SmartAlarmEvaluator.evaluate(.init(mode: .inTheGreen, now: start,
            windowStart: start, windowEnd: end, recoveryForecastLow: 66.99,
            inputObservedAt: start)).decision, .wait)
        XCTAssertEqual(SmartAlarmEvaluator.evaluate(.init(mode: .inTheGreen, now: start,
            windowStart: start, windowEnd: end, recoveryForecastLow: 67,
            inputObservedAt: start)).decision, .wakeNow)
    }

    func testAdaptiveModesRefuseMissingOrStaleObservations() {
        // No observation timestamp at all: satisfied inputs still cannot wake.
        let missing = SmartAlarmEvaluator.evaluate(.init(mode: .sleepGoal, now: start,
            windowStart: start, windowEnd: end, bankedSleepMinutes: 500, sleepNeedMinutes: 400))
        XCTAssertEqual(missing.decision, .unavailable)
        XCTAssertEqual(missing.reason, "missingLiveObservation")
        // Observation older than the freshness ceiling: same refusal, named as staleness.
        let staleBy = SmartAlarmEvaluator.maximumInputAgeSeconds + 1
        let stale = SmartAlarmEvaluator.evaluate(.init(mode: .inTheGreen, now: start,
            windowStart: start, windowEnd: end, recoveryForecastLow: 100,
            inputObservedAt: start.addingTimeInterval(-staleBy)))
        XCTAssertEqual(stale.decision, .unavailable)
        XCTAssertEqual(stale.reason, "staleLiveObservation")
        // Exactly at the ceiling is still fresh.
        let boundary = SmartAlarmEvaluator.evaluate(.init(mode: .inTheGreen, now: start,
            windowStart: start, windowEnd: end, recoveryForecastLow: 100,
            inputObservedAt: start.addingTimeInterval(-SmartAlarmEvaluator.maximumInputAgeSeconds)))
        XCTAssertEqual(boundary.decision, .wakeNow)
        // Exact time never needs a live observation: the endpoint is the contract.
        let exact = SmartAlarmEvaluator.evaluate(.init(mode: .exactTime, now: start,
            windowStart: start, windowEnd: end))
        XCTAssertEqual(exact.decision, .wait)
    }

    func testActuationPlanGatesOnDecisionAndLink() {
        let wake = SmartAlarmEvaluator.evaluate(.init(mode: .sleepGoal, now: start,
            windowStart: start, windowEnd: end, bankedSleepMinutes: 500, sleepNeedMinutes: 400,
            inputObservedAt: start))
        XCTAssertEqual(wake.decision, .wakeNow)
        XCTAssertEqual(SmartAlarmEvaluator.actuationPlan(for: wake, linkReady: true,
                                                         context: .foreground), .rearmEarlier)
        XCTAssertEqual(SmartAlarmEvaluator.actuationPlan(for: wake, linkReady: false,
                                                         context: .backgroundBestEffort), .queueForReconnect)
        let wait = SmartAlarmEvaluator.evaluate(.init(mode: .sleepGoal, now: start,
            windowStart: start, windowEnd: end, bankedSleepMinutes: 100, sleepNeedMinutes: 400,
            inputObservedAt: start))
        XCTAssertEqual(SmartAlarmEvaluator.actuationPlan(for: wait, linkReady: true,
                                                         context: .foreground), .none)
    }
}
