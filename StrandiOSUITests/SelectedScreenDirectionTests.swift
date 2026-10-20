import XCTest

/// UI proof for directions 2A, 3B and 5A. Run on the task simulator with demo fixtures.
/// Preference tests preserve the existing container and restore the seven values they change.
@MainActor
final class SelectedScreenDirectionTests: XCTestCase {
    private enum TextSize: String {
        case normal = "UICTContentSizeCategoryL"
        case accessibilityXXXL = "UICTContentSizeCategoryAccessibilityXXXL"
    }

    private enum HarnessError: Error {
        case unreachable(String)
        case invalidSwitchValue(String)
    }

    private let settingNames = ["journal", "live", "workout", "strength", "intervals", "breathe", "recentActivity"]
    private let menuNames = ["journal", "live", "startWorkout", "strength", "intervals", "breathe"]

    func testLiveHRNormal() throws { try assertLiveHR(size: .normal) }
    func testLiveHRAccessibilityXXXL() throws { try assertLiveHR(size: .accessibilityXXXL) }
    func testBreatheNormal() throws { try assertBreathe(size: .normal) }
    func testBreatheAccessibilityXXXL() throws { try assertBreathe(size: .accessibilityXXXL) }
    func testQuickActionSettingsNormal() throws { try assertSettings(size: .normal) }
    func testQuickActionSettingsAccessibilityXXXL() throws { try assertSettings(size: .accessibilityXXXL) }

    private func launch(_ app: XCUIApplication, route: String, size: TextSize) {
        app.terminate()
        app.launchArguments = [
            "--demo-seed", "--noop-qa-route", route,
            // Load the existing simulator-only idle Lift fixture so a preceding routine
            // test's active session cannot resume over this route or disable Workout.
            "--noop-lift-demo", "fresh",
            "-UIPreferredContentSizeCategoryName", size.rawValue,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
    }

    private func assertLiveHR(size: TextSize) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "live-hr", size: size)
        defer { app.terminate() }

        let freshness = element("live.hr.freshness", in: app)
        try reveal(freshness, in: app)
        XCTAssertEqual(freshness.value as? String, "Offline", "A demo launch without a strap must identify the offline state")
        capture(app, "live-hr-\(size)-overview")

        // Reachability matters at large sizes even when a command starts below the fold.
        // Do not scan or pair hardware as part of this simulator presentation test.
        for name in ["scan", "startWorkout", "manageDevices"] {
            let command = app.buttons["live.hr.\(name)"]
            try reveal(command, in: app)
            XCTAssertTrue(command.isEnabled, "\(name) remains available while offline")
            XCTAssertGreaterThanOrEqual(command.frame.height, 44, "\(name) has a usable touch target")
            capture(app, "live-hr-\(size)-\(name)")
        }
    }

    private func assertBreathe(size: TextSize) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "breathe", size: size)
        defer { app.terminate() }

        let phase = element("breathe.phase", in: app)
        try requireExists(app.buttons["breathe.mode.breathe"], timeout: 60)
        try reveal(phase, in: app)
        XCTAssertEqual(phase.label, "Ready to breathe")
        try reveal(element("breathe.timeline", in: app), in: app)
        capture(app, "breathe-\(size)-ready-timeline")

        let start = app.buttons["breathe.start"]
        try reveal(start, in: app)
        start.tap()
        let stop = app.buttons["breathe.stop"]
        try requireExists(stop)
        XCTAssertFalse(start.exists, "A running session exposes Stop instead of a second Start")

        let status = element("breathe.status", in: app)
        try reveal(status, in: app, direction: .down)
        XCTAssertEqual(status.label, "Session live")

        // A running label alone is insufficient: the existing phase clock must change phase.
        try reveal(phase, in: app)
        XCTAssertTrue(["Breathe in…", "Breathe out…"].contains(phase.label))
        let initialPhase = phase.label
        let nextPhase = initialPhase == "Breathe in…" ? "Breathe out…" : "Breathe in…"
        let advances = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", nextPhase),
            object: phase
        )
        XCTAssertEqual(XCTWaiter.wait(for: [advances], timeout: 14), .completed, "Starting a session advances its inhale/exhale clock")
        capture(app, "breathe-\(size)-running-timeline")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS[cd] 'pause'")).count, 0,
                       "This direction preserves the shipped Start/Stop behavior")

        try reveal(stop, in: app)
        stop.tap()
        try requireExists(start)
        XCTAssertFalse(stop.exists)
        try reveal(status, in: app, direction: .down)
        XCTAssertEqual(status.label, "Ready")
        try reveal(phase, in: app)
        XCTAssertEqual(phase.label, "Ready to breathe", "Stop returns the actual phase display to its idle state")
        capture(app, "breathe-\(size)-stopped-timeline")
        try reveal(start, in: app)
        XCTAssertTrue(start.isEnabled, "The stopped session can be started again")
    }

    private func assertSettings(size: TextSize) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "settings-quickActions", size: size)
        defer { app.terminate() }
        try requireExists(app.switches["settings.quickActions.journal"], timeout: 60)

        // The task simulator can already contain preferences. Save them before establishing
        // the all-on presentation fixture; registered-default behavior has separate unit coverage.
        var original: [String: Bool] = [:]
        for name in settingNames {
            let toggle = app.switches["settings.quickActions.\(name)"]
            try reveal(toggle, in: app)
            original[name] = try switchValue(toggle)
        }
        defer {
            launch(app, route: "settings-quickActions", size: size)
            for name in settingNames {
                if let value = original[name] {
                    do { try setSwitch(name, to: value, in: app) }
                    catch { XCTFail("Could not restore \(name): \(error)") }
                }
            }
        }

        launch(app, route: "settings-quickActions", size: size)
        for name in settingNames { try setSwitch(name, to: true, in: app) }
        try reveal(app.switches["settings.quickActions.journal"], in: app, direction: .down)
        capture(app, "settings-\(size)-six-actions-top")
        try reveal(app.switches["settings.quickActions.recentActivity"], in: app)
        capture(app, "settings-\(size)-recent-activity")

        try setSwitch("breathe", to: false, in: app, direction: .down)
        try setSwitch("recentActivity", to: false, in: app)
        launch(app, route: "settings-quickActions", size: size)
        for name in ["breathe", "recentActivity"] {
            let toggle = app.switches["settings.quickActions.\(name)"]
            try reveal(toggle, in: app)
            XCTAssertFalse(try switchValue(toggle), "\(name) persists across process relaunch")
        }
        capture(app, "settings-\(size)-persisted-hidden")

        launch(app, route: "quick-actions", size: size)
        try requireExists(app.buttons["quickActions.close"], timeout: 60)
        XCTAssertFalse(app.buttons["quickActions.breathe"].exists, "The hidden Breathe shortcut is absent from the menu")
        XCTAssertFalse(app.buttons["quickActions.recentSport"].exists, "Disabling Recent prevents its offer even when a sport is eligible")
        for name in menuNames where name != "breathe" {
            // The accessibility menu anchors its scroll view at the bottom on opening.
            try reveal(app.buttons["quickActions.\(name)"], in: app, direction: name == "journal" ? .down : .up)
        }
        capture(app, "quick-actions-\(size)-breathe-hidden")

        launch(app, route: "settings-quickActions", size: size)
        try setSwitch("breathe", to: true, in: app)
        launch(app, route: "quick-actions", size: size)
        try requireExists(app.buttons["quickActions.close"], timeout: 60)
        try reveal(app.buttons["quickActions.breathe"], in: app)
        capture(app, "quick-actions-\(size)-breathe-restored")

        launch(app, route: "settings-quickActions", size: size)
        for name in settingNames { try setSwitch(name, to: false, in: app) }
        launch(app, route: "quick-actions", size: size)
        let choose = app.buttons["quickActions.choose"]
        try requireExists(choose, timeout: 60)
        try reveal(choose, in: app)
        XCTAssertGreaterThanOrEqual(choose.frame.height, 44, "The empty menu keeps a usable Settings command")
        for name in menuNames {
            XCTAssertFalse(app.buttons["quickActions.\(name)"].exists, "All-hidden removes the \(name) command")
        }
        XCTAssertFalse(app.buttons["quickActions.recentSport"].exists)
        capture(app, "quick-actions-\(size)-all-hidden")
        choose.tap()
        try requireExists(app.switches["settings.quickActions.journal"], timeout: 15)
        let fanClosed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: app.buttons["quickActions.close"]
        )
        XCTAssertEqual(XCTWaiter.wait(for: [fanClosed], timeout: 10), .completed,
                       "Choose quick actions closes the menu and opens its Settings page")
        XCTAssertFalse(try switchValue(app.switches["settings.quickActions.journal"]),
                       "Opening Settings preserves the all-hidden preferences")
        capture(app, "settings-\(size)-from-empty-menu")
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func requireExists(_ element: XCUIElement, timeout: TimeInterval = 10) throws {
        guard element.waitForExistence(timeout: timeout) else {
            captureFailure(in: XCUIApplication())
            XCTFail("Required element did not appear; see failure hierarchy and screenshot")
            throw HarnessError.unreachable("Required element did not appear")
        }
    }

    private enum ScrollDirection { case up, down }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, direction: ScrollDirection = .up) throws {
        // SwiftUI Form can create rows lazily, so a row need not exist until it has been scrolled into view.
        for attempt in 0..<16 {
            if element.exists && element.isHittable && app.frame.contains(element.frame) { return }
            if attempt == 0 { _ = element.waitForExistence(timeout: 5) }
            if element.exists && element.isHittable && app.frame.contains(element.frame) { return }
            let surface = app.scrollViews.allElementsBoundByIndex.first(where: \.isHittable) ?? app
            switch direction {
            case .up: surface.swipeUp()
            case .down: surface.swipeDown()
            }
        }
        captureFailure(in: app)
        XCTFail("Required element was not fully visible and tappable; see failure hierarchy and screenshot")
        throw HarnessError.unreachable("Required element was not fully visible and tappable")
    }

    private func switchValue(_ toggle: XCUIElement) throws -> Bool {
        guard let value = toggle.value as? String, value == "0" || value == "1" else {
            captureFailure(in: XCUIApplication())
            XCTFail("Expected a native switch value; see failure hierarchy and screenshot")
            throw HarnessError.invalidSwitchValue("Expected a native switch value")
        }
        return value == "1"
    }

    private func setSwitch(_ name: String, to desired: Bool, in app: XCUIApplication,
                           direction: ScrollDirection = .up) throws {
        let toggle = app.switches["settings.quickActions.\(name)"]
        try reveal(toggle, in: app, direction: direction)
        if try switchValue(toggle) != desired { toggle.tap() }
        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", desired ? "1" : "0"), object: toggle
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed, "\(name) reflects its saved value")
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func captureFailure(in app: XCUIApplication) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "failure-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        capture(app, "failure-screen")
    }
}
