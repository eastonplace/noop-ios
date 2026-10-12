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

    // MARK: Nothing to save, then Keep recording

    /// End finds nothing to save: the workout carries on, so the route recorder must still be recording when it does.
    /// (It used to be stopped before the evidence check, and Keep recording resumed a workout that had no route.)
    func testAnEndWithNothingToSaveLeavesTheRouteRecorderRunning() async {
        let m = model(.running)
        m.activeWorkout?.restore(samples: [], pauses: WorkoutPauseLedger())
        m.gpsRecorder.seedDemoRoute(points: [], elapsedSeconds: 600, paused: true)
        XCTAssertTrue(m.activeWorkoutIsGps)
        XCTAssertTrue(m.gpsRecorder.isRecording)
        XCTAssertFalse(m.workoutWouldSave)

        let result = await m.endWorkout()
        guard case .failure(.insufficientEvidence) = result else { return XCTFail("expected nothing to save: \(result)") }
        XCTAssertTrue(m.finishNeedsMoreEvidence)
        XCTAssertTrue(m.gpsRecorder.isRecording, "Keep recording must find the recorder still recording")
        XCTAssertNotNil(m.activeWorkout)
    }

    func testResumingFromElsewhereClearsNothingToSaveSoPauseIsOfferedAgain() {
        let m = model(.nothingToSave)
        XCTAssertTrue(m.finishNeedsMoreEvidence)
        XCTAssertTrue(m.setWorkoutPaused(false), "the resume bar or the Lock Screen resumes it")
        XCTAssertFalse(m.finishNeedsMoreEvidence)
        XCTAssertEqual(m.workoutFinishState, .recording)
    }

    /// "Would this save" is the save's own rule: two points in ONE segment. Two fixes either side of a pause are two
    /// segments, and `capturedRoute()` drops both.
    func testTwoFixesInSeparateSegmentsWouldNotSave() {
        let m = model(.pausedNothing)
        m.activeWorkout?.restore(samples: [], pauses: WorkoutPauseLedger())
        m.gpsRecorder.seedDemoRoute(points: [RouteMath.LatLng(40.0, -73.0)], elapsedSeconds: 60, paused: true)
        XCTAssertEqual(m.gpsRecorder.pointCount, 1)
        XCTAssertFalse(m.gpsRecorder.hasDrawableRoute)
        XCTAssertFalse(m.workoutWouldSave)
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
