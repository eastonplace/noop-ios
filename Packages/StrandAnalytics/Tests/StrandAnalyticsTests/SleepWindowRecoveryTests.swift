import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

final class SleepWindowRecoveryTests: XCTestCase {
    private func stillGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { GravitySample(ts: start + $0, x: 0, y: 0, z: 1) }
    }

    private func activeGravity(start: Int, durationS: Int) -> [GravitySample] {
        (0..<durationS).map { index in
            GravitySample(ts: start + index, x: index.isMultiple(of: 2) ? 0 : 0.4, y: 0, z: 1)
        }
    }

    private func hr(start: Int, durationS: Int, bpm: Int) -> [HRSample] {
        (0..<durationS).map { HRSample(ts: start + $0, bpm: bpm) }
    }

    private func evidence() -> SleepWindowEvidence {
        SleepWindowEvidence(
            gravitySamples: 10_000,
            hrSamples: 10_000,
            rrSamples: 2_000,
            respSamples: 1_000,
            gravityCoverage: 1,
            hrCoverage: 1,
            rrCoverage: 1,
            respCoverage: 1)
    }

    private func daily(
        day: String,
        totalSleepMin: Double? = nil,
        restingHr: Int? = nil,
        avgHrv: Double? = nil,
        strain: Double? = nil,
        steps: Int? = nil
    ) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: totalSleepMin,
            efficiency: totalSleepMin == nil ? nil : 0.85,
            deepMin: totalSleepMin == nil ? nil : 60,
            remMin: totalSleepMin == nil ? nil : 90,
            lightMin: totalSleepMin.map { max(0, $0 - 150) },
            disturbances: totalSleepMin == nil ? nil : 2,
            restingHr: restingHr,
            avgHrv: avgHrv,
            recovery: nil,
            strain: strain,
            exerciseCount: strain == nil ? nil : 1,
            steps: steps,
            strainVersion: strain == nil ? nil : 2)
    }

    func testBoundedRecoveryCanRecoverHighHRNightRejectedByAutomaticDetector() {
        let sleepStart = 1_749_520_800 // 2026-06-10 02:00 UTC
        let awakeStart = sleepStart - 4 * 3_600
        let sleepDuration = 90 * 60
        let awakeDuration = 4 * 3_600

        let allGravity = activeGravity(start: awakeStart, durationS: awakeDuration)
            + stillGravity(start: sleepStart, durationS: sleepDuration)
        let allHR = hr(start: awakeStart, durationS: awakeDuration, bpm: 55)
            + hr(start: sleepStart, durationS: sleepDuration, bpm: 120)

        XCTAssertTrue(
            SleepStager.detectSleep(hr: allHR, gravity: allGravity).isEmpty,
            "the automatic detector should reject the still block because its HR never dipped")

        let recovered = SleepWindowRecovery.analyze(
            start: sleepStart,
            end: sleepStart + sleepDuration,
            hr: allHR,
            gravity: allGravity)

        XCTAssertEqual(recovered.outcome, .complete)
        XCTAssertTrue(recovered.canPersistSession)
        XCTAssertFalse(recovered.stages.isEmpty)
        XCTAssertEqual(recovered.restingHR, 120)
        XCTAssertGreaterThan(recovered.confidence, 0.5)
    }

    func testShortLowSleepNightCanBeRecoveredWhenUserConstrainsWindow() {
        let start = 1_749_520_800
        let duration = 45 * 60
        let recovered = SleepWindowRecovery.analyze(
            start: start,
            end: start + duration,
            hr: hr(start: start, durationS: duration, bpm: 62),
            gravity: stillGravity(start: start, durationS: duration))

        XCTAssertEqual(recovered.outcome, .complete)
        XCTAssertGreaterThanOrEqual(recovered.efficiency ?? 0, 0.5)
        XCTAssertEqual(recovered.requestedEnd - recovered.requestedStart, duration)
    }

    func testSparseMotionPreservesRealVitalsWithoutInventingStages() {
        let start = 1_749_520_800
        let duration = 6 * 3_600
        let recovered = SleepWindowRecovery.analyze(
            start: start,
            end: start + duration,
            hr: hr(start: start, durationS: duration, bpm: 51),
            gravity: [])

        XCTAssertEqual(recovered.outcome, .partial)
        XCTAssertEqual(recovered.reason, .sparseMotion)
        XCTAssertTrue(recovered.canPersistSession)
        XCTAssertFalse(recovered.hasDefensibleStages)
        XCTAssertNil(recovered.efficiency)
        XCTAssertEqual(recovered.restingHR, 51)
    }

    func testNoPhysiologyDoesNotCreateSession() {
        let start = 1_749_520_800
        let recovered = SleepWindowRecovery.analyze(
            start: start,
            end: start + 8 * 3_600)

        XCTAssertEqual(recovered.outcome, .insufficientData)
        XCTAssertEqual(recovered.reason, .noPhysiology)
        XCTAssertFalse(recovered.canPersistSession)
        XCTAssertEqual(recovered.confidence, 0)
    }

    func testInvalidAndImplausiblyLongWindowsAreRejected() {
        let start = 1_749_520_800
        let inverted = SleepWindowRecovery.analyze(start: start, end: start - 60)
        let tooShort = SleepWindowRecovery.analyze(start: start, end: start + 20 * 60)
        let tooLong = SleepWindowRecovery.analyze(start: start, end: start + 17 * 3_600)

        for result in [inverted, tooShort, tooLong] {
            XCTAssertEqual(result.outcome, .invalidWindow)
            XCTAssertEqual(result.reason, .invalidDuration)
            XCTAssertFalse(result.canPersistSession)
        }
    }

    func testExtremeTimestampsFailClosedWithoutWrappedEvidenceOrSleep() {
        let recovered = SleepWindowRecovery.analyze(
            start: Int.min,
            end: Int.max,
            hr: [HRSample(ts: 0, bpm: 60)],
            gravity: [GravitySample(ts: 0, x: 0, y: 0, z: 1)])

        XCTAssertEqual(recovered.outcome, .invalidWindow)
        XCTAssertEqual(recovered.reason, .invalidDuration)
        XCTAssertFalse(recovered.canPersistSession)
        XCTAssertEqual(recovered.evidence.hrSamples, 0)
        XCTAssertEqual(recovered.evidence.gravitySamples, 0)
        XCTAssertEqual(
            SleepWindowRecovery.coverageFraction(
                [Int.min, Int.max], start: Int.min, end: Int.max),
            0)
        XCTAssertNil(SleepWindowRecovery.asleepSeconds(
            in: [StageSegment(start: Int.min, end: Int.max, stage: "light")],
            start: 0,
            end: 3_600))
    }

    func testDSTSpringForwardWindowUsesAbsoluteElapsedTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 1, minute: 30)))
        let end = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 8, hour: 3, minute: 30)))
        let startTs = Int(start.timeIntervalSince1970)
        let endTs = Int(end.timeIntervalSince1970)

        XCTAssertEqual(endTs - startTs, 60 * 60)
        let recovered = SleepWindowRecovery.analyze(
            start: startTs,
            end: endTs,
            hr: hr(start: startTs, durationS: endTs - startTs, bpm: 55),
            gravity: stillGravity(start: startTs, durationS: endTs - startTs))

        XCTAssertEqual(recovered.outcome, .complete)
        XCTAssertEqual(recovered.requestedEnd - recovered.requestedStart, 60 * 60)
    }

    func testDailyScorerUsesRecoveredStagesAndPreservesActivityFields() {
        let start = 10_000
        let end = start + 8 * 3_600
        let analysis = SleepWindowRecoveryResult(
            source: .manualWindow,
            outcome: .complete,
            reason: .boundedReanalysis,
            confidence: 0.9,
            requestedStart: start,
            requestedEnd: end,
            stages: [
                StageSegment(start: start, end: start + 30 * 60, stage: "wake"),
                StageSegment(start: start + 30 * 60, end: start + 4 * 3_600, stage: "light"),
                StageSegment(start: start + 4 * 3_600, end: start + 5 * 3_600, stage: "deep"),
                StageSegment(start: start + 5 * 3_600, end: start + 6 * 3_600, stage: "rem"),
                StageSegment(start: start + 6 * 3_600, end: end, stage: "light"),
            ],
            efficiency: 0.9375,
            restingHR: 49,
            avgHRV: 68,
            evidence: evidence())
        let existing = daily(day: "2026-07-26", totalSleepMin: 300, restingHr: 58,
                             avgHrv: 40, strain: 36, steps: 9_000)

        let score = ManualSleepDailyScorer.score(
            day: "2026-07-26",
            analysis: analysis,
            existing: existing,
            priorHistory: [],
            hrvBaselineEpoch: 0,
            recoveryBaselineEpoch: 0)

        XCTAssertEqual(score.daily.totalSleepMin ?? 0, 450, accuracy: 0.001)
        XCTAssertEqual(score.daily.deepMin ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(score.daily.remMin ?? 0, 60, accuracy: 0.001)
        XCTAssertEqual(score.daily.lightMin ?? 0, 330, accuracy: 0.001)
        XCTAssertEqual(score.daily.restingHr, 49)
        XCTAssertEqual(score.daily.avgHrv, 68)
        XCTAssertEqual(score.daily.strain, 36)
        XCTAssertEqual(score.daily.steps, 9_000)
        XCTAssertNotNil(score.restScore)
        XCTAssertNil(score.daily.recovery, "Charge remains nil until the personal baseline is usable")
    }

    func testPartialDailyScoreClearsStaleSleepInsteadOfInventingIt() {
        let analysis = SleepWindowRecoveryResult(
            source: .manualWindow,
            outcome: .partial,
            reason: .sparseMotion,
            confidence: 0.55,
            requestedStart: 10_000,
            requestedEnd: 30_000,
            stages: [],
            efficiency: nil,
            restingHR: 50,
            avgHRV: 62,
            evidence: evidence())
        let existing = daily(day: "2026-07-26", totalSleepMin: 420, restingHr: 57,
                             avgHrv: 44, strain: 20, steps: 7_500)

        let score = ManualSleepDailyScorer.score(
            day: "2026-07-26",
            analysis: analysis,
            existing: existing,
            priorHistory: [],
            hrvBaselineEpoch: 0,
            recoveryBaselineEpoch: 0)

        XCTAssertNil(score.daily.totalSleepMin)
        XCTAssertNil(score.daily.efficiency)
        XCTAssertNil(score.daily.deepMin)
        XCTAssertNil(score.daily.remMin)
        XCTAssertNil(score.daily.lightMin)
        XCTAssertNil(score.restScore)
        XCTAssertEqual(score.daily.restingHr, 50)
        XCTAssertEqual(score.daily.avgHrv, 62)
        XCTAssertEqual(score.daily.strain, 20)
        XCTAssertEqual(score.daily.steps, 7_500)
    }

    func testDailyScorerRejectsMalformedStageTimestamps() {
        let analysis = SleepWindowRecoveryResult(
            source: .manualWindow,
            outcome: .complete,
            reason: .boundedReanalysis,
            confidence: 0.9,
            requestedStart: 0,
            requestedEnd: 3_600,
            stages: [StageSegment(start: Int.min, end: Int.max, stage: "light")],
            efficiency: 1,
            restingHR: 50,
            avgHRV: 60,
            evidence: evidence())

        let score = ManualSleepDailyScorer.score(
            day: "2026-07-26",
            analysis: analysis,
            existing: daily(day: "2026-07-26", totalSleepMin: 420),
            priorHistory: [])

        XCTAssertNil(score.daily.totalSleepMin)
        XCTAssertNil(score.restScore)
    }

    func testDailyScorerRegeneratesChargeOnceBaselineIsUsable() {
        let start = 20_000
        let end = start + 8 * 3_600
        let analysis = SleepWindowRecoveryResult(
            source: .manualWindow,
            outcome: .complete,
            reason: .boundedReanalysis,
            confidence: 0.9,
            requestedStart: start,
            requestedEnd: end,
            stages: [StageSegment(start: start, end: end, stage: "light")],
            efficiency: 1,
            restingHR: 49,
            avgHRV: 70,
            evidence: evidence())
        let history = [
            daily(day: "2026-07-21", totalSleepMin: 430, restingHr: 55, avgHrv: 55),
            daily(day: "2026-07-22", totalSleepMin: 440, restingHr: 54, avgHrv: 56),
            daily(day: "2026-07-23", totalSleepMin: 450, restingHr: 53, avgHrv: 57),
            daily(day: "2026-07-24", totalSleepMin: 460, restingHr: 52, avgHrv: 58),
        ]

        let score = ManualSleepDailyScorer.score(
            day: "2026-07-26",
            analysis: analysis,
            existing: nil,
            priorHistory: history,
            hrvBaselineEpoch: 0,
            recoveryBaselineEpoch: 0)

        XCTAssertNotNil(score.restScore)
        XCTAssertNotNil(score.daily.recovery)
        XCTAssertGreaterThan(score.daily.recovery ?? 0, 50)
    }
}
