import CoreLocation
import XCTest
import StrandAnalytics
@testable import NOOP

/// A run keeps recording through a screen lock only if the recorder holds a CLBackgroundActivitySession while
/// updates run, releases it on stop, and re-arms CoreLocation when the app returns to the foreground. The
/// recorder takes its `CLLocationManager` and session factory as seams, so these tests drive it with a
/// subclassed manager and a session spy; no real CoreLocation service is touched.
@MainActor
final class GpsWorkoutRecorderBackgroundTests: XCTestCase {
    private final class SpyLocationManager: CLLocationManager {
        var status: CLAuthorizationStatus = .authorizedWhenInUse
        var accuracy: CLAccuracyAuthorization = .fullAccuracy
        private(set) var startCount = 0
        private(set) var stopCount = 0
        private(set) var authorizationRequests = 0

        override var authorizationStatus: CLAuthorizationStatus { status }
        override var accuracyAuthorization: CLAccuracyAuthorization { accuracy }
        override func startUpdatingLocation() { startCount += 1 }
        override func stopUpdatingLocation() { stopCount += 1 }
        override func requestWhenInUseAuthorization() { authorizationRequests += 1 }
        override class func locationServicesEnabled() -> Bool { true }
    }

    private final class SessionSpy: GpsBackgroundActivity {
        private(set) var invalidated = false
        func invalidate() { invalidated = true }
    }

    private final class SessionLedger {
        private(set) var sessions: [SessionSpy] = []
        func make() -> GpsBackgroundActivity? {
            let session = SessionSpy()
            sessions.append(session)
            return session
        }
        var live: [SessionSpy] { sessions.filter { !$0.invalidated } }
    }

    private func makeRecorder(
        status: CLAuthorizationStatus = .authorizedWhenInUse,
        accuracy: CLAccuracyAuthorization = .fullAccuracy
    ) -> (recorder: GpsWorkoutRecorder, manager: SpyLocationManager, ledger: SessionLedger) {
        let manager = SpyLocationManager()
        manager.status = status
        manager.accuracy = accuracy
        let ledger = SessionLedger()
        let recorder = GpsWorkoutRecorder(manager: manager, makeBackgroundActivity: { ledger.make() })
        return (recorder, manager, ledger)
    }

    private func restorableSnapshot(recordingWasActive: Bool) -> ActiveGpsWorkoutPersistence.Snapshot {
        ActiveGpsWorkoutPersistence.Snapshot(
            sessionID: UUID(),
            workoutStartMs: 1_700_000_000_000,
            segments: [],
            distanceM: 0,
            rawFixCount: 0,
            recordingWasActive: recordingWasActive,
            hadTerminatedGap: false
        )
    }

    // MARK: Session lifetime

    func testStartHoldsOneSessionUntilStop() {
        let (recorder, manager, ledger) = makeRecorder()

        recorder.start(startMs: 1_700_000_000_000)
        XCTAssertEqual(manager.startCount, 1)
        XCTAssertEqual(ledger.live.count, 1)

        recorder.stop()
        XCTAssertTrue(ledger.live.isEmpty)
        XCTAssertEqual(ledger.sessions.count, 1)
    }

    func testRestartingAnArmedRecorderReleasesTheOldSession() {
        let (recorder, _, ledger) = makeRecorder()

        recorder.start(startMs: 1_700_000_000_000)
        recorder.start(startMs: 1_700_000_100_000)

        XCTAssertEqual(ledger.sessions.count, 2)
        XCTAssertEqual(ledger.live.count, 1)
    }

    func testFirstRunGrantStartsUpdatesAndTheSessionOnceAuthorizationArrives() {
        let (recorder, manager, ledger) = makeRecorder(status: .notDetermined)

        recorder.start(startMs: 1_700_000_000_000)
        XCTAssertEqual(manager.authorizationRequests, 1)
        XCTAssertEqual(manager.startCount, 0)
        XCTAssertTrue(ledger.sessions.isEmpty)

        manager.status = .authorizedWhenInUse
        recorder.locationManagerDidChangeAuthorization(manager)
        XCTAssertEqual(manager.startCount, 1)
        XCTAssertEqual(ledger.live.count, 1)
    }

    func testDeniedPermissionStartsNothingAndHoldsNoSession() {
        let (recorder, manager, ledger) = makeRecorder(status: .denied)

        recorder.start(startMs: 1_700_000_000_000)

        XCTAssertEqual(manager.startCount, 0)
        XCTAssertTrue(ledger.sessions.isEmpty)
    }

    func testRevokedPermissionMidRunReleasesTheSession() {
        let (recorder, manager, ledger) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)

        manager.status = .denied
        recorder.locationManagerDidChangeAuthorization(manager)

        XCTAssertGreaterThanOrEqual(manager.stopCount, 1)
        XCTAssertTrue(ledger.live.isEmpty)
    }

    func testAuthorizationCallbackNeverReplacesAnExistingSession() {
        let (recorder, manager, ledger) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)

        // iOS can deliver this callback while backgrounded; a replacement made there would start inactive.
        recorder.locationManagerDidChangeAuthorization(manager)

        XCTAssertEqual(ledger.sessions.count, 1)
        XCTAssertEqual(ledger.live.count, 1)
    }

    // MARK: Foreground re-arm

    func testResumeIsANoOpWhenNothingIsRecording() {
        let (recorder, manager, ledger) = makeRecorder()

        recorder.resumeUpdatesIfNeeded()

        XCTAssertEqual(manager.startCount, 0)
        XCTAssertTrue(ledger.sessions.isEmpty)
    }

    func testResumeRearmsUpdatesAndRenewsTheSessionWithoutAGap() {
        let (recorder, manager, ledger) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)

        recorder.resumeUpdatesIfNeeded()

        XCTAssertEqual(manager.startCount, 2)
        XCTAssertEqual(ledger.sessions.count, 2)
        XCTAssertTrue(ledger.sessions[0].invalidated)
        XCTAssertFalse(ledger.sessions[1].invalidated)
    }

    func testResumeDoesNotStartUpdatesWithoutPermission() {
        let (recorder, manager, _) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        manager.status = .denied

        recorder.resumeUpdatesIfNeeded()

        XCTAssertEqual(manager.startCount, 1)
    }

    func testResumeAfterStopDoesNothing() {
        let (recorder, manager, ledger) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        recorder.stop()

        recorder.resumeUpdatesIfNeeded()

        XCTAssertEqual(manager.startCount, 1)
        XCTAssertTrue(ledger.live.isEmpty)
    }

    // MARK: Relaunch restore

    func testRestoringAnActiveRecordingRearmsUpdatesAndTheSession() {
        let (recorder, manager, ledger) = makeRecorder()

        recorder.restore(restorableSnapshot(recordingWasActive: true))

        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(manager.startCount, 1)
        XCTAssertEqual(ledger.live.count, 1)
    }

    func testRestoringAFinishedRecordingStartsNothing() {
        let (recorder, manager, ledger) = makeRecorder()

        recorder.restore(restorableSnapshot(recordingWasActive: false))

        XCTAssertFalse(recorder.isRecording)
        XCTAssertEqual(manager.startCount, 0)
        XCTAssertTrue(ledger.sessions.isEmpty)
    }

    // MARK: Reduced accuracy and failures

    func testReducedAccuracyIsFlaggedWhileRecordingAndClearedOnStop() {
        let (recorder, _, _) = makeRecorder(accuracy: .reducedAccuracy)
        XCTAssertFalse(recorder.isReducedAccuracy)

        recorder.start(startMs: 1_700_000_000_000)
        XCTAssertTrue(recorder.isReducedAccuracy)

        recorder.stop()
        XCTAssertFalse(recorder.isReducedAccuracy)
    }

    func testFullAccuracyIsNotFlagged() {
        let (recorder, _, _) = makeRecorder(accuracy: .fullAccuracy)
        recorder.start(startMs: 1_700_000_000_000)
        XCTAssertFalse(recorder.isReducedAccuracy)
    }

    func testLocationErrorsAreLoggedAndNeverTearDownTheRun() {
        let key = "testcentre.active." + TestDomain.workouts.id
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }

        let (recorder, manager, ledger) = makeRecorder()
        var lines: [String] = []
        recorder.workoutsLog = { lines.append($0) }
        recorder.start(startMs: 1_700_000_000_000)

        recorder.locationManager(manager, didFailWithError: CLError(.locationUnknown))

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].contains("locationError"), lines[0])
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(ledger.live.count, 1)
    }
}
