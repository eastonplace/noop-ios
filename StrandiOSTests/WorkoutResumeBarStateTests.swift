import XCTest
@testable import NOOP

/// The resume bar's state, and what it allows.
final class WorkoutResumeBarStateTests: XCTestCase {
    private func make(paused: Bool = false, ending: Bool = false, finish: WorkoutFinishState = .recording,
                      pending: Bool = false) -> WorkoutResumeBarState {
        .make(isPaused: paused, isEnding: ending, finish: finish, finishPending: pending)
    }

    func testRunningAndPausedFollowTheWorkout() {
        XCTAssertEqual(make(), .running)
        XCTAssertEqual(make(paused: true), .paused)
    }

    func testASaveInProgressShowsSavingWhateverElseIsTrue() {
        XCTAssertEqual(make(paused: true, finish: .saving, pending: true), .saving)
    }

    func testAFailedPendingFinishShowsFailedAndOffersARetry() {
        XCTAssertEqual(make(finish: .failed("disk"), pending: true), .failed)
    }

    func testOnlyARunningOrPausedWorkoutCanBePausedOrResumedFromTheBar() {
        XCTAssertTrue(WorkoutResumeBarState.running.allowsPauseToggle)
        XCTAssertTrue(WorkoutResumeBarState.paused.allowsPauseToggle)
        XCTAssertFalse(WorkoutResumeBarState.saving.allowsPauseToggle)
        XCTAssertFalse(WorkoutResumeBarState.failed.allowsPauseToggle)
    }

    func testTheBarPulsesAsRecordingOnlyWhileItIsRecording() {
        XCTAssertTrue(WorkoutResumeBarState.running.pulses)
        XCTAssertFalse(WorkoutResumeBarState.paused.pulses)
        XCTAssertFalse(WorkoutResumeBarState.saving.pulses)
        XCTAssertFalse(WorkoutResumeBarState.failed.pulses)
        XCTAssertTrue(WorkoutResumeBarState.paused.isPausedLook)
        XCTAssertFalse(WorkoutResumeBarState.running.isPausedLook)
    }
}
