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

    /// A minimized, paused run must not read as one that is recording, and the number the bar shows is part of what it says.
    func testTheSpokenSummaryNamesThePausedStateAndTheMetric() {
        let running = WorkoutResumeBarState.spokenSummary(.running, sport: "Running", spokenElapsed: "12 minutes, 3 seconds",
                                                          spokenMetric: "5.49 kilometers")
        XCTAssertEqual(running, "Running, 12 minutes, 3 seconds, 5.49 kilometers")
        let paused = WorkoutResumeBarState.spokenSummary(.paused, sport: "Running", spokenElapsed: "12 minutes, 3 seconds",
                                                         spokenMetric: "5.49 kilometers")
        XCTAssertEqual(paused, "Running, \(String(localized: "Paused")), 12 minutes, 3 seconds, 5.49 kilometers")
    }

    func testTheSpokenSummaryLeavesOutAMetricThereIsNone() {
        XCTAssertEqual(WorkoutResumeBarState.spokenSummary(.running, sport: "Yoga", spokenElapsed: "1 minute", spokenMetric: nil),
                       "Yoga, 1 minute")
    }
}
