import XCTest

@MainActor
final class LocalCoachShellTests: XCTestCase {
    func testComposerQuickActionsAndStreamingReplyInFullTabShell() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--noop-coach-shell-qa", "--noop-coach-shell-fixture", "--demo-tab", "coach", "-AppleInterfaceStyle", "Dark"]
        app.launch()
        let coachTab = app.buttons["app.tab.4"]
        XCTAssertTrue(coachTab.waitForExistence(timeout: 30))
        // Coach is chat-first. A second tab selection must no longer be required to reach the composer.
        let composer = app.descendants(matching: .any).matching(identifier: "coach.composer").firstMatch
        let quickActions = app.buttons["app.quickActions"]
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        XCTAssertTrue(composer.isHittable)
        XCTAssertTrue(quickActions.isHittable)
        XCTAssertLessThan(composer.frame.maxY, quickActions.frame.minY)
        capture(app, "01-full-shell-composer")

        quickActions.tap()
        XCTAssertTrue(app.buttons["quickActions.startWorkout"].waitForExistence(timeout: 5))
        capture(app, "02-restored-quick-actions")
        app.buttons["quickActions.close"].tap()
        // New conversation is a header action (the composer's + menu no longer repeats it).
        app.buttons["coach.newConversation"].tap()
        composer.tap()
        composer.typeText("This is a software check. Reply with the single word READY.")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["coach.send"].isHittable)
        XCTAssertLessThanOrEqual(composer.frame.maxY, app.keyboards.firstMatch.frame.minY)
        capture(app, "03-keyboard-and-composer")
        app.buttons["coach.send"].tap()
        XCTAssertTrue(app.buttons["Read aloud"].waitForExistence(timeout: 90), app.debugDescription)
        // Native fixture tests prove cumulative callbacks; this shell test proves their final rendering.
        XCTAssertTrue(app.staticTexts["READY"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "coach.error").firstMatch.exists)
        XCTAssertFalse(app.buttons["coach.retry"].exists)
        XCTAssertFalse(app.staticTexts["The data source changed. The previous operation was stopped."].exists)
        capture(app, "04-streaming-fixture-reply")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
