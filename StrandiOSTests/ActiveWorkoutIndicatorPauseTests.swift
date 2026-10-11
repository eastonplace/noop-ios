import XCTest
import StrandAnalytics
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
}
