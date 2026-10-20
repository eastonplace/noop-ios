import XCTest

/// Presentation and navigation proof for the approved H2 header, M1 Health Monitor,
/// display-only dashboard preferences, and native WHOOP Settings.
/// Run against the task simulator. No device command or log export is activated.
@MainActor
final class ApprovedDashboardUITests: XCTestCase {
    private enum TextSize: String {
        case normal = "UICTContentSizeCategoryL"
        case accessibilityXXXL = "UICTContentSizeCategoryAccessibilityXXXL"
    }

    private enum HarnessError: Error {
        case unreachable(String)
        case invalidValue(String)
    }

    private struct Selection: Equatable {
        let summary: [String]
        let health: [String]
    }

    func testTodayNormal() throws { try assertToday(size: .normal) }
    func testTodayAccessibilityXXXL() throws { try assertToday(size: .accessibilityXXXL) }
    func testDashboardSettingsSelectionPersists() throws { try assertSettingsRoundTrip() }
    func testDashboardSettingsAccessibilityXXXL() throws { try assertSettingsAccessibility() }
    func testWHOOPSettingsNormal() throws { try assertWHOOPSettings(size: .normal) }
    func testWHOOPSettingsAccessibilityXXXL() throws { try assertWHOOPSettings(size: .accessibilityXXXL) }

    func testDeviceRegistryRemainsReachableWithoutCommandDashboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "settings-whoop")
        defer { app.terminate() }
        let manageDevices = app.buttons["settings.whoop.manageDevices"]
        try requireExists(element("settings.whoop.connection", in: app), in: app, timeout: 60)
        try reveal(manageDevices, in: app)
        manageDevices.tap()
        try waitFor(manageDevices, predicate: "exists == false", in: app)

        let title = app.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", "Devices")).firstMatch
        try requireExists(title, in: app)
        let pairedCount = app.staticTexts.matching(NSPredicate(format: "label MATCHES[cd] %@", "[0-9]+ paired")).firstMatch
        try reveal(pairedCount, in: app, needsHitTarget: false)
        if pairedCount.label == "0 paired" {
            try reveal(app.staticTexts["No devices paired"], in: app, needsHitTarget: false)
        } else {
            let deviceActions = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Device actions for ")).firstMatch
            try reveal(deviceActions, in: app)
        }
        let addDevice = app.buttons.matching(NSPredicate(format: "label ==[cd] %@", "Add a device")).firstMatch
        try reveal(addDevice, in: app)
        XCTAssertTrue(addDevice.isEnabled, "The registry preserves its Add a device entry point")
        capture(app, "device-registry-without-command-dashboard")
        for retiredTitle in ["Command Centre", "Command Center", "Command Deck", "Telemetry"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", retiredTitle)).firstMatch.exists,
                           "The registry does not embed the retired \(retiredTitle) dashboard")
        }
    }

    func testPreservedSleepStagesPresentation() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "sleep")
        defer { app.terminate() }
        let sleepTitle = app.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", "Sleep")).firstMatch
        try requireExists(sleepTitle, in: app, timeout: 60)
        let stages = app.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", "Sleep stages")).firstMatch
        try reveal(stages, in: app, needsHitTarget: false)
        capture(app, "preserved-sleep-stages-presentation")
    }

    private func launch(_ app: XCUIApplication, route: String? = nil, size: TextSize = .normal) {
        app.terminate()
        app.launchArguments = [
            "--noop-coach-shell-qa", "--demo-seed", "--noop-lift-demo", "fresh",
            "--demo-tab", "today",
            "-UIPreferredContentSizeCategoryName", size.rawValue,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark",
        ]
        if let route { app.launchArguments += ["--noop-qa-route", route] }
        app.launch()
    }

    private func assertToday(size: TextSize) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, size: size)
        defer { app.terminate() }
        let device = app.buttons["app.deviceStatus"]
        try requireExists(device, in: app, timeout: 60)
        for id in ["app.deviceStatus", "app.notifications", "app.settings"] {
            let button = app.buttons[id]
            try reveal(button, in: app)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(id) retains its touch target")
            XCTAssertFalse(button.label.isEmpty)
        }
        XCTAssertTrue(device.label.contains("Today"), "The page title remains part of the device entry point")
        let headerY = device.frame.minY
        capture(app, "today-\(size)-H2-header-white-plus")

        let plus = app.buttons["app.quickActions"]
        try reveal(plus, in: app)
        XCTAssertEqual(plus.label, "Quick Actions")
        XCTAssertGreaterThanOrEqual(plus.frame.height, 54)
        plus.tap()
        try requireExists(app.buttons["quickActions.close"], in: app)
        capture(app, "today-\(size)-quick-actions-open")
        app.buttons["quickActions.close"].tap()
        try waitFor(app.buttons["quickActions.close"], predicate: "exists == false", in: app)

        let title = element("today.health.title", in: app)
        try reveal(title, in: app, needsHitTarget: false, viewport: app.scrollViews.firstMatch)
        XCTAssertEqual(title.label, "Health Monitor", "The M1 heading has no metric count")
        let health = element("today.health.monitor", in: app)
        XCTAssertEqual(health.buttons.matching(NSPredicate(format: "label CONTAINS[cd] 'custom' ")).count, 0,
                       "Health customization lives in Settings")
        capture(app, "today-\(size)-M1-health-top")
        assertPinnedHeader(device, initialY: headerY, in: app)
        let allMetrics = app.buttons["today.health.allMetrics"]
        try reveal(allMetrics, in: app)
        XCTAssertGreaterThanOrEqual(allMetrics.frame.height, 44)
        try reveal(app.buttons["today.health.dataSources"], in: app)
        capture(app, "today-\(size)-M1-health-footer")
        assertPinnedHeader(device, initialY: headerY, in: app)
        device.tap()
        try requireExists(element("settings.whoop.connection", in: app), in: app)
        capture(app, "today-\(size)-scrolled-header-opens-native-whoop")
        try closeSettingsToToday(in: app)
        try reveal(allMetrics, in: app, direction: .down)
        allMetrics.tap()
        try waitFor(allMetrics, predicate: "exists == false", in: app)
        let destinationTitle = app.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", "All metrics")).firstMatch
        try requireExists(destinationTitle, in: app)
        capture(app, "today-\(size)-all-metrics-destination")
    }

    private func assertSettingsRoundTrip() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "settings-todayDashboard")
        defer { app.terminate() }
        let original = try selection(in: app)
        var restoredOriginal = false
        // The exact enabled order is restored through the same native controls, including
        // selections that existed before this test. Cleanup navigates in the current
        // process: the task simulator must not need a third process launch to restore it.
        defer {
            if !restoredOriginal {
                do {
                    try openTodayDashboardSettings(in: app)
                    try setSelection(original, in: app)
                    XCTAssertEqual(try selection(in: app), original, "Restore the pre-test selection and order")
                } catch { XCTFail("Could not restore dashboard preferences: \(error)") }
            }
        }

        let allScores = Selection(summary: ["recovery", "strain", "sleep"], health: original.health)
        try setSelection(allScores, in: app)
        try reveal(app.switches["today.summary.recovery"], in: app, direction: .down)
        for name in allScores.summary {
            XCTAssertTrue(try switchValue(app.switches["today.summary.\(name)"]))
        }
        capture(app, "dashboard-settings-three-summary-switches")
        try reveal(app.buttons["todayDashboard.edit"], in: app, direction: .down)
        app.buttons["todayDashboard.edit"].tap()
        capture(app, "dashboard-settings-native-edit-order-controls")
        // Leave native edit mode before changing switches. XCTest's Switch proxy is
        // not a reorder handle, and dragging it would not prove native reordering.
        app.buttons["todayDashboard.edit"].tap()

        let changed = Selection(summary: ["strain", "recovery"], health: ["hrv", "restingHr", "respiratory"])
        try setSelection(changed, in: app)
        launch(app, route: "settings-todayDashboard")
        XCTAssertEqual(try selection(in: app), changed, "Both ordered selections persist across process relaunch")
        capture(app, "dashboard-settings-persisted-summary-order")
        try reveal(app.switches["today.health.respiratory"], in: app)
        capture(app, "dashboard-settings-persisted-health-selection")

        try closeSettingsToToday(in: app)
        try requireExists(app.buttons["today.summary.pillar.strain"], in: app, timeout: 60)
        let strain = app.buttons["today.summary.pillar.strain"]
        let recovery = app.buttons["today.summary.pillar.recovery"]
        try reveal(strain, in: app)
        try reveal(recovery, in: app)
        XCTAssertFalse(app.buttons["today.summary.pillar.sleep"].exists)
        XCTAssertLessThan(strain.frame.midX, recovery.frame.midX, "Today follows the saved summary order")
        capture(app, "today-selected-summary-order")
        for name in changed.health { try reveal(app.buttons["today.health.tile.\(name)"], in: app) }
        XCTAssertFalse(app.buttons["today.health.tile.sleep"].exists)
        capture(app, "today-three-selected-health-metrics")
        try openTodayDashboardSettings(in: app)
        try setSelection(original, in: app)
        XCTAssertEqual(try selection(in: app), original, "Restore the exact pre-test enabled selections and their order")
        capture(app, "dashboard-settings-original-selection-restored")
        restoredOriginal = true
    }

    private func returnToSettingsRoot(in app: XCUIApplication) throws {
        // Deep-linked Settings pages are native pushes above this root. Scope Back to
        // the navigation bar so a content button with the same label cannot be tapped.
        for _ in 0..<4 {
            if app.navigationBars["Settings"].exists { return }
            let back = app.navigationBars.buttons.matching(NSPredicate(
                format: "label ==[cd] %@ OR label ==[cd] %@", "Settings", "Back"
            )).firstMatch
            try requireExists(back, in: app)
            back.tap()
        }
        captureFailure(in: app)
        throw HarnessError.unreachable("Could not return to the native Settings root")
    }

    private func closeSettingsToToday(in app: XCUIApplication) throws {
        try returnToSettingsRoot(in: app)
        let done = app.buttons["settings.done"]
        try requireExists(done, in: app)
        done.tap()
        try waitFor(done, predicate: "exists == false", in: app)
        try requireExists(app.buttons["app.settings"], in: app)
    }

    private func openTodayDashboardSettings(in app: XCUIApplication) throws {
        if element("todayDashboard.settings", in: app).exists { return }
        if !app.buttons["settings.done"].exists {
            let profile = app.buttons["app.settings"]
            try reveal(profile, in: app, direction: .down)
            profile.tap()
            try requireExists(app.buttons["settings.done"], in: app)
        }
        try returnToSettingsRoot(in: app)
        let dashboard = app.buttons["settings.row.todayDashboard"]
        try reveal(dashboard, in: app)
        dashboard.tap()
        try requireExists(element("todayDashboard.settings", in: app), in: app)
    }

    private func assertSettingsAccessibility() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "settings-todayDashboard", size: .accessibilityXXXL)
        defer { app.terminate() }
        let saved = try selection(in: app)
        for name in ["recovery", "strain", "sleep"] {
            try reveal(app.switches["today.summary.\(name)"], in: app, needsHitTarget: false)
            capture(app, "dashboard-settings-AX-summary-\(name)")
        }
        for name in saved.health {
            try reveal(app.switches["today.health.\(name)"], in: app, needsHitTarget: false)
        }
        capture(app, "dashboard-settings-AX-health-selection")
        XCTAssertEqual(try selection(in: app), saved, "Reading large-text Settings does not alter display preferences")
    }

    private func assertWHOOPSettings(size: TextSize) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "settings-whoop", size: size)
        defer { app.terminate() }
        let connection = element("settings.whoop.connection", in: app)
        try requireExists(connection, in: app, timeout: 60)
        try reveal(connection, in: app, needsHitTarget: false)
        assertReadout(connection, title: "Status")
        capture(app, "whoop-\(size)-connection")
        for (id, title) in [("battery", "Battery"), ("liveHR", "Live heart rate"), ("packet", "Last packet")] {
            let row = element("settings.whoop.\(id)", in: app)
            try reveal(row, in: app, needsHitTarget: false)
            assertReadout(row, title: title)
            if id == "battery" || (size == .accessibilityXXXL && id == "liveHR") {
                capture(app, "whoop-\(size)-\(id)")
            }
        }
        let deviceDetails = element("settings.whoop.deviceDetails", in: app)
        try reveal(deviceDetails, in: app)
        deviceDetails.tap()
        for (id, title) in [("bond", "Encrypted link"), ("clock", "Clock latched"), ("wrist", "Wrist"),
                            ("charging", "Charging"), ("runtime", "Estimated runtime")] {
            let row = element("settings.whoop.\(id)", in: app)
            try reveal(row, in: app, needsHitTarget: false)
            assertReadout(row, title: title)
        }
        capture(app, "whoop-\(size)-device-details")
        for (id, title) in [("history", "Current session"), ("lastSync", "Last completed sync")] {
            let row = element("settings.whoop.\(id)", in: app)
            try reveal(row, in: app, needsHitTarget: false)
            assertReadout(row, title: title)
        }
        capture(app, "whoop-\(size)-history")
        let historyDetails = element("settings.whoop.historyDetails", in: app)
        try reveal(historyDetails, in: app)
        historyDetails.tap()
        for (id, title) in [("frontier", "Saved through"), ("chunks", "Chunks this session"), ("window", "History window")] {
            let row = element("settings.whoop.\(id)", in: app)
            try reveal(row, in: app, needsHitTarget: false)
            assertReadout(row, title: title)
        }
        capture(app, "whoop-\(size)-history-details")
        for id in ["sync", "vibration", "refreshBattery", "rescan", "disconnect", "manageDevices"] {
            let command = app.buttons["settings.whoop.\(id)"]
            // Disabled offline controls still must be visible. Reaching a command is
            // distinct from activating BLE, pairing, or a log export.
            try reveal(command, in: app, needsHitTarget: false)
            XCTAssertGreaterThanOrEqual(command.frame.height, 44)
            if id == "sync" || id == "manageDevices" { capture(app, "whoop-\(size)-controls-\(id)") }
        }
        for id in ["copyLog", "saveLog", "testCentre"] {
            try reveal(app.buttons["settings.whoop.\(id)"], in: app, needsHitTarget: false)
        }
        capture(app, "whoop-\(size)-diagnostics")
        XCTAssertFalse(element("settings.whoop.feedback", in: app).exists, "Read-only navigation issues no device command")
    }

    private func selection(in app: XCUIApplication) throws -> Selection {
        let container = element("todayDashboard.settings", in: app)
        try requireExists(container, in: app, timeout: 60)
        guard let raw = container.value as? String else {
            captureFailure(in: app)
            throw HarnessError.invalidValue("Missing ordered dashboard selection readback")
        }
        let fields = raw.split(separator: ";").map(String.init)
        guard fields.count == 2, fields[0].hasPrefix("summary:"), fields[1].hasPrefix("health:") else {
            captureFailure(in: app)
            throw HarnessError.invalidValue("Unexpected dashboard selection readback: \(raw)")
        }
        let summary = fields[0].dropFirst("summary:".count).split(separator: ",").map(String.init)
        let health = fields[1].dropFirst("health:".count).split(separator: ",").map(String.init)
        guard !summary.isEmpty, !health.isEmpty else { throw HarnessError.invalidValue("Empty dashboard selection") }
        return Selection(summary: summary, health: health)
    }

    private func setSelection(_ target: Selection, in app: XCUIApplication) throws {
        try setOrderedSelection(target.summary, group: "summary", in: app)
        try setOrderedSelection(target.health, group: "health", in: app)
        XCTAssertEqual(try selection(in: app), target)
    }

    private func setOrderedSelection(_ target: [String], group: String, in app: XCUIApplication) throws {
        guard let anchor = target.first else { throw HarnessError.invalidValue("A selection requires one metric") }
        let saved = try selection(in: app)
        var current = group == "summary" ? saved.summary : saved.health
        if current == target { return }
        // Make room before enabling a new anchor at the nine-card limit.
        if !current.contains(anchor) {
            if group == "health", current.count == 9, let last = current.last {
                try setSwitch("today.\(group).\(last)", to: false, in: app)
                current.removeLast()
            }
            try setSwitch("today.\(group).\(anchor)", to: true, in: app, direction: .down)
            current.append(anchor)
        }
        for name in current where name != anchor { try setSwitch("today.\(group).\(name)", to: false, in: app) }
        for name in target.dropFirst() { try setSwitch("today.\(group).\(name)", to: true, in: app) }
    }

    private func setSwitch(_ id: String, to desired: Bool, in app: XCUIApplication,
                           direction: ScrollDirection = .up) throws {
        let row = app.switches[id]
        try reveal(row, in: app, direction: direction)
        let rowFrame = row.frame
        let controls = row.descendants(matching: .switch).allElementsBoundByIndex.filter {
            let frame = $0.frame
            return $0.identifier.isEmpty && frame.width > 0 && frame.height > 0
                && frame.width < rowFrame.width / 2 && rowFrame.contains(frame)
        }
        guard controls.count == 1, let control = controls.first else {
            captureFailure(in: app)
            throw HarnessError.unreachable("Expected one native switch for \(id)")
        }
        let previous = try switchValue(row)
        XCTAssertEqual(try switchValue(control), previous)
        if previous != desired {
            XCTAssertTrue(control.isEnabled, "\(id) permits the requested selection change")
            control.tap()
        }
        try waitFor(row, predicate: desired ? "value == '1'" : "value == '0'", in: app)
        XCTAssertEqual(try switchValue(control), desired)
    }

    private func switchValue(_ toggle: XCUIElement) throws -> Bool {
        guard let raw = toggle.value as? String, raw == "0" || raw == "1" else {
            throw HarnessError.invalidValue("Expected native switch value for \(toggle.identifier)")
        }
        return raw == "1"
    }

    private func readout(_ row: XCUIElement) -> String {
        ([row.label, row.value as? String ?? ""] + row.staticTexts.allElementsBoundByIndex.map(\.label))
            .joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func assertReadout(_ row: XCUIElement, title: String) {
        let value = readout(row).replacingOccurrences(of: title, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        XCTAssertFalse(value.isEmpty, "\(title) exposes a value as well as its field label")
    }

    private func assertPinnedHeader(_ device: XCUIElement, initialY: CGFloat, in app: XCUIApplication) {
        let exists = device.exists
        let frame = device.frame
        let hittable = device.isHittable
        if !exists || !hittable || !app.frame.contains(frame) || abs(frame.minY - initialY) > 1 {
            let state = XCTAttachment(string: "exists=\(exists)\nlabel=\(device.label)\nisHittable=\(hittable)\nframe=\(frame)\ninitialY=\(initialY)\nappFrame=\(app.frame)")
            state.name = "pinned-header-hit-test-state"
            state.lifetime = .keepAlways
            add(state)
            captureFailure(in: app)
        }
        XCTAssertTrue(device.exists, "The Today device header remains in the accessibility tree after Health scrolling")
        XCTAssertTrue(device.isHittable, "The pinned Today device entry point remains tappable after Health scrolling")
        XCTAssertTrue(app.frame.contains(device.frame), "The pinned Today header remains fully on screen")
        XCTAssertEqual(device.frame.minY, initialY, accuracy: 1, "Health scrolling preserves the header's vertical position")
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private enum ScrollDirection { case up, down }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        direction: ScrollDirection = .up, needsHitTarget: Bool = true,
                        viewport: XCUIElement? = nil) throws {
        for attempt in 0..<20 {
            let visibleFrame = viewport.map { $0.frame.intersection(app.frame) } ?? app.frame
            if element.identifier == "today.health.title", attempt < 4 {
                print("[health-scroll] attempt=\(attempt) targetFrame=\(element.frame) viewportFrame=\(String(describing: viewport?.frame)) isHittable=\(element.isHittable)")
                capture(app, "health-scroll-attempt-\(attempt)")
            }
            if element.exists, element.frame.width > 0, element.frame.height > 0,
               visibleFrame.contains(element.frame), !needsHitTarget || element.isHittable { return }
            if attempt == 0 { _ = element.waitForExistence(timeout: 3) }
            let surface = app.scrollViews.allElementsBoundByIndex.first(where: \.isHittable)
                ?? app.tables.allElementsBoundByIndex.first(where: \.isHittable) ?? app
            // Search both ways: native Settings reorders enabled rows after a switch changes.
            let forward = attempt < 10
            switch (direction, forward) {
            case (.up, true), (.down, false): surface.swipeUp()
            case (.down, true), (.up, false): surface.swipeDown()
            }
        }
        captureFailure(in: app)
        throw HarnessError.unreachable("Could not reveal \(element.identifier)")
    }

    private func requireExists(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 10) throws {
        guard element.waitForExistence(timeout: timeout) else {
            captureFailure(in: app)
            throw HarnessError.unreachable("Missing \(element.identifier)")
        }
    }

    private func waitFor(_ element: XCUIElement, predicate: String, in app: XCUIApplication) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: 8) == .completed else {
            captureFailure(in: app)
            throw HarnessError.invalidValue("Expected \(predicate) for \(element.identifier)")
        }
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func captureFailure(in app: XCUIApplication) {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "approved-dashboard-failure-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        capture(app, "approved-dashboard-failure-screen")
    }
}
