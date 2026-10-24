import XCTest

@MainActor
final class SleepStageInspectionUITests: XCTestCase {
    func testLongPressAndHeldDragInspectRecordedStageWindows() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Stage inspection uses the isolated simulator demo")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--noop-coach-shell-qa", "--demo-seed", "--noop-lift-demo", "fresh",
            "--demo-tab", "today", "--noop-qa-route", "sleep",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
        defer { app.terminate() }
        let chart = element("sleep.stageChart", in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 60))
        XCTAssertTrue(app.frame.contains(chart.frame))
        // The demo's first recorded block is Light. The 40pt label gutter precedes the plot;
        // its Light lane is at 5/8 of the minimum-height plot height, before the clock axis.
        let firstBar = chart.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.55))
        firstBar.tap()
        let callout = element("sleep.stageInspection", in: app)
        XCTAssertTrue(callout.waitForExistence(timeout: 5), "A normal tap must select a stage")
        XCTAssertTrue(callout.label.hasPrefix("Light,"), callout.label)
        XCTAssertNotNil(callout.label.range(of: #"\d{1,2}:\d{2} [AP]M to \d{1,2}:\d{2} [AP]M"#,
            options: .regularExpression), callout.label)
        XCTAssertTrue(app.frame.contains(callout.frame), "The readout stays on screen")
        XCTAssertTrue(callout.label.contains("minute"), "The selected period includes its duration")
        let firstWindow = callout.label
        capture(app, "sleep-stage-tapped-light-window")

        firstBar.press(forDuration: 0.45, thenDragTo: chart.coordinate(
            withNormalizedOffset: CGVector(dx: 0.60, dy: 0.55)), withVelocity: .slow, thenHoldForDuration: 0.2)
        XCTAssertTrue(callout.exists)
        XCTAssertNotEqual(callout.label, firstWindow, "Holding while dragging reads the new period")
        XCTAssertTrue(callout.label.hasPrefix("REM,"), "Dragging into REM shows that period: \(callout.label)")
        XCTAssertNotNil(callout.label.range(of: #"\d{1,2}:\d{2} [AP]M to \d{1,2}:\d{2} [AP]M"#,
            options: .regularExpression), callout.label)
        XCTAssertTrue(app.frame.contains(callout.frame))
        capture(app, "sleep-stage-held-drag-window")

        chart.coordinate(withNormalizedOffset: CGVector(dx: 0.20, dy: 0.05)).tap()
        XCTAssertFalse(callout.exists, "A tap in empty chart space dismisses the retained readout")
        let beforeScroll = chart.frame.minY
        firstBar.press(forDuration: 0.05, thenDragTo: firstBar.withOffset(CGVector(dx: 0, dy: -100)))
        XCTAssertLessThan(chart.frame.minY, beforeScroll - 20, "Ordinary movement still scrolls before a hold")
        XCTAssertFalse(callout.exists)
        capture(app, "sleep-stage-ordinary-chart-scroll")
        #endif
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
