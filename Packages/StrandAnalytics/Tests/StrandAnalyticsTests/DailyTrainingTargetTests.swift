import XCTest
@testable import StrandAnalytics

final class DailyTrainingTargetTests: XCTestCase {
    private let day = "2026-10-22"

    private func input(recovery: Double? = 80, sleep: Double? = 8, need: Double? = 8,
                       needDay: String? = "2026-10-22", strain: Double? = 10,
                       history: [DailyTrainingTargetEngine.Day]? = nil) -> DailyTrainingTargetEngine.Input {
        .init(day: day, recovery: recovery, sleptHours: sleep, sleepNeedHours: need,
              sleepNeedDay: needDay, currentStrainStored: strain,
              history: history ?? days(count: 42, load: 45))
    }

    private func days(count: Int, load: Double) -> [DailyTrainingTargetEngine.Day] {
        (1...count).reversed().map {
            .init(day: DailyTrainingTargetEngine.offsetDay(day, by: -$0)!,
                  strainStored: load, recovery: 75)
        }
    }

    func testTargetUsesCompletedHistoryAndReportsEvidence() throws {
        let result = DailyTrainingTargetEngine.evaluate(input())
        let target = try XCTUnwrap(result.target)
        XCTAssertEqual(target.observedDays, 14)
        XCTAssertEqual(target.usualStrainStored, 45)
        XCTAssertGreaterThan(target.upperStored, target.lowerStored)
        XCTAssertTrue((0...100).contains(target.lowerStored))
        XCTAssertTrue((0...100).contains(target.upperStored))
        XCTAssertEqual(target.progress, .below)
        XCTAssertEqual(result.load?.state, .established)
    }

    func testLowRecoveryAndShortSleepEachLowerTheRange() throws {
        let good = try XCTUnwrap(DailyTrainingTargetEngine.evaluate(input()).target)
        let low = try XCTUnwrap(DailyTrainingTargetEngine.evaluate(input(recovery: 20)).target)
        let short = try XCTUnwrap(DailyTrainingTargetEngine.evaluate(input(sleep: 5)).target)
        let both = try XCTUnwrap(DailyTrainingTargetEngine.evaluate(input(recovery: 20, sleep: 5)).target)
        XCTAssertLessThan(low.upperStored, good.upperStored)
        XCTAssertLessThan(short.upperStored, good.upperStored)
        XCTAssertLessThan(both.upperStored, low.upperStored)
        XCTAssertLessThan(both.upperStored, short.upperStored)
    }

    func testExtraSleepCannotIncreaseTheTargetPastAdequateSleep() {
        let good = DailyTrainingTargetEngine.evaluate(input()).target
        let extra = DailyTrainingTargetEngine.evaluate(input(sleep: 12)).target
        XCTAssertEqual(good?.lowerStored, extra?.lowerStored)
        XCTAssertEqual(good?.upperStored, extra?.upperStored)
    }

    func testRecoveryBandsMatchTheRoundedDashboardScore() {
        XCTAssertTrue(DailyTrainingTargetEngine.evaluate(input(recovery: 33.49)).target!.drivers.contains(.recoveryLow))
        XCTAssertTrue(DailyTrainingTargetEngine.evaluate(input(recovery: 33.5)).target!.drivers.contains(.recoveryModerate))
        XCTAssertTrue(DailyTrainingTargetEngine.evaluate(input(recovery: 66.5)).target!.drivers.contains(.recoveryHigh))
    }

    func testTodayAndFutureDoNotEnterHistoricalBaseline() {
        let baseline = DailyTrainingTargetEngine.evaluate(input())
        var history = days(count: 42, load: 45)
        history += [.init(day: day, strainStored: 99, recovery: 0),
                    .init(day: "2026-10-23", strainStored: 100, recovery: 100)]
        let result = DailyTrainingTargetEngine.evaluate(input(history: history))
        XCTAssertEqual(result, baseline)
    }

    func testMissingYesterdayStillBuildsATargetFromTheMeasuredDays() throws {
        let baseline = try XCTUnwrap(DailyTrainingTargetEngine.evaluate(input()).target)
        let missingYesterday = days(count: 42, load: 45).filter { $0.day != "2026-10-21" }
        let result = DailyTrainingTargetEngine.evaluate(input(history: missingYesterday))
        let target = try XCTUnwrap(result.target)
        // The usual day is a median of measured days; a missing day is never a zero.
        XCTAssertEqual(target.observedDays, 13)
        XCTAssertEqual(target.usualStrainStored, baseline.usualStrainStored)
        // The load model ends on the newest measured day instead of a day with no data.
        XCTAssertEqual(result.load?.endDay, "2026-10-20")
    }

    func testRecentGapLongerThanTheLoadModelToleratesPausesTheTarget() throws {
        let twoMissing = days(count: 42, load: 45).filter { !["2026-10-21", "2026-10-20"].contains($0.day) }
        XCTAssertNotNil(DailyTrainingTargetEngine.evaluate(input(history: twoMissing)).target)
        let threeMissing = days(count: 42, load: 45)
            .filter { !["2026-10-21", "2026-10-20", "2026-10-19"].contains($0.day) }
        XCTAssertEqual(DailyTrainingTargetEngine.evaluate(input(history: threeMissing)).unavailableReason,
                       .needsRecentHistory)
    }

    func testSparseRecentHistoryDoesNotInventTarget() {
        XCTAssertEqual(DailyTrainingTargetEngine.evaluate(input(history: days(count: 6, load: 45))).unavailableReason,
                       .needsRecentHistory)
        XCTAssertNotNil(DailyTrainingTargetEngine.evaluate(input(history: days(count: 7, load: 45))).target)
    }

    func testMeasuredZeroIsRealAndMissingIsNotZero() throws {
        let zero = try XCTUnwrap(DailyTrainingTargetEngine.evaluate(input(history: days(count: 14, load: 0))).target)
        XCTAssertEqual(zero.upperStored, 0)
        let missing = days(count: 14, load: 45).map {
            DailyTrainingTargetEngine.Day(day: $0.day, strainStored: nil, recovery: 75)
        }
        XCTAssertNil(DailyTrainingTargetEngine.evaluate(input(history: missing)).target)
    }

    func testMissingInputsHaveSpecificReasons() {
        XCTAssertEqual(DailyTrainingTargetEngine.evaluate(input(recovery: nil)).unavailableReason, .needsRecovery)
        XCTAssertEqual(DailyTrainingTargetEngine.evaluate(input(sleep: nil)).unavailableReason, .needsSleep)
        XCTAssertEqual(DailyTrainingTargetEngine.evaluate(input(need: nil)).unavailableReason, .needsSleepNeed)
        XCTAssertEqual(DailyTrainingTargetEngine.evaluate(input(needDay: nil)).unavailableReason, .needsSleepNeed)
    }

    func testNeedMustBeRecentAndCannotComeFromFuture() {
        XCTAssertNotNil(DailyTrainingTargetEngine.evaluate(input(needDay: "2026-10-16")).target)
        XCTAssertEqual(DailyTrainingTargetEngine.evaluate(input(needDay: "2026-10-15")).unavailableReason, .needsSleepNeed)
        XCTAssertEqual(DailyTrainingTargetEngine.evaluate(input(needDay: "2026-10-23")).unavailableReason, .needsSleepNeed)
    }

    func testNonfiniteAndOutOfRangeInputsAreRejected() {
        for invalid in [Double.nan, .infinity, -1, 101] {
            XCTAssertNil(DailyTrainingTargetEngine.evaluate(input(recovery: invalid)).target)
        }
        for invalid in [Double.nan, .infinity, -1, 25] {
            XCTAssertNil(DailyTrainingTargetEngine.evaluate(input(sleep: invalid)).target)
        }
        for invalid in [Double.nan, .infinity, 0, 25] {
            XCTAssertNil(DailyTrainingTargetEngine.evaluate(input(need: invalid)).target)
        }
        for invalid in [Double.nan, .infinity, -1, 101] {
            var history = days(count: 14, load: 45)
            history[0] = .init(day: history[0].day, strainStored: invalid, recovery: 75)
            XCTAssertEqual(DailyTrainingTargetEngine.evaluate(input(history: history)).unavailableReason, .invalidHistory)
        }
    }

    func testDuplicateDayIsRejected() {
        var history = days(count: 14, load: 45)
        history.append(history[0])
        XCTAssertEqual(DailyTrainingTargetEngine.evaluate(input(history: history)).unavailableReason, .invalidHistory)
    }

    func testUnknownProgressDoesNotBecomeZero() throws {
        let result = DailyTrainingTargetEngine.evaluate(input(strain: nil))
        XCTAssertEqual(result.target?.progress, .unknown)
        XCTAssertNil(DailyTrainingTargetEngine.preview(result, plannedTotalStored: 50, plannedSleepHours: 8))
    }

    func testAlreadyAboveTargetDoesNotRaiseTheTarget() throws {
        let normal = try XCTUnwrap(DailyTrainingTargetEngine.evaluate(input()).target)
        let above = try XCTUnwrap(DailyTrainingTargetEngine.evaluate(input(strain: 95)).target)
        XCTAssertEqual(above.upperStored, normal.upperStored)
        XCTAssertEqual(above.progress, .above)
    }

    func testPreviewUsesExistingLoadStepAndDoesNotAlterEvaluation() throws {
        let result = DailyTrainingTargetEngine.evaluate(input())
        let original = result
        let preview = try XCTUnwrap(DailyTrainingTargetEngine.preview(result, plannedTotalStored: 60, plannedSleepHours: 8))
        let expected = TrainingLoadEngine.step(acute: 45, chronic: 45, load: 60)
        XCTAssertEqual(try XCTUnwrap(preview.acuteLoad), expected.acute, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(preview.chronicLoad), expected.chronic, accuracy: 0.000_001)
        XCTAssertNotNil(preview.recovery)
        XCTAssertEqual(result, original)
    }

    func testPreviewCannotUndoRecordedStrainOrAcceptInvalidPlans() {
        let result = DailyTrainingTargetEngine.evaluate(input(strain: 65))
        for invalid in [Double.nan, .infinity, -1, 40, 101] {
            XCTAssertNil(DailyTrainingTargetEngine.preview(result, plannedTotalStored: invalid, plannedSleepHours: 8))
        }
        for invalid in [Double.nan, .infinity, 0, 25] {
            XCTAssertNil(DailyTrainingTargetEngine.preview(result, plannedTotalStored: 65, plannedSleepHours: invalid))
        }
    }

    func testPreviewKeepsLoadAndRecoveryMissingWhenEvidenceIsThin() throws {
        let history = days(count: 7, load: 45).map {
            DailyTrainingTargetEngine.Day(day: $0.day, strainStored: $0.strainStored, recovery: nil)
        }
        let result = DailyTrainingTargetEngine.evaluate(input(history: history))
        let preview = try XCTUnwrap(DailyTrainingTargetEngine.preview(result, plannedTotalStored: 50, plannedSleepHours: 8))
        XCTAssertNil(preview.acuteLoad)
        XCTAssertNil(preview.chronicLoad)
        XCTAssertNil(preview.recovery)
    }

    func testHigherRecentLoadLowersSameHistoricalMedianTarget() throws {
        var rising = days(count: 42, load: 20)
        for i in (rising.count - 6)..<rising.count {
            rising[i] = .init(day: rising[i].day, strainStored: 85, recovery: 75)
        }
        let flat = try XCTUnwrap(DailyTrainingTargetEngine.evaluate(input(history: days(count: 42, load: 20))).target)
        let high = try XCTUnwrap(DailyTrainingTargetEngine.evaluate(input(history: rising)).target)
        XCTAssertEqual(flat.usualStrainStored, high.usualStrainStored)
        XCTAssertLessThan(high.upperStored, flat.upperStored)
        XCTAssertTrue(high.drivers.contains(.recentLoadHigh))
    }

    func testCivilDayMathHandlesLeapDayAndDSTWithoutCompressingDates() {
        XCTAssertEqual(DailyTrainingTargetEngine.offsetDay("2024-03-01", by: -1), "2024-02-29")
        XCTAssertEqual(DailyTrainingTargetEngine.offsetDay("2026-03-09", by: -1), "2026-03-08")
        XCTAssertNil(DailyTrainingTargetEngine.offsetDay("2026-02-30", by: -1))
        XCTAssertNil(DailyTrainingTargetEngine.offsetDay("2026-2-03", by: -1))
    }
}
