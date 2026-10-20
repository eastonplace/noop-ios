import XCTest
@testable import NOOP

/// Settings is a sheet the shell presents on request, not a tab. These pin the request the router publishes, the
/// deep-link key that still means "open Settings", and the page a deep link lands on.
@MainActor
final class SettingsSheetRouterTests: XCTestCase {
    func testOpeningSettingsPublishesARequestForTheRoot() throws {
        let router = NavRouter()
        XCTAssertNil(router.settingsRequest)
        router.openSettings()
        let request = try XCTUnwrap(router.settingsRequest)
        XCTAssertNil(request.route)
        XCTAssertNil(router.requestedDestination, "Settings no longer goes through the shell's destination switch")
    }

    func testOpeningSettingsCanLandOnOnePage() throws {
        let router = NavRouter()
        router.openSettings(.personalProfile)
        XCTAssertEqual(try XCTUnwrap(router.settingsRequest).route, .personalProfile)
    }

    func testTwoRequestsForTheSamePageAreTwoRequests() throws {
        let router = NavRouter()
        router.openSettings(.syncBattery)
        let first = try XCTUnwrap(router.settingsRequest)
        router.openSettings(.syncBattery)
        let second = try XCTUnwrap(router.settingsRequest)
        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.id, second.id)
    }

    func testTheSettingsDeepLinkKeyStillMapsToItsDestination() {
        XCTAssertEqual(NavRouter.Destination(deepLinkKey: "settings"), .settings)
    }

    func testTheSheetStartsOnTheRootOrOnTheDeepLinkedPage() {
        XCTAssertEqual(SettingsSheetHost.initialPath(for: SettingsSheetRequest()), [])
        XCTAssertEqual(SettingsSheetHost.initialPath(for: SettingsSheetRequest(route: .appearanceUnits)), [.appearanceUnits])
        XCTAssertEqual(SettingsSheetHost.initialPath(for: SettingsSheetRequest(route: .recentUpdates)), [.recentUpdates])
    }
}
