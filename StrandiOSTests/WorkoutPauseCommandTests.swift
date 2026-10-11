import XCTest
@testable import NOOP

/// The hand-off from the Live Activity's Pause button to the recorder, and the pause fields the activity carries.
@MainActor
final class WorkoutPauseCommandTests: XCTestCase {
    private var suite: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "noop.tests.pause-command.\(UUID().uuidString)"
        suite = UserDefaults(suiteName: suiteName)
        WorkoutPauseCommand.defaultsOverride = suite
        WorkoutPauseCommand.apply = nil
    }

    override func tearDown() async throws {
        WorkoutPauseCommand.apply = nil
        WorkoutPauseCommand.defaultsOverride = nil
        suite.removePersistentDomain(forName: suiteName)
    }

    func testARequestWithAWorkoutInFlightIsAppliedAtOnceAndKeepsNothing() {
        var seen: [Bool] = []
        WorkoutPauseCommand.apply = { paused in seen.append(paused); return true }
        WorkoutPauseCommand.deliver(paused: true)
        XCTAssertEqual(seen, [true])
        XCTAssertNil(WorkoutPauseCommand.pendingRequest())
    }

    func testARequestWithNoWorkoutIsDroppedNotKept() {
        // A workout started a minute later must not begin paused because of a tap meant for the last one.
        WorkoutPauseCommand.apply = { _ in false }
        WorkoutPauseCommand.deliver(paused: true)
        XCTAssertNil(WorkoutPauseCommand.pendingRequest())

        var seen: [Bool] = []
        WorkoutPauseCommand.apply = { paused in seen.append(paused); return true }
        WorkoutPauseCommand.drain()
        XCTAssertEqual(seen, [], "nothing is waiting to be applied to the next workout")
    }

    func testARequestThatArrivesBeforeTheAppIsReadyWaitsAndIsHandedOverOnce() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        WorkoutPauseCommand.deliver(paused: true, now: now)
        XCTAssertEqual(WorkoutPauseCommand.pendingRequest(now: now.addingTimeInterval(5)), true)

        var seen: [Bool] = []
        WorkoutPauseCommand.apply = { paused in seen.append(paused); return true }
        WorkoutPauseCommand.drain(now: now.addingTimeInterval(5))
        WorkoutPauseCommand.drain(now: now.addingTimeInterval(6))
        XCTAssertEqual(seen, [true], "handed over exactly once")
        XCTAssertNil(WorkoutPauseCommand.pendingRequest(now: now.addingTimeInterval(6)))
    }

    func testAWaitingRequestExpiresAndIsNeverAppliedLate() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        WorkoutPauseCommand.deliver(paused: true, now: now)
        let late = now.addingTimeInterval(WorkoutPauseCommand.lifetime + 1)
        XCTAssertNil(WorkoutPauseCommand.pendingRequest(now: late))

        var seen: [Bool] = []
        WorkoutPauseCommand.apply = { paused in seen.append(paused); return true }
        WorkoutPauseCommand.drain(now: late)
        XCTAssertEqual(seen, [])
        XCTAssertNil(WorkoutPauseCommand.pendingRequest(now: now), "an expired record is cleared, not kept")
    }

    func testTheIntentNamesTheStateItWantsNotAToggle() {
        XCTAssertTrue(SetWorkoutPausedIntent(paused: true).paused)
        XCTAssertFalse(SetWorkoutPausedIntent(paused: false).paused)
    }

    // MARK: Content state

    func testContentStateRoundTripsThePauseFields() throws {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let pausedAt = started.addingTimeInterval(600)
        let state = NOOPActivityAttributes.ContentState(
            bpm: 140, recovery: nil, bonded: true, sport: "Running", workoutStartedAt: started,
            isPaused: true, pausedAt: pausedAt)
        let decoded = try JSONDecoder().decode(
            NOOPActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertTrue(decoded.paused)
        XCTAssertEqual(decoded.pausedAt, pausedAt)
    }

    func testAnActivityStartedByAnOlderBuildDecodesAsRunning() throws {
        let old = #"{"bpm":131,"bonded":true,"sport":"Running","workoutStartedAt":700000000}"#
        let decoded = try JSONDecoder().decode(NOOPActivityAttributes.ContentState.self, from: Data(old.utf8))
        XCTAssertFalse(decoded.paused)
        XCTAssertNil(decoded.pausedAt)
        XCTAssertTrue(decoded.isWorkout)
        XCTAssertFalse(decoded.finishing, "an activity from an older build is not finishing")
        XCTAssertNil(decoded.isFinishing)
    }

    func testAFinishingActivityRoundTripsAndDiffersFromARunningOne() throws {
        let started = Date(timeIntervalSince1970: 1_000_000)
        let running = NOOPActivityAttributes.ContentState(
            bpm: 140, recovery: nil, bonded: true, sport: "Running", workoutStartedAt: started, isPaused: false)
        var finishing = running
        finishing.isFinishing = true
        XCTAssertNotEqual(finishing, running, "the controller's unchanged-state dedupe must not swallow the finishing edge")
        XCTAssertTrue(finishing.finishing)
        XCTAssertFalse(running.finishing)
        let decoded = try JSONDecoder().decode(
            NOOPActivityAttributes.ContentState.self, from: JSONEncoder().encode(finishing))
        XCTAssertEqual(decoded, finishing)
        XCTAssertTrue(decoded.finishing)
    }
}
