import SwiftUI
import XCTest
@testable import NOOP

/// The countdown can end exactly one way. Cancel (or the phone leaving the foreground) must really stop it, so the workout
/// cannot start afterwards, and it must not stop for a blip.
final class WorkoutCountdownStateTests: XCTestCase {
    func testItStartsCountingFromThree() {
        let state = WorkoutCountdownState()
        XCTAssertEqual(state.digit, 3)
        XCTAssertTrue(state.canStart)
    }

    func testFinishingStartsTheWorkoutOnceAndOnlyOnce() {
        var state = WorkoutCountdownState()
        XCTAssertTrue(state.finish())
        XCTAssertFalse(state.finish(), "a tap that races the last second does not start a second workout")
        XCTAssertFalse(state.cancel(), "it cannot be cancelled once it has started")
        XCTAssertFalse(state.canStart)
    }

    /// The bug: a Cancel did not mark the count as over, so the loop reached zero and started the workout behind setup.
    func testAfterCancelNothingCanStartTheWorkout() {
        var state = WorkoutCountdownState()
        state.show(2)
        XCTAssertTrue(state.cancel())
        XCTAssertFalse(state.canStart)
        XCTAssertFalse(state.finish(), "the count reaching zero, or a tap to skip, does nothing after Cancel")
        state.show(1)
        XCTAssertEqual(state.digit, 2, "a cancelled count does not move on")
        XCTAssertFalse(state.cancel(), "and cancels only once")
    }

    func testOnlyARealBackgroundTransitionCancels() {
        XCTAssertTrue(WorkoutCountdownState.cancels(on: .background))
        XCTAssertFalse(WorkoutCountdownState.cancels(on: .inactive), "Control Center or a banner is a blip, not leaving")
        XCTAssertFalse(WorkoutCountdownState.cancels(on: .active))
    }

    /// A quick start with the countdown turned off never mounts the countdown view: no "3", no haptic.
    func testTheCountdownViewIsMountedOnlyWhenTheCountdownIsOn() {
        XCTAssertTrue(WorkoutCountdown.mountsView(countdownOn: true))
        XCTAssertFalse(WorkoutCountdown.mountsView(countdownOn: false))
    }
}
