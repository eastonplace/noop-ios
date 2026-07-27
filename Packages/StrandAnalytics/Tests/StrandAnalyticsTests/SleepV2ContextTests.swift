import XCTest
@testable import StrandAnalytics
import WhoopProtocol

final class SleepV2ContextTests: XCTestCase {
    private func session(_ start: Int, _ minutes: Int, wake: Int = 0) -> SleepSession {
        let end = start + minutes * 60
        let wakeEnd = start + wake * 60
        let stages = wake > 0
            ? [StageSegment(start: start, end: wakeEnd, stage: "wake"),
               StageSegment(start: wakeEnd, end: end, stage: "light")]
            : [StageSegment(start: start, end: end, stage: "light")]
        return SleepSession(start: start, end: end,
                            efficiency: Double(minutes - wake) / Double(minutes),
                            stages: stages, restingHR: 55, avgHRV: 50)
    }

    func testNightSummaryReusesMainGroupAndExcludesNap() throws {
        let nap = session(12 * 3600, 45)
        let first = session(22 * 3600, 180, wake: 20)
        let second = session(25 * 3600 + 20 * 60, 240)
        let summary = try XCTUnwrap(SleepNightSummary.select(
            from: [nap, first, second], wakeDay: "2026-07-20", offsetSeconds: 0,
            source: .noopMeasured, sourceRowId: "row"))
        XCTAssertEqual(summary.mainSleepStart, first.start)
        XCTAssertEqual(summary.mainSleepEnd, second.end)
        XCTAssertEqual(summary.mainSleepMinutes, 400, accuracy: 0.01)
        XCTAssertEqual(summary.inBedMinutes, 440, accuracy: 0.01)
        XCTAssertEqual(summary.efficiency, 400.0 / 440.0, accuracy: 0.0001)
        XCTAssertEqual(summary.recentNapMinutes, 45)
    }

    func testNightSummaryIgnoresExtremeStageAndNormalizesExtremeOffset() throws {
        let session = SleepSession(
            start: 0,
            end: 600,
            efficiency: 1,
            stages: [
                StageSegment(start: 0, end: 600, stage: "light"),
                StageSegment(start: Int.min, end: Int.max, stage: "deep"),
            ],
            restingHR: nil,
            avgHRV: nil)

        let summary = try XCTUnwrap(SleepNightSummary.select(
            from: [session], wakeDay: "2026-07-20", offsetSeconds: Int.max,
            source: .noopMeasured, sourceRowId: "row"))
        XCTAssertEqual(summary.mainSleepMinutes, 10, accuracy: 0.001)
        XCTAssertEqual(summary.inBedMinutes, 10, accuracy: 0.001)
        XCTAssertEqual(summary.efficiency, 1, accuracy: 0.001)
        XCTAssertEqual(summary.onsetMinuteLocal,
                       SleepStageTotals.localSecOfDay(0, offsetSec: Int.max) / 60)
        XCTAssertEqual(summary.wakeMinuteLocal,
                       SleepStageTotals.localSecOfDay(600, offsetSec: Int.max) / 60)
    }

    func testChronologicalReplayUsesPreviousDayEffortAndCarriesDebt() throws {
        let s1 = SleepNightSummary(wakeDay: "2026-07-19", mainSleepStart: 0, mainSleepEnd: 25_200,
            mainSleepMinutes: 420, inBedMinutes: 450, efficiency: 420.0 / 450,
            onsetMinuteLocal: 1380, wakeMinuteLocal: 420, recentNapMinutes: 0,
            lowStressQuality: 0.8, source: .noopMeasured, sourceRowId: "a")
        let s2 = SleepNightSummary(wakeDay: "2026-07-20", mainSleepStart: 86_400, mainSleepEnd: 115_200,
            mainSleepMinutes: 480, inBedMinutes: 500, efficiency: 0.96,
            onsetMinuteLocal: 1380, wakeMinuteLocal: 420, recentNapMinutes: 30,
            lowStressQuality: 0.8, source: .noopEdited, sourceRowId: "b")
        let result = SleepScoringContextBuilder.replay(
            summaries: [s2, s1],
            efforts: [.init(day: "2026-07-18", value: 100), .init(day: "2026-07-19", value: 0)])
        XCTAssertEqual(result.map(\.day), ["2026-07-19", "2026-07-20"])
        XCTAssertEqual(result[0].need.strainAdjustmentMinutes, 60)
        XCTAssertEqual(result[1].need.strainAdjustmentMinutes, 0)
        XCTAssertEqual(result[1].need.debtBalanceBeforeNightMinutes,
                       result[0].debtAfterNight.newBalanceMinutes)
        XCTAssertEqual(result[1].summary.source, .noopEdited)
    }

    func testStressRenormalizesMissingMotionAndRequiresSixWindows() throws {
        let start = 1_000_000
        let hr = (0..<40).map { HRSample(ts: start + $0 * 60, bpm: 55) }
        let rr = (0..<40).map { RRInterval(ts: start + $0 * 60, rrMs: $0.isMultiple(of: 2) ? 950 : 1_050) }
        let stages = [StageSegment(start: start, end: start + 40 * 60, stage: "light")]
        let reference = [SleepStressV1.Reference(meanSleepingHR: 55, meanSleepingRMSSD: 100)]
        let calm = try XCTUnwrap(SleepStressV1.score(start: start, end: start + 40 * 60,
            hr: hr, rr: rr, stages: stages, priorReferences: reference))
        let activatedHR = hr.map { HRSample(ts: $0.ts, bpm: 75) }
        let activated = try XCTUnwrap(SleepStressV1.score(start: start, end: start + 40 * 60,
            hr: activatedHR, rr: rr, stages: stages, priorReferences: reference))
        XCTAssertGreaterThan(calm.lowStressQuality, activated.lowStressQuality)
        XCTAssertNil(SleepStressV1.score(start: start, end: start + 20 * 60,
            hr: Array(hr.prefix(20)), rr: Array(rr.prefix(20)), stages: stages,
            priorReferences: reference))
    }
}
