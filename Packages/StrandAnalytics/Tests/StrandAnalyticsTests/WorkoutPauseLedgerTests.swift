import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class WorkoutPauseLedgerTests: XCTestCase {
    private let t0 = 1_700_000_000.0
    private let maxHR = 190.0
    private let profile = UserProfile(weightKg: 78, heightCm: 181, age: 31, sex: "male")

    private func steady(from start: Int, to end: Int, bpm: Int) -> [HRSample] {
        (start...end).map { HRSample(ts: $0, bpm: bpm) }
    }

    // MARK: Toggles are idempotent

    func testPauseWhileAlreadyPausedChangesNothing() {
        var ledger = WorkoutPauseLedger()
        XCTAssertTrue(ledger.pause(at: t0 + 100))
        let once = ledger
        XCTAssertFalse(ledger.pause(at: t0 + 130), "a second pause must not move the pause start")
        XCTAssertEqual(ledger, once)
        XCTAssertEqual(ledger.openSince, t0 + 100)
    }

    func testResumeWhileRunningChangesNothing() {
        var ledger = WorkoutPauseLedger()
        XCTAssertFalse(ledger.resume(at: t0 + 10))
        XCTAssertEqual(ledger, WorkoutPauseLedger())
        ledger.pause(at: t0 + 100)
        XCTAssertTrue(ledger.resume(at: t0 + 160))
        let once = ledger
        XCTAssertFalse(ledger.resume(at: t0 + 200), "a double-tapped Resume adds no interval")
        XCTAssertEqual(ledger, once)
        XCTAssertEqual(ledger.intervals.count, 1)
    }

    func testNonFiniteTimesAreRefused() {
        var ledger = WorkoutPauseLedger()
        XCTAssertFalse(ledger.pause(at: .nan))
        XCTAssertFalse(ledger.pause(at: .infinity))
        XCTAssertFalse(ledger.isPaused)
        ledger.pause(at: t0)
        XCTAssertFalse(ledger.resume(at: .nan))
        XCTAssertTrue(ledger.isPaused)
    }

    func testClockStepBackCannotOverlapAnEarlierPause() {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 100)
        ledger.resume(at: t0 + 200)
        ledger.pause(at: t0 + 150)   // clock stepped back
        XCTAssertEqual(ledger.openSince, t0 + 200)
        ledger.resume(at: t0 + 140)
        XCTAssertEqual(ledger.intervals, [.init(start: t0 + 100, end: t0 + 200)])
    }

    // MARK: Elapsed time excludes pauses

    func testActiveSecondsExcludeClosedAndOpenPauses() {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 600)
        ledger.resume(at: t0 + 660)       // 60 s paused
        ledger.pause(at: t0 + 1_200)      // still paused at the read
        XCTAssertEqual(ledger.activeSeconds(from: t0, to: t0 + 1_500), 1_500 - 60 - 300, accuracy: 0.001)
        XCTAssertEqual(ledger.pausedSeconds(from: t0, to: t0 + 1_500), 360, accuracy: 0.001)
    }

    func testTimerFreezesWhilePaused() {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 300)
        let atPause = ledger.activeSeconds(from: t0, to: t0 + 300)
        XCTAssertEqual(ledger.activeSeconds(from: t0, to: t0 + 301), atPause, accuracy: 0.001)
        XCTAssertEqual(ledger.activeSeconds(from: t0, to: t0 + 4_000), atPause, accuracy: 0.001)
        ledger.resume(at: t0 + 4_000)
        XCTAssertEqual(ledger.activeSeconds(from: t0, to: t0 + 4_010), atPause + 10, accuracy: 0.001)
    }

    func testPauseOutsideTheWindowIsNotCounted() {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 100)
        ledger.resume(at: t0 + 200)
        XCTAssertEqual(ledger.pausedSeconds(from: t0 + 150, to: t0 + 400), 50, accuracy: 0.001)
        XCTAssertEqual(ledger.pausedSeconds(from: t0 + 250, to: t0 + 400), 0, accuracy: 0.001)
    }

    // MARK: Readings

    func testBoundarySecondsStayActive() {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 100.7)
        ledger.resume(at: t0 + 160.2)
        XCTAssertFalse(ledger.isPausedSecond(Int(t0) + 100))
        XCTAssertTrue(ledger.isPausedSecond(Int(t0) + 101))
        XCTAssertTrue(ledger.isPausedSecond(Int(t0) + 159))
        XCTAssertFalse(ledger.isPausedSecond(Int(t0) + 160))
    }

    func testSegmentsDropPausedReadingsAndSplitAtThePause() {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 100)
        ledger.resume(at: t0 + 160)
        let base = Int(t0)
        let all = steady(from: base, to: base + 300, bpm: 150)
        let segments = ledger.segments(of: all)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].last?.ts, base + 100)
        XCTAssertEqual(segments[1].first?.ts, base + 160)
        XCTAssertFalse(segments.flatMap { $0 }.contains { ledger.isPausedSecond($0.ts) })
    }

    func testSegmentsWithoutPausesAreTheReadingsUntouched() {
        let all = steady(from: 10, to: 40, bpm: 120)
        XCTAssertEqual(WorkoutPauseLedger().segments(of: all), [all])
    }

    func testAShortPauseStillSplitsTheStretch() {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 100)
        ledger.resume(at: t0 + 130)       // shorter than the 90 s strain kernel gap
        XCTAssertEqual(ledger.segments(of: steady(from: Int(t0), to: Int(t0) + 200, bpm: 150)).count, 2)
    }

    func testAPauseUnderASecondDoesNotSplit() {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 100.2)
        ledger.resume(at: t0 + 100.6)
        XCTAssertEqual(ledger.segments(of: steady(from: Int(t0), to: Int(t0) + 200, bpm: 150)).count, 1)
    }

    func testAnOpenPauseDropsEverythingAfterIt() {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 100)
        let segments = ledger.segments(of: steady(from: Int(t0), to: Int(t0) + 200, bpm: 150))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].last?.ts, Int(t0) + 100)
    }

    // MARK: Strain and calories exclude paused windows

    func testStrainOverSegmentsEqualsPlainStrainWithOneStretch() throws {
        let readings = steady(from: 0, to: 1_800, bpm: 150)
        let plain = try XCTUnwrap(StrainScorerV2.strain(readings, maxHR: maxHR, mode: .activity))
        let segmented = try XCTUnwrap(StrainScorerV2.activityStrain(segments: [readings], maxHR: maxHR))
        XCTAssertEqual(plain, segmented, accuracy: 1e-12)
    }

    func testAShortPauseIsNotCreditedAsLoad() throws {
        // 25 minutes of work either side of a 60 s pause. Run straight through (no pause) the 60 s gap is under
        // the 90 s kernel limit, so the plain scorer credits it; the segmented scorer must not.
        let before = steady(from: 0, to: 1_500, bpm: 165)
        let after = steady(from: 1_560, to: 3_060, bpm: 165)
        let straightThrough = try XCTUnwrap(StrainScorerV2.strain(before + after, maxHR: maxHR, mode: .activity))
        let segmented = try XCTUnwrap(StrainScorerV2.activityStrain(segments: [before, after], maxHR: maxHR))
        XCTAssertLessThan(segmented, straightThrough)
        // The same work without any pause between: two back-to-back stretches of 1500 s each.
        let continuous = steady(from: 0, to: 3_000, bpm: 165)
        let expected = try XCTUnwrap(StrainScorerV2.strain(continuous, maxHR: maxHR, mode: .activity))
        XCTAssertEqual(segmented, expected, accuracy: 0.6, "only the 60 s hole separates them")
    }

    func testAccumulatorBreakMatchesTheSegmentedBatchScore() throws {
        let before = steady(from: 1_000, to: 2_500, bpm: 160)
        let after = steady(from: 2_700, to: 4_200, bpm: 175)
        var live = StrainScorerV2.ActivityAccumulator(maxHR: maxHR)
        before.forEach { live.append($0) }
        live.breakStream()
        after.forEach { live.append($0) }
        let batch = try XCTUnwrap(StrainScorerV2.activityStrain(segments: [before, after], maxHR: maxHR))
        XCTAssertEqual(try XCTUnwrap(live.strain), batch, accuracy: 1e-12)
        XCTAssertEqual(live.readingCount, before.count + after.count)
    }

    func testBreakingTheStreamKeepsTheAverageAndPeak() {
        var live = StrainScorerV2.ActivityAccumulator(maxHR: maxHR)
        steady(from: 1_000, to: 1_059, bpm: 100).forEach { live.append($0) }
        live.breakStream()
        steady(from: 1_400, to: 1_459, bpm: 160).forEach { live.append($0) }
        XCTAssertEqual(live.averageHR, 130)
        XCTAssertEqual(live.peakHR, 160)
    }

    func testRestoreFromReadingsAndLedgerMatchesTheLiveAccumulator() throws {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 1_500)
        ledger.resume(at: t0 + 1_560)
        let base = Int(t0)
        let readings = ledger.activeSamples(steady(from: base, to: base + 3_000, bpm: 158))
        var live = StrainScorerV2.ActivityAccumulator(maxHR: maxHR)
        for segment in ledger.segments(of: readings) {
            if live.readingCount > 0 { live.breakStream() }
            segment.forEach { live.append($0) }
        }
        let batch = try XCTUnwrap(StrainScorerV2.activityStrain(
            segments: ledger.segments(of: readings), maxHR: maxHR))
        XCTAssertEqual(try XCTUnwrap(live.strain), batch, accuracy: 1e-12)
    }

    func testTooFewReadingsAcrossStretchesGiveNoStrain() {
        let a = steady(from: 0, to: 5, bpm: 150)
        let b = steady(from: 100, to: 105, bpm: 150)
        XCTAssertNil(StrainScorerV2.activityStrain(segments: [a, b], maxHR: maxHR))
        XCTAssertNil(StrainScorerV2.activityStrain(segments: [], maxHR: maxHR))
    }

    func testCaloriesDoNotCreditThePauseAsTimeAtTheLastRate() {
        let before = steady(from: 0, to: 600, bpm: 160)
        let after = steady(from: 700, to: 1_300, bpm: 160)
        let joined = Calories.estimateBoutCalories(before + after, profile: profile, hrmax: maxHR, restingHR: nil).0
        let segmented = Calories.estimateBoutCalories(segments: [before, after], profile: profile,
                                                      hrmax: maxHR, restingHR: nil).0
        // Joined, the 100 s hole is charged at the active rate; segmented it is not.
        XCTAssertLessThan(segmented, joined)
        let perSecond = Calories.activeKcalPerS(Calories.resolveCoeffs("male"), hr: 160, hrmax: maxHR,
                                                weightKg: 78, age: 31)
        XCTAssertEqual(joined - segmented, perSecond * 99, accuracy: perSecond * 2)
    }

    func testLiveProjectionAfterAPauseMatchesTheSegmentedEstimate() {
        let before = steady(from: 1_000, to: 1_600, bpm: 150)
        let after = steady(from: 1_700, to: 2_300, bpm: 120)
        var projection = WorkoutLiveProjectionAccumulator(
            profile: profile, hrmax: maxHR, restingHR: nil,
            zoneSet: HRZones.zones(maxHR: maxHR, source: "profile"))
        before.forEach { projection.append($0) }
        after.enumerated().forEach { index, sample in
            if index == 0 { projection.appendAfterPause(sample) } else { projection.append(sample) }
        }
        let expected = Calories.estimateBoutCalories(segments: [before, after], profile: profile,
                                                     hrmax: maxHR, restingHR: nil).0
        XCTAssertEqual(projection.snapshot().caloriesKcal, expected, accuracy: 1e-6)
        XCTAssertEqual(projection.snapshot().sampleCount, before.count + after.count)
    }

    // MARK: Rescore of a saved workout

    func testRescoreLeavesPausedReadingsOutOfEveryNumber() throws {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 600)
        ledger.resume(at: t0 + 1_200)
        let base = Int(t0)
        // The strap kept logging through the pause; a rest-level 70 bpm sits in the paused window.
        let window = steady(from: base, to: base + 600, bpm: 150)
            + steady(from: base + 601, to: base + 1_199, bpm: 70)
            + steady(from: base + 1_200, to: base + 1_800, bpm: 150)
        let withPauses = try XCTUnwrap(ManualWorkoutRescore.scored(
            windowSamples: window, profile: profile, hrMax: maxHR, pauses: ledger))
        XCTAssertEqual(withPauses.avgHr, 150)
        XCTAssertEqual(withPauses.maxHr, 150)
        let ignoringPauses = try XCTUnwrap(ManualWorkoutRescore.scored(
            windowSamples: window, profile: profile, hrMax: maxHR))
        XCTAssertLessThan(ignoringPauses.avgHr, 150)
        XCTAssertGreaterThan(try XCTUnwrap(withPauses.kcal), 0)
    }

    func testRescoreWithoutPausesIsUnchanged() throws {
        let window = steady(from: 0, to: 900, bpm: 140)
        let plain = ManualWorkoutRescore.scored(windowSamples: window, profile: profile, hrMax: maxHR)
        let empty = ManualWorkoutRescore.scored(windowSamples: window, profile: profile, hrMax: maxHR,
                                                pauses: WorkoutPauseLedger())
        XCTAssertEqual(plain, empty)
    }

    // MARK: Persisted ledgers are untrusted

    func testLedgerRoundTripsThroughJSON() throws {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: t0 + 10)
        ledger.resume(at: t0 + 70)
        ledger.pause(at: t0 + 500)
        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutPauseLedger.self, from: data), ledger)
    }

    func testDecodingSanitisesOverlapsDisorderAndNonFiniteEntries() throws {
        let json = """
        {"intervals":[{"start":300,"end":400},{"start":100,"end":350},{"start":500,"end":450}],"openSince":null}
        """
        let ledger = try JSONDecoder().decode(WorkoutPauseLedger.self, from: Data(json.utf8))
        XCTAssertEqual(ledger.intervals, [.init(start: 100, end: 400)], "a pause with no length is dropped")
        XCTAssertNil(ledger.openSince)
        XCTAssertEqual(try JSONDecoder().decode(WorkoutPauseLedger.self, from: Data("{}".utf8)), WorkoutPauseLedger())
    }
}
