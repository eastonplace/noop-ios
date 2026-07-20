import XCTest
@testable import StrandAnalytics

final class SleepNeedV2Tests: XCTestCase {
    func testChronicRestrictionCannotLowerAutomaticBaseline() {
        let history = (0..<14).map { _ in
            SleepNeedV2.BaselineNight(totalSleepMinutes: 390,
                                      previousDayEffort: 20,
                                      efficiency: 0.92,
                                      debtBeforeNightMinutes: 0)
        }
        let estimate = SleepNeedV2.estimateBaseline(history: history)
        XCTAssertEqual(estimate.minutes, 480)
        XCTAssertEqual(estimate.source, .learnedUpward)
    }

    func testEligibleLowLoadHistoryCanRaiseBaseline() {
        let values = [480.0, 490, 500, 510, 520, 530, 540, 550]
        let history = values.map {
            SleepNeedV2.BaselineNight(totalSleepMinutes: $0,
                                      previousDayEffort: 25,
                                      efficiency: 0.90,
                                      debtBeforeNightMinutes: 0)
        }
        let estimate = SleepNeedV2.estimateBaseline(history: history)
        XCTAssertEqual(estimate.minutes, 532.5, accuracy: 0.001)
        XCTAssertEqual(estimate.source, .learnedUpward)
    }

    func testUserOverrideWinsAndClamps() {
        XCTAssertEqual(SleepNeedV2.estimateBaseline(history: [], userOverrideMinutes: 450).minutes, 450)
        XCTAssertEqual(SleepNeedV2.estimateBaseline(history: [], userOverrideMinutes: 900).minutes, 570)
    }

    func testStrainAdjustmentIsBoundedAndMonotonic() {
        let low = SleepNeedV2.strainAdjustment(previousDayEffort: 0)
        let mid = SleepNeedV2.strainAdjustment(previousDayEffort: 50)
        let high = SleepNeedV2.strainAdjustment(previousDayEffort: 100)
        XCTAssertEqual(low, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(mid, low)
        XCTAssertGreaterThan(high, mid)
        XCTAssertEqual(high, 60, accuracy: 1e-9)
    }

    func testNeedBreakdownAddsDebtAndSubtractsNap() {
        let baseline = SleepNeedV2.BaselineEstimate(minutes: 480,
                                                    source: .defaultPopulation,
                                                    eligibleNightCount: 0)
        let result = SleepNeedV2.calculate(.init(baseline: baseline,
                                                 previousDayEffort: 0,
                                                 sleepDebtMinutes: 120,
                                                 recentNapMinutes: 30))
        XCTAssertEqual(result.strainAdjustmentMinutes, 0, accuracy: 0.01)
        XCTAssertEqual(result.napCreditMinutes, 24, accuracy: 0.01)
        XCTAssertEqual(result.debtRepaymentMinutes, 30, accuracy: 0.01)
        XCTAssertEqual(result.totalMinutes, 486, accuracy: 0.01)
    }

    func testMeetingDynamicNeedRepaysScheduledDebt() {
        let baseline = SleepNeedV2.BaselineEstimate(minutes: 480,
                                                    source: .defaultPopulation,
                                                    eligibleNightCount: 0)
        let need = SleepNeedV2.calculate(.init(baseline: baseline,
                                               previousDayEffort: 0,
                                               sleepDebtMinutes: 120,
                                               recentNapMinutes: 0))
        XCTAssertEqual(need.totalMinutes, 510)
        let update = SleepNeedV2.updateDebt(previousBalanceMinutes: 120,
                                            need: need,
                                            mainSleepMinutes: 510)
        XCTAssertEqual(update.repaidMinutes, 30)
        XCTAssertEqual(update.newBalanceMinutes, 90)
    }

    func testShortSleepAddsOnlyCoreDeficit() {
        let baseline = SleepNeedV2.BaselineEstimate(minutes: 480,
                                                    source: .defaultPopulation,
                                                    eligibleNightCount: 0)
        let need = SleepNeedV2.calculate(.init(baseline: baseline,
                                               previousDayEffort: 0,
                                               sleepDebtMinutes: 120,
                                               recentNapMinutes: 0))
        let update = SleepNeedV2.updateDebt(previousBalanceMinutes: 120,
                                            need: need,
                                            mainSleepMinutes: 420)
        XCTAssertEqual(update.addedDeficitMinutes, 60)
        XCTAssertEqual(update.repaidMinutes, 0)
        XCTAssertEqual(update.newBalanceMinutes, 180)
    }

    func testMissingSleepHoldsDebt() {
        let baseline = SleepNeedV2.BaselineEstimate(minutes: 480,
                                                    source: .defaultPopulation,
                                                    eligibleNightCount: 0)
        let need = SleepNeedV2.calculate(.init(baseline: baseline,
                                               previousDayEffort: nil,
                                               sleepDebtMinutes: 120,
                                               recentNapMinutes: 0))
        let update = SleepNeedV2.updateDebt(previousBalanceMinutes: 120,
                                            need: need,
                                            mainSleepMinutes: nil)
        XCTAssertEqual(update.newBalanceMinutes, 120)
        XCTAssertEqual(update.reason, .heldMissingSleep)
    }
}
