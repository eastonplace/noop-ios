import XCTest
@testable import NOOP

#if os(iOS)
/// An activity the app did not end is dropped. After the system ends one, the next request waits a doubling backoff and is
/// capped per workout; after a person dismisses one, nothing is requested until the next workout.
final class LiveActivityRestartPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnEndedActivityOrADismissalAfterAnObservedEndIsTheSystems() {
        XCTAssertEqual(LiveActivityRestartPolicy.cause(of: .ended, endObserved: false, liveFor: 600), .system)
        XCTAssertEqual(LiveActivityRestartPolicy.cause(of: .ended, endObserved: true, liveFor: 600), .system)
        XCTAssertEqual(LiveActivityRestartPolicy.cause(of: .dismissed, endObserved: true, liveFor: 600), .system,
                       "the system ended it, then removed it")
    }

    /// `dismissed` alone is a person's swipe only once the activity had shown long enough to have rendered. A removal
    /// sooner is a render the system gave up on, and goes through the backoff and the cap instead of a hold.
    func testABareDismissalIsAPersonsOnlyAfterTheActivityHadRendered() {
        XCTAssertEqual(LiveActivityRestartPolicy.cause(of: .dismissed, endObserved: false, liveFor: 5), .system)
        XCTAssertEqual(LiveActivityRestartPolicy.cause(
            of: .dismissed, endObserved: false, liveFor: LiveActivityRestartPolicy.renderedAfter - 0.1), .system)
        XCTAssertEqual(LiveActivityRestartPolicy.cause(
            of: .dismissed, endObserved: false, liveFor: LiveActivityRestartPolicy.renderedAfter), .person)
        XCTAssertEqual(LiveActivityRestartPolicy.cause(of: .dismissed, endObserved: false, liveFor: 600), .person)

        var policy = LiveActivityRestartPolicy()
        policy.noteDrive(workoutIsActive: true)
        policy.noteGone(LiveActivityRestartPolicy.cause(of: .dismissed, endObserved: false, liveFor: 3), now: start)
        XCTAssertFalse(policy.dismissedByPerson, "no hold for the rest of the workout")
        XCTAssertEqual(policy.systemEnds, 1)
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(LiveActivityRestartPolicy.firstBackoff)), .allowed)
    }

    func testAFreshPolicyAllowsARequest() {
        XCTAssertEqual(LiveActivityRestartPolicy().verdict(now: start), .allowed)
    }

    func testASystemEndWaitsADoublingBackoffBeforeTheNextRequest() {
        var policy = LiveActivityRestartPolicy()
        policy.noteDrive(workoutIsActive: true)
        policy.noteGone(.system, now: start)
        XCTAssertEqual(policy.verdict(now: start), .backoff)
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(29)), .backoff)
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(30)), .allowed)

        let second = start.addingTimeInterval(100)
        policy.noteGone(.system, now: second)
        XCTAssertEqual(policy.verdict(now: second.addingTimeInterval(59)), .backoff, "doubled")
        XCTAssertEqual(policy.verdict(now: second.addingTimeInterval(60)), .allowed)
    }

    func testTheSystemEndsAreCappedPerWorkoutAndTheNextWorkoutStartsAfresh() {
        var policy = LiveActivityRestartPolicy()
        policy.noteDrive(workoutIsActive: true)
        var now = start
        for _ in 0..<LiveActivityRestartPolicy.maxRestartsPerWorkout {
            policy.noteGone(.system, now: now)
            now = now.addingTimeInterval(10_000)
            XCTAssertEqual(policy.verdict(now: now), .allowed)
        }
        policy.noteGone(.system, now: now)
        XCTAssertEqual(policy.verdict(now: now.addingTimeInterval(100_000)), .exhausted)

        policy.noteDrive(workoutIsActive: true)
        XCTAssertEqual(policy.verdict(now: now.addingTimeInterval(100_000)), .exhausted, "still the same workout")
        policy.noteDrive(workoutIsActive: false)
        policy.noteDrive(workoutIsActive: true)
        XCTAssertEqual(policy.verdict(now: now), .allowed, "a new workout")
        XCTAssertEqual(policy.systemEnds, 0)
    }

    func testAPersonsDismissalDuringAWorkoutHoldsUntilTheNextWorkout() {
        var policy = LiveActivityRestartPolicy()
        policy.noteDrive(workoutIsActive: true)
        policy.noteGone(.person, now: start)
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(3_600)), .dismissedByPerson)

        policy.noteDrive(workoutIsActive: true)
        XCTAssertEqual(policy.verdict(now: start), .dismissedByPerson, "the same workout")
        policy.noteDrive(workoutIsActive: false)
        XCTAssertEqual(policy.verdict(now: start), .dismissedByPerson, "nor the heart-rate card after it")
        policy.noteDrive(workoutIsActive: true)
        XCTAssertEqual(policy.verdict(now: start), .allowed, "the next workout")
    }

    func testAPersonsDismissalOfTheHeartRateCardHoldsUntilAWorkoutStarts() {
        var policy = LiveActivityRestartPolicy()
        policy.noteDrive(workoutIsActive: false)
        policy.noteGone(.person, now: start)
        policy.noteDrive(workoutIsActive: false)
        XCTAssertEqual(policy.verdict(now: start), .dismissedByPerson)
        policy.noteDrive(workoutIsActive: true)
        XCTAssertEqual(policy.verdict(now: start), .allowed)
    }
}
#endif
