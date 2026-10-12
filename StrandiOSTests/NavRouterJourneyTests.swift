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
