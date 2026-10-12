#if targetEnvironment(simulator)
import XCTest
import StrandAnalytics
import WhoopStore
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

    /// A workout that was really started writes its snapshot and its pause ledger; discarding must clear every one of them,
    /// or the next launch brings the workout back. (A fixture workout writes nothing, so it cannot prove this.)
    func testDiscardLeavesNothingToRestoreOnTheNextLaunch() {
        ActiveWorkoutPersistence.clear()
        ActiveGpsWorkoutPersistence.clear()
        ActiveWorkoutPauseStore.clear()
        addTeardownBlock { @MainActor in
            ActiveWorkoutPersistence.clear()
            ActiveGpsWorkoutPersistence.clear()
            ActiveWorkoutPauseStore.clear()
        }
        let m = AppModel()
        m.startWorkout(sport: "Strength Training")
        guard let workout = m.activeWorkout else { return XCTFail("the workout did not start") }
        XCTAssertTrue(m.setWorkoutPaused(true))
        XCTAssertNotNil(ActiveWorkoutPersistence.load(), "a started workout can be restored")
        XCTAssertNotNil(ActiveWorkoutPauseStore.load(sessionID: workout.sessionID), "so can its pause")

        XCTAssertTrue(m.discardWorkout())
        XCTAssertNil(ActiveWorkoutPersistence.load())
        XCTAssertNil(ActiveGpsWorkoutPersistence.load())
        XCTAssertNil(ActiveWorkoutPauseStore.load(sessionID: workout.sessionID))
    }

    func testDiscardIsRefusedWhileASaveIsRunning() {
        let m = model(.saving)
        XCTAssertEqual(m.workoutFinishState, .saving)
        XCTAssertFalse(m.discardWorkout())
        XCTAssertNotNil(m.activeWorkout, "the workout the save is writing is untouched")
        XCTAssertEqual(m.workoutFinishState, .saving)
    }

    /// The Lock Screen and Dynamic Island are rebuilt from the workout in flight and read this edge; a paused or
    /// nothing-to-save workout has no other reason to raise it on its way out, and its activity would stay up.
    func testDiscardTellsTheLockScreenTheWorkoutIsGone() {
        for scenario in [AppModel.DemoLiveWorkoutScenario.paused, .nothingToSave, .running] {
            let m = model(scenario)
            let before = m.workoutPauseEdge
            XCTAssertTrue(m.discardWorkout())
            XCTAssertGreaterThan(m.workoutPauseEdge, before, "\(scenario)")
        }
    }

    /// A save that failed after its row was written (the route's read-back failed): discarding takes the row back, so
    /// "Nothing will be saved" is true. The route and pause entries that were written with it go too.
    func testDiscardRemovesTheRouteAndPausesAFailedSaveAlreadyWrote() {
        let m = model(.failed)
        let key = AppModel.WorkoutRowKey(startTs: 1_000_000_007, sport: "Discard Test Sport")
        m.pendingWorkoutRowKey = key
        RouteStore.store(WorkoutRoute(segmentPolylines: [RouteMath.encode([RouteMath.LatLng(40.0, -73.0), RouteMath.LatLng(40.001, -73.0)])],
                                      distanceM: 111), startTs: key.startTs, sport: key.sport)
        WorkoutPauseStore.store(WorkoutPauseLedger(intervals: [.init(start: 10, end: 400)]), startTs: key.startTs, sport: key.sport)
        XCTAssertNotNil(WorkoutPauseStore.load(startTs: key.startTs, sport: key.sport))
        addTeardownBlock {
            RouteStore.remove(startTs: key.startTs, sport: key.sport)
            WorkoutPauseStore.remove(startTs: key.startTs, sport: key.sport)
        }
        XCTAssertNotNil(RouteStore.load(startTs: key.startTs, sport: key.sport))

        XCTAssertTrue(m.discardWorkout())
        XCTAssertNil(RouteStore.load(startTs: key.startTs, sport: key.sport))
        XCTAssertNil(WorkoutPauseStore.load(startTs: key.startTs, sport: key.sport))
        XCTAssertNil(m.pendingWorkoutRowKey)
    }

    /// The key of a row a failed save already wrote is kept on disk: after the app is closed and reopened, the restored workout
    /// is still the one whose row is in Workouts, and discarding it must take that row back.
    func testThePendingRowKeySurvivesARelaunch() {
        let suite = "noop.tests.rowkey.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(AppModel.loadPendingRowKey(from: defaults))
        let key = AppModel.WorkoutRowKey(startTs: 1_000_000_011, sport: "Rowing")
        AppModel.storePendingRowKey(key, in: defaults)
        XCTAssertEqual(AppModel.loadPendingRowKey(from: defaults), key)
        AppModel.storePendingRowKey(nil, in: defaults)
        XCTAssertNil(AppModel.loadPendingRowKey(from: defaults))
    }

    func testDiscardAfterARelaunchStillRemovesTheRowAFailedSaveWrote() {
        let key = AppModel.WorkoutRowKey(startTs: 1_000_000_013, sport: "Relaunch Discard Sport")
        model(.failed).pendingWorkoutRowKey = key          // the process that wrote it
        let relaunched = model(.failed)                      // a new process: nothing in memory
        XCTAssertEqual(relaunched.pendingWorkoutRowKey, key)
        RouteStore.store(WorkoutRoute(segmentPolylines: [RouteMath.encode([RouteMath.LatLng(40.0, -73.0), RouteMath.LatLng(40.001, -73.0)])],
                                      distanceM: 111), startTs: key.startTs, sport: key.sport)
        addTeardownBlock {
            AppModel.storePendingRowKey(nil, in: .standard)
            RouteStore.remove(startTs: key.startTs, sport: key.sport)
        }
        XCTAssertTrue(relaunched.discardWorkout())
        XCTAssertNil(RouteStore.load(startTs: key.startTs, sport: key.sport))
        XCTAssertNil(relaunched.pendingWorkoutRowKey)
    }

    /// A save that was written and read back is settled before `endWorkout` awaits its refresh. If the process dies in that
    /// await, the next launch must not restore the saved workout as one in flight with its row key still set: a Discard
    /// would then delete the verified row, its route and its pauses.
    func testAVerifiedSaveLeavesNothingADiscardAfterARelaunchCouldTakeBack() {
        ActiveWorkoutPersistence.clear()
        ActiveGpsWorkoutPersistence.clear()
        ActiveWorkoutPauseStore.clear()
        let key = AppModel.WorkoutRowKey(startTs: 1_000_000_017, sport: "Verified Save Sport")
        addTeardownBlock { @MainActor in
            ActiveWorkoutPersistence.clear()
            ActiveGpsWorkoutPersistence.clear()
            ActiveWorkoutPauseStore.clear()
            AppModel.storePendingRowKey(nil, in: .standard)
            RouteStore.remove(startTs: key.startTs, sport: key.sport)
            WorkoutPauseStore.remove(startTs: key.startTs, sport: key.sport)
        }
        let m = AppModel()
        m.startWorkout(sport: "Strength Training")
        guard let workout = m.activeWorkout else { return XCTFail("the workout did not start") }
        XCTAssertTrue(m.setWorkoutPaused(true))
        XCTAssertNotNil(ActiveWorkoutPersistence.load(), "a started workout can be restored")

        // What `endWorkout` has done by the time the read-back succeeds: the row is written (its key kept for a discard)
        // and its route and pauses are stored next to it.
        m.pendingWorkoutRowKey = key
        RouteStore.store(WorkoutRoute(segmentPolylines: [RouteMath.encode([RouteMath.LatLng(40.0, -73.0), RouteMath.LatLng(40.001, -73.0)])],
                                      distanceM: 111), startTs: key.startTs, sport: key.sport)
        WorkoutPauseStore.store(WorkoutPauseLedger(intervals: [.init(start: 10, end: 400)]), startTs: key.startTs, sport: key.sport)
        let saved = WorkoutRow(startTs: key.startTs, endTs: key.startTs + 1_800, sport: key.sport, source: "manual",
                               durationS: 1_800, energyKcal: nil, avgHr: 120, maxHr: 150, strain: 8.0, distanceM: 111,
                               zonesJSON: nil, notes: nil)
        m.commitVerifiedWorkoutSave(saved)

        // The app is sent to the background while the refresh is awaited: the suspension's flush writes nothing back.
        XCTAssertTrue(m.flushActiveWorkoutSnapshot())
        XCTAssertNil(ActiveWorkoutPersistence.load(), "nothing is left to restore as a workout in flight")
        XCTAssertNil(ActiveWorkoutPauseStore.load(sessionID: workout.sessionID))
        XCTAssertEqual(m.workoutFinishState, .saved(saved))

        // The process dies there. The next launch has no row key, so even a workout in flight discarded then (a fixture
        // here) leaves the saved row's route and pauses alone.
        let relaunched = model(.failed)
        XCTAssertNil(relaunched.pendingWorkoutRowKey)
        XCTAssertTrue(relaunched.discardWorkout())
        XCTAssertNotNil(RouteStore.load(startTs: key.startTs, sport: key.sport))
        XCTAssertNotNil(WorkoutPauseStore.load(startTs: key.startTs, sport: key.sport))
    }

    // MARK: Why the durability warning is up

    func testDataThatIsNotSafelyStoredIsTheRecoverabilityWarning() {
        let m = model(.durability)
        XCTAssertEqual(m.workoutDurabilityIssue, .notRecoverable)
        XCTAssertNotNil(m.workoutDurabilityWarning)
    }

    /// A restore after the app closed carries the same text slot, but it is not a warning that data is unsafe.
    func testARestoredGapIsNotReportedAsUnsafeData() {
        let m = model(.gpsGap)
        XCTAssertEqual(m.workoutDurabilityIssue, .gpsGapRestored)
        XCTAssertNotNil(m.workoutDurabilityWarning, "the explanation is still there to open")
        XCTAssertNotNil(m.gpsGapRestoredAt)
        XCTAssertNil(model(.running).workoutDurabilityIssue)
        _ = m.discardWorkout()
        XCTAssertNil(m.workoutDurabilityIssue)
        XCTAssertNil(m.gpsGapRestoredAt)
    }

    /// "GPS gap while closed" is said once for the workout: its window starts the first time the screen has the workout in
    /// front of the wearer, not again whenever the screen is reopened (the resume bar builds a new one each time), and only a
    /// real return from the background opens it again.
    func testTheGapNoticeWindowStartsOnceAndOnlyAForegroundReturnOpensItAgain() {
        let m = model(.gpsGap)
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(m.gpsGapNoticeShownAt)
        m.reopenGpsGapNoticeWindow(at: t0)
        XCTAssertNil(m.gpsGapNoticeShownAt, "never shown: there is nothing to open again")
        m.noteGpsGapNoticeOnScreen(at: t0)
        XCTAssertEqual(m.gpsGapNoticeShownAt, t0)
        m.noteGpsGapNoticeOnScreen(at: t0.addingTimeInterval(1_200))
        XCTAssertEqual(m.gpsGapNoticeShownAt, t0, "reopened twenty minutes later: the window is not started again")
        m.reopenGpsGapNoticeWindow(at: t0.addingTimeInterval(1_300))
        XCTAssertEqual(m.gpsGapNoticeShownAt, t0.addingTimeInterval(1_300), "back from the background")
        _ = m.discardWorkout()
        XCTAssertNil(m.gpsGapNoticeShownAt, "cleared with the gap")
        let plain = model(.running)
        plain.noteGpsGapNoticeOnScreen(at: t0)
        XCTAssertNil(plain.gpsGapNoticeShownAt, "a workout with no gap never opens a window")
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
