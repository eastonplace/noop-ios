import XCTest

/// Production Settings navigation and native controls, using only the simulator demo host.
/// No test requests notification permission or starts a session. The Picker probe
/// temporarily selects Notify and restores the captured mode through the same native control.
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

    func testNativePickerRetains44PointTouchTarget() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Notification demo UI qualification runs only on Simulator")
        #endif
        continueAfterFailure = false
        let app = XCUIApplication()
        launchNotifications(app, size: .normal)
        defer { app.terminate() }
        try requireExists(app.navigationBars["Notifications"], in: app, timeout: 60)
        let picker = button("Morning summary", in: app)
        try reveal(picker, in: app)
        let row = try pickerRow(containing: picker, in: app)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "notifications-native-picker-row-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        // Exercise both vertical edges of a 44-point target, beyond the inner AX label's bounds.
        let originalValue = picker.label
        guard let originalMode = ["Off", "In app", "Notify"].first(where: { originalValue == "Morning summary, \($0)" }) else {
            fail("The native Picker must expose its saved delivery mode", in: app)
            throw HarnessError.unreachable("Missing saved Picker mode")
        }
        var restoredOriginal = true
        defer {
            if !restoredOriginal {
                do { try restorePickerMode(originalMode, originalValue: originalValue, picker: picker, in: app) }
                catch { XCTFail("Could not restore the original delivery mode: \(error)") }
            }
        }
        for offset in [-22.0, 22.0] {
            let point = CGPoint(x: picker.frame.midX, y: picker.frame.midY + offset)
            XCTAssertTrue(row.frame.contains(point))
            if picker.frame.height < 44 {
                XCTAssertFalse(picker.frame.contains(point), "The probe reaches beyond the inner AX label")
            }
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: point.x - app.frame.minX, dy: point.y - app.frame.minY)).tap()
            let option = app.buttons["Notify"]
            try requireExists(option, in: app)
            try requireExists(button("Off", in: app), in: app)
            try requireExists(button("In app", in: app), in: app)
            capture(app, "notifications-native-picker-edge-\(offset)")
            // iOS 26 can report a visible native menu item as non-hittable. Deliver the
            // actual touch and require its saved result rather than relying on that AX flag.
            restoredOriginal = false
            try activateMenuOption("Notify", in: app)
            let applied = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Morning summary, Notify"), object: picker)
            let appliedResult = XCTWaiter.wait(for: [applied], timeout: 5)
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: option)
            let dismissedResult = XCTWaiter.wait(for: [dismissed], timeout: 5)
            try restorePickerMode(originalMode, originalValue: originalValue, picker: picker, in: app)
            restoredOriginal = true
            XCTAssertEqual(appliedResult, .completed, "The exact Notify option saves the selected delivery mode")
            XCTAssertEqual(dismissedResult, .completed, "Activating Notify closes the native menu")
            XCTAssertEqual(picker.label, originalValue, "The edge probe restores the original saved value")
        }
    }

    private func activateMenuOption(_ mode: String, in app: XCUIApplication) throws {
        let option = app.buttons.matching(NSPredicate(format: "label == %@", mode)).firstMatch
        try requireExists(option, in: app)
        let frame = option.frame
        guard !frame.isEmpty, !frame.isNull, !frame.isInfinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite, app.frame.contains(frame) else {
            fail("The native \(mode) option must be fully visible before activation", in: app)
            throw HarnessError.unreachable("Invalid native menu option frame")
        }
        XCTAssertTrue(option.isEnabled, "The native \(mode) option remains enabled")
        option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    private func restorePickerMode(_ mode: String, originalValue: String, picker: XCUIElement,
                                   in app: XCUIApplication) throws {
        if !button(mode, in: app).exists {
            try reveal(picker, in: app)
            picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let option = app.buttons.matching(NSPredicate(format: "label == %@", mode)).firstMatch
        try activateMenuOption(mode, in: app)
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", originalValue), object: picker)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: option)
        guard XCTWaiter.wait(for: [restored, closed], timeout: 5) == .completed else {
            fail("The native Picker did not restore its captured delivery mode", in: app)
            throw HarnessError.unreachable("Delivery mode restoration failed")
        }
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
        launchNotifications(app, size: size)
        defer { app.terminate() }

        let notificationsBar = app.navigationBars["Notifications"]
        try requireExists(notificationsBar, in: app, timeout: 60)
        try assertHeader("Delivery status", in: app)
        let permission = text("Notification permission", in: app)
        try reveal(permission, in: app, needsHitTarget: false)
        let permissionStates = [
            "Allowed", "Quiet delivery", "Temporary permission", "Off in system settings",
            "Not requested", "Unavailable",
        ]
        let permissionRow = app.cells.containing(.staticText, identifier: permission.label).firstMatch
        try reveal(permissionRow, in: app, needsHitTarget: false)
        let stateLabels = permissionStates + permissionStates.map { "Notification permission, \($0)" }
        let status = permissionRow.staticTexts.matching(NSPredicate(format: "label IN %@", stateLabels)).firstMatch
        // Native LabeledContent may expose a combined value as a sibling of the isolated title.
        // Read only this permission row and require one complete, known system state.
        XCTAssertTrue(status.exists || stateLabels.contains(permission.label) || stateLabels.contains(permissionRow.label),
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
        if cancel.exists {
            cancel.tap()
        } else {
            // Native popovers omit the cancel-role row and expose a dismissal region instead.
            XCTAssertTrue(app.popovers.firstMatch.exists)
            let dismissRegion = app.otherElements["PopoverDismissRegion"]
            try requireExists(dismissRegion, in: app)
            dismissRegion.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.18)).tap()
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: useEssentials)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed,
                       "Cancel closes the preview without applying Essentials")
        XCTAssertTrue(notificationsBar.exists)

        try assertHeader("Sleep", in: app)
        try assertPicker("Morning summary", in: app)
        try assertSwitch("Wind-down reminder", in: app)
        try assertButton("Wake alarm", in: app)
        capture(app, "notifications-\(size)-sleep")

        try assertHeader("Training", in: app)
        for name in ["Scheduled workout", "Workout summary", "Daily strain target"] {
            try assertPicker(name, in: app)
        }
        capture(app, "notifications-\(size)-training")

        try assertHeader("Habits", in: app)
        try assertPicker("Journal check-in", in: app)
        try assertTimePicker("Check-in time", in: app)
        try assertButton("Check-in days", in: app)
        capture(app, "notifications-\(size)-habits")

        try assertHeader("Device", in: app)
        try assertSwitch("Low and full battery alerts", in: app)
        try assertSwitch("Predictive battery reminders", in: app)
        capture(app, "notifications-\(size)-middle-battery")

        try assertHeader("Reviews", in: app)
        try assertPicker("Weekly review", in: app)
        try assertPicker("Review day", in: app)
        try assertTimePicker("Review time", in: app)
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
        let nestedDone = app.buttons["settings.done"]
        try requireExists(nestedDone, in: app)
        XCTAssertTrue(nestedDone.isHittable)
        XCTAssertGreaterThanOrEqual(nestedDone.frame.height, 44)
        capture(app, "notifications-\(size)-wrist-editor")
        let back = wristBar.buttons["Notifications"]
        try requireExists(back, in: app)
        XCTAssertTrue(back.isHittable, "The wrist editor keeps native back navigation reachable")
        back.tap()
        try requireExists(notificationsBar, in: app)
        try reveal(button("Wrist alerts & actions", in: app), in: app)
        XCTAssertFalse(wristBar.exists, "Back returns to Notifications rather than dismissing Settings")
        capture(app, "notifications-\(size)-returned-from-wrist")
        try reveal(button("Wrist alerts & actions", in: app), in: app)
        button("Wrist alerts & actions", in: app).tap()
        try requireExists(wristBar, in: app)
        let close = app.buttons["settings.done"]
        try requireExists(close, in: app)
        close.tap()
        try requireExists(app.buttons["app.deviceStatus"], in: app)
        XCTAssertFalse(wristBar.exists, "Done closes Settings from a nested destination")
    }

    private func launchNotifications(_ app: XCUIApplication, size: TextSize) {
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
    }

    private func text(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label ==[c] %@ OR label BEGINSWITH[c] %@", label, label + ",")).firstMatch
    }

    private func button(_ label: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@",
                                         label, label, label + ",")).firstMatch
    }

    private func assertHeader(_ label: String, in app: XCUIApplication) throws {
        try reveal(text(label, in: app), in: app, needsHitTarget: false)
    }

    @discardableResult
    private func assertButton(_ label: String, in app: XCUIApplication) throws -> XCUIElement {
        let control = button(label, in: app)
        try reveal(control, in: app)
        XCTAssertTrue(control.isEnabled, "\(label) remains enabled")
        XCTAssertGreaterThanOrEqual(control.frame.height, 44, "\(label) keeps a usable native row touch target")
        return control
    }

    @discardableResult
    private func assertPicker(_ label: String, in app: XCUIApplication) throws -> XCUIElement {
        let control = button(label, in: app)
        try reveal(control, in: app)
        XCTAssertTrue(control.isEnabled, "\(label) remains enabled")
        _ = try pickerRow(containing: control, in: app)
        return control
    }

    private func pickerRow(containing control: XCUIElement, in app: XCUIApplication) throws -> XCUIElement {
        // Native List owns the menu Picker's tap target; its AX Button can describe only the inner label.
        // The separate edge-touch test verifies that this larger row actually opens the same control.
        let rows = app.cells.containing(.button, identifier: control.label).allElementsBoundByIndex
        let finiteRows = rows.filter { row in
            guard row.exists else { return false }
            let frame = row.frame
            return !frame.isEmpty && !frame.isNull && !frame.isInfinite
                && frame.origin.x.isFinite && frame.origin.y.isFinite
                && frame.width.isFinite && frame.height.isFinite
        }
        guard let row = finiteRows.min(by: { $0.frame.height < $1.frame.height }) else {
            fail("The native Picker has no containing list row", in: app)
            throw HarnessError.unreachable("Missing native Picker row")
        }
        try reveal(row, in: app, needsHitTarget: false)
        XCTAssertGreaterThanOrEqual(row.frame.height, 44, "The native Picker row keeps a 44-point touch target")
        XCTAssertTrue(app.frame.contains(row.frame), "The complete native Picker row is visible")
        XCTAssertTrue(row.frame.contains(control.frame), "The measured row owns this exact Picker")
        return row
    }

    private func assertTimePicker(_ title: String, in app: XCUIApplication) throws {
        // The native compact DatePicker is unlabeled; SwiftUI exposes its title as a sibling text.
        // Locate its exact labeled row, then require the real enabled DatePicker within that row.
        let row = app.cells.containing(.staticText, identifier: title).firstMatch
        try reveal(row, in: app, needsHitTarget: false)
        let control = row.datePickers.firstMatch
        try requireExists(control, in: app)
        try reveal(control, in: app)
        XCTAssertTrue(control.isEnabled, "The saved \(title.lowercased()) remains editable")
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

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, allowOversizedText: Bool = false,
                        needsHitTarget: Bool = true) throws {
        // Native List creates rows lazily. Each checkpoint is visited in display order;
        // use small bounded swipes so an AX row cannot be skipped by a full-screen fling.
        for _ in 0..<40 {
            if element.exists && !element.frame.isEmpty && app.frame.contains(element.frame)
                && (!needsHitTarget || element.isHittable) { return }
            // The native collection's empty center can report non-hittable while visible rows work.
            // Use its visible geometry for drags; every interactive row still has to pass hit testing.
            let isVisible: (XCUIElement) -> Bool = { candidate in
                candidate.exists && candidate.frame.intersection(app.frame).height > 100
                    && candidate.frame.intersection(app.frame).width > 100
            }
            let surface = app.collectionViews.allElementsBoundByIndex.first(where: isVisible)
                ?? app.tables.allElementsBoundByIndex.first(where: isVisible)
                ?? app.scrollViews.allElementsBoundByIndex.first(where: isVisible)
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
