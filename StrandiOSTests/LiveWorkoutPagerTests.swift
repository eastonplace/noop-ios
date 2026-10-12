import XCTest
@testable import NOOP

/// Which pages the live screen has, where it opens, and what it keeps between a Minimize and a return.
final class LiveWorkoutPagerTests: XCTestCase {
    func testARouteWorkoutHasThreePagesAndAnythingElseTwo() {
        XCTAssertEqual(LiveWorkoutPage.pages(tracksRoute: true), [.focus, .heart, .route])
        XCTAssertEqual(LiveWorkoutPage.pages(tracksRoute: false), [.focus, .heart])
    }

    func testAPageTheWorkoutNoLongerHasFallsBackToTheFirst() {
        let indoor = LiveWorkoutPage.pages(tracksRoute: false)
        XCTAssertEqual(LiveWorkoutPage.resolve(.route, in: indoor), .focus, "location went off while the route page was showing")
        XCTAssertEqual(LiveWorkoutPage.resolve(.heart, in: indoor), .heart)
        XCTAssertEqual(LiveWorkoutPage.resolve(nil, in: indoor), .focus)
    }

    func testTheDemoFlagNamesAPage() {
        XCTAssertEqual(LiveWorkoutPage.demoPage(arguments: ["app", "--demo-live-page", "heart"]), .heart)
        XCTAssertEqual(LiveWorkoutPage.demoPage(arguments: ["--demo-live-page", "route"]), .route)
        XCTAssertNil(LiveWorkoutPage.demoPage(arguments: ["--demo-live-page", "splits"]))
        XCTAssertNil(LiveWorkoutPage.demoPage(arguments: ["--demo-live-page"]))
        XCTAssertNil(LiveWorkoutPage.demoPage(arguments: []))
    }

    @MainActor func testEachWorkoutKeepsItsOwnPage() {
        let memory = WorkoutPageMemory()
        let first = UUID(), second = UUID()
        XCTAssertNil(memory[first])
        memory[first] = .heart
        memory[second] = .route
        XCTAssertEqual(memory[first], .heart)
        XCTAssertEqual(memory[second], .route)
    }

    @MainActor func testTheRouterOwnsTheMemoryTheJourneyHandsToTheLiveScreen() {
        let router = NavRouter()
        let session = UUID()
        router.workoutPageMemory[session] = .heart
        XCTAssertEqual(router.workoutPageMemory[session], .heart)
    }
}
