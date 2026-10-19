import Foundation
import XCTest
@testable import StrandAnalytics

final class TrainingLoadEngineTests: XCTestCase {
    func testConstantLoadConvergesExactlyToLoadAndZeroBalance() {
        let result = TrainingLoadEngine.evaluateDense(Array(repeating: 50, count: 42))
        XCTAssertEqual(result.state, .established)
        XCTAssertNil(result.unavailableReason)
        XCTAssertEqual(result.contiguousDays, 42)
        XCTAssertEqual(result.points.count, 36)
        XCTAssertEqual(result.ctl!, 50, accuracy: 1e-12)
        XCTAssertEqual(result.atl!, 50, accuracy: 1e-12)
        XCTAssertEqual(result.tsb!, 0, accuracy: 1e-12)
    }

    func testStepUpRaisesAcuteLoadFasterThanChronicLoad() {
        let loads = Array(repeating: 50.0, count: 7) + Array(repeating: 100.0, count: 7)
        let result = TrainingLoadEngine.evaluateDense(loads)

        XCTAssertEqual(result.state, .building)
        XCTAssertEqual(result.contiguousDays, 14)
        XCTAssertEqual(result.ctl!, 57.67591375546929, accuracy: 1e-10)
        XCTAssertEqual(result.atl!, 81.6060279414279, accuracy: 1e-10)
        XCTAssertEqual(result.tsb!, -23.930114185958608, accuracy: 1e-10)
        XCTAssertGreaterThan(result.atl!, result.ctl!)
        XCTAssertLessThan(result.tsb!, 0)
    }

    func testStepDownProducesPositiveBalanceAsAcuteLoadFallsFaster() {
        let loads = Array(repeating: 100.0, count: 7) + Array(repeating: 20.0, count: 14)
        let result = TrainingLoadEngine.evaluateDense(loads)
        XCTAssertEqual(result.state, .building)
        XCTAssertGreaterThan(result.ctl!, result.atl!)
        XCTAssertGreaterThan(result.tsb!, 0)
    }

    func testMinimumAndEstablishedHistoryBoundariesAreExplicit() {
        let thirteen = TrainingLoadEngine.evaluateDense(Array(repeating: 40, count: 13))
        XCTAssertEqual(thirteen.state, .unavailable)
        XCTAssertEqual(thirteen.unavailableReason, .notEnoughContiguousDays)
        XCTAssertEqual(thirteen.contiguousDays, 13)
        XCTAssertTrue(thirteen.points.isEmpty)

        let fourteen = TrainingLoadEngine.evaluateDense(Array(repeating: 40, count: 14))
        XCTAssertEqual(fourteen.state, .building)
        XCTAssertEqual(fourteen.contiguousDays, 14)

        let fortyTwo = TrainingLoadEngine.evaluateDense(Array(repeating: 40, count: 42))
        XCTAssertEqual(fortyTwo.state, .established)
    }

    func testRealZeroLoadDayIsObservedRatherThanTreatedAsMissing() {
        var loads = Array(repeating: 50.0, count: 13)
        loads.append(0)
        let result = TrainingLoadEngine.evaluateDense(loads)
        XCTAssertTrue(result.isAvailable)
        XCTAssertEqual(result.contiguousDays, 14)
        XCTAssertEqual(result.points.last?.load, 0)
        XCTAssertLessThan(result.atl!, 50)
    }

    // MARK: - AN-13: short gaps decay with zero load instead of resetting the model

    /// One day off-wrist (a nil load) no longer wipes CTL/ATL/TSB: the day steps with zero load, emits no
    /// point (it is not a measured rest day) and lowers coverage.
    func testOneMissingLoadDecaysWithZeroInsteadOfResetting() throws {
        var days: [TrainingLoadEngine.DailyLoad] = []
        for day in 1...20 {
            days.append(.init(day: String(format: "2026-07-%02d", day), load: day == 12 ? nil : 50))
        }
        let result = TrainingLoadEngine.evaluate(days: days)
        XCTAssertEqual(result.state, .building)
        XCTAssertNil(result.unavailableReason)
        XCTAssertEqual(result.contiguousDays, 19)
        XCTAssertEqual(result.spanDays, 20)
        XCTAssertEqual(try XCTUnwrap(result.coverage), 0.95, accuracy: 1e-12)
        XCTAssertEqual(result.startDay, "2026-07-01")
        XCTAssertEqual(result.endDay, "2026-07-20")
        XCTAssertFalse(result.points.contains { $0.day == "2026-07-12" })

        // The state equals a model that saw a zero on that day.
        var dense = Array(repeating: 50.0, count: 20)
        dense[11] = 0
        let zeroDay = TrainingLoadEngine.evaluateDense(dense)
        XCTAssertEqual(try XCTUnwrap(result.ctl), try XCTUnwrap(zeroDay.ctl), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(result.atl), try XCTUnwrap(zeroDay.atl), accuracy: 1e-12)
        XCTAssertLessThan(try XCTUnwrap(result.atl), 50)
    }

    /// A missing row is the same as a nil load: calendar time is not compressed.
    func testMissingCalendarDayDecaysRatherThanCompressingTime() throws {
        var days: [TrainingLoadEngine.DailyLoad] = []
        for day in 1...20 where day != 15 {
            days.append(.init(day: String(format: "2026-06-%02d", day), load: 50))
        }
        let result = TrainingLoadEngine.evaluate(days: days)
        XCTAssertEqual(result.state, .building)
        XCTAssertEqual(result.contiguousDays, 19)
        XCTAssertEqual(result.spanDays, 20)
        XCTAssertEqual(result.startDay, "2026-06-01")
        var dense = Array(repeating: 50.0, count: 20)
        dense[14] = 0
        XCTAssertEqual(try XCTUnwrap(result.atl),
                       try XCTUnwrap(TrainingLoadEngine.evaluateDense(dense).atl), accuracy: 1e-12)
    }

    /// Two consecutive missing days are tolerated; a third ends the run and only the days after it count.
    func testTwoMissingDaysAreToleratedAndThreeReset() {
        func run(missing: Set<Int>) -> TrainingLoadEngine.Result {
            TrainingLoadEngine.evaluate(days: (1...30).filter { !missing.contains($0) }.map {
                .init(day: String(format: "2026-08-%02d", $0), load: 40)
            })
        }
        let two = run(missing: [14, 15])
        XCTAssertEqual(two.state, .building)
        XCTAssertEqual(two.contiguousDays, 28)
        XCTAssertEqual(two.spanDays, 30)
        XCTAssertEqual(two.startDay, "2026-08-01")

        let three = run(missing: [13, 14, 15])
        XCTAssertEqual(three.state, .building)
        XCTAssertEqual(three.contiguousDays, 15)
        XCTAssertEqual(three.spanDays, 15)
        XCTAssertEqual(three.startDay, "2026-08-16")
        XCTAssertEqual(three.coverage, 1)
    }

    /// Gaps inside the priming window are skipped, not averaged in as zero, and an unobserved target still
    /// models nothing.
    func testPrimingIgnoresGapsAndAnUnobservedTargetIsUnavailable() throws {
        var days: [TrainingLoadEngine.DailyLoad] = []
        for day in 1...16 where day != 3 {
            days.append(.init(day: String(format: "2026-09-%02d", day), load: 30))
        }
        let primed = TrainingLoadEngine.evaluate(days: days, through: "2026-09-08")
        XCTAssertEqual(primed.state, .unavailable, "7 observed days are below the 14-day minimum")
        let result = TrainingLoadEngine.evaluate(days: days)
        XCTAssertEqual(result.points.first?.day, "2026-09-08", "the 7th observation seeds the model")
        XCTAssertEqual(try XCTUnwrap(result.points.first?.chronicLoad), 30, accuracy: 1e-12)

        days.append(.init(day: "2026-09-17", load: nil))
        let nilTarget = TrainingLoadEngine.evaluate(days: days)
        XCTAssertEqual(nilTarget.state, .unavailable)
        XCTAssertEqual(nilTarget.unavailableReason, .notEnoughContiguousDays)
        XCTAssertEqual(nilTarget.contiguousDays, 0)
    }

    func testExplicitTargetUsesOnlyHistoryThroughThatDay() {
        let days = (1...25).map {
            TrainingLoadEngine.DailyLoad(day: String(format: "2026-05-%02d", $0), load: Double($0))
        }
        let result = TrainingLoadEngine.evaluate(days: days, through: "2026-05-20")
        XCTAssertEqual(result.contiguousDays, 20)
        XCTAssertEqual(result.endDay, "2026-05-20")
        XCTAssertEqual(result.points.last?.day, "2026-05-20")
    }

    func testMissingExplicitTargetFailsClosed() {
        let days = (1...20).map {
            TrainingLoadEngine.DailyLoad(day: String(format: "2026-04-%02d", $0), load: 50)
        }
        let result = TrainingLoadEngine.evaluate(days: days, through: "2026-04-25")
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.unavailableReason, .missingTargetDay)
    }

    func testInputOrderDoesNotChangeResult() {
        let days = (1...20).map {
            TrainingLoadEngine.DailyLoad(day: String(format: "2026-03-%02d", $0), load: Double(20 + $0))
        }
        XCTAssertEqual(TrainingLoadEngine.evaluate(days: days),
                       TrainingLoadEngine.evaluate(days: Array(days.reversed())))
    }

    func testMalformedDuplicateNegativeAndNonFiniteInputFailClosed() {
        XCTAssertEqual(
            TrainingLoadEngine.evaluate(days: [.init(day: "2026-02-30", load: 10)]).unavailableReason,
            .invalidDay
        )
        XCTAssertEqual(
            TrainingLoadEngine.evaluate(days: [
                .init(day: "2026-02-01", load: 10), .init(day: "2026-02-01", load: 11),
            ]).unavailableReason,
            .duplicateDay
        )
        XCTAssertEqual(
            TrainingLoadEngine.evaluate(days: [.init(day: "2026-02-01", load: -1)]).unavailableReason,
            .invalidLoad
        )
        XCTAssertEqual(
            TrainingLoadEngine.evaluate(days: [.init(day: "2026-02-01", load: .nan)]).unavailableReason,
            .invalidLoad
        )
    }

    func testInvalidConfigurationFailsClosed() {
        let bad = TrainingLoadEngine.Configuration(chronicTimeConstantDays: 0)
        let result = TrainingLoadEngine.evaluateDense(Array(repeating: 50, count: 42), configuration: bad)
        XCTAssertEqual(result.state, .unavailable)
        XCTAssertEqual(result.unavailableReason, .invalidConfiguration)
    }

    func testLeapDayAndMonthBoundaryStayContiguousWithoutTimezoneMath() {
        let days = [
            "2024-02-22", "2024-02-23", "2024-02-24", "2024-02-25", "2024-02-26", "2024-02-27",
            "2024-02-28", "2024-02-29", "2024-03-01", "2024-03-02", "2024-03-03", "2024-03-04",
            "2024-03-05", "2024-03-06",
        ].map { TrainingLoadEngine.DailyLoad(day: $0, load: 30) }
        let result = TrainingLoadEngine.evaluate(days: days)
        XCTAssertEqual(result.state, .building)
        XCTAssertEqual(result.contiguousDays, 14)
        XCTAssertEqual(result.ctl!, 30, accuracy: 1e-12)
        XCTAssertEqual(result.atl!, 30, accuracy: 1e-12)
    }
    // MARK: - The public one-day step (a projection reuses the engine's math)

    /// `step` is exactly the update `evaluate` takes for the next observed day, bit for bit.
    func testStepEqualsEvaluatingOneMoreObservedDay() {
        let loads: [Double] = (0..<50).map { 20 + Double(($0 * 7) % 23) * 3 }
        let before = TrainingLoadEngine.evaluateDense(loads)
        for next in [0.0, 12 / 0.21, 90] {
            let stepped = TrainingLoadEngine.step(acute: before.acuteLoad!, chronic: before.chronicLoad!, load: next)
            let after = TrainingLoadEngine.evaluateDense(loads + [next])
            XCTAssertEqual(stepped.acute, after.acuteLoad!)
            XCTAssertEqual(stepped.chronic, after.chronicLoad!)
        }
    }

    func testStepHonoursAConfigurationsTimeConstants() {
        let configuration = TrainingLoadEngine.Configuration(chronicTimeConstantDays: 10, acuteTimeConstantDays: 2)
        let stepped = TrainingLoadEngine.step(acute: 40, chronic: 40, load: 80, configuration: configuration)
        XCTAssertEqual(stepped.acute, 40 + (1 - exp(-1.0 / 2)) * 40, accuracy: 1e-12)
        XCTAssertEqual(stepped.chronic, 40 + (1 - exp(-1.0 / 10)) * 40, accuracy: 1e-12)
        XCTAssertEqual(TrainingLoadEngine.smoothingFactor(timeConstantDays: 7), 1 - exp(-1.0 / 7), accuracy: 1e-15)
    }
}
