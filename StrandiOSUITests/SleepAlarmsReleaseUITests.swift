import XCTest

@MainActor
final class SleepAlarmsReleaseUITests: XCTestCase {
    func testSleepChartLeadsWithLargerFiguresAndAlarmsBelow() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "sleep")
        defer { app.terminate() }
        let chart = element("sleep.stageChart", in: app)
        XCTAssertTrue(chart.waitForExistence(timeout: 60))
        XCTAssertGreaterThanOrEqual(chart.frame.height, 155)
        XCTAssertGreaterThanOrEqual(chart.frame.width, 300)
        XCTAssertTrue(chart.frame.intersects(app.frame), "The chart is visible before any scroll")
        capture(app, "sleep-201-larger-kpis-and-chart")
        let alarm = element("sleep.alarm", in: app)
        for _ in 0..<4 {
            if alarm.exists && alarm.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(alarm.exists && alarm.isHittable)
        XCTAssertGreaterThan(alarm.frame.minY, chart.frame.maxY)
        capture(app, "sleep-201-chart-before-alarms")
    }

    func testMultipleAlarmsPersistAndCanBeChangedIndependently() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "sleep")
        defer { app.terminate() }
        openAlarms(in: app)
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "alarm.row."))
        let toggles = app.switches.matching(NSPredicate(format: "identifier BEGINSWITH %@", "alarm.toggle."))
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(toggles.count, 1)
        XCTAssertEqual(toggles.element(boundBy: 0).value as? String, "0")
        toggles.element(boundBy: 0).tap()
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        for expectedCount in 2...3 {
            element("alarm.add", in: app).tap()
            let save = element("alarm.editor.save", in: app)
            XCTAssertTrue(save.waitForExistence(timeout: 5))
            save.tap()
            XCTAssertTrue(element("alarm.add", in: app).waitForExistence(timeout: 5))
            XCTAssertEqual(rows.count, expectedCount)
        }
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("7:00"))
        XCTAssertTrue(rows.element(boundBy: 1).label.contains("7:10"))
        XCTAssertTrue(rows.element(boundBy: 2).label.contains("7:20"))
        capture(app, "alarms-202-three-wake-times")
        let lastToggleID = toggles.element(boundBy: 2).identifier
        let lastRowID = rows.element(boundBy: 2).identifier
        let lastToggleMatches = app.switches.matching(identifier: lastToggleID)
        XCTAssertEqual(lastToggleMatches.count, 1)
        let lastToggle = lastToggleMatches.firstMatch
        XCTAssertTrue(lastToggle.isHittable)
        XCTAssertEqual(lastToggle.value as? String, "1")
        // Hit the visible on-state thumb rather than the midpoint of the track. This is one action.
        lastToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        assertAlarmSwitchValue(lastToggleID, equals: "0", in: app)
        XCTAssertEqual(toggles.element(boundBy: 0).value as? String, "1")
        XCTAssertEqual(toggles.element(boundBy: 1).value as? String, "1")
        app.terminate()
        launch(app, route: "sleep", preservePreferences: true)
        openAlarms(in: app)
        XCTAssertEqual(rows.count, 3)
        assertAlarmSwitchValue(lastToggleID, equals: "0", in: app)
        element(lastRowID, in: app).tap()
        XCTAssertTrue(element("alarm.editor.save", in: app).waitForExistence(timeout: 5))
        capture(app, "alarms-202-edit-wake-time")
        let delete = element("alarm.editor.delete", in: app)
        for _ in 0..<5 {
            if delete.exists && delete.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(delete.exists && delete.isHittable)
        delete.tap()
        XCTAssertTrue(element("alarm.add", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(element(lastRowID, in: app).exists)
    }

    private func assertAlarmSwitchValue(_ id: String, equals expected: String, in app: XCUIApplication,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let toggle = app.switches.matching(identifier: id).firstMatch
        let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: toggle)
        let result = XCTWaiter.wait(for: [value], timeout: 5)
        if result != .completed { captureSwitchDiagnostics(id, in: app, phase: "state-mismatch") }
        XCTAssertEqual(result, .completed,
                       "Alarm switch \(id) must become \(expected); actual value is \(String(describing: toggle.value))",
                       file: file, line: line)
        XCTAssertEqual(toggle.value as? String, expected, file: file, line: line)
    }

    private func captureSwitchDiagnostics(_ id: String, in app: XCUIApplication, phase: String) {
        let matches = app.descendants(matching: .any).matching(identifier: id).allElementsBoundByIndex
        let typed = app.switches.matching(identifier: id).allElementsBoundByIndex
        let rows = matches.enumerated().map { index, item in
            "any[\(index)] type=\(item.elementType.rawValue) value=\(String(describing: item.value)) label=\(item.label) frame=\(item.frame) hittable=\(item.isHittable)"
        }
        let switches = typed.enumerated().map { index, item in
            "switch[\(index)] value=\(String(describing: item.value)) frame=\(item.frame) hittable=\(item.isHittable)"
        }
        let text = (["phase=\(phase) id=\(id) anyMatches=\(matches.count) switchMatches=\(typed.count)"]
                    + rows + switches + [app.debugDescription]).joined(separator: "\n")
        let attachment = XCTAttachment(string: text)
        attachment.name = "alarm-switch-\(phase)"
        attachment.lifetime = .keepAlways
        add(attachment)
        capture(app, "alarm-switch-\(phase)")
    }

    private func openAlarms(in app: XCUIApplication) {
        let alarm = element("sleep.alarm", in: app)
        XCTAssertTrue(element("sleep.stageChart", in: app).waitForExistence(timeout: 60))
        for _ in 0..<4 {
            if alarm.exists && alarm.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(alarm.exists && alarm.isHittable)
        alarm.tap()
        XCTAssertTrue(element("alarm.add", in: app).waitForExistence(timeout: 10))
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func launch(_ app: XCUIApplication, route: String, preservePreferences: Bool = false) {
        app.launchArguments = [
            "--noop-coach-shell-qa", "--demo-seed", "--noop-lift-demo", "fresh",
            "--demo-tab", "today", "--noop-qa-route", route,
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark",
        ]
        if preservePreferences { app.launchArguments.append("--noop-qa-preserve-preferences") }
        app.launch()
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
