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
            windowStart: start, windowEnd: end)).decision, .unavailable)
        XCTAssertEqual(SmartAlarmEvaluator.evaluate(.init(mode: .sleepGoal, now: start,
            windowStart: start, windowEnd: end, bankedSleepMinutes: 479,
            sleepNeedMinutes: 480)).decision, .wait)
        XCTAssertEqual(SmartAlarmEvaluator.evaluate(.init(mode: .sleepGoal, now: start,
            windowStart: start, windowEnd: end, bankedSleepMinutes: 480,
            sleepNeedMinutes: 480)).decision, .wakeNow)
    }

    func testGreenUsesConservativeForecastLowBound() {
        XCTAssertEqual(SmartAlarmEvaluator.evaluate(.init(mode: .inTheGreen, now: start,
            windowStart: start, windowEnd: end, recoveryForecastLow: 66.99)).decision, .wait)
        XCTAssertEqual(SmartAlarmEvaluator.evaluate(.init(mode: .inTheGreen, now: start,
            windowStart: start, windowEnd: end, recoveryForecastLow: 67)).decision, .wakeNow)
    }
}
