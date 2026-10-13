import XCTest
@testable import NOOP

#if os(iOS)
/// An activity the app did not end is dropped. After the system ends one, the next request waits a doubling backoff and is
/// capped per workout; after a person dismisses one, nothing is requested until the next workout.
final class LiveActivityRestartPolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAnEndedActivityOrADismissalAfterAnObservedEndIsTheSystems() {
        XCTAssertEqual(LiveActivityRestartPolicy.cause(of: .ended, endObserved: false), .system)
        XCTAssertEqual(LiveActivityRestartPolicy.cause(of: .ended, endObserved: true), .system)
        XCTAssertEqual(LiveActivityRestartPolicy.cause(of: .dismissed, endObserved: true), .system,
                       "the system ended it, then removed it")
        XCTAssertEqual(LiveActivityRestartPolicy.cause(of: .dismissed, endObserved: false), .person,
                       "a swipe removes it with no end before")
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
