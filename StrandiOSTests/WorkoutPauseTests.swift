import CoreLocation
import HealthKit
import XCTest
import StrandAnalytics
import WhoopProtocol
import WhoopStore
@testable import NOOP

/// Pause and resume for a live cardio workout: the timer stands still, paused heart-rate readings and GPS fixes are
/// not counted anywhere, the state survives a relaunch, and toggling twice changes nothing.
@MainActor
final class WorkoutPauseTests: XCTestCase {

    // MARK: Helpers

    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private let profile = UserProfile(weightKg: 78, heightCm: 181, age: 31, sex: "male")

    private func workout(withEnergy: Bool = true) -> AppModel.ActiveWorkout {
        AppModel.ActiveWorkout(start: start, sport: "Running", maxHR: 190,
                               energyProfile: withEnergy ? profile : nil)
    }

    private func t(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    /// One reading a second from `from` to `to` seconds after the start.
    private func feed(_ workout: AppModel.ActiveWorkout, from: Int, to: Int, bpm: Int) {
        for second in from...to {
            workout.ingest(HRSample(ts: 1_700_000_000 + second, bpm: bpm))
        }
    }

    private func ephemeralDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "noop.tests.pause.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    // MARK: Elapsed time excludes pauses

    func testElapsedTimeStandsStillWhilePausedAndExcludesPausesAfterwards() {
        let w = workout()
        XCTAssertEqual(w.activeElapsed(at: t(600)), 600, accuracy: 0.001)

        XCTAssertTrue(w.setPaused(true, at: t(600)))
        XCTAssertEqual(w.activeElapsed(at: t(600)), 600, accuracy: 0.001)
        XCTAssertEqual(w.activeElapsed(at: t(900)), 600, accuracy: 0.001, "the timer is frozen while paused")
        XCTAssertEqual(w.activeElapsed(at: t(5_000)), 600, accuracy: 0.001)

        XCTAssertTrue(w.setPaused(false, at: t(900)))
        XCTAssertEqual(w.activeElapsed(at: t(960)), 660, accuracy: 0.001, "300 s of pause are not in the elapsed time")
    }

    // MARK: Idempotent toggles

    func testPausingTwiceAndResumingTwiceChangeNothing() {
        let w = workout()
        XCTAssertFalse(w.setPaused(false, at: t(10)), "resume while running does nothing")
        XCTAssertTrue(w.setPaused(true, at: t(100)))
        let paused = w.pauseLedger
        XCTAssertFalse(w.setPaused(true, at: t(140)), "a double-tapped Pause does nothing")
        XCTAssertEqual(w.pauseLedger, paused)
        XCTAssertTrue(w.setPaused(false, at: t(200)))
        let resumed = w.pauseLedger
        XCTAssertFalse(w.setPaused(false, at: t(260)), "a double-tapped Resume does nothing")
        XCTAssertEqual(w.pauseLedger, resumed)
        XCTAssertEqual(w.pauseLedger.intervals.count, 1)
        XCTAssertEqual(w.activeElapsed(at: t(300)), 200, accuracy: 0.001)
    }

    // MARK: Heart-rate stats exclude paused windows

    func testSameSecondCorrectionKeepsLiveEnergyEqualToCanonicalReplay() {
        let live = workout()
        XCTAssertTrue(live.ingest(HRSample(ts: 1_700_000_001, bpm: 100)))
        XCTAssertTrue(live.ingest(HRSample(ts: 1_700_000_001, bpm: 220)))
        XCTAssertTrue(live.ingest(HRSample(ts: 1_700_000_151, bpm: 100)))
        let restored = workout()
        restored.restore(samples: live.samples)

        XCTAssertEqual(live.samples.count, 2)
        XCTAssertEqual(live.liveCalories, restored.liveCalories,
                       "a corrected tail must supply the next interval's calorie rate")
        XCTAssertEqual(live.liveStrainState, restored.liveStrainState)
    }

    func testPausedReadingsAreNotCountedButTheLiveNumberStillShows() {
        let w = workout()
        feed(w, from: 1, to: 100, bpm: 150)
        w.setPaused(true, at: t(100.5))
        feed(w, from: 101, to: 200, bpm: 70)          // the strap keeps reading through the pause
        XCTAssertEqual(w.samples.count, 100)
        XCTAssertEqual(w.avgHr, 150)
        XCTAssertEqual(w.peakHr, 150)
        XCTAssertEqual(w.currentBPM, 70, "the screen still shows the live number")
        XCTAssertNotNil(w.lastReadingAt)

        w.setPaused(false, at: t(200.5))
        feed(w, from: 201, to: 300, bpm: 160)
        XCTAssertEqual(w.samples.count, 200)
        XCTAssertEqual(w.avgHr, 155)
        XCTAssertEqual(w.peakHr, 160)
    }

    func testLiveStrainCreditsNothingAcrossAPause() throws {
        let w = workout()
        feed(w, from: 1, to: 1_500, bpm: 165)
        w.setPaused(true, at: t(1_500.5))
        w.setPaused(false, at: t(1_560.5))            // 60 s, under the scorer's 90 s interval limit
        feed(w, from: 1_561, to: 3_060, bpm: 165)

        let stretches = w.pauseLedger.segments(of: w.samples)
        XCTAssertEqual(stretches.count, 2)
        let batch = try XCTUnwrap(StrainScorerV2.activityStrain(segments: stretches, maxHR: 190))
        guard case .scored(let live) = w.liveStrainState else { return XCTFail("expected a score") }
        XCTAssertEqual(live, batch, accuracy: 1e-9, "the live score equals the saved one")
        let credited = try XCTUnwrap(StrainScorerV2.strain(w.samples, maxHR: 190, mode: .activity))
        XCTAssertLessThan(live, credited, "the plain scorer would credit the 60 s hole")
    }

    func testFinishScoresStrainAndCaloriesWithoutThePause() throws {
        let readings = (1...1_500).map { HRSample(ts: 1_700_000_000 + $0, bpm: 165) }
            + (1_561...3_060).map { HRSample(ts: 1_700_000_000 + $0, bpm: 165) }
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: 1_700_000_000 + 1_500.5)
        ledger.resume(at: 1_700_000_000 + 1_560.5)
        let end = t(3_060)

        let paused = ManualWorkoutScoring.score(samples: readings, pauses: ledger, start: start, end: end,
                                                maxHR: 190, profile: profile)
        let ignoring = ManualWorkoutScoring.score(samples: readings, pauses: WorkoutPauseLedger(),
                                                  start: start, end: end, maxHR: 190, profile: profile)
        XCTAssertEqual(paused.durationS, 3_060 - 60, accuracy: 0.001, "duration is the time it ran")
        XCTAssertEqual(ignoring.durationS, 3_060, accuracy: 0.001)
        XCTAssertLessThan(try XCTUnwrap(paused.strain), try XCTUnwrap(ignoring.strain))
        XCTAssertLessThan(paused.kcal, ignoring.kcal)
    }

    func testUnpausedWorkoutScoresExactlyAsBefore() throws {
        let readings = (1...1_200).map { HRSample(ts: 1_700_000_000 + $0, bpm: 150) }
        let scored = ManualWorkoutScoring.score(samples: readings, pauses: WorkoutPauseLedger(), start: start,
                                                end: t(1_200), maxHR: 190, profile: profile)
        XCTAssertEqual(scored.strain, StrainScorerV2.strain(readings, maxHR: 190, mode: .activity))
        XCTAssertEqual(scored.kcal,
                       Calories.estimateBoutCalories(readings, profile: profile, hrmax: 190, restingHR: nil).0)
        XCTAssertEqual(scored.durationS, 1_200, accuracy: 0.001)
    }

    func testLiveEnergyLeavesAPauseOut() throws {
        let w = workout()
        feed(w, from: 1, to: 600, bpm: 160)
        w.setPaused(true, at: t(600.5))
        w.setPaused(false, at: t(700.5))
        feed(w, from: 701, to: 1_300, bpm: 160)
        let live = try XCTUnwrap(w.liveCalories)
        let expected = Calories.estimateBoutCalories(
            segments: w.pauseLedger.segments(of: w.samples), profile: profile, hrmax: 190, restingHR: nil).0
        XCTAssertEqual(Double(live), expected, accuracy: 1.0)
    }

    // MARK: Relaunch

    func testPauseStateSurvivesARelaunch() throws {
        let defaults = ephemeralDefaults()
        let w = workout()
        feed(w, from: 1, to: 300, bpm: 150)
        w.setPaused(true, at: t(300.5))
        w.setPaused(false, at: t(360.5))
        feed(w, from: 361, to: 500, bpm: 155)
        w.setPaused(true, at: t(500.5))               // paused again when iOS ends the app
        ActiveWorkoutPauseStore.store(w.pauseLedger, sessionID: w.sessionID, in: defaults)

        // Relaunch: a new process rebuilds the session from the durable samples and the stored pauses.
        let reloaded = try XCTUnwrap(ActiveWorkoutPauseStore.load(sessionID: w.sessionID, from: defaults))
        let restored = AppModel.ActiveWorkout(sessionID: w.sessionID, start: start, sport: "Running",
                                              maxHR: 190, energyProfile: profile)
        restored.restore(samples: w.samples, pauses: reloaded)

        XCTAssertTrue(restored.isPaused)
        XCTAssertEqual(restored.pauseLedger, w.pauseLedger)
        XCTAssertEqual(restored.activeElapsed(at: t(9_000)), w.activeElapsed(at: t(9_000)), accuracy: 0.001)
        XCTAssertEqual(restored.activeElapsed(at: t(9_000)), 500.5 - 60, accuracy: 0.001)
        XCTAssertEqual(restored.avgHr, w.avgHr)
        XCTAssertEqual(restored.peakHr, w.peakHr)
        XCTAssertEqual(restored.liveStrainState, w.liveStrainState)
        XCTAssertEqual(restored.liveCalories, w.liveCalories)

        // Resuming after the relaunch starts a fresh stretch: nothing is credited back to the last restored reading.
        XCTAssertTrue(restored.setPaused(false, at: t(900.5)))
        restored.ingest(HRSample(ts: 1_700_000_901, bpm: 150))
        XCTAssertEqual(restored.pauseLedger.segments(of: restored.samples).count, 3)
    }

    /// A workout restored while paused ends its zone stretch like its strain stretch: the first reading after the resume is not
    /// credited for the time since the last reading before the pause.
    func testARestoredPausedWorkoutDoesNotCreditTheGapToTheFirstReadingAfterResume() {
        let w = workout()
        feed(w, from: 1, to: 300, bpm: 150)
        w.setPaused(true, at: t(300.5))
        let restored = AppModel.ActiveWorkout(sessionID: w.sessionID, start: start, sport: "Running",
                                              maxHR: 190, energyProfile: profile)
        restored.restore(samples: w.samples, pauses: w.pauseLedger)
        let before = restored.personalZoneSeconds.reduce(0, +)
        XCTAssertGreaterThan(before, 0)
        XCTAssertTrue(restored.setPaused(false, at: t(900.5)))
        restored.ingest(HRSample(ts: 1_700_000_901, bpm: 150))
        XCTAssertEqual(restored.personalZoneSeconds.reduce(0, +), before, "the first reading after the pause starts a stretch")
        restored.ingest(HRSample(ts: 1_700_000_906, bpm: 150))
        XCTAssertEqual(restored.personalZoneSeconds.reduce(0, +), before + 5, "and the next one is credited as usual")
    }

    func testAStoredLedgerBelongsToItsSessionOnly() {
        let defaults = ephemeralDefaults()
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: 100)
        let session = UUID()
        ActiveWorkoutPauseStore.store(ledger, sessionID: session, in: defaults)
        XCTAssertEqual(ActiveWorkoutPauseStore.load(sessionID: session, from: defaults), ledger)
        XCTAssertNil(ActiveWorkoutPauseStore.load(sessionID: UUID(), from: defaults))
        ActiveWorkoutPauseStore.clear(in: defaults)
        XCTAssertNil(ActiveWorkoutPauseStore.load(sessionID: session, from: defaults))
    }

    func testAWorkoutNeverPausedStoresNothing() {
        let defaults = ephemeralDefaults()
        ActiveWorkoutPauseStore.store(WorkoutPauseLedger(), sessionID: UUID(), in: defaults)
        XCTAssertNil(defaults.data(forKey: ActiveWorkoutPauseStore.defaultsKey))
    }

    // MARK: A finished workout keeps its pauses

    private func pauseTestRow(start: Int, end: Int, sport: String) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: end, sport: sport, source: "manual", durationS: nil, energyKcal: nil,
                   avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil, strainVersion: nil)
    }

    func testFinishedWorkoutPausesRoundTripAndFollowTheWorkout() {
        let defaults = ephemeralDefaults()
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: 1_000)
        ledger.resume(at: 1_090)
        WorkoutPauseStore.store(ledger, startTs: 900, sport: "Running", into: defaults)

        XCTAssertEqual(WorkoutPauseStore.load(startTs: 900, sport: "Running", from: defaults)?.intervals, ledger.intervals)
        XCTAssertEqual(WorkoutPauseStore.load(startTs: 900, from: defaults)?.intervals, ledger.intervals)
        XCTAssertNil(WorkoutPauseStore.load(startTs: 900, sport: "Cycling", from: defaults))

        WorkoutPauseStore.follow(fromStartTs: 900, fromSport: "Running", to: pauseTestRow(start: 900, end: 1_200, sport: "Hiking"),
                                 in: defaults)
        XCTAssertNil(WorkoutPauseStore.load(startTs: 900, sport: "Running", from: defaults))
        XCTAssertEqual(WorkoutPauseStore.load(startTs: 900, sport: "Hiking", from: defaults)?.intervals, ledger.intervals)

        WorkoutPauseStore.remove(startTs: 900, sport: "Hiking", from: defaults)
        XCTAssertNil(WorkoutPauseStore.load(startTs: 900, from: defaults))
    }

    func testMovingAWorkoutOntoItsOwnKeyKeepsItsPauses() {
        let defaults = ephemeralDefaults()
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: 10)
        ledger.resume(at: 80)
        WorkoutPauseStore.store(ledger, startTs: 5, sport: "Running", into: defaults)
        WorkoutPauseStore.follow(fromStartTs: 5, fromSport: "Running", to: pauseTestRow(start: 5, end: 100, sport: "Running"),
                                 in: defaults)
        XCTAssertNotNil(WorkoutPauseStore.load(startTs: 5, sport: "Running", from: defaults))
    }

    func testAnUnpausedWorkoutAddsNoEntry() {
        let defaults = ephemeralDefaults()
        WorkoutPauseStore.store(WorkoutPauseLedger(), startTs: 1, sport: "Running", into: defaults)
        XCTAssertTrue(WorkoutPauseStore.loadMap(from: defaults).isEmpty)
    }

    func testACorruptStoredMapIsCleanedNotTrusted() {
        let json = #"{"900|Running":[{"start":100,"end":50},{"start":40,"end":60}],"1|Run":[]}"#
        let map = WorkoutPauseStore.decodeMap(Data(json.utf8))
        XCTAssertEqual(map["900|Running"]?.count, 1)
        XCTAssertNil(map["1|Run"])
        XCTAssertTrue(WorkoutPauseStore.decodeMap(Data("nope".utf8)).isEmpty)
    }

    // MARK: Health events

    func testHealthGetsPairedPauseAndResumeEventsInsideTheWorkout() {
        var ledger = WorkoutPauseLedger()
        ledger.pause(at: 1_700_000_100)
        ledger.resume(at: 1_700_000_160)
        ledger.pause(at: 1_700_000_300)
        ledger.resume(at: 1_700_000_300.4)            // under a second: dropped
        ledger.pause(at: 1_700_009_000)
        ledger.resume(at: 1_700_009_100)              // outside the workout: dropped
        let events = HealthKitBridge.workoutPauseEvents(
            ledger, start: Date(timeIntervalSince1970: 1_700_000_000), end: Date(timeIntervalSince1970: 1_700_000_600))
        XCTAssertEqual(events.map(\.type), [.pause, .resume])
        XCTAssertEqual(events.map { $0.dateInterval.start.timeIntervalSince1970 }, [1_700_000_100, 1_700_000_160])
    }

    func testAnUnpausedWorkoutSendsHealthNoEvents() {
        XCTAssertTrue(HealthKitBridge.workoutPauseEvents(
            nil, start: start, end: t(60)).isEmpty)
        XCTAssertTrue(HealthKitBridge.workoutPauseEvents(
            WorkoutPauseLedger(), start: start, end: t(60)).isEmpty)
    }
}

// MARK: - GPS

@MainActor
final class GpsPauseTests: XCTestCase {
    private final class SpyLocationManager: CLLocationManager {
        var status: CLAuthorizationStatus = .authorizedWhenInUse
        private(set) var startCount = 0
        private(set) var stopCount = 0
        override var authorizationStatus: CLAuthorizationStatus { status }
        override var accuracyAuthorization: CLAccuracyAuthorization { .fullAccuracy }
        override func startUpdatingLocation() { startCount += 1 }
        override func stopUpdatingLocation() { stopCount += 1 }
        override class func locationServicesEnabled() -> Bool { true }
    }

    private final class SessionSpy: GpsBackgroundActivity {
        private(set) var invalidated = false
        func invalidate() { invalidated = true }
    }

    private final class SessionLedger {
        private(set) var sessions: [SessionSpy] = []
        func make() -> GpsBackgroundActivity? { let s = SessionSpy(); sessions.append(s); return s }
        var live: [SessionSpy] { sessions.filter { !$0.invalidated } }
    }

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)
    private var second = 0

    private func makeRecorder() -> (GpsWorkoutRecorder, SpyLocationManager, SessionLedger) {
        let manager = SpyLocationManager()
        let ledger = SessionLedger()
        let recorder = GpsWorkoutRecorder(manager: manager, makeBackgroundActivity: { ledger.make() })
        return (recorder, manager, ledger)
    }

    /// A fix `seconds` after the previous one, `metres` north of `lat`, healthy accuracy.
    private func fix(_ lat: Double, lon: Double = -73.9855) -> CLLocation {
        second += 1
        return CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            timestamp: origin.addingTimeInterval(TimeInterval(second)))
    }

    private func deliver(_ recorder: GpsWorkoutRecorder, _ manager: CLLocationManager, _ locations: CLLocation...) {
        recorder.locationManager(manager, didUpdateLocations: locations)
    }

    /// 0.00008 degrees of latitude is about 8.9 m: under the filter's 12 m/s speed gate at one fix a second.
    private func lat(_ step: Int, from base: Double = 40.7580) -> Double { base + Double(step) * 0.00008 }

    func testDistanceExcludesFixesDeliveredWhilePaused() {
        let (recorder, manager, _) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        deliver(recorder, manager, fix(lat(0)), fix(lat(1)), fix(lat(2)))
        let before = recorder.distanceM
        let pointsBefore = recorder.pointCount
        XCTAssertGreaterThan(before, 15)

        recorder.setPaused(true)
        deliver(recorder, manager, fix(lat(3)), fix(lat(4)), fix(lat(5)), fix(lat(6)))
        XCTAssertEqual(recorder.distanceM, before, "no distance while paused")
        XCTAssertEqual(recorder.pointCount, pointsBefore, "no points while paused")
        XCTAssertEqual(recorder.routePoints.count, pointsBefore)
    }

    /// One fix before a pause and one after are two segments of one point each: a route of two points that was never
    /// joined. The save drops both, so "a route was recorded" must not count them.
    func testFixesEitherSideOfAPauseAreNotADrawableRoute() {
        let (recorder, manager, _) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        deliver(recorder, manager, fix(lat(0)))
        recorder.setPaused(true)
        recorder.setPaused(false)
        deliver(recorder, manager, fix(lat(40)))
        XCTAssertEqual(recorder.pointCount, 2)
        XCTAssertEqual(recorder.routeSegments.map(\.count), [1, 1])
        XCTAssertFalse(recorder.hasDrawableRoute)
        XCTAssertNil(recorder.capturedRoute())

        deliver(recorder, manager, fix(lat(41)))
        XCTAssertTrue(recorder.hasDrawableRoute)
        XCTAssertNotNil(recorder.capturedRoute())
    }

    func testResumeNeverBridgesTheGapWithADistanceOrALine() {
        let (recorder, manager, _) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        deliver(recorder, manager, fix(lat(0)), fix(lat(1)), fix(lat(2)))
        let before = recorder.distanceM

        recorder.setPaused(true)
        recorder.setPaused(false)
        // The person walked a long way while paused; the first fix after resuming lands far from the last one.
        let far = 40.7580 + 0.01
        deliver(recorder, manager, fix(far))
        XCTAssertEqual(recorder.distanceM, before, accuracy: 0.001, "the move while paused is not distance")
        XCTAssertEqual(recorder.routeSegments.count, 2, "the route restarts as its own segment")

        deliver(recorder, manager, fix(lat(1, from: far)), fix(lat(2, from: far)))
        XCTAssertGreaterThan(recorder.distanceM, before + 15)
        XCTAssertEqual(recorder.routeSegments.count, 2)
        XCTAssertEqual(recorder.routeSegments[0].count, 3)
    }

    func testPausingKeepsLocationUpdatesAndTheBackgroundSessionAlive() {
        let (recorder, manager, ledger) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        XCTAssertEqual(manager.startCount, 1)

        recorder.setPaused(true)
        XCTAssertTrue(recorder.isPaused)
        XCTAssertTrue(recorder.isRecording)
        XCTAssertEqual(manager.stopCount, 0, "a locked phone must still be able to resume")
        XCTAssertEqual(ledger.live.count, 1)

        recorder.setPaused(false)
        XCTAssertFalse(recorder.isPaused)
        XCTAssertEqual(manager.stopCount, 0)
        XCTAssertEqual(ledger.live.count, 1)
        XCTAssertEqual(ledger.sessions.count, 1)
    }

    func testRecorderPauseToggleIsIdempotent() {
        let (recorder, manager, _) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        deliver(recorder, manager, fix(lat(0)), fix(lat(1)))
        recorder.setPaused(true)
        recorder.setPaused(true)
        XCTAssertTrue(recorder.isPaused)
        recorder.setPaused(false)
        recorder.setPaused(false)
        XCTAssertFalse(recorder.isPaused)
        deliver(recorder, manager, fix(lat(2)), fix(lat(3)))
        XCTAssertEqual(recorder.routeSegments.count, 2, "one resume, one new segment")
    }

    func testPausingAnIdleRecorderDoesNothing() {
        let (recorder, _, _) = makeRecorder()
        recorder.setPaused(true)
        XCTAssertFalse(recorder.isPaused)
    }

    func testStopClearsThePause() {
        let (recorder, _, _) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        recorder.setPaused(true)
        recorder.stop()
        XCTAssertFalse(recorder.isPaused)
        XCTAssertFalse(recorder.isRecording)
    }

    func testPaceUsesTheTimeTheWorkoutRan() throws {
        let (recorder, manager, _) = makeRecorder()
        recorder.activeElapsedProvider = { 100 }
        recorder.start(startMs: 1_700_000_000_000)
        deliver(recorder, manager, fix(lat(0)), fix(lat(1)), fix(lat(2)))
        let pace = try XCTUnwrap(recorder.paceSecPerKm)
        XCTAssertEqual(pace, 100 / (recorder.distanceM / 1000), accuracy: 0.001)
    }

    func testARestoredPausedRecorderStillDropsFixes() {
        let (recorder, manager, ledger) = makeRecorder()
        recorder.restore(ActiveGpsWorkoutPersistence.Snapshot(
            sessionID: UUID(), workoutStartMs: 1_700_000_000_000, segments: [], distanceM: 0, rawFixCount: 0,
            recordingWasActive: true, hadTerminatedGap: false))
        recorder.setPaused(true)
        deliver(recorder, manager, fix(lat(0)), fix(lat(1)))
        XCTAssertEqual(recorder.pointCount, 0)
        XCTAssertEqual(ledger.live.count, 1, "the session was re-armed on restore and stays")
    }

    // MARK: Signal

    func testSignalIsSearchingUntilTheFirstFixThenQuiet() {
        let (recorder, manager, _) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        XCTAssertEqual(recorder.signalState(now: Date()), .ok, "still within the wait for a first fix")
        XCTAssertEqual(recorder.signalState(now: Date().addingTimeInterval(45)), .searching)
        deliver(recorder, manager, fix(lat(0)), fix(lat(1)))
        XCTAssertEqual(recorder.signalState(now: Date().addingTimeInterval(600)), .ok,
                       "standing still delivers no fixes, which is not a fault")
        recorder.setPaused(true)
        XCTAssertEqual(recorder.signalState(now: Date().addingTimeInterval(600)), .paused)
    }

    /// Fixes keep arriving during a pause (the person walked to a fountain). They are not accepted into the route, so if the
    /// recorder noted them as raw fixes, the first reading after the resume would see "fixes arrived, none accepted" and
    /// report a weak signal on a good one.
    func testFixesThatArriveDuringAPauseDoNotMakeTheResumeLookLikeAWeakSignal() throws {
        let (recorder, manager, _) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        deliver(recorder, manager, fix(lat(0)), fix(lat(1)), fix(lat(2)))
        recorder.setPaused(true)
        Thread.sleep(forTimeInterval: 0.05)
        deliver(recorder, manager, fix(lat(3)), fix(lat(4)))
        recorder.setPaused(false)

        let accepted = try XCTUnwrap(recorder.lastAcceptedFixAt)
        // Just over the patience after the last accepted fix, which is inside it for the fixes that came during the pause.
        let now = accepted.addingTimeInterval(30.02)
        XCTAssertEqual(recorder.signalState(now: now), .ok, "a good signal after a resume is not 'weak'")
    }

    func testASystemLocationErrorIsReportedOnceItHasPersisted() {
        let (recorder, manager, _) = makeRecorder()
        recorder.start(startMs: 1_700_000_000_000)
        deliver(recorder, manager, fix(lat(0)), fix(lat(1)))
        recorder.locationManager(manager, didFailWithError: CLError(.locationUnknown))
        XCTAssertEqual(recorder.signalState(now: Date().addingTimeInterval(1)), .ok, "a blip is not a fault")
        XCTAssertEqual(recorder.signalState(now: Date().addingTimeInterval(10)), .lost)
        deliver(recorder, manager, fix(lat(2)))
        XCTAssertEqual(recorder.signalState(now: Date().addingTimeInterval(10)), .ok)
    }
}
