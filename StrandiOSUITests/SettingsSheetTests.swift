import XCTest

/// Settings is a sheet behind the top bar's profile button, built from the iOS Settings idiom: a native navigation bar
/// and back button, a search field, rows that push pages, and a swipe down that dismisses it.
@MainActor
final class SettingsSheetTests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--demo-seed", "--demo-tab", "today", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        return app
    }

    private func row(_ route: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["settings.row.\(route)"].firstMatch
    }

    /// The demo seed finishes after the shell is interactive, and its root redraw drops a sheet opened before it. The
    /// seeded strap battery is set only once the seed returns, so wait for it before navigating, as
    /// ApprovedDashboardUITests does.
    private func waitForDemoSeed(in app: XCUIApplication) {
        let battery = app.buttons["app.battery"]
        XCTAssertTrue(battery.waitForExistence(timeout: 60), "the header shows the strap battery")
        let seeded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Strap battery 68 percent'"),
                                               object: battery)
        XCTAssertEqual(XCTWaiter.wait(for: [seeded], timeout: 60), .completed, "the demo seed finished before navigating")
    }

    /// Pinned header chrome can report a false accessibility hit test above the clipped scroll view beneath it, so the
    /// profile button gets a real touch at its centre, as in ApprovedDashboardUITests.
    private func openSettings(_ avatar: XCUIElement) {
        avatar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func testAvatarOpensSettingsSearchPushesAPageAndSwipeDownDismisses() throws {
        continueAfterFailure = false
        let app = launch()

        // The tab bar is four tabs and the quick-actions button; Settings is not one of them.
        XCTAssertTrue(app.buttons["app.tab.4"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["app.tab.3"].exists)

        let avatar = app.buttons["Profile and settings"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 30))
        waitForDemoSeed(in: app)
        openSettings(avatar)

        let done = app.buttons["settings.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 15), "the Settings sheet opens with its Done button")
        XCTAssertTrue(app.descendants(matching: .any)["settings.profileRow"].firstMatch.exists, "the profile row leads the list")
        XCTAssertTrue(row("whoop", in: app).exists, "the root lists its pages as rows")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5), "the search bar is the native one")
        search.tap()
        search.typeText("battery")

        let result = row("syncBattery", in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 5), "the search lists Sync & battery")
        result.tap()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(timeout: 10), "the pushed page is Sync & battery")

        // Back to the Settings root with the navigation bar's own back button, then swipe the sheet down.
        // The root's own "Done" is in the bar too, so the back button is the bar button that is not it.
        let back = app.navigationBars.buttons.matching(NSPredicate(format: "identifier != 'settings.done'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 15), "a Settings page has the native back button")
        back.tap()
        // The search is still showing what it found, as in iOS Settings, so the root is told apart by that result.
        XCTAssertTrue(row("syncBattery", in: app).waitForExistence(timeout: 15), "back lands on the Settings root, still inside the sheet")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(avatar.waitForExistence(timeout: 10))
        XCTAssertFalse(done.exists, "the sheet is gone")
    }

    func testAPageGoesBackWithTheEdgeSwipeAndTheProfileRowOpensPersonalProfile() throws {
        continueAfterFailure = false
        let app = launch()
        let avatar = app.buttons["Profile and settings"]
        XCTAssertTrue(avatar.waitForExistence(timeout: 60))
        waitForDemoSeed(in: app)
        openSettings(avatar)

        let profileRow = app.descendants(matching: .any)["settings.profileRow"].firstMatch
        XCTAssertTrue(profileRow.waitForExistence(timeout: 15))
        profileRow.tap()
        XCTAssertTrue(app.datePickers.firstMatch.waitForExistence(timeout: 10), "Personal profile has the date of birth")

        // The native edge swipe pops the page; the swipe belongs to the navigation stack, not to the sheet.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))
        XCTAssertTrue(app.buttons["settings.done"].waitForExistence(timeout: 5))
        XCTAssertTrue(row("whoop", in: app).waitForExistence(timeout: 5), "back at the Settings root")
    }
}
