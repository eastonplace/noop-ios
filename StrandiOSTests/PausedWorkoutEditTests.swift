import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

/// Editing a workout that was recorded with a pause. The edit sheet's duration is the time the workout ran (`durationS`
/// leaves the pause out), while the stored window is the wall clock it spanned, so a rename must not write the running
/// time back as the window and cut the paused stretch off its end.
final class PausedWorkoutEditTests: XCTestCase {

    /// A run from 07:00 to 08:00 with a pause from 07:20 to 07:35: 45 minutes ran, 15 were paused.
    private let start = 1_700_000_000
    private var end: Int { start + 3_600 }
    private var pause: WorkoutPauseLedger.Interval { .init(start: Double(start + 1_200), end: Double(start + 2_100)) }
    private var ledger: WorkoutPauseLedger { WorkoutPauseLedger(intervals: [pause]) }

    private func recordedRun(sport: String = "Running") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: "manual", durationS: 2_700, energyKcal: 540,
                   avgHr: 148, maxHr: 172, strain: 12.4, distanceM: 7_400, zonesJSON: nil, notes: nil, strainVersion: 2)
    }

    private func ephemeralDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "noop.tests.pausededit.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// What the sheet does on Save, then what `Repository.saveManualWorkout` does to the pauses.
    private func edit(_ old: WorkoutRow, sport: String, start newStart: Int? = nil, durationMin: Int? = nil,
                      defaults: UserDefaults) throws -> WorkoutRow {
        let built = try XCTUnwrap(WorkoutSource.buildManualRow(
            start: Date(timeIntervalSince1970: TimeInterval(newStart ?? old.startTs)),
            durationMin: durationMin ?? WorkoutSource.editableDurationMin(old),
            sport: sport, avgHr: old.avgHr, energyKcal: old.energyKcal))
        let row = WorkoutSource.preservingCaptured(
            built, from: old, pauses: WorkoutPauseStore.load(startTs: old.startTs, sport: old.sport, from: defaults))
        WorkoutPauseStore.follow(fromStartTs: old.startTs, fromSport: old.sport, to: row, in: defaults)
        return row
    }

    /// Everything that reads a saved workout's window and pauses must agree with the running time the list shows: the
    /// window minus the pauses kept for it is `durationS`, and Health is told exactly those pauses.
    private func assertConsistent(_ row: WorkoutRow, defaults: UserDefaults, file: StaticString = #filePath, line: UInt = #line) {
        let kept = WorkoutPauseStore.load(startTs: row.startTs, sport: row.sport, from: defaults)
        let active = (kept ?? WorkoutPauseLedger()).activeSeconds(from: Double(row.startTs), to: Double(row.endTs))
        XCTAssertEqual(active, row.durationS ?? -1, accuracy: 1, "window minus pauses is the running time", file: file, line: line)
        let inside = (kept?.intervals ?? []).filter { $0.start >= Double(row.startTs) && $0.end <= Double(row.endTs) }
        XCTAssertEqual(kept?.intervals.count ?? 0, inside.count, "no stored pause lies outside the window", file: file, line: line)
        let events = HealthKitBridge.workoutPauseEvents(
            kept, start: Date(timeIntervalSince1970: TimeInterval(row.startTs)),
            end: Date(timeIntervalSince1970: TimeInterval(row.endTs)))
        XCTAssertEqual(events.count, inside.count * 2, "Health gets a pause and a resume for each pause in the window",
                       file: file, line: line)
    }

    // MARK: The rename

    func testRenamingAPausedWorkoutKeepsItsWindowItsRunningTimeAndItsPauses() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        XCTAssertEqual(WorkoutSource.editableDurationMin(old), 45, "the stepper starts at the time that ran")

        let renamed = try edit(old, sport: "Trail Running", defaults: defaults)

        XCTAssertEqual(renamed.endTs, old.endTs, "the wall-clock end is not moved earlier by the paused time")
        XCTAssertEqual(renamed.durationS, 2_700, "the running time is untouched")
        XCTAssertEqual(renamed.endTs - renamed.startTs, 3_600)
        XCTAssertEqual(renamed.sport, "Trail Running")
        XCTAssertEqual(WorkoutPauseStore.load(startTs: start, sport: "Trail Running", from: defaults)?.intervals, [pause],
                       "the pause followed the workout to its new name")
        XCTAssertNil(WorkoutPauseStore.load(startTs: start, sport: "Running", from: defaults))
        assertConsistent(renamed, defaults: defaults)
        // The captured fields the sheet does not expose are carried too.
        XCTAssertEqual(renamed.strain, 12.4)
        XCTAssertEqual(renamed.maxHr, 172)
        XCTAssertEqual(renamed.distanceM, 7_400)
    }

    func testTheRunningTimeKeepsItsExactSecondsNotTheStepperWholeMinutes() throws {
        let defaults = ephemeralDefaults()
        // 44 min 41 s ran inside a 60 min window with 15 min paused: 2,681 s is not a whole number of minutes.
        let old = WorkoutRow(startTs: start, endTs: end, sport: "Running", source: "manual", durationS: 2_681,
                             energyKcal: nil, avgHr: nil, maxHr: 170, strain: 11, distanceM: nil, zonesJSON: nil, notes: nil)
        WorkoutPauseStore.store(ledger, startTs: start, sport: "Running", into: defaults)
        let renamed = try edit(old, sport: "Hiking", defaults: defaults)
        XCTAssertEqual(renamed.durationS, 2_681)
        XCTAssertEqual(renamed.endTs, old.endTs)
    }

    func testEditingAnotherFieldOfAPausedWorkoutLeavesTheTimesAlone() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        let built = try XCTUnwrap(WorkoutSource.buildManualRow(
            start: Date(timeIntervalSince1970: TimeInterval(old.startTs)), durationMin: 45, sport: "Running",
            avgHr: 150, energyKcal: 560))
        let edited = WorkoutSource.preservingCaptured(
            built, from: old, pauses: WorkoutPauseStore.load(startTs: old.startTs, sport: old.sport, from: defaults))
        XCTAssertEqual(edited.endTs, old.endTs)
        XCTAssertEqual(edited.durationS, 2_700)
        XCTAssertEqual(edited.avgHr, 150)
        XCTAssertEqual(edited.energyKcal, 560)
    }

    // MARK: A deliberate change of the running time
    //
    // The run is 07:00 to 08:00 with a pause 07:20 to 07:35 (offsets 1,200 s and 2,100 s from the start).

    func testLengtheningTheRunningTimeEndsItAfterThePauseThatIsReached() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        let longer = try edit(old, sport: "Running", durationMin: 60, defaults: defaults)
        XCTAssertEqual(longer.durationS, 3_600)
        XCTAssertEqual(longer.endTs, start + 3_600 + 900, "an hour ran, 15 minutes were paused: 08:15")
        XCTAssertEqual(WorkoutPauseStore.load(startTs: start, sport: "Running", from: defaults)?.intervals, [pause])
        assertConsistent(longer, defaults: defaults)
    }

    func testShorteningToBeforeThePauseBeginsDropsThePauseAndEndsAtThatMinute() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        let shorter = try edit(old, sport: "Running", durationMin: 15, defaults: defaults)
        XCTAssertEqual(shorter.durationS, 900)
        XCTAssertEqual(shorter.endTs, start + 900, "07:15, not 07:30: the pause is never reached")
        XCTAssertNil(WorkoutPauseStore.load(startTs: start, sport: "Running", from: defaults),
                     "a pause outside the window is not kept")
        assertConsistent(shorter, defaults: defaults)
    }

    func testAWorkoutThatRunsExactlyUntilThePauseBeginsEndsThere() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        let atThePause = try edit(old, sport: "Running", durationMin: 20, defaults: defaults)
        XCTAssertEqual(atThePause.endTs, start + 1_200, "the first moment 20 minutes have run: 07:20, before the pause")
        XCTAssertNil(WorkoutPauseStore.load(startTs: start, sport: "Running", from: defaults))
        assertConsistent(atThePause, defaults: defaults)
    }

    func testShorteningToJustPastThePauseKeepsTheWholePause() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        let shorter = try edit(old, sport: "Running", durationMin: 25, defaults: defaults)
        XCTAssertEqual(shorter.endTs, start + 1_500 + 900, "20 minutes before the pause and 5 after it: 07:40")
        XCTAssertEqual(WorkoutPauseStore.load(startTs: start, sport: "Running", from: defaults)?.intervals, [pause])
        assertConsistent(shorter, defaults: defaults)
    }

    func testShorteningBelowTheTimeThatWasPausedStillEndsBeforeThePause() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        // 10 minutes is less than the 15 that were paused: the old window-plus-total rule gave 07:25, inside the pause.
        let shorter = try edit(old, sport: "Running", durationMin: 10, defaults: defaults)
        XCTAssertEqual(shorter.endTs, start + 600, "07:10")
        assertConsistent(shorter, defaults: defaults)
    }

    func testMovingTheStartPastWhereThePauseWasTakesThePauseAlong() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        let later = try edit(old, sport: "Running", start: start + 2_400, defaults: defaults)   // 07:40
        XCTAssertEqual(later.startTs, start + 2_400)
        XCTAssertEqual(later.durationS, 2_700, "the running time was not touched")
        XCTAssertEqual(later.endTs, start + 2_400 + 3_600, "the pause is 20 minutes in, as before: it ends at 08:40")
        let moved = try XCTUnwrap(WorkoutPauseStore.load(startTs: later.startTs, sport: "Running", from: defaults))
        XCTAssertEqual(moved.intervals, [.init(start: pause.start + 2_400, end: pause.end + 2_400)])
        XCTAssertNil(WorkoutPauseStore.load(startTs: start, sport: "Running", from: defaults), "nothing left at the old key")
        assertConsistent(later, defaults: defaults)
    }

    func testMovingTheStartEarlierShiftsThePauseTheSameWay() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        let earlier = try edit(old, sport: "Running", start: start - 2_400, defaults: defaults)
        XCTAssertEqual(earlier.endTs, start - 2_400 + 3_600)
        XCTAssertEqual(try XCTUnwrap(WorkoutPauseStore.load(startTs: earlier.startTs, sport: "Running", from: defaults)).intervals,
                       [.init(start: pause.start - 2_400, end: pause.end - 2_400)])
        assertConsistent(earlier, defaults: defaults)
    }

    func testMovingTheStartAndShorteningTogetherWalksTheShiftedPause() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        let both = try edit(old, sport: "Trail Running", start: start + 600, durationMin: 30, defaults: defaults)
        // Pause now 07:30 to 07:45; the run starts 07:10 and 30 minutes of running end at 07:55 (20 + 10 after the pause).
        XCTAssertEqual(both.endTs, start + 600 + 1_200 + 900 + 600)
        XCTAssertEqual(both.durationS, 1_800)
        assertConsistent(both, defaults: defaults)
    }

    func testTheWalkOverSeveralPauses() {
        let ledger = WorkoutPauseLedger(intervals: [.init(start: 100, end: 160), .init(start: 400, end: 430)])
        XCTAssertEqual(ledger.wallClockEnd(from: 0, activeSeconds: 50), 50)
        XCTAssertEqual(ledger.wallClockEnd(from: 0, activeSeconds: 100), 100, "reaches its time as the first pause begins")
        XCTAssertEqual(ledger.wallClockEnd(from: 0, activeSeconds: 101), 161)
        XCTAssertEqual(ledger.wallClockEnd(from: 0, activeSeconds: 400), 490, "400 running plus the 60 and 30 paused")
        XCTAssertEqual(ledger.wallClockEnd(from: 120, activeSeconds: 30), 190, "a start inside a pause waits for it to end")
        XCTAssertEqual(WorkoutPauseLedger().wallClockEnd(from: 5, activeSeconds: 7), 12)
        for active in stride(from: 10.0, through: 500.0, by: 37.0) {
            let end = ledger.wallClockEnd(from: 0, activeSeconds: active)
            XCTAssertEqual(ledger.activeSeconds(from: 0, to: end), active, accuracy: 0.001)
        }
    }

    func testClippingAndShiftingThePauses() {
        let ledger = WorkoutPauseLedger(intervals: [.init(start: 100, end: 160), .init(start: 400, end: 430)])
        XCTAssertEqual(ledger.shifted(by: 50).intervals, [.init(start: 150, end: 210), .init(start: 450, end: 480)])
        XCTAssertEqual(ledger.clipped(from: 120, to: 410).intervals, [.init(start: 120, end: 160), .init(start: 400, end: 410)])
        XCTAssertTrue(ledger.clipped(from: 0, to: 90).intervals.isEmpty)
    }

    // MARK: Workouts that were never paused behave as before

    func testAWorkoutWithNoPausesIsEditedExactlyAsItAlwaysWas() throws {
        let defaults = ephemeralDefaults()
        let old = WorkoutRow(startTs: start, endTs: start + 2_700, sport: "Running", source: "manual", durationS: 2_700,
                             energyKcal: nil, avgHr: nil, maxHr: 170, strain: 11, distanceM: nil, zonesJSON: nil, notes: nil)
        let renamed = try edit(old, sport: "Hiking", defaults: defaults)
        XCTAssertEqual(renamed.endTs, start + 2_700)
        XCTAssertEqual(renamed.durationS, 2_700)
        let longer = try edit(old, sport: "Running", durationMin: 50, defaults: defaults)
        XCTAssertEqual(longer.endTs, start + 3_000)
    }

    func testAnAddedWorkoutIsUnaffected() throws {
        let built = try XCTUnwrap(WorkoutSource.buildManualRow(
            start: Date(timeIntervalSince1970: TimeInterval(start)), durationMin: 30, sport: "Run", avgHr: nil, energyKcal: nil))
        XCTAssertEqual(WorkoutSource.preservingCaptured(built, from: nil, pauses: ledger), built)
    }
}
