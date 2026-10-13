import XCTest
@testable import NOOP

/// The router is how every screen asks the shell for the workout journey. The shell is the only consumer.
@MainActor
final class NavRouterJourneyTests: XCTestCase {
    func testBeginWorkoutRequestsSetupOnTheChosenSport() {
        let router = NavRouter()
        XCTAssertNil(router.workoutJourneyRequest)
        router.beginWorkout()
        XCTAssertEqual(router.workoutJourneyRequest, .setup(initialSport: nil))
        router.beginWorkout(sport: "Cycling")
        XCTAssertEqual(router.workoutJourneyRequest, .setup(initialSport: "Cycling"))
    }

    func testOpenActiveWorkoutRequestsTheLiveScreen() {
        let router = NavRouter()
        router.openActiveWorkout()
        XCTAssertEqual(router.workoutJourneyRequest, .live)
    }

    /// Returning to the workout (the resume bar, a Live Activity tap, a deep link) both asks for the journey at the live
    /// screen and counts as a request, which the shell's auto-present policy reads (`workoutOpenedByRequest`), so a workout
    /// opened that way, Settings closed first, does not reopen by itself after it is minimized.
    func testReturningToTheWorkoutRequestsTheJourneyAndCountsAsARequest() {
        let router = NavRouter()
        router.openActiveWorkout()
        XCTAssertEqual(router.workoutJourneyRequest, .live)
        XCTAssertEqual(router.workoutRequestCount, 1)
    }

    func testOpeningAWorkoutNoLongerRaisesTheOldSheetFlagOrADestination() {
        let router = NavRouter()
        router.openActiveWorkout()
        XCTAssertNil(router.requestedDestination, "the shell presents the cover itself; no routed pillar is asked for")
    }

    func testTheActiveWorkoutDeepLinkKeyStillParses() {
        XCTAssertEqual(NavRouter.Destination(deepLinkKey: "activeWorkout"), .activeWorkout)
    }

    func testEachCollapseRequestIsANewGenerationSoEveryPresenterSeesIt() {
        let router = NavRouter()
        let first = router.modalCollapseGeneration
        router.collapseModals()
        router.collapseModals()
        XCTAssertEqual(router.modalCollapseGeneration, first &+ 2)
    }

    func testTwoEntriesForTheSameStartAreDistinctSoTheCoverRebuilds() {
        let a = WorkoutJourneyEntry(start: .live)
        let b = WorkoutJourneyEntry(start: .live)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(a.start, b.start)
    }
}
