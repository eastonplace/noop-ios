import XCTest
@testable import Strand

/// Pins the active-workout indicator model (now the resume bar's), the router request that re-opens the workout journey, the deep-link key, and the elapsed-clock
/// formatter (including the H:MM:SS extension past one hour). Pure / @MainActor, no UI host needed.
@MainActor
final class ActiveWorkoutIndicatorTests: XCTestCase {
    func testModelMakeReflectsActiveWorkoutVisibility() {
        // No workout -> no indicator (the card renders nothing).
        XCTAssertNil(ActiveWorkoutIndicatorModel.make(from: nil))

        var workout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: 100),
                                              sport: "Cycling", maxHR: 190)
        workout.sport = "Cycling"
        let model = ActiveWorkoutIndicatorModel.make(from: workout)

        XCTAssertEqual(model, ActiveWorkoutIndicatorModel(sport: "Cycling", startedAt: workout.start))
    }

    func testActiveWorkoutRoutingContract() {
        let router = NavRouter()

        router.openActiveWorkout()

        // The shell answers with the workout journey's one full-screen cover, opened at the live screen. No routed
        // destination and no one-shot flag are raised any more.
        XCTAssertEqual(router.workoutJourneyRequest, .live)
        XCTAssertNil(router.requestedDestination)
        XCTAssertEqual(NavRouter.Destination(deepLinkKey: "activeWorkout"), .activeWorkout)
    }

    func testClearingRouteAndWorkoutStateLeavesNoStaleRequest() {
        let router = NavRouter()
        var workout = AppModel.ActiveWorkout(start: Date(timeIntervalSince1970: 200),
                                              sport: "Rowing", maxHR: 190)
        workout.sport = "Rowing"

        XCTAssertNil(router.requestedDestination)
        XCTAssertNil(ActiveWorkoutIndicatorModel.make(from: nil))

        router.openActiveWorkout()
        XCTAssertEqual(router.workoutJourneyRequest, .live)
        XCTAssertEqual(ActiveWorkoutIndicatorModel.make(from: workout)?.sport, "Rowing")

        // The shell clears the request once handled; the indicator clears once the workout ends. Neither
        // leaves a stale request that would re-route on the next appearance.
        router.workoutJourneyRequest = nil
        XCTAssertNil(router.workoutJourneyRequest)
        XCTAssertNil(ActiveWorkoutIndicatorModel.make(from: nil))
    }

    func testElapsedFormatting() {
        let start = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            ActiveWorkoutIndicatorModel.elapsed(since: start, now: start.addingTimeInterval(65)),
            "1:05"
        )
        XCTAssertEqual(
            ActiveWorkoutIndicatorModel.elapsed(since: start, now: start),
            "0:00"
        )
        // Clock skew (now < start) clamps to zero rather than showing a negative time.
        XCTAssertEqual(
            ActiveWorkoutIndicatorModel.elapsed(since: start, now: start.addingTimeInterval(-5)),
            "0:00"
        )
    }

    /// Past one hour the clock extends to H:MM:SS, so a 1h 23m 07s session reads "1:23:07", NOT "83:07".
    func testElapsedFormattingPastOneHour() {
        let start = Date(timeIntervalSince1970: 1_000)

        // Exactly one hour rolls over to the H:MM:SS form.
        XCTAssertEqual(
            ActiveWorkoutIndicatorModel.elapsed(since: start, now: start.addingTimeInterval(3_600)),
            "1:00:00"
        )
        // 1h 23m 07s.
        XCTAssertEqual(
            ActiveWorkoutIndicatorModel.elapsed(since: start, now: start.addingTimeInterval(3_600 + 23 * 60 + 7)),
            "1:23:07"
        )
        // Multi-hour stays correct (2h 05m 09s).
        XCTAssertEqual(
            ActiveWorkoutIndicatorModel.elapsed(since: start, now: start.addingTimeInterval(2 * 3_600 + 5 * 60 + 9)),
            "2:05:09"
        )
    }
}
