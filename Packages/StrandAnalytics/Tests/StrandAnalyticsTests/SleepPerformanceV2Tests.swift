import XCTest
@testable import StrandAnalytics

final class SleepPerformanceV2Tests: XCTestCase {
    private func need(_ minutes: Double) -> SleepNeedV2.Breakdown {
        SleepNeedV2.Breakdown(baselineMinutes: minutes,
                              baselineSource: .defaultPopulation,
                              strainAdjustmentMinutes: 0,
                              napCreditMinutes: 0,
                              coreRequirementMinutes: minutes,
                              debtRepaymentMinutes: 0,
                              totalMinutes: minutes,
                              debtBalanceBeforeNightMinutes: 0)
    }

    func testPerfectFullyCoveredNightScoresOneHundred() throws {
        let result = try XCTUnwrap(SleepPerformanceV2.score(.init(mainSleepMinutes: 480,
                                                                  need: need(480),
                                                                  efficiency: 1,
                                                                  consistency: 1,
                                                                  lowStressQuality: 1)))
        XCTAssertEqual(result.score, 100)
        XCTAssertEqual(result.confidence, .solid)
        XCTAssertEqual(result.recoveryInput, 1)
    }

    func testShortSleepCannotBeHiddenByStrongSecondarySignals() throws {
        let result = try XCTUnwrap(SleepPerformanceV2.score(.init(mainSleepMinutes: 360,
                                                                  need: need(510),
                                                                  efficiency: 0.95,
                                                                  consistency: 0.90,
                                                                  lowStressQuality: 0.90)))
        XCTAssertLessThan(result.score, 80)
        XCTAssertEqual(result.components.sufficiency, 0.7059, accuracy: 0.0001)
    }

    func testHigherNeedLowersOtherwiseIdenticalScore() throws {
        let lowerNeed = try XCTUnwrap(SleepPerformanceV2.score(.init(mainSleepMinutes: 450,
                                                                     need: need(480),
                                                                     efficiency: 0.92,
                                                                     consistency: 0.90,
                                                                     lowStressQuality: 0.90)))
        let higherNeed = try XCTUnwrap(SleepPerformanceV2.score(.init(mainSleepMinutes: 450,
                                                                      need: need(540),
                                                                      efficiency: 0.92,
                                                                      consistency: 0.90,
                                                                      lowStressQuality: 0.90)))
        XCTAssertGreaterThan(lowerNeed.score, higherNeed.score)
    }

    func testMissingComponentGetsNoNeutralCreditAndCapsCoverage() throws {
        let oneMissing = try XCTUnwrap(SleepPerformanceV2.score(.init(mainSleepMinutes: 480,
                                                                      need: need(480),
                                                                      efficiency: 1,
                                                                      consistency: nil,
                                                                      lowStressQuality: 1)))
        XCTAssertEqual(oneMissing.score, 90)
        XCTAssertEqual(oneMissing.inputCoverage, 0.9)
        XCTAssertEqual(oneMissing.confidence, .building)

        let bothMissing = try XCTUnwrap(SleepPerformanceV2.score(.init(mainSleepMinutes: 480,
                                                                       need: need(480),
                                                                       efficiency: 1,
                                                                       consistency: nil,
                                                                       lowStressQuality: nil)))
        XCTAssertEqual(bothMissing.score, 80)
        XCTAssertEqual(bothMissing.inputCoverage, 0.8)
        XCTAssertEqual(bothMissing.confidence, .calibrating)
    }

    func testEfficiencyIsRequired() {
        XCTAssertNil(SleepPerformanceV2.score(.init(mainSleepMinutes: 480,
                                                     need: need(480),
                                                     efficiency: nil,
                                                     consistency: 1,
                                                     lowStressQuality: 1)))
    }

    func testConsistencyUsesCircularClockMath() throws {
        let prior = [
            SleepPerformanceV2.SleepTiming(onsetMinute: 1430, wakeMinute: 420),
            SleepPerformanceV2.SleepTiming(onsetMinute: 0, wakeMinute: 425),
            SleepPerformanceV2.SleepTiming(onsetMinute: 10, wakeMinute: 430),
            SleepPerformanceV2.SleepTiming(onsetMinute: 5, wakeMinute: 435),
        ]
        let score = try XCTUnwrap(SleepPerformanceV2.consistency(
            current: .init(onsetMinute: 1435, wakeMinute: 428),
            priorNights: prior))
        XCTAssertGreaterThan(score, 0.95)
    }

    func testConsistencyRequiresFourPriorNights() {
        let prior = Array(repeating: SleepPerformanceV2.SleepTiming(onsetMinute: 1380,
                                                                    wakeMinute: 420),
                          count: 3)
        XCTAssertNil(SleepPerformanceV2.consistency(current: .init(onsetMinute: 1380,
                                                                    wakeMinute: 420),
                                                     priorNights: prior))
    }
}
