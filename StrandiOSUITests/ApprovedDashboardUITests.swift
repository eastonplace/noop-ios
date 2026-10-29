import XCTest

/// Presentation and navigation proof for the approved H2 header, M1 Health Monitor,
/// display-only dashboard preferences, and native WHOOP Settings.
/// Run against the task simulator. No device command or log export is activated.
@MainActor
final class ApprovedDashboardUITests: XCTestCase {
    // Ignore only floating-point representation error in native touch-target dimensions.
    private let targetDimensionRoundingTolerance: CGFloat = 0.000001

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
    func testSettingsRootDoneAlignmentNormal() throws { try assertSettingsRootDone(size: .normal) }
    func testSettingsRootDoneAlignmentAccessibilityXXXL() throws { try assertSettingsRootDone(size: .accessibilityXXXL) }
    func testSharedBatteryHeaderAndRecentUpdatesNormal() throws { try assertSharedBatteryHeaderAndRecentUpdates(size: .normal) }
    func testSharedBatteryHeaderAndRecentUpdatesAccessibilityXXXL() throws { try assertSharedBatteryHeaderAndRecentUpdates(size: .accessibilityXXXL) }

    private func assertSharedBatteryHeaderAndRecentUpdates(size: TextSize) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, size: size)
        defer { app.terminate() }
        try requireDemoSeedReady(in: app)
        if size == .accessibilityXXXL {
            // Keep Today's real profile-button route separate from dashboard-content inspection.
            let profile = app.buttons["app.settings"]
            try reveal(profile, in: app, direction: .down, needsHitTarget: false)
            XCTAssertTrue(app.buttons["app.deviceStatus"].label.contains("Today"), "The profile route starts on Today")
            XCTAssertGreaterThanOrEqual(profile.frame.height + targetDimensionRoundingTolerance, 44)
            profile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            try requireExists(app.navigationBars["Settings"], in: app)
            try requireExists(app.buttons["settings.done"], in: app)
            capture(app, "shared-battery-AX-today-opens-settings")
            try closeSettingsToToday(in: app)
            XCTAssertTrue(app.buttons["app.deviceStatus"].label.contains("Today"), "Done returns the profile route to Today")
            capture(app, "shared-battery-AX-today-settings-dismissed")
        }
        let tabs: [(String, String)] = [("0", "Today"), ("1", "Trends"), ("4", "Coach"), ("2", "Sleep")]
        for (tag, title) in tabs {
            let tab = app.buttons["app.tab.\(tag)"]
            try requireExists(tab, in: app, timeout: 60)
            if tag != "0" { tab.tap() }
            let header = app.buttons["app.deviceStatus"]
            try waitFor(header, predicate: "exists == true AND label CONTAINS[cd] '\(title)'", in: app)
            XCTAssertEqual(app.buttons.matching(identifier: "app.deviceStatus").count, 1, "One shared header per tab")
            XCTAssertFalse(app.buttons["app.notifications"].exists, "Updates no longer occupy the header")
            let battery = app.buttons["app.battery"]
            try requireExists(battery, in: app)
            try waitFor(battery, predicate: "label == 'Strap battery 68 percent'", in: app)
            for action in [battery, app.buttons["app.settings"]] {
                XCTAssertTrue(app.frame.contains(action.frame), "\(title) keeps its header action fully on screen")
                XCTAssertGreaterThanOrEqual(action.frame.height + targetDimensionRoundingTolerance, 44)
                XCTAssertGreaterThanOrEqual(action.frame.width + targetDimensionRoundingTolerance, 44)
            }
            if title == "Trends" {
                let share = app.buttons["trends.share"]
                for action in [share] {
                    try requireExists(action, in: app)
                    XCTAssertTrue(app.frame.contains(action.frame), "Trends tools stay fully on screen")
                    XCTAssertGreaterThanOrEqual(action.frame.width + targetDimensionRoundingTolerance, 44)
                    XCTAssertGreaterThanOrEqual(action.frame.height + targetDimensionRoundingTolerance, 44)
                }
                XCTAssertEqual(share.label, "Share Trends")
                if size == .normal {
                    XCTAssertEqual(share.frame.midY, battery.frame.midY, accuracy: 1,
                                   "Share aligns with the account controls")
                } else {
                    XCTAssertLessThanOrEqual(share.frame.maxY, battery.frame.minY,
                                             "Accessibility tools reflow above account controls")
                }
            }
            capture(app, "shared-battery-\(size)-\(title.lowercased())")
        }

        // The new battery slot remains a real device Settings entry, including on another tab.
        let battery = app.buttons["app.battery"]
        battery.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        try requireExists(element("settings.whoop.connection", in: app), in: app)
        capture(app, "shared-battery-\(size)-opens-whoop")
        try closeSettingsToToday(in: app)
        XCTAssertTrue(app.buttons["app.deviceStatus"].label.contains("Sleep"), "Closing device Settings preserves the selected tab")

        app.buttons["app.settings"].tap()
        try requireExists(app.navigationBars["Settings"], in: app)
        let updates = app.buttons["settings.row.recentUpdates"]
        try requireExists(updates, in: app)
        XCTAssertTrue(app.frame.contains(updates.frame), "Recent updates is available at the top without scrolling")
        let profile = element("settings.profileRow", in: app)
        if profile.exists { XCTAssertLessThan(updates.frame.minY, profile.frame.minY) }
        let unreadLabel = updates.label
        capture(app, "recent-updates-\(size)-settings-root")
        updates.tap()
        try requireExists(element("settings.recentUpdates", in: app), in: app)
        try requireExists(app.navigationBars["Recent updates"], in: app)
        capture(app, "recent-updates-\(size)-native-inbox")
        try returnToSettingsRoot(in: app)
        XCTAssertEqual(updates.label, unreadLabel, "Opening Recent updates does not mark the inbox read")
        app.buttons["settings.done"].tap()
        try waitFor(app.buttons["settings.done"], predicate: "exists == false", in: app)
        XCTAssertTrue(app.buttons["app.deviceStatus"].label.contains("Sleep"), "Done returns to the selected tab")
    }

    private func assertSettingsRootDone(size: TextSize) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "settings", size: size)
        defer { app.terminate() }
        let navigation = app.navigationBars["Settings"]
        try requireExists(navigation, in: app, timeout: 60)
        let title = navigation.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", "Settings")).firstMatch
        try requireExists(title, in: app)
        let done = app.buttons["settings.done"]
        try reveal(done, in: app)
        capture(app, "settings-root-\(size)-plain-done-title-alignment")
        XCTAssertTrue(navigation.frame.contains(title.frame), "Settings uses the native navigation title")
        XCTAssertTrue(navigation.frame.contains(done.frame), "Done stays in the native navigation bar")
        XCTAssertEqual(title.frame.midY, done.frame.midY, accuracy: 4, "Done aligns vertically with the Settings title")
        XCTAssertGreaterThanOrEqual(done.frame.width + targetDimensionRoundingTolerance, 44, "Done retains a usable touch-target width")
        XCTAssertGreaterThanOrEqual(done.frame.height + targetDimensionRoundingTolerance, 44, "Done retains a usable touch-target height")
        XCTAssertTrue(done.isEnabled)
        done.tap()
        try waitFor(done, predicate: "exists == false", in: app)
        let today = app.buttons["app.deviceStatus"]
        try requireExists(today, in: app)
        XCTAssertTrue(today.label.contains("Today"), "Done dismisses Settings to Today")
        XCTAssertTrue(app.frame.contains(today.frame))
        capture(app, "settings-root-\(size)-done-dismissed-to-today")
    }

    func testDeviceRegistryRemainsReachableWithoutCommandDashboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "settings")
        defer { app.terminate() }
        try openWHOOPFromSettingsRoot(in: app)
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

    func testStrapStatusPanelAndCalendar() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app)
        defer { app.terminate() }
        let status = app.buttons["app.deviceStatus"]
        try requireExists(status, in: app, timeout: 60)
        XCTAssertEqual(app.buttons.matching(identifier: "app.deviceStatus").count, 1)
        XCTAssertEqual(app.buttons.matching(identifier: "today.dateButton").count, 1)
        status.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)).tap()
        try requireExists(element("app.statusPanel", in: app), in: app)
        for title in ["Test vibration", "Sync now", "Device settings"] {
            try requireExists(app.buttons[title], in: app)
        }
        capture(app, "strap-status-panel")
        status.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.75)).tap()
        try waitFor(element("app.statusPanel", in: app), predicate: "exists == false", in: app)
        let date = app.buttons["today.dateButton"]
        try requireExists(date, in: app)
        date.tap()
        try requireExists(element("today.calendar", in: app), in: app)
        try requireExists(app.buttons["Previous month"], in: app)
        capture(app, "today-month-calendar")
        app.buttons["today.calendar.todayButton"].tap()
        try waitFor(element("today.calendar", in: app), predicate: "exists == false", in: app)
        capture(app, "today-returned-from-calendar")
    }

    func testForkAboutAndWhatsNew() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "settings-about")
        defer { app.terminate() }
        try requireExists(app.buttons["What's new"], in: app, timeout: 60)
        let version = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "Version, [0-9]+[.][0-9]+[.][0-9]+")).firstMatch
        try requireExists(version, in: app)
        let displayedVersion = String(version.label.dropFirst("Version, ".count))
        let source = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Source code on GitHub")).firstMatch
        try requireExists(source, in: app)
        capture(app, "fork-about")
        app.buttons["What's new"].tap()
        let hero = element("whatsNew.hero", in: app)
        try requireExists(hero, in: app)
        // The hero intentionally combines its heading, version, title and date into
        // one accessibility element. Verify the exact dotted version in that label.
        let heroVersions = hero.label.split { !$0.isNumber && $0 != "." }
            .filter { $0.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil }
            .map(String.init)
        XCTAssertEqual(heroVersions, [displayedVersion], "What's New shows the running version from About")
        try requireExists(app.buttons["Continue"], in: app)
        capture(app, "fork-whats-new")
        // Current features use an eager VStack; earlier releases have no feature rows until opened.
        // Snapshot every current row before scrolling, then bind the final row by its stable identifier.
        let featurePrefix = "whatsNew.feature."
        let currentFeatures = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", featurePrefix)
        ).allElementsBoundByIndex
        XCTAssertGreaterThanOrEqual(currentFeatures.count, 3, "The current release exposes its full feature list")
        let lastSnapshot = try XCTUnwrap(currentFeatures.last)
        let lastIdentifier = lastSnapshot.identifier
        let lastLabel = lastSnapshot.label
        let title = String(lastIdentifier.dropFirst(featurePrefix.count))
        XCTAssertNotEqual(lastIdentifier, currentFeatures.first?.identifier, "The scroll proof targets the final row, not the first")
        XCTAssertFalse(title.isEmpty)
        XCTAssertTrue(lastLabel.hasPrefix(title), "The row label includes its feature title")
        let detail = String(lastLabel.dropFirst(title.count))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        XCTAssertFalse(detail.isEmpty, "The final feature includes its detail, not only a title")
        let lastFeature = element(lastIdentifier, in: app)
        let viewport = app.scrollViews.firstMatch
        try reveal(lastFeature, in: app, needsHitTarget: false, viewport: viewport)
        XCTAssertTrue(viewport.frame.intersection(app.frame).contains(lastFeature.frame), "The entire final feature is reachable")
        XCTAssertEqual(lastFeature.label, lastLabel, "The final feature's complete title and detail remain intact after scrolling")
        capture(app, "fork-whats-new-last-feature")
        app.buttons["Continue"].tap()
        try requireExists(app.buttons["What's new"], in: app)
    }

    func testNewLiveEnrollmentOffersOnlyWHOOP() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, route: "settings")
        defer { app.terminate() }
        try openWHOOPFromSettingsRoot(in: app)
        let manage = app.buttons["settings.whoop.manageDevices"]
        try reveal(manage, in: app)
        manage.tap()
        let addDevice = app.buttons.matching(NSPredicate(format: "label ==[cd] %@", "Add a device")).firstMatch
        try reveal(addDevice, in: app)
        addDevice.tap()
        let whoop5 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "WHOOP 5.0 / MG.")).firstMatch
        let whoop4 = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "WHOOP 4.0.")).firstMatch
        try requireExists(whoop5, in: app)
        try requireExists(whoop4, in: app)
        XCTAssertEqual(app.buttons.matching(NSPredicate(
            format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "WHOOP 5.0 / MG.", "WHOOP 4.0."
        )).count, 2)
        for retired in ["Oura", "Amazfit", "Heart-rate strap", "Gym equipment"] {
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", retired)).firstMatch.exists)
        }
        capture(app, "whoop-only-new-enrollment")
    }

    func testDeepDataPermissionWordingInSettings() throws {
        try assertDeepDataPermissionCopy(route: "settings-diagnosticsexperimental", captureName: "deep-data-settings-permission")
    }

    func testDeepDataPermissionWordingInTestCentre() throws {
        try assertDeepDataPermissionCopy(route: "settings-testcentre", captureName: "deep-data-test-centre-permission")
    }

    private func assertDeepDataPermissionCopy(route: String, captureName: String) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The argument domain selects a synthetic 5/MG UI without changing a paired device.
        launch(app, route: route, extraArguments: ["-selectedWhoopModel", "WHOOP 5.0 / MG"])
        defer { app.terminate() }
        let permission = app.switches.matching(NSPredicate(format: "label CONTAINS %@", "Allow WHOOP 5/MG deep-data changes")).firstMatch
        try reveal(permission, in: app)
        XCTAssertTrue(permission.isEnabled)
        let detail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Off cancels changes that have not been sent.")).firstMatch
        try reveal(detail, in: app, needsHitTarget: false)
        XCTAssertTrue(detail.label.contains("Changes already sent can still apply."))
        XCTAssertTrue(detail.label.contains("NOOP cannot restore earlier strap settings."))
        capture(app, captureName)
    }

    private func launch(_ app: XCUIApplication, route: String? = nil, size: TextSize = .normal,
                        preserveDemoPreferences: Bool = false, extraArguments: [String] = []) {
        app.terminate()
        app.launchArguments = [
            "--noop-coach-shell-qa", "--demo-seed", "--noop-lift-demo", "fresh",
            "--demo-tab", "today",
            "-UIPreferredContentSizeCategoryName", size.rawValue,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark",
        ]
        if preserveDemoPreferences { app.launchArguments.append("--noop-qa-preserve-preferences") }
        if let route { app.launchArguments += ["--noop-qa-route", route] }
        app.launchArguments += extraArguments
        app.launch()
    }

    /// The fixture writes finish after the shell is interactive. The existing demo battery
    /// assignment happens only after that async seed returns; do not navigate during its root redraw.
    private func requireDemoSeedReady(in app: XCUIApplication) throws {
        let battery = app.buttons["app.battery"]
        try requireExists(battery, in: app, timeout: 60)
        try waitFor(battery, predicate: "label == 'Strap battery 68 percent'", in: app, timeout: 60)
        print("[demo-ready] seeded battery label=\(battery.label)")
    }

    private func assertToday(size: TextSize) throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        launch(app, size: size)
        defer { app.terminate() }
        let device = app.buttons["app.deviceStatus"]
        try requireExists(device, in: app, timeout: 60)
        for id in ["app.deviceStatus", "app.battery", "app.settings"] {
            let button = app.buttons[id]
            try reveal(button, in: app, needsHitTarget: id != "app.deviceStatus")
            XCTAssertGreaterThanOrEqual(button.frame.height + targetDimensionRoundingTolerance, 44, "\(id) retains its touch target")
            XCTAssertFalse(button.label.isEmpty)
        }
        XCTAssertTrue(device.label.contains("Today"), "The page title remains part of the device entry point")
        let headerY = device.frame.minY
        capture(app, "today-\(size)-H2-header-white-plus")

        let plus = app.buttons["app.quickActions"]
        try reveal(plus, in: app)
        XCTAssertEqual(plus.label, "Quick Actions")
        XCTAssertGreaterThanOrEqual(plus.frame.height + targetDimensionRoundingTolerance, 54)
        plus.tap()
        try requireExists(app.buttons["quickActions.close"], in: app)
        capture(app, "today-\(size)-quick-actions-open")
        // Use the visible X: the full-screen scrim's center is covered by the menu at AX sizes.
        XCTAssertEqual(plus.label, "Close Quick Actions")
        plus.tap()
        try waitFor(app.buttons["quickActions.close"], predicate: "exists == false", in: app)

        let title = element("today.health.title", in: app)
        let viewport = app.scrollViews.firstMatch
        let anchors = todayScrollAnchors(in: app)
        try reveal(title, in: app, needsHitTarget: false, viewport: viewport, scrollAnchors: anchors)
        XCTAssertEqual(title.label, "Health Monitor", "The M1 heading has no metric count")
        let health = element("today.health.monitor", in: app)
        XCTAssertEqual(health.buttons.matching(NSPredicate(format: "label CONTAINS[cd] 'custom' ")).count, 0,
                       "Health customization lives in Settings")
        capture(app, "today-\(size)-M1-health-top")
        assertPinnedHeader(device, initialY: headerY, in: app)
        let allMetrics = app.buttons["today.health.allMetrics"]
        try reveal(allMetrics, in: app, viewport: size == .normal ? viewport : nil, scrollAnchors: anchors)
        XCTAssertGreaterThanOrEqual(allMetrics.frame.height + targetDimensionRoundingTolerance, 44)
        try reveal(app.buttons["today.health.dataSources"], in: app,
                   viewport: size == .normal ? viewport : nil, scrollAnchors: anchors)
        capture(app, "today-\(size)-M1-health-footer")
        assertPinnedHeader(device, initialY: headerY, in: app)
        // Prove the physical touch and its navigation outcome. The pinned SwiftUI
        // header can report false isHittable above its clipped scrolling sibling.
        // The status line now opens the quick-status popover; the battery slot is the device Settings entry.
        app.buttons["app.battery"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
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
        launch(app)
        defer { app.terminate() }
        try requireDemoSeedReady(in: app)
        try openTodayDashboardSettings(in: app)
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
        try setSwitch("today.summary.strain", to: false, in: app, direction: .down)
        XCTAssertEqual(try selection(in: app), Selection(summary: ["recovery"], health: changed.health),
                       "Disabling one of two scores leaves the exact remaining score and preserves Health selection")
        let lastScore = app.switches["today.summary.recovery"]
        try reveal(lastScore, in: app, direction: .down, needsHitTarget: false)
        XCTAssertFalse(lastScore.isEnabled, "The final enabled summary metric cannot be hidden")
        try setSelection(changed, in: app)
        launch(app, preserveDemoPreferences: true)
        try requireDemoSeedReady(in: app)
        try openTodayDashboardSettings(in: app)
        XCTAssertEqual(try selection(in: app), changed, "Both ordered selections persist across process relaunch")
        capture(app, "dashboard-settings-persisted-summary-order")
        try reveal(app.switches["today.health.respiratory"], in: app)
        capture(app, "dashboard-settings-persisted-health-selection")

        try closeSettingsToToday(in: app)
        try requireExists(element("today.summary.pillar.strain", in: app), in: app, timeout: 60)
        let strain = element("today.summary.pillar.strain", in: app)
        let recovery = element("today.summary.pillar.recovery", in: app)
        let viewport = app.scrollViews.firstMatch
        try reveal(strain, in: app, needsHitTarget: false, viewport: viewport)
        try reveal(recovery, in: app, needsHitTarget: false, viewport: viewport)
        XCTAssertFalse(element("today.summary.pillar.sleep", in: app).exists)
        XCTAssertLessThan(strain.frame.midX, recovery.frame.midX, "Today follows the saved summary order")
        capture(app, "today-selected-summary-order")
        for name in changed.health {
            try reveal(element("today.health.tile.\(name)", in: app), in: app,
                       needsHitTarget: false, viewport: viewport, scrollAnchors: todayScrollAnchors(in: app))
        }
        XCTAssertFalse(element("today.health.tile.sleep", in: app).exists)
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
            // Pinned chrome can expose a false AX hit-test result above the clipped scroll sibling.
            // Require its full visible touch target, deliver a real touch, then verify the Settings route.
            try reveal(profile, in: app, direction: .down, needsHitTarget: false)
            XCTAssertGreaterThanOrEqual(profile.frame.height + targetDimensionRoundingTolerance, 44)
            profile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            try requireExists(app.buttons["settings.done"], in: app)
        }
        try returnToSettingsRoot(in: app)
        let dashboard = app.buttons["settings.row.todayDashboard"]
        let settingsList = app.collectionViews.firstMatch
        try requireExists(settingsList, in: app)
        try reveal(dashboard, in: app, viewport: settingsList)
        dashboard.tap()
        try requireExists(element("todayDashboard.settings", in: app), in: app)
    }

    private func assertSettingsAccessibility() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        // The separately selected shared-header XXXL case verifies Today's real profile-to-Settings route.
        // This case owns native Settings-list routing and large-text dashboard content.
        launch(app, route: "settings", size: .accessibilityXXXL)
        defer { app.terminate() }
        try requireDemoSeedReady(in: app)
        try openTodayDashboardSettings(in: app)
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
        launch(app, route: "settings", size: size)
        defer { app.terminate() }
        try openWHOOPFromSettingsRoot(in: app)
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
            XCTAssertGreaterThanOrEqual(command.frame.height + targetDimensionRoundingTolerance, 44)
            if id == "sync" || id == "manageDevices" { capture(app, "whoop-\(size)-controls-\(id)") }
        }
        for id in ["copyLog", "saveLog", "testCentre"] {
            try reveal(app.buttons["settings.whoop.\(id)"], in: app, needsHitTarget: false)
        }
        capture(app, "whoop-\(size)-diagnostics")
        XCTAssertFalse(element("settings.whoop.feedback", in: app).exists, "Read-only navigation issues no device command")
    }

    private func openWHOOPFromSettingsRoot(in app: XCUIApplication) throws {
        try requireExists(app.navigationBars["Settings"], in: app, timeout: 60)
        let whoop = app.buttons["settings.row.whoop"]
        try reveal(whoop, in: app)
        whoop.tap()
        try requireExists(element("settings.whoop.connection", in: app), in: app)
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
        let fields = id.split(separator: ".").map(String.init)
        guard fields.count == 3, fields[0] == "today", ["summary", "health"].contains(fields[1]) else {
            throw HarnessError.invalidValue("Unexpected dashboard switch identifier: \(id)")
        }
        let before = try selection(in: app)
        let group = fields[1]
        let metric = fields[2]
        var expectedGroup = group == "summary" ? before.summary : before.health
        XCTAssertEqual(expectedGroup.contains(metric), previous, "The native switch agrees with its saved selection before activation")
        if desired, !expectedGroup.contains(metric) {
            expectedGroup.append(metric)
        } else if !desired {
            expectedGroup.removeAll { $0 == metric }
        }
        let expected = group == "summary"
            ? Selection(summary: expectedGroup, health: before.health)
            : Selection(summary: before.summary, health: expectedGroup)
        if previous != desired {
            XCTAssertTrue(control.isEnabled, "\(id) permits the requested selection change")
            let nativeFrame = control.frame
            XCTAssertTrue(row.frame.contains(nativeFrame), "The native switch remains fully inside its validated row")
            XCTAssertTrue(app.frame.contains(nativeFrame), "The native switch center is inside the visible app")
            print("[dashboard-toggle-center-tap] switch=\(id) nativeFrame=\(nativeFrame) center=(\(nativeFrame.midX),\(nativeFrame.midY)) previous=\(previous) desired=\(desired)")
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.2)
        }
        // Enabled rows move ahead of disabled rows. A successful native toggle can
        // therefore move this row out of the List's accessibility viewport. Verify
        // the entire ordered selection without retaining the moved child proxy.
        let expectedValue = "summary:" + expected.summary.joined(separator: ",")
            + ";health:" + expected.health.joined(separator: ",")
        let saved = element("todayDashboard.settings", in: app)
        let committed = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                // Re-resolve the parent on each poll after native List row reordering.
                let current = app.descendants(matching: .any)
                    .matching(identifier: "todayDashboard.settings").firstMatch
                return current.exists && (current.value as? String) == expectedValue
            }, object: app
        )
        // On the hosted simulator one accessibility read of this List can take 5-7 seconds right after a toggle, so an
        // 8-second wait saw a single read taken before the save landed. Allow several reads of the same exact value.
        guard XCTWaiter.wait(for: [committed], timeout: 30) == .completed else {
            let actualValue = String(describing: saved.value)
            let parsedSelection: String
            do {
                let actual = try selection(in: app)
                parsedSelection = "summary:" + actual.summary.joined(separator: ",")
                    + ";health:" + actual.health.joined(separator: ",")
            } catch {
                parsedSelection = "Could not parse direct selection: \(error)"
            }
            let currentRow = app.switches[id]
            let rowValue = currentRow.exists ? String(describing: currentRow.value) : "Row is virtualized"
            let state = "switch=\(id)\nprevious=\(previous)\ndesired=\(desired)\nexpectedValue=\(expectedValue)\nsaved.value=\(actualValue)\ndirectParsedSelection=\(parsedSelection)\ncurrentRowValue=\(rowValue)"
            print("[dashboard-toggle-readback-failure] \(state)")
            let readback = XCTAttachment(string: state)
            readback.name = "dashboard-toggle-readback-failure"
            readback.lifetime = .keepAlways
            add(readback)
            captureFailure(in: app)
            throw HarnessError.invalidValue("The native toggle did not save the exact expected selection for \(id)")
        }
        XCTAssertEqual(try selection(in: app), expected, "The toggle preserves both ordered selections")
        let updatedRow = app.switches[id]
        if updatedRow.exists {
            XCTAssertEqual(try switchValue(updatedRow), desired, "A remaining native row reflects its saved value")
        }
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
        if !exists || !app.frame.contains(frame) || abs(frame.minY - initialY) > 1 {
            let state = XCTAttachment(string: "exists=\(exists)\nlabel=\(device.label)\nisHittable=\(hittable)\nframe=\(frame)\ninitialY=\(initialY)\nappFrame=\(app.frame)")
            state.name = "pinned-header-hit-test-state"
            state.lifetime = .keepAlways
            add(state)
            captureFailure(in: app)
        }
        XCTAssertTrue(device.exists, "The Today device header remains in the accessibility tree after Health scrolling")
        XCTAssertTrue(app.frame.contains(device.frame), "The pinned Today header remains fully on screen")
        XCTAssertEqual(device.frame.minY, initialY, accuracy: 1, "Health scrolling preserves the header's vertical position")
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private enum ScrollDirection { case up, down }

    private func todayScrollAnchors(in app: XCUIApplication) -> [XCUIElement] {
        // Resolve visible text outside chart scrub regions at either text size. The large-text
        // training target changes where the HR chart lands; a fixed gutter drag can stop there.
        // HR's heading and footer labels bridge that card without starting on its trace.
        [element("today.health.title", in: app), app.staticTexts["Today’s Stress"],
         app.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", "Live Heart Rate")).firstMatch,
         app.staticTexts["LOW"], app.staticTexts["AVG"], app.staticTexts["PEAK"]]
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        direction: ScrollDirection = .up, needsHitTarget: Bool = true,
                        viewport: XCUIElement? = nil,
                        scrollAnchors: [XCUIElement] = []) throws {
        if let viewport { try requireExists(viewport, in: app) }
        for attempt in 0..<20 {
            guard let frames = settledScrollFrames(in: app, viewport: viewport) else {
                printScrollSurfaces(in: app, tag: "scroll-viewport-invalid")
                captureFailure(in: app)
                throw HarnessError.unreachable("The requested scroll viewport has an invalid raw frame")
            }
            let appFrame = frames.app
            let viewportFrame = frames.viewport
            var visibleFrame = viewportFrame.intersection(appFrame)
            if viewport != nil, app.navigationBars.firstMatch.exists {
                // A native List's AX frame extends beneath its navigation/search chrome.
                // Requiring app-frame containment alone can accept a row covered by Search.
                for bar in app.navigationBars.allElementsBoundByIndex where bar.exists && usableScrollFrame(bar.frame) {
                    let chrome = bar.frame.intersection(visibleFrame)
                    if usableScrollFrame(chrome), bar.frame.minY <= visibleFrame.minY + 32 {
                        visibleFrame = CGRect(x: visibleFrame.minX, y: chrome.maxY,
                                              width: visibleFrame.width, height: visibleFrame.maxY - chrome.maxY)
                    }
                }
            }
            guard usableScrollFrame(visibleFrame) else {
                captureFailure(in: app)
                throw HarnessError.unreachable("The requested scroll viewport has no finite visible area")
            }
            if element.exists, element.identifier == "today.health.title", attempt < 4 {
                print("[health-scroll] attempt=\(attempt) targetFrame=\(element.frame) viewportFrame=\(String(describing: viewport?.frame)) isHittable=\(element.isHittable)")
                capture(app, "health-scroll-attempt-\(attempt)")
            }
            if element.exists, element.frame.width > 0, element.frame.height > 0,
               visibleFrame.contains(element.frame), !needsHitTarget || element.isHittable { return }
            if attempt == 0 { _ = element.waitForExistence(timeout: 3) }
            // A root ScrollView may report a false AX hit test when its center is a chart.
            // Honor the caller's actual viewport instead of switching to a nested scroll surface.
            let surface = viewport ?? app.scrollViews.allElementsBoundByIndex.first(where: \.isHittable)
                ?? app.tables.allElementsBoundByIndex.first(where: \.isHittable) ?? app
            // Search both ways: native Settings reorders enabled rows after a switch changes.
            let forward = attempt < 10
            let scrollUp: Bool
            if element.exists, usableScrollFrame(element.frame), element.frame.minY < visibleFrame.minY {
                scrollUp = false
            } else if element.exists, usableScrollFrame(element.frame), element.frame.maxY > visibleFrame.maxY {
                scrollUp = true
            } else {
                switch (direction, forward) {
                case (.up, true), (.down, false): scrollUp = true
                case (.down, true), (.up, false): scrollUp = false
                }
            }
            if surface.elementType == .scrollView || viewport != nil {
                // Default to the gutter outside charts and native row controls. For Today,
                // a visible section heading provides a start outside chart gestures.
                // Bound both endpoints to the visible intersection, including partially clipped views.
                let surfaceFrame = surface.frame
                guard usableScrollFrame(surfaceFrame) else {
                    captureFailure(in: app)
                    throw HarnessError.unreachable("The selected scroll surface has an invalid raw frame")
                }
                let gestureFrame = surfaceFrame.intersection(visibleFrame)
                guard usableScrollFrame(gestureFrame) else {
                    captureFailure(in: app)
                    throw HarnessError.unreachable("The selected scroll surface has no finite visible area")
                }
                if element.exists, element.identifier == "today.health.title", attempt < 4 {
                    print("[health-gesture] attempt=\(attempt) explicitViewport=\(viewport != nil) surfaceType=\(surface.elementType.rawValue) surfaceID=\(surface.identifier) gestureFrame=\(gestureFrame)")
                }
                let origin = app.coordinate(withNormalizedOffset: .zero)
                let defaultEndY = gestureFrame.minY + gestureFrame.height * (scrollUp ? 0.2 : 0.8)
                // Text inside a tappable Today card (Stress, Live Heart Rate) may start only a drag long enough
                // to be an unmistakable scroll. A 44-50pt crawl from the Stress heading near the viewport edge
                // looks to have been delivered as a tap on hosted simulators: the Stress detail was pushed, Today's
                // scroll view left the screen, and the Health Monitor heading could never be reached. The
                // Health Monitor heading is plain text, so its short drags stay.
                let minimumCardDragTravel: CGFloat = 150
                let anchorPoints = scrollAnchors.compactMap { anchor -> CGPoint? in
                    guard anchor.exists else { return nil }
                    let frame = anchor.frame
                    guard usableScrollFrame(frame) else { return nil }
                    let visible = frame.intersection(gestureFrame)
                    // A partly clipped heading is still a safe start on its visible text. Requiring
                    // its entire frame discarded it and fell back onto the chart beneath it.
                    guard usableScrollFrame(visible), visible.height >= min(frame.height, 16) else { return nil }
                    let inset = min(8, visible.height / 2)
                    let y = scrollUp ? visible.maxY - inset : visible.minY + inset
                    guard scrollUp ? y > gestureFrame.minY + 44 : y < gestureFrame.maxY - 44 else { return nil }
                    let travel = scrollUp ? y - defaultEndY : defaultEndY - y
                    if travel < minimumCardDragTravel, anchor.identifier != "today.health.title" { return nil }
                    return CGPoint(x: visible.midX, y: y)
                }
                let anchor = scrollUp ? anchorPoints.max(by: { $0.y < $1.y })
                    : anchorPoints.min(by: { $0.y < $1.y })
                let x = (anchor?.x ?? (gestureFrame.minX + gestureFrame.width * 0.02)) - appFrame.minX
                let startY = anchor?.y ?? (gestureFrame.minY + gestureFrame.height * (scrollUp ? 0.8 : 0.2))
                let endY = anchor == nil ? defaultEndY
                    : (scrollUp ? min(defaultEndY, startY - 44) : max(defaultEndY, startY + 44))
                let start = origin.withOffset(CGVector(dx: x, dy: startY - appFrame.minY))
                let end = origin.withOffset(CGVector(dx: x, dy: endY - appFrame.minY))
                start.press(forDuration: 0.05, thenDragTo: end)
            } else if scrollUp {
                surface.swipeUp()
            } else {
                surface.swipeDown()
            }
        }
        captureFailure(in: app)
        throw HarnessError.unreachable("Could not reveal \(element.exists ? element.identifier : "the requested element")")
    }

    /// Right after a scroll gesture the hosted simulator can take seconds per accessibility snapshot, and one lookup
    /// can come back without the viewport. Re-read for a few seconds before calling it invalid; a viewport that stays
    /// unusable still fails the caller.
    private func settledScrollFrames(in app: XCUIApplication, viewport: XCUIElement?,
                                     timeout: TimeInterval = 5) -> (app: CGRect, viewport: CGRect)? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let appFrame = app.frame
            let viewportFrame = viewport?.frame ?? appFrame
            if usableScrollFrame(appFrame), usableScrollFrame(viewportFrame) { return (appFrame, viewportFrame) }
            printScrollSurfaces(in: app, tag: "scroll-viewport-unsettled")
            _ = viewport?.waitForExistence(timeout: 1)
        } while Date() < deadline
        return nil
    }

    /// The scroll surfaces and modal chrome on screen, for a log that has to explain a failure without its attachments.
    private func printScrollSurfaces(in app: XCUIApplication, tag: String) {
        let scrolls = app.scrollViews.allElementsBoundByIndex.map { "\($0.identifier)@\($0.frame)" }
        let bars = app.navigationBars.allElementsBoundByIndex.map(\.identifier)
        print("[\(tag)] scrollViews=\(scrolls) navigationBars=\(bars) alerts=\(app.alerts.count) sheets=\(app.sheets.count)")
    }

    private func usableScrollFrame(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && !frame.isInfinite
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
    }

    private func requireExists(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 10) throws {
        guard element.waitForExistence(timeout: timeout) else {
            captureFailure(in: app)
            throw HarnessError.unreachable("Missing \(element.exists ? element.identifier : "the requested element")")
        }
    }

    private func waitFor(_ element: XCUIElement, predicate: String, in app: XCUIApplication,
                         timeout: TimeInterval = 8) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            captureFailure(in: app)
            throw HarnessError.invalidValue("Expected \(predicate) for \(element.exists ? element.identifier : "the requested element")")
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
