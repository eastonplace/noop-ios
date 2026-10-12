#if targetEnvironment(simulator)
import XCTest
import StrandAnalytics
@testable import NOOP

/// The model rules the journey stands on: when End would save, why Start would do nothing, what Done and Discard clear.
/// Fixture workouts (the demo scenarios) write nothing to disk.
@MainActor
final class AppModelWorkoutJourneyTests: XCTestCase {
    private func model(_ scenario: AppModel.DemoLiveWorkoutScenario) -> AppModel {
        let model = AppModel()
        model.seedDemoLiveWorkout(scenario)
        return model
    }

    // MARK: What End would do

    func testAWorkoutWithHeartRateWouldSave() {
        let m = model(.paused)
        XCTAssertTrue(m.workoutWouldSave)
    }

    func testARouteOnlyWorkoutWouldSave() {
        // A run with the strap quiet but a recorded route: seeded readings exist, so clear them to isolate the route.
        let m = model(.running)
        m.activeWorkout?.restore(samples: [], pauses: WorkoutPauseLedger())
        XCTAssertTrue(m.activeWorkoutIsGps)
        XCTAssertGreaterThanOrEqual(m.gpsRecorder.pointCount, 2)
        XCTAssertTrue(m.workoutWouldSave)
    }

    func testAWorkoutWithNeitherWouldNotSave() {
        let m = model(.pausedNothing)
        XCTAssertEqual(m.activeWorkout?.samples.count, 0)
        XCTAssertFalse(m.activeWorkoutIsGps)
        XCTAssertFalse(m.workoutWouldSave)
    }

    func testNoWorkoutWouldNotSaveEither() {
        XCTAssertFalse(AppModel().workoutWouldSave)
    }

    // MARK: Why Start would do nothing

    func testStartIsBlockedByAWorkoutAlreadyRecording() {
        XCTAssertNil(AppModel().workoutStartBlock)
        XCTAssertEqual(model(.running).workoutStartBlock, .workoutActive)
    }

    func testStartIsBlockedByALiftInProgress() {
        let m = AppModel()
        m.hasActiveReceiptLift = { true }
        XCTAssertEqual(m.workoutStartBlock, .liftActive)
        m.hasActiveReceiptLift = { false }
        XCTAssertNil(m.workoutStartBlock)
    }

    // MARK: The finish state

    func testNothingToSaveIsRecognisedAndAcknowledgingGoesBackToRecording() {
        let m = model(.nothingToSave)
        XCTAssertTrue(m.finishNeedsMoreEvidence)
        XCTAssertNotNil(m.activeWorkout, "it is still the workout in progress")
        m.acknowledgeFinishState()
        XCTAssertEqual(m.workoutFinishState, .recording)
        XCTAssertFalse(m.finishNeedsMoreEvidence)
    }

    func testAFailedSaveWaitingForARetryIsNotNothingToSaveAndAcknowledgingKeepsIt() {
        let m = model(.failed)
        XCTAssertTrue(m.isWorkoutFinishPending)
        XCTAssertFalse(m.finishNeedsMoreEvidence)
        m.acknowledgeFinishState()
        if case .failed = m.workoutFinishState {} else { XCTFail("the retry is still owed: \(m.workoutFinishState)") }
    }

    func testTheFinishAttemptChangesWhenTheStateReturnsToWhereEndCanBeAskedAgain() {
        let m = model(.nothingToSave)
        let before = m.finishAttemptID
        m.acknowledgeFinishState()
        XCTAssertNotEqual(m.finishAttemptID, before, "the hold button is rebuilt, so it can be held again")
    }

    // MARK: Discard

    func testDiscardClearsTheWorkoutAndEverythingPending() {
        let m = model(.failed)
        XCTAssertTrue(m.isWorkoutFinishPending)
        XCTAssertTrue(m.discardWorkout())
        XCTAssertNil(m.activeWorkout)
        XCTAssertNil(m.lastWorkout, "nothing was saved")
        XCTAssertFalse(m.isWorkoutFinishPending)
        XCTAssertEqual(m.workoutFinishState, .recording)
        XCTAssertFalse(m.activeWorkoutIsGps)
        XCTAssertFalse(m.workoutWouldSave)
        XCTAssertNil(m.workoutStartBlock, "a new workout can be started")
    }

    func testDiscardLeavesNothingToRestoreOnTheNextLaunch() {
        let m = model(.paused)
        XCTAssertTrue(m.discardWorkout())
        XCTAssertNil(ActiveWorkoutPersistence.load())
        XCTAssertNil(ActiveGpsWorkoutPersistence.load())
    }

    func testDiscardWithNothingRecordingDoesNothing() {
        XCTAssertFalse(AppModel().discardWorkout())
    }

    func testDiscardCannotBeCalledTwice() {
        let m = model(.paused)
        XCTAssertTrue(m.discardWorkout())
        XCTAssertFalse(m.discardWorkout())
    }
}
#endif
