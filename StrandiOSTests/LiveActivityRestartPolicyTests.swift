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
        let afterBackoff = start.addingTimeInterval(LiveActivityRestartPolicy.firstBackoff)
        XCTAssertEqual(policy.verdict(now: afterBackoff, isForeground: true), .allowed)
    }

    func testAFreshPolicyAllowsARequest() {
        XCTAssertEqual(LiveActivityRestartPolicy().verdict(now: start, isForeground: true), .allowed)
    }

    func testASystemEndWaitsADoublingBackoffBeforeTheNextRequest() {
        var policy = LiveActivityRestartPolicy()
        policy.noteDrive(workoutIsActive: true)
        policy.noteGone(.system, now: start)
        XCTAssertEqual(policy.verdict(now: start, isForeground: true), .backoff)
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(29), isForeground: true), .backoff)
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(30), isForeground: true), .allowed)

        let second = start.addingTimeInterval(100)
        policy.noteGone(.system, now: second)
        XCTAssertEqual(policy.verdict(now: second.addingTimeInterval(59), isForeground: true), .backoff, "doubled")
        XCTAssertEqual(policy.verdict(now: second.addingTimeInterval(60), isForeground: true), .allowed)
    }

    func testTheSystemEndsAreCappedPerWorkoutAndTheNextWorkoutStartsAfresh() {
        var policy = LiveActivityRestartPolicy()
        policy.noteDrive(workoutIsActive: true)
        var now = start
        for _ in 0..<LiveActivityRestartPolicy.maxRestartsPerWorkout {
            policy.noteGone(.system, now: now)
            now = now.addingTimeInterval(10_000)
            XCTAssertEqual(policy.verdict(now: now, isForeground: true), .allowed)
        }
        policy.noteGone(.system, now: now)
        XCTAssertEqual(policy.verdict(now: now.addingTimeInterval(100_000), isForeground: true), .exhausted)

        policy.noteDrive(workoutIsActive: true)
        XCTAssertEqual(policy.verdict(now: now.addingTimeInterval(100_000), isForeground: true), .exhausted,
                       "still the same workout")
        policy.noteDrive(workoutIsActive: false)
        policy.noteDrive(workoutIsActive: true)
        XCTAssertEqual(policy.verdict(now: now, isForeground: true), .allowed, "a new workout")
        XCTAssertEqual(policy.systemEnds, 0)
    }

    /// A refused request waits like a system end and counts toward the same cap, instead of being repeated every drive.
    func testARefusedRequestBacksOffAndCountsTowardTheCap() {
        var policy = LiveActivityRestartPolicy()
        policy.noteDrive(workoutIsActive: true)
        policy.noteRequestFailed(now: start)
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(1), isForeground: true), .backoff)
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(30), isForeground: true), .allowed)
        policy.noteGone(.system, now: start.addingTimeInterval(40))
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(99), isForeground: true), .backoff,
                       "the second setback doubles the wait")
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(100), isForeground: true), .allowed)
        for step in 0..<3 { policy.noteRequestFailed(now: start.addingTimeInterval(1_000 * Double(step + 1))) }
        XCTAssertEqual(policy.setbacks, 5)
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(100_000), isForeground: true), .exhausted)
    }

    /// After a setback only a drive with the app in front asks again; a first request is not held back.
    func testAfterASetbackOnlyAForegroundDriveAsksAgain() {
        var policy = LiveActivityRestartPolicy()
        XCTAssertEqual(policy.verdict(now: start, isForeground: false), .allowed, "no setback yet")
        policy.noteDrive(workoutIsActive: true)
        policy.noteGone(.system, now: start)
        let later = start.addingTimeInterval(3_600)
        XCTAssertEqual(policy.verdict(now: later, isForeground: false), .waitingForForeground)
        XCTAssertEqual(policy.verdict(now: later, isForeground: true), .allowed)
    }

    func testAPersonsDismissalDuringAWorkoutHoldsUntilTheNextWorkout() {
        var policy = LiveActivityRestartPolicy()
        policy.noteDrive(workoutIsActive: true)
        policy.noteGone(.person, now: start)
        XCTAssertEqual(policy.verdict(now: start.addingTimeInterval(3_600), isForeground: true), .dismissedByPerson)

        policy.noteDrive(workoutIsActive: true)
        XCTAssertEqual(policy.verdict(now: start, isForeground: true), .dismissedByPerson, "the same workout")
        policy.noteDrive(workoutIsActive: false)
        XCTAssertEqual(policy.verdict(now: start, isForeground: true), .dismissedByPerson,
                       "nor the heart-rate card after it")
        policy.noteDrive(workoutIsActive: true)
        XCTAssertEqual(policy.verdict(now: start, isForeground: true), .allowed, "the next workout")
    }

    func testAPersonsDismissalOfTheHeartRateCardHoldsUntilAWorkoutStarts() {
        var policy = LiveActivityRestartPolicy()
        policy.noteDrive(workoutIsActive: false)
        policy.noteGone(.person, now: start)
        policy.noteDrive(workoutIsActive: false)
        XCTAssertEqual(policy.verdict(now: start, isForeground: true), .dismissedByPerson)
        policy.noteDrive(workoutIsActive: true)
        XCTAssertEqual(policy.verdict(now: start, isForeground: true), .allowed)
    }
}
#endif
