import XCTest
@testable import NOOP

/// The Live Activities attach these URLs with `widgetURL`; the app parses them in `onOpenURL`. Both sides
/// share `WorkoutDeepLink`, and these tests pin the wire format plus the Info.plist registration iOS needs.
final class WorkoutDeepLinkTests: XCTestCase {
    func testRunAndLiftLinksRoundTrip() {
        for link in [WorkoutDeepLink.activeRun, .activeLift] {
            XCTAssertEqual(WorkoutDeepLink(url: link.url), link)
        }
    }

    func testWireFormat() {
        XCTAssertEqual(WorkoutDeepLink.activeRun.url.absoluteString, "noop://workout/active")
        XCTAssertEqual(WorkoutDeepLink.activeLift.url.absoluteString, "noop://lift/active")
    }

    func testSchemeAndHostAreCaseInsensitive() throws {
        XCTAssertEqual(WorkoutDeepLink(url: try XCTUnwrap(URL(string: "NOOP://Workout/active"))), .activeRun)
    }

    func testForeignAndMalformedLinksAreRejected() throws {
        let rejected = [
            "https://workout/active",
            "noop://workout",
            "noop://workout/finished",
            "noop://workout/active/extra",
            "noop://unknown/active",
            "noop://import-health?v=1&payload=AAAA",
        ]
        for string in rejected {
            XCTAssertNil(WorkoutDeepLink(url: try XCTUnwrap(URL(string: string))), string)
        }
    }

    func testBuiltAppRegistersTheScheme() throws {
        let types = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        )
        let schemes = types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(WorkoutDeepLink.scheme))
    }

    @MainActor
    func testRouterRaisesTheLiftRequestOneShot() {
        let router = NavRouter()
        XCTAssertFalse(router.activeLiftRequested)
        router.openActiveLift()
        XCTAssertTrue(router.activeLiftRequested)
    }

    /// The shell's auto-present policy learns a workout was opened on request from this counter.
    @MainActor
    func testEveryWorkoutRequestBumpsTheRequestCounter() {
        let router = NavRouter()
        XCTAssertEqual(router.workoutRequestCount, 0)
        router.openActiveWorkout()
        XCTAssertEqual(router.workoutRequestCount, 1)
        router.openActiveLift()
        XCTAssertEqual(router.workoutRequestCount, 2)
    }
}
