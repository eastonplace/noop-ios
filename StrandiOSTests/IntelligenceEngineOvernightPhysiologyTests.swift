import XCTest
import WhoopStore
@testable import NOOP

@MainActor
final class IntelligenceEngineOvernightPhysiologyTests: XCTestCase {
    private let dayStart = 1_767_225_600 // 2026-01-01 00:00 UTC

    private func daily(restingHR: Int? = nil) -> DailyMetric {
        DailyMetric(day: "2026-01-01", totalSleepMin: nil, efficiency: nil,
                    deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
                    restingHr: restingHR, avgHrv: nil, recovery: nil,
                    strain: 25, exerciseCount: 1, steps: 1_000, strainVersion: 2)
    }

    private func session(start: Int, end: Int, restingHR: Int?, adjusted: Int? = nil) -> CachedSleepSession {
        let effectiveStart = adjusted ?? start
        return CachedSleepSession(
            startTs: start, endTs: end, efficiency: 1, restingHr: restingHR, avgHrv: 60,
            stagesJSON: "[{\"start\":\(effectiveStart),\"end\":\(end),\"stage\":\"light\"}]",
            userEdited: adjusted != nil, startTsAdjusted: adjusted)
    }

    private func rebuild(_ fresh: DailyMetric, sessions: [CachedSleepSession]) -> DailyMetric? {
        IntelligenceEngine.rebuildingMissingOvernightFields(
            in: fresh, from: sessions, dayStart: dayStart, nextDayStart: dayStart + 86_400,
            habitualMidsleepSec: nil, timeZoneOffsetSeconds: 0)
    }

    func testRepairUsesPrimaryNightFloorAndPreservesDaytimeFields() throws {
        let night = session(start: dayStart - 3_600, end: dayStart + 6 * 3_600, restingHR: 57)
        let nap = session(start: dayStart + 13 * 3_600, end: dayStart + 15 * 3_600, restingHR: 41)
        let fresh = daily()
        let repaired = try XCTUnwrap(rebuild(fresh, sessions: [night, nap]))

        XCTAssertEqual(repaired.restingHr, 57)
        XCTAssertEqual(repaired.strain, fresh.strain)
        XCTAssertEqual(repaired.strainVersion, 2)
        XCTAssertEqual(repaired.steps, fresh.steps)
        XCTAssertEqual(repaired.exerciseCount, fresh.exerciseCount)
    }

    func testRepairDoesNotReplaceMissingPrimaryHRWithNap() throws {
        let night = session(start: dayStart - 3_600, end: dayStart + 6 * 3_600, restingHR: nil)
        let nap = session(start: dayStart + 13 * 3_600, end: dayStart + 15 * 3_600, restingHR: 41)
        let repaired = try XCTUnwrap(rebuild(daily(), sessions: [night, nap]))

        XCTAssertNotNil(repaired.totalSleepMin)
        XCTAssertNil(repaired.restingHr)
    }

    func testRepairUsesEditedEffectiveDurationForPrimarySelection() throws {
        // The bedtime correction shortens this block from seven hours to one hour. The separate
        // two-hour block is now the longest; selecting by the immutable detected key would be wrong.
        let edited = session(start: dayStart - 3_600, end: dayStart + 6 * 3_600,
                             restingHR: 57, adjusted: dayStart + 5 * 3_600)
        let longer = session(start: dayStart + 13 * 3_600, end: dayStart + 15 * 3_600, restingHR: 45)
        let repaired = try XCTUnwrap(rebuild(daily(), sessions: [edited, longer]))

        XCTAssertEqual(repaired.restingHr, 45)
    }

    func testRepairKeepsFreshRHRWhenAlreadyPresent() throws {
        let night = session(start: dayStart - 3_600, end: dayStart + 6 * 3_600, restingHR: 57)
        let repaired = try XCTUnwrap(rebuild(daily(restingHR: 59), sessions: [night]))

        XCTAssertEqual(repaired.restingHr, 59)
    }

    func testCurrentDayPartialPassStillPreservesPriorOvernightValues() {
        let prior = DailyMetric(day: "2026-01-01", totalSleepMin: 420, efficiency: 0.9,
                                deepMin: 80, remMin: 80, lightMin: 260, disturbances: 1,
                                restingHr: 57, avgHrv: 60, recovery: 75, strain: 10, exerciseCount: 0)
        let fresh = daily()
        let preserved = IntelligenceEngine.preservingPriorOvernightFields(in: fresh, from: prior)

        XCTAssertEqual(preserved.restingHr, prior.restingHr)
        XCTAssertEqual(preserved.avgHrv, prior.avgHrv)
        XCTAssertEqual(preserved.recovery, prior.recovery)
        XCTAssertEqual(preserved.totalSleepMin, prior.totalSleepMin)
        XCTAssertEqual(preserved.strain, fresh.strain)
        XCTAssertEqual(preserved.steps, fresh.steps)
    }
}
