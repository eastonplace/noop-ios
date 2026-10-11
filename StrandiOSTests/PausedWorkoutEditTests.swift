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

    /// What the sheet does on Save, then what `Repository.saveManualWorkout` does to the pauses of a re-keyed row.
    private func edit(_ old: WorkoutRow, sport: String, start newStart: Int? = nil, durationMin: Int? = nil,
                      defaults: UserDefaults) throws -> WorkoutRow {
        let paused = WorkoutSource.pausedSeconds(
            of: old, ledger: WorkoutPauseStore.load(startTs: old.startTs, sport: old.sport, from: defaults))
        let built = try XCTUnwrap(WorkoutSource.buildManualRow(
            start: Date(timeIntervalSince1970: TimeInterval(newStart ?? old.startTs)),
            durationMin: durationMin ?? WorkoutSource.editableDurationMin(old),
            sport: sport, avgHr: old.avgHr, energyKcal: old.energyKcal))
        let row = WorkoutSource.preservingCaptured(built, from: old, pausedSeconds: paused)
        if old.startTs != row.startTs || old.sport != row.sport {
            WorkoutPauseStore.move(fromStartTs: old.startTs, fromSport: old.sport,
                                   toStartTs: row.startTs, toSport: row.sport, in: defaults)
        }
        return row
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
        let paused = WorkoutSource.pausedSeconds(
            of: old, ledger: WorkoutPauseStore.load(startTs: old.startTs, sport: old.sport, from: defaults))
        let edited = WorkoutSource.preservingCaptured(built, from: old, pausedSeconds: paused)
        XCTAssertEqual(edited.endTs, old.endTs)
        XCTAssertEqual(edited.durationS, 2_700)
        XCTAssertEqual(edited.avgHr, 150)
        XCTAssertEqual(edited.energyKcal, 560)
    }

    // MARK: A deliberate change of the running time

    func testChangingTheRunningTimeMovesTheEndByThatChangePlusTheSamePause() throws {
        let defaults = ephemeralDefaults()
        let old = recordedRun()
        WorkoutPauseStore.store(ledger, startTs: old.startTs, sport: old.sport, into: defaults)
        let longer = try edit(old, sport: "Running", durationMin: 50, defaults: defaults)
        XCTAssertEqual(longer.durationS, 3_000)
        XCTAssertEqual(longer.endTs, start + 3_000 + 900, "50 minutes ran, 15 were paused")
        XCTAssertEqual(WorkoutPauseStore.load(startTs: start, sport: "Running", from: defaults)?.intervals, [pause])
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
        XCTAssertEqual(WorkoutSource.preservingCaptured(built, from: nil, pausedSeconds: 600), built)
    }

    func testThePausedSecondsAreOnlyThoseInsideTheRowsWindow() {
        let old = recordedRun()
        XCTAssertEqual(WorkoutSource.pausedSeconds(of: old, ledger: ledger), 900)
        XCTAssertEqual(WorkoutSource.pausedSeconds(of: old, ledger: nil), 0)
        let elsewhere = WorkoutPauseLedger(intervals: [.init(start: Double(end + 10), end: Double(end + 100))])
        XCTAssertEqual(WorkoutSource.pausedSeconds(of: old, ledger: elsewhere), 0)
    }
}
