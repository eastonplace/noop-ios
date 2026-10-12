import XCTest
@testable import NOOP

/// The Quick Actions "Start <last sport>" row: offered only when starting it would not have to ask anything.
final class WorkoutQuickStartTests: XCTestCase {
    private typealias QS = WorkoutQuickStart

    func testTheLastSportIsOfferedWhenNothingHasToBeAsked() {
        XCTAssertEqual(QS.offer(recents: ["Running", "Cycling"], gps: .ready, blockedByLift: false), "Running")
    }

    func testARouteSportWhoseLocationIsUndecidedIsLeftToTheSetupPage() {
        XCTAssertNil(QS.offer(recents: ["Running"], gps: .willAsk, blockedByLift: false),
                     "starting would put the location prompt in the middle of a quick start")
    }

    func testARouteSportWithLocationRefusedIsStillOffered() {
        // Nothing is asked: it starts without a route, as the setup page's own Start would.
        XCTAssertEqual(QS.offer(recents: ["Running"], gps: .denied, blockedByLift: false), "Running")
        XCTAssertEqual(QS.offer(recents: ["Running"], gps: .restricted, blockedByLift: false), "Running")
    }

    func testASportWithNoRouteDoesNotCareAboutLocation() {
        XCTAssertEqual(QS.offer(recents: ["Yoga"], gps: .willAsk, blockedByLift: false), "Yoga")
    }

    func testALiftInProgressBlocksTheRow() {
        XCTAssertNil(QS.offer(recents: ["Running"], gps: .ready, blockedByLift: true))
    }

    func testNoRecentSportMeansNoRow() {
        XCTAssertNil(QS.offer(recents: [], gps: .ready, blockedByLift: false))
        XCTAssertNil(QS.offer(recents: ["Quidditch"], gps: .ready, blockedByLift: false), "only catalogue sports are offered")
    }

    func testAQuickStartOpensTheCountdownAndAnActiveWorkoutOpensLive() {
        XCTAssertEqual(WorkoutJourneyPhase.initial(.quickStart(sport: "Running"), hasActiveWorkout: false),
                       .countdown(sport: "Running"))
        XCTAssertEqual(WorkoutJourneyPhase.initial(.quickStart(sport: "Running"), hasActiveWorkout: true), .live,
                       "never a second start on a workout that is already recording")
    }

    @MainActor func testTheRouterRaisesAQuickStartRequest() {
        let router = NavRouter()
        router.quickStartWorkout(sport: "Cycling")
        XCTAssertEqual(router.workoutJourneyRequest, .quickStart(sport: "Cycling"))
    }
}
