import XCTest

/// Editing gives the keyboard the navigation's space without separating it from the composer.
@MainActor
final class CoachKeyboardLayoutTests: XCTestCase {
    func testTypingKeepsNavigationBehindKeyboardAndRestoresItAfterDismissal() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--noop-coach-shell-qa", "--demo-tab", "coach",
            "--noop-lift-demo", "fresh", "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
        defer { app.terminate() }

        let composer = app.descendants(matching: .any).matching(identifier: "coach.composer").firstMatch
        let navigation = ["app.tab.0", "app.tab.1", "app.quickActions", "app.tab.4", "app.tab.2"]
            .map { app.buttons[$0] }
        XCTAssertTrue(composer.waitForExistence(timeout: 30))
        for button in navigation { XCTAssertTrue(button.isHittable) }
        let restingNavigationY = app.buttons["app.quickActions"].frame.minY
        capture(app, "coach-keyboard-01-resting-navigation")

        composer.tap()
        composer.typeText("Keyboard layout check")
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        capture(app, "coach-keyboard-02-editing")

        let navigationIsHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                !app.descendants(matching: .any).matching(identifier: "app.bottomNavigation").firstMatch.exists
                    && navigation.allSatisfy { !$0.exists }
            }, object: app
        )
        XCTAssertEqual(XCTWaiter.wait(for: [navigationIsHidden], timeout: 5), .completed,
                       "Global navigation must be removed while typing so its glow cannot show through the keyboard")
        XCTAssertTrue(composer.isHittable, "The composer remains reachable while the keyboard is open")
        XCTAssertTrue(app.buttons["coach.send"].isHittable, "The send action remains reachable while typing")
        XCTAssertLessThanOrEqual(composer.frame.maxY, keyboard.frame.minY)
        // These AX frames exclude the capsule's field insets and the keyboard's prediction strip.
        // The visually docked state measures 68.3 pt here; an extra 77 pt navigation reservation
        // would measure about 145 pt, so this bound still catches that blank band.
        XCTAssertLessThanOrEqual(keyboard.frame.minY - composer.frame.maxY, 80,
                                 "The composer must use the navigation's released space and sit close to the keyboard")

        // This existing local page action clears composer focus without submitting a message
        // or changing the person's stored conversations.
        app.buttons["coach.more"].tap()
        app.buttons["Daily overview"].tap()
        let keyboardDismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: keyboard
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardDismissed], timeout: 5), .completed)
        for button in navigation { XCTAssertTrue(button.isHittable, "Navigation returns after keyboard dismissal") }
        XCTAssertEqual(app.buttons["app.quickActions"].frame.minY, restingNavigationY, accuracy: 1)
        app.buttons["app.quickActions"].tap()
        XCTAssertTrue(app.buttons["quickActions.close"].waitForExistence(timeout: 5))
        app.buttons["quickActions.close"].tap()
        capture(app, "coach-keyboard-03-navigation-restored")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
