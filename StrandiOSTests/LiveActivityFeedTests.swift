import XCTest
@testable import NOOP

#if os(iOS)
/// The Live Activity is fed from three places (the app's drive, the verified publication worker and the HealthKit scoring
/// publish). They build through `LiveActivityFeed`, so these tests pin what every one of them sends.
@MainActor
final class LiveActivityFeedTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private func t(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    /// A mutable stand-in for the model, so a test can change it between making the feed and reading it.
    private final class Model {
        var workout: AppModel.ActiveWorkout?
        var finishPending = false
        var connected = true
        var passiveBPM: Int?
        var edges = 0
        var now = Date(timeIntervalSince1970: 1_700_000_100)
    }

    private func feed(_ model: Model, workoutReading: Int? = nil) -> LiveActivityFeed {
        LiveActivityFeed(
            inputs: { LiveActivityFeed.Inputs(workout: model.workout, finishPending: model.finishPending,
                                              connected: model.connected, passiveBPM: model.passiveBPM) },
            profile: ProfileStore(), projections: WorkoutLiveProjectionCache(),
            pauseEdgeGeneration: { model.edges }, workoutReading: workoutReading, now: { model.now })
    }

    private func running() -> AppModel.ActiveWorkout {
        AppModel.ActiveWorkout(start: start, sport: "Running", maxHR: 190)
    }

    // MARK: One rule on every path

    func testTheEndingFlagRidesEveryStateTheFeedBuilds() throws {
        let model = Model()
        model.workout = running()
        XCTAssertFalse(try XCTUnwrap(feed(model).workoutState()).isFinishing)
        model.finishPending = true
        XCTAssertTrue(try XCTUnwrap(feed(model).workoutState()).isFinishing,
                      "a publish that arrives after End must not re-enable Pause")
    }

    func testAWorkoutKeepsItsOwnReadingWhateverThePassiveSourceSays() {
        let model = Model()
        let workout = running()
        workout.noteReading(143, at: t(10))
        model.workout = workout
        model.connected = false
        model.passiveBPM = 61
        XCTAssertEqual(feed(model).bpm, 143, "connected or not, a workout shows the last reading it took")
        model.connected = true
        XCTAssertEqual(feed(model).bpm, 143, "and never the passive reading")
        XCTAssertEqual(feed(model, workoutReading: 150).bpm, 150, "a reading in hand wins")
    }

    func testOutsideAWorkoutThePassiveReadingShowsOnlyWhileConnected() {
        let model = Model()
        model.passiveBPM = 61
        model.connected = true
        XCTAssertEqual(feed(model).bpm, 61)
        model.connected = false
        XCTAssertNil(feed(model).bpm)
        XCTAssertFalse(feed(model).workoutIsActive)
        XCTAssertNil(feed(model).workoutState())
    }

    // MARK: Built when it is written, stamped with the edges it has

    func testTheStateIsBuiltWhenAskedForNotWhenTheFeedWasMade() throws {
        let model = Model()
        let workout = running()
        model.workout = workout
        let queued = feed(model)                       // an update is queued behind another write ...
        XCTAssertTrue(workout.setPaused(true, at: t(60)))   // ... Pause is tapped meanwhile ...
        model.edges += 1
        let written = try XCTUnwrap(queued.workoutState())  // ... and the controller asks for the state to write.
        XCTAssertEqual(written.pausedAt, t(60), "the state written is the paused one")
        XCTAssertEqual(written.pauseEdgeGeneration, 1)
    }

    func testAStateBuiltBeforeAnEdgeNeverMarksThatEdgeDelivered() throws {
        let model = Model()
        model.workout = running()
        var latch = PauseEdgeLatch()
        // Built eagerly and queued: it carries the count it was built at, 0.
        let early = try XCTUnwrap(feed(model).workoutState())
        XCTAssertEqual(early.pauseEdgeGeneration, latch.generation)
        // Pause is tapped; the edge is raised.
        latch.noteEdge()
        model.edges = latch.generation
        // The queued write drains and goes out. It was built before the edge, so it delivers nothing of it.
        latch.delivered(builtAt: early.pauseEdgeGeneration)
        XCTAssertTrue(latch.isPending, "the paused state still has to be written")
        // The write that follows is built after the edge and clears it.
        let late = try XCTUnwrap(feed(model).workoutState())
        XCTAssertEqual(late.pauseEdgeGeneration, 1)
        latch.delivered(builtAt: late.pauseEdgeGeneration)
        XCTAssertFalse(latch.isPending)
    }

    // MARK: The strap going quiet (the app's own rule, carried to the activity)

    func testTheFeedUsesTheAppsFifteenSecondRule() {
        let model = Model()
        let workout = running()
        workout.noteReading(140, at: model.now.addingTimeInterval(-10))
        model.workout = workout
        XCTAssertFalse(feed(model).heartRateIsStale, "10 s of quiet is within the app's patience")
        model.now = model.now.addingTimeInterval(10)     // 20 s since the last reading
        XCTAssertTrue(feed(model).heartRateIsStale)
        XCTAssertEqual(feed(model).heartRateIsStale,
                       LiveWorkoutSignals.heartRateIsStale(lastReadingAt: workout.lastReadingAt, workoutStart: start,
                                                           isPaused: false, now: model.now),
                       "one definition: the same function the live screen's tiles ask")
    }

    func testAPausedWorkoutIsNeverQuiet() {
        let model = Model()
        let workout = running()
        workout.noteReading(140, at: model.now.addingTimeInterval(-300))
        XCTAssertTrue(workout.setPaused(true, at: model.now.addingTimeInterval(-200)))
        model.workout = workout
        XCTAssertFalse(feed(model).heartRateIsStale)
    }

    func testNoWorkoutIsNeverQuiet() {
        XCTAssertFalse(feed(Model()).heartRateIsStale)
    }

    func testAPendingFinishIsNeverQuietOnTheFeedOrOnTheStateTheActivityIsWrittenWith() throws {
        let model = Model()
        let workout = running()
        // The strap went quiet 5 minutes before End; the finish then failed and waits for a retry.
        workout.noteReading(140, at: model.now.addingTimeInterval(-300))
        model.workout = workout
        XCTAssertTrue(feed(model).heartRateIsStale, "while it records, 5 minutes of quiet is a strap problem")
        XCTAssertTrue(try XCTUnwrap(feed(model).workoutState()).heartRateIsStale)
        workout.freeze(at: model.now)
        model.finishPending = true
        XCTAssertFalse(feed(model).heartRateIsStale, "the app shows no warning while Ending")
        XCTAssertFalse(try XCTUnwrap(feed(model).workoutState()).heartRateIsStale,
                       "so the Lock Screen and the island do not dim the heart either")
        // The pending flag alone (the model's own word for it) is enough, whatever the workout object says.
        workout.freeze(at: nil)
        XCTAssertFalse(try XCTUnwrap(feed(model).workoutState()).heartRateIsStale)
    }

    func testTheQuietStrapVerdictIsTakenWhenTheStateIsBuiltNotWhenTheUpdateWasQueued() throws {
        let model = Model()
        let workout = running()
        workout.noteReading(140, at: model.now.addingTimeInterval(-10))
        model.workout = workout
        var latch = PauseEdgeLatch()
        // A verified publish is queued behind a write already in flight. Its state is built lazily, as the controller does:
        // the closure is handed over now and called when the write is made.
        let queued = feed(model)
        let buildWhenWritten = { queued.workoutState() }
        // Meanwhile the strap goes quiet; the 5 s check raises an edge for the new verdict.
        model.now = model.now.addingTimeInterval(10)                  // 20 s since the last reading
        latch.noteEdge()
        model.edges = latch.generation
        // The queued write is made now: it carries the verdict of this moment and the edge it clears, together.
        let written = try XCTUnwrap(buildWhenWritten())
        XCTAssertTrue(written.heartRateIsStale, "the verdict of the moment the state is built, not of the moment it was queued")
        XCTAssertEqual(written.pauseEdgeGeneration, 1)
        latch.delivered(builtAt: written.pauseEdgeGeneration)
        XCTAssertFalse(latch.isPending, "the edge is cleared by a state that already carries what it was raised for")
    }

    func testTheCachedStateFollowsTheStrapThroughARecoveryAndAFlipOnTheRealFeed() throws {
        let model = Model()
        let workout = running()
        workout.noteReading(140, at: model.now.addingTimeInterval(-30))        // quiet for 30 s
        model.workout = workout
        let f = feed(model)
        var cache = LiveActivityWorkoutStateCache()
        func write() -> WorkoutLiveActivityState? {
            guard case .state(let state) = cache.stateForWrite(
                workoutIsActive: true, now: model.now, build: { f.workoutState() }, heartRateIsStale: { f.heartRateIsStale })
            else { return nil }
            return state
        }
        let quiet = try XCTUnwrap(write())
        XCTAssertTrue(quiet.heartRateIsStale)
        let builtAt = cache.builtAt
        // The strap comes back 3 s later: the cached projection is reused and the heart is undimmed at once.
        model.now = model.now.addingTimeInterval(3)
        workout.noteReading(143, at: model.now)
        let recovered = try XCTUnwrap(write())
        XCTAssertEqual(cache.builtAt, builtAt, "reused, not rebuilt")
        XCTAssertFalse(recovered.heartRateIsStale)
        // Then it goes quiet again. 8 s after the reading it is not stale yet; 17 s after it is, and the write says so
        // (by then the ten-second window has passed and the projection is rebuilt: the verdict is the same either way).
        model.now = model.now.addingTimeInterval(8)
        XCTAssertFalse(try XCTUnwrap(write()).heartRateIsStale)
        model.now = model.now.addingTimeInterval(9)
        XCTAssertTrue(try XCTUnwrap(write()).heartRateIsStale)
    }

    func testAStateBuiltBeforeTheStrapWentQuietNeverClearsTheEdgeRaisedForIt() throws {
        let model = Model()
        let workout = running()
        workout.noteReading(140, at: model.now.addingTimeInterval(-10))
        model.workout = workout
        var latch = PauseEdgeLatch()
        let early = try XCTUnwrap(feed(model).workoutState())          // built before: not quiet, stamped 0
        XCTAssertFalse(early.heartRateIsStale)
        model.now = model.now.addingTimeInterval(10)
        latch.noteEdge()
        model.edges = latch.generation
        latch.delivered(builtAt: early.pauseEdgeGeneration)
        XCTAssertTrue(latch.isPending, "the old verdict cannot mark the new one delivered")
        let late = try XCTUnwrap(feed(model).workoutState())
        XCTAssertTrue(late.heartRateIsStale)
        latch.delivered(builtAt: late.pauseEdgeGeneration)
        XCTAssertFalse(latch.isPending)
    }

    // MARK: Ending: every clock stops at the same moment

    func testAFinishingWorkoutCarriesTheMomentItStoppedAndAnchorsTheClockToIt() throws {
        let model = Model()
        let workout = running()
        XCTAssertTrue(workout.setPaused(true, at: t(300)))
        XCTAssertTrue(workout.setPaused(false, at: t(360)))   // a minute paused, over
        workout.freeze(at: t(1_000))
        model.workout = workout
        model.finishPending = true
        let state = try XCTUnwrap(feed(model).workoutState())
        XCTAssertEqual(state.frozenAt, t(1_000))
        // The Lock Screen clock is (stop - startedAt): the time the workout ran, 940 s, not running on with the wall clock.
        XCTAssertEqual(try XCTUnwrap(state.frozenAt).timeIntervalSince(state.startedAt), 940, accuracy: 0.001)
        XCTAssertEqual(workout.activeElapsed(at: t(5_000)), 940, accuracy: 0.001, "the live screen's clock agrees")
    }

    func testAWorkoutThatIsNotEndingCarriesNoFreeze() throws {
        let model = Model()
        model.workout = running()
        XCTAssertNil(try XCTUnwrap(feed(model).workoutState()).frozenAt)
    }
}
#endif
