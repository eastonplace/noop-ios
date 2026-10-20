import XCTest

/// Production Settings navigation and native controls, using only the simulator demo host.
/// These tests do not change preferences, request notification permission, or start a session.
@MainActor
final class NotificationSettingsUITests: XCTestCase {
    private enum TextSize: String {
        case normal = "UICTContentSizeCategoryL"
        case accessibilityXXXL = "UICTContentSizeCategoryAccessibilityXXXL"
    }

    private enum HarnessError: Error {
        case unreachable(String)
    }

    func testNotificationsNormal() throws {
        try assertNotifications(size: .normal)
    }

    func testNotificationsAccessibilityXXXL() throws {
        try assertNotifications(size: .accessibilityXXXL)
    }

    private func assertNotifications(size: TextSize) throws {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        try XCTSkipUnless(isSimulator, "Notification demo UI qualification runs only on Simulator")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = [
            // This existing simulator-only host bypasses overlays without recording consent.
            "--noop-coach-shell-qa", "--demo-seed",
            "--noop-qa-route", "settings-notificationsAlerts",
            "--noop-lift-demo", "fresh",
            "-UIPreferredContentSizeCategoryName", size.rawValue,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
        defer { app.terminate() }

        let notificationsBar = app.navigationBars["Notifications"]
        try requireExists(notificationsBar, in: app, timeout: 60)
        try assertHeader("Delivery status", in: app)
        let permission = text("Notification permission", in: app)
        try reveal(permission, in: app)
        let permissionStates = [
            "Allowed", "Quiet delivery", "Temporary permission", "Off in system settings",
            "Not requested", "Unavailable",
        ]
        let status = app.staticTexts.matching(NSPredicate(format: "label IN %@", permissionStates)).firstMatch
        // LabeledContent can expose its title and value separately or as one accessibility label.
        XCTAssertTrue(status.exists || permissionStates.contains(where: { permission.label.contains($0) }),
                      "Delivery status must report the actual system authorization state")
        try assertButton("Open system notification settings", in: app)
        // Inspect the settings command, but never leave the app or request OS permission.
        capture(app, "notifications-\(size)-top-permission")

        let preview = try assertButton("Preview Essentials", in: app)
        preview.tap()
        let useEssentials = app.buttons["Use Essentials"]
        try requireExists(useEssentials, in: app)
        XCTAssertTrue(useEssentials.isEnabled, "The preview offers the explicitly confirmed preset")
        capture(app, "notifications-\(size)-essentials-preview")
        let cancel = app.buttons["Cancel"]
        try requireExists(cancel, in: app)
        cancel.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: useEssentials)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "Cancel closes the preview without applying Essentials")
        XCTAssertTrue(notificationsBar.exists)

        try assertHeader("Sleep", in: app)
        try assertButton("Morning summary", in: app)
        try assertSwitch("Wind-down reminder", in: app)
        try assertButton("Wake alarm", in: app)
        capture(app, "notifications-\(size)-sleep")

        try assertHeader("Training", in: app)
        for name in ["Scheduled workout", "Workout summary", "Daily strain target"] {
            try assertButton(name, in: app)
        }
        capture(app, "notifications-\(size)-training")

        try assertHeader("Habits", in: app)
        try assertButton("Journal check-in", in: app)
        let checkInTime = app.datePickers["Check-in time"]
        try reveal(checkInTime, in: app)
        XCTAssertTrue(checkInTime.isEnabled, "The saved check-in time remains editable")
        try assertButton("Check-in days", in: app)
        capture(app, "notifications-\(size)-habits")

        try assertHeader("Device", in: app)
        try assertSwitch("Low and full battery alerts", in: app)
        try assertSwitch("Predictive battery reminders", in: app)
        capture(app, "notifications-\(size)-middle-battery")

        try assertHeader("Reviews", in: app)
        try assertButton("Weekly review", in: app)
        try assertButton("Review day", in: app)
        let reviewTime = app.datePickers["Review time"]
        try reveal(reviewTime, in: app)
        XCTAssertTrue(reviewTime.isEnabled, "The saved weekly review time remains editable")
        capture(app, "notifications-\(size)-reviews")

        try assertHeader("Recovery", in: app)
        try assertSwitch("Health-pattern alerts", in: app)
        try assertHeader("Timing & privacy", in: app)
        for name in ["Proactive notifications", "Preview new advice without sending",
                     "Quiet hours for proactive advice", "Show health details in previews"] {
            try assertSwitch(name, in: app)
        }
        capture(app, "notifications-\(size)-bottom-privacy-controls")

        let privacyCopy = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Proactive advice is limited to 2 notices per day"
        )).firstMatch
        // The full footer can be taller than the viewport at AX XXXL. Read its complete
        // accessibility copy without claiming that the whole paragraph fits on screen.
        try reveal(privacyCopy, in: app, allowOversizedText: true)
        XCTAssertTrue(privacyCopy.label.contains("Private previews are the default"))
        XCTAssertTrue(privacyCopy.label.contains("sensitive journal details are never included"))
        XCTAssertTrue(privacyCopy.label.contains("iOS preview settings still apply"))
        capture(app, "notifications-\(size)-privacy-explanation")

        let wristLink = try assertButton("Wrist alerts & actions", in: app)
        capture(app, "notifications-\(size)-bottom-wrist-link")
        wristLink.tap()
        let wristBar = app.navigationBars["Wrist alerts & actions"]
        try requireExists(wristBar, in: app)
        try assertSwitch("Enable wrist alerts", in: app)
        capture(app, "notifications-\(size)-wrist-editor")
        let back = wristBar.buttons["Notifications"]
        try requireExists(back, in: app)
        XCTAssertTrue(back.isHittable, "The wrist editor keeps native back navigation reachable")
        back.tap()
        try requireExists(notificationsBar, in: app)
        try reveal(button("Wrist alerts & actions", in: app), in: app)
        XCTAssertFalse(wristBar.exists, "Back returns to Notifications rather than dismissing Settings")
        capture(app, "notifications-\(size)-returned-from-wrist")
    }

    private func text(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@ OR label BEGINSWITH[c] %@", label, label + ",")).firstMatch
    }

    private func button(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@",
                                         label, label, label + ",")).firstMatch
    }

    private func assertHeader(_ label: String, in app: XCUIApplication) throws {
        try reveal(text(label, in: app), in: app)
    }

    @discardableResult
    private func assertButton(_ label: String, in app: XCUIApplication) throws -> XCUIElement {
        let control = button(label, in: app)
        try reveal(control, in: app)
        XCTAssertTrue(control.isEnabled, "\(label) remains enabled")
        XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(label) keeps a usable native row touch target")
        return control
    }

    private func assertSwitch(_ label: String, in app: XCUIApplication) throws {
        let control = app.switches.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ",")).firstMatch
        try reveal(control, in: app)
        XCTAssertTrue(control.isEnabled, "\(label) remains enabled")
        XCTAssertTrue(["0", "1"].contains(control.value as? String ?? ""),
                      "\(label) exposes its saved native on/off value")
    }

    private func requireExists(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 10) throws {
        guard element.waitForExistence(timeout: timeout) else {
            fail("Required element did not appear", in: app)
            throw HarnessError.unreachable("Required element did not appear")
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, allowOversizedText: Bool = false) throws {
        // Native List creates rows lazily. Each checkpoint is visited in display order;
        // use small bounded swipes so an AX row cannot be skipped by a full-screen fling.
        for _ in 0..<40 {
            if element.exists && element.isHittable && app.frame.contains(element.frame) { return }
            let surface = app.collectionViews.allElementsBoundByIndex.first(where: \.isHittable)
                ?? app.tables.allElementsBoundByIndex.first(where: \.isHittable)
                ?? app.scrollViews.allElementsBoundByIndex.first(where: \.isHittable)
            guard let surface else {
                fail("No native settings list was available to scroll", in: app)
                throw HarnessError.unreachable("Missing settings list")
            }
            // Only the long explanatory footer may exceed a screen. Controls and headers
            // always require the complete frame above; partial visibility never qualifies them.
            if allowOversizedText && element.exists && element.isHittable
                && element.frame.height > surface.frame.height
                && surface.frame.intersection(element.frame).height > 100 { return }
            let targetIsAbove = element.exists && !element.frame.isEmpty
                && element.frame.maxY < surface.frame.midY
            let start = targetIsAbove ? 0.42 : 0.72
            let end = targetIsAbove ? 0.72 : 0.42
            surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
                .press(forDuration: 0.05, thenDragTo: surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)))
        }
        fail("Required row was not fully visible and hittable after bounded scrolling", in: app)
        throw HarnessError.unreachable("Required row was not reachable")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func fail(_ message: String, in app: XCUIApplication) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "notifications-failure-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        capture(app, "notifications-failure-screen")
        XCTFail(message)
    }
}
