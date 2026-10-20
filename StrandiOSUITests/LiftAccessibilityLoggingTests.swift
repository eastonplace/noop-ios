import XCTest

@MainActor
final class LiftAccessibilityLoggingTests: XCTestCase {
    func testLogSetAtAccessibilityMedium() throws {
        try assertAccessibleSetLogging(contentSize: "UICTContentSizeCategoryAccessibilityM")
    }

    func testLogSetAtAccessibilityExtraExtraExtraLarge() throws {
        try assertAccessibleSetLogging(contentSize: "UICTContentSizeCategoryAccessibilityXXXL")
    }

    private func assertAccessibleSetLogging(contentSize: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--demo-seed", "--noop-qa-route", "lift",
            "--noop-lift-demo", "session", "--noop-lift-scene", "live-composer",
            "--noop-lift-hold-stamp",
            "-UIPreferredContentSizeCategoryName", contentSize,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.buttons["Finish workout"].waitForExistence(timeout: 60), "The seeded live workout opens")
        // The stacked accessibility editor always exposes its step controls. The regular table only exposes these
        // after a field is selected, so this also proves that the launch selected the accessibility layout.
        XCTAssertTrue(app.buttons["Add a rep"].waitForExistence(timeout: 10), "The accessibility editor is active")

        let loggedStamp = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS 'ADDED TO RECEIPT'")
        ).firstMatch
        XCTAssertFalse(loggedStamp.exists)

        let logSet = app.buttons["Log set"]
        for _ in 0..<8 {
            if logSet.exists && logSet.isHittable { break }
            app.swipeUp()
        }
        capture(app, "\(contentSize)-before-log")
        XCTAssertTrue(logSet.exists, "Accessibility text sizes must keep the action that logs the draft set")
        XCTAssertTrue(logSet.isHittable, "The Log set action must be reachable by scrolling")
        logSet.tap()

        // This confirmation is created only after LiftStore.logSet succeeds, so finding the button alone cannot pass.
        XCTAssertTrue(loggedStamp.waitForExistence(timeout: 10), "Tapping Log set adds the draft to the workout receipt")
        capture(app, "\(contentSize)-logged")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
