import XCTest
import StrandAnalytics
import StrandDesign
@testable import NOOP

/// Today's "Workout in progress" card counts the time the workout ran, like the live screen and the Lock Screen: it stands
/// still while the workout is paused and does not include earlier pauses.
@MainActor
final class ActiveWorkoutIndicatorPauseTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func workout() -> AppModel.ActiveWorkout {
        AppModel.ActiveWorkout(start: start, sport: "Running", maxHR: 190)
    }

    private func t(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func testTheCardClockFreezesWhilePausedAndAgreesWithTheLiveScreen() throws {
        let w = workout()
        XCTAssertTrue(w.setPaused(true, at: t(34 * 60 + 12)))
        let model = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        XCTAssertTrue(model.isPaused)
        // Three minutes into the pause, ten, an hour: the card still reads 34:12, as the hero and the Lock Screen do.
        for later in [180.0, 600, 3_600] {
            let now = t(34 * 60 + 12 + later)
            XCTAssertEqual(model.elapsedText(at: now), "34:12")
            XCTAssertEqual(model.elapsedText(at: now), LiveWorkoutTiles.elapsedText(w.activeElapsed(at: now)))
        }
    }

    func testAfterAResumeTheCardStaysAtTheTimeThatRanNotTheWallClock() throws {
        let w = workout()
        XCTAssertTrue(w.setPaused(true, at: t(34 * 60 + 12)))
        XCTAssertTrue(w.setPaused(false, at: t(34 * 60 + 12 + 180)))
        let model = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        XCTAssertFalse(model.isPaused)
        let now = t(34 * 60 + 12 + 180 + 60)
        XCTAssertEqual(model.elapsedText(at: now), "35:12", "the three paused minutes are not in it")
        XCTAssertEqual(ActiveWorkoutIndicatorModel.elapsed(since: start, now: now), "38:12",
                       "the wall-clock helper is what the card used to show: three minutes ahead")
        XCTAssertEqual(model.elapsedText(at: now), LiveWorkoutTiles.elapsedText(w.activeElapsed(at: now)))
    }

    func testAWorkoutThatWasNeverPausedReadsTheWallClockAsBefore() throws {
        let model = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: workout()))
        XCTAssertFalse(model.isPaused)
        XCTAssertEqual(model.elapsedText(at: t(65)), "1:05")
        XCTAssertEqual(model.elapsedText(at: t(3_600 + 23 * 60 + 7)), "1:23:07")
        XCTAssertEqual(model.elapsedText(at: t(-5)), "0:00")
    }

    func testAPauseOrResumeChangesTheModelSoTheCardRedraws() throws {
        let w = workout()
        let running = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        XCTAssertTrue(w.setPaused(true, at: t(100)))
        let paused = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        XCTAssertNotEqual(running, paused)
        XCTAssertTrue(w.setPaused(false, at: t(160)))
        let resumed = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        XCTAssertNotEqual(paused, resumed)
        XCTAssertNotEqual(running, resumed, "the closed pause is part of the model")
    }

    // MARK: A finish that is pending stops every clock at the end the save will use

    func testOnceAFinishIsPendingTheHeroAndTheTodayCardStopAtTheEnd() throws {
        let w = workout()
        w.freeze(at: t(1_800))                         // End was tapped 30 minutes in; the save failed
        let model = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        for later in [1_801.0, 1_900, 3_600, 36_000] {
            XCTAssertEqual(w.activeElapsed(at: t(later)), 1_800, accuracy: 0.001, "the hero stays at the saved duration")
            XCTAssertEqual(model.elapsedText(at: t(later)), "30:00", "so does the Today card")
        }
        XCTAssertEqual(model.elapsedText(at: t(600)), "10:00", "before the freeze they read the live time")
        XCTAssertEqual(w.activeElapsed(at: t(600)), 600, accuracy: 0.001)
    }

    func testTheFrozenClockMatchesTheDurationTheRetrySaves() throws {
        let w = workout()
        XCTAssertTrue(w.setPaused(true, at: t(600)))
        XCTAssertTrue(w.setPaused(false, at: t(780)))   // three minutes paused
        w.freeze(at: t(1_800))
        XCTAssertEqual(w.activeElapsed(at: t(9_999)), w.pauseLedger.activeSeconds(
            from: start.timeIntervalSince1970, to: t(1_800).timeIntervalSince1970), accuracy: 0.001)
        XCTAssertEqual(w.activeElapsed(at: t(9_999)), 1_620, accuracy: 0.001, "27 minutes ran")
    }

    func testEndedWhilePausedTheClockStaysWhereThePauseBegan() throws {
        let w = workout()
        XCTAssertTrue(w.setPaused(true, at: t(900)))
        w.freeze(at: t(900))                           // an end while paused stops at the moment it was paused
        let model = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        XCTAssertEqual(model.elapsedText(at: t(5_000)), "15:00")
        XCTAssertEqual(w.activeElapsed(at: t(5_000)), 900, accuracy: 0.001)
    }

    func testAFreezeChangesTheModelSoTheCardRedrawsAndItCanBeLifted() throws {
        let w = workout()
        let live = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        w.freeze(at: t(60))
        let frozen = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        XCTAssertNotEqual(live, frozen)
        w.freeze(at: nil)                              // nothing to save: the workout carries on
        XCTAssertEqual(try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w)), live)
        XCTAssertEqual(w.activeElapsed(at: t(500)), 500, accuracy: 0.001)
    }

    /// The live figures use the flat paused grey whenever nothing is live: paused, or End was tried (saving, failed).
    func testTheFiguresAreStillWhilePausedAndOnceAFinishIsPendingAndLiveOtherwise() throws {
        let w = workout()
        XCTAssertFalse(w.isStill)
        XCTAssertTrue(w.setPaused(true, at: t(60)))
        XCTAssertTrue(w.isStill, "paused")
        XCTAssertTrue(w.setPaused(false, at: t(120)))
        XCTAssertFalse(w.isStill)
        w.freeze(at: t(300))
        XCTAssertTrue(w.isStill, "End was tried: ending, failed and nothing-to-save are all frozen")
        w.freeze(at: nil)
        XCTAssertFalse(w.isStill, "nothing to save: the workout carries on")
    }

    func testEveryPendingFinishSurfaceAgreesOnEnding() throws {
        let w = workout()
        XCTAssertFalse(w.isEnding)
        XCTAssertFalse(try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w)).isEnding)
        w.freeze(at: t(120))                           // End tried: the save is running or failed
        XCTAssertTrue(w.isEnding, "the live screen's eyebrow and hero")
        XCTAssertTrue(try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w)).isEnding, "Today's card")
        // Ended while paused: still ending, and the card still knows it is paused.
        let p = workout()
        XCTAssertTrue(p.setPaused(true, at: t(60)))
        p.freeze(at: t(60))
        let model = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: p))
        XCTAssertTrue(model.isEnding)
        XCTAssertTrue(model.isPaused)
        w.freeze(at: nil)
        XCTAssertFalse(w.isEnding, "a finish with nothing to save lifts it again")
    }

    /// Every live-workout indicator (Today's dot, the live screen's eyebrow, the Lock Screen card's eyebrow and the expanded
    /// island's) asks `NOOPLiveWorkoutPulse`, so none can pulse "recording" next to the Ending pill that another has stopped.
    func testNothingPulsesAsRecordingWhileEndingOrPaused() throws {
        let w = workout()
        let running = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        XCTAssertTrue(NOOPLiveWorkoutPulse.isActive(isPaused: running.isPaused, isEnding: running.isEnding))
        XCTAssertTrue(w.setPaused(true, at: t(60)))
        let paused = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        XCTAssertFalse(NOOPLiveWorkoutPulse.isActive(isPaused: paused.isPaused, isEnding: paused.isEnding))
        XCTAssertTrue(w.setPaused(false, at: t(90)))
        w.freeze(at: t(120))
        let ending = try XCTUnwrap(ActiveWorkoutIndicatorModel.make(from: w))
        XCTAssertFalse(NOOPLiveWorkoutPulse.isActive(isPaused: ending.isPaused, isEnding: ending.isEnding),
                       "Today's dot, with the Ending pill beside it")
        XCTAssertFalse(NOOPLiveWorkoutPulse.isActive(isPaused: false, isEnding: true, isStale: false),
                       "the island eyebrow")
        XCTAssertFalse(NOOPLiveWorkoutPulse.isActive(isPaused: false, isEnding: false, isStale: true),
                       "a card whose reading has gone stale is not news from a live strap")
    }
}
