import XCTest

/// Cold typed taps through NavRouter's real payload decoder and the production shell guards.
/// Only the simulator demo host injects responses. Tests inspect real dated demo records and
/// existing native pages; they never answer the journal, issue a device command, start a workout,
/// apply a notification preset, or request OS permission. Screenshot color/chrome needs visual review.
@MainActor
final class NotificationDestinationUITests: XCTestCase {
    private enum TextSize: String {
        case normal = "UICTContentSizeCategoryL"
        case accessibilityXXXL = "UICTContentSizeCategoryAccessibilityXXXL"
    }

    private enum HarnessError: Error { case unreachable(String) }
    private let roundingTolerance: CGFloat = 0.000001

    func testSettingsQueuedDismissalNormal() throws { try assertSettingsQueue(size: .normal) }
    func testSettingsQueuedDismissalAccessibilityXXXL() throws { try assertSettingsQueue(size: .accessibilityXXXL) }
    func testWHOOPDeviceNormal() throws { try assertWHOOP(size: .normal) }
    func testWHOOPDeviceAccessibilityXXXL() throws { try assertWHOOP(size: .accessibilityXXXL) }
    func testDatedJournalNormal() throws { try assertJournal(size: .normal) }
    func testDatedJournalAccessibilityXXXL() throws { try assertJournal(size: .accessibilityXXXL) }
    func testDaySleepWeeklyNormal() throws { try assertDaySleepWeekly(size: .normal) }
    func testDaySleepWeeklyAccessibilityXXXL() throws { try assertDaySleepWeekly(size: .accessibilityXXXL) }

    private func assertSettingsQueue(size: TextSize) throws {
        let app = XCUIApplication()
        // Two ordinary typed payloads enter before source readiness. The second must remain queued
        // until the approved Settings host finishes dismissing and clears notification ownership.
        try launch(app, size: size, destinations: [settingsJSON, deviceJSON])
        defer { app.terminate() }
        let notifications = app.navigationBars["Notifications"]
        try require(notifications, in: app, timeout: 60)
        try require(app.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", "Delivery status")).firstMatch, in: app)
        XCTAssertFalse(app.buttons["notification.done"].exists, "Settings uses the approved native Settings host")
        try assertDone("settings.done", in: app)
        capture(app, "typed-settings-\(size)-approved-host-done")
        app.buttons["settings.done"].tap()
        try require(app.navigationBars["WHOOP"], in: app)
        try require(element("settings.whoop.connection", in: app), in: app)
        XCTAssertFalse(notifications.exists, "The next queued tap opens only after Notifications closes")
        try assertDone("settings.done", in: app)
        capture(app, "typed-settings-\(size)-next-queued-whoop")
        try dismiss("settings.done", in: app)
        try assertSettingsCanOpenAgain(in: app)
    }

    private func assertWHOOP(size: TextSize) throws {
        let app = XCUIApplication()
        try launch(app, size: size, destinations: [deviceJSON])
        defer { app.terminate() }
        try require(app.navigationBars["WHOOP"], in: app, timeout: 60)
        let connection = element("settings.whoop.connection", in: app)
        try require(connection, in: app)
        XCTAssertFalse(app.buttons["notification.done"].exists, "The active WHOOP opens its native Settings controls")
        try assertDone("settings.done", in: app)
        capture(app, "typed-whoop-\(size)-native-connection-done")
        let host = try presentationHost(done: "settings.done", in: app)
        let viewport = try scrollSurface(within: host, in: app)
        for id in ["sync", "vibration", "refreshBattery", "rescan", "disconnect", "manageDevices"] {
            let command = host.buttons["settings.whoop.\(id)"]
            try reveal(command, in: app, needsHitTarget: false, within: host, viewport: viewport)
            XCTAssertGreaterThanOrEqual(command.frame.height + roundingTolerance, 44)
            // Offline controls may be disabled. Inspection must not activate any device command.
            if id == "sync" || id == "manageDevices" { capture(app, "typed-whoop-\(size)-controls-\(id)") }
        }
        XCTAssertFalse(element("settings.whoop.feedback", in: app).exists)
        try dismiss("settings.done", in: app)
    }

    private func assertJournal(size: TextSize) throws {
        let app = XCUIApplication()
        // AppleDemoSeeder has imported journal history for the last 40 days. Yesterday is a real
        // dated demo day, rather than a nonexistent id or a synthetic destination-only placeholder.
        let day = demoDate(daysAgo: 1)
        try launch(app, size: size, destinations: [try json(["journal": ["logicalDay": dayKey(day)]])])
        defer { app.terminate() }
        try require(app.navigationBars["Journal"], in: app, timeout: 60)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = .current
        formatter.dateStyle = .full
        let dateLabel = app.staticTexts["Journal date: \(formatter.string(from: day))"]
        try reveal(dateLabel, in: app)
        try assertDone("notification.done", in: app)
        XCTAssertFalse(app.staticTexts["Notification update"].exists)
        capture(app, "typed-journal-\(size)-dated-record-read-only")
        try dismiss("notification.done", in: app)
    }

    private func assertDaySleepWeekly(size: TextSize) throws {
        let day = dayKey(demoDate(daysAgo: 1))
        var weekCalendar = Calendar(identifier: .iso8601)
        weekCalendar.timeZone = .current
        let week = dayKey(weekCalendar.dateInterval(of: .weekOfYear, for: demoDate(daysAgo: 7))!.start)
        let destinations: [(String, String)] = [
            ("day", try json(["day": ["logicalDay": day]])),
            ("sleep", try json(["sleepPlan": ["logicalDay": day]])),
            ("weekly", try json(["weeklyReview": ["weekStart": week]])),
        ]
        // Each destination gets a separate process and the same unmodified production route path.
        for (name, destination) in destinations {
            let app = XCUIApplication()
            try launch(app, size: size, destinations: [destination])
            defer { app.terminate() }
            try require(app.buttons["notification.done"], in: app, timeout: 60)
            let host = try presentationHost(done: "notification.done", in: app)
            let viewport = try scrollSurface(within: host, in: app)
            switch name {
            case "day":
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US")
                formatter.timeZone = .current
                formatter.dateStyle = .medium
                let dateNavigation = host.buttons[formatter.string(from: demoDate(daysAgo: 1)) + ". Swipe or tap to change day"]
                try reveal(dateNavigation, in: app, within: host)
                let headings = host.staticTexts.matching(identifier: "today.health.title")
                XCTAssertEqual(headings.count, 1, "The foreground dated destination owns one Health Monitor heading")
                try reveal(headings.firstMatch, in: app, needsHitTarget: false, within: host,
                           viewport: viewport, usesInteriorLaneWhenStalled: true)
                XCTAssertEqual(headings.firstMatch.label, "Health Monitor")
            case "sleep":
                // Preserve and capture the existing Sleep page; this test makes no Sleep redesign.
                try reveal(host.staticTexts.matching(NSPredicate(format: "label ==[cd] %@", "Sleep stages")).firstMatch,
                           in: app, needsHitTarget: false, within: host, viewport: viewport)
            default:
                try require(host.navigationBars["Week in review"], in: app)
                let coverage = host.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "[1-7] of 7 days had data this week")).firstMatch
                try reveal(coverage, in: app, needsHitTarget: false, within: host, viewport: viewport)
            }
            XCTAssertFalse(app.staticTexts["Notification update"].exists, "\(name) resolves actual demo data")
            try assertDone("notification.done", in: app)
            capture(app, "typed-\(name)-\(size)-existing-native-page")
            try dismiss("notification.done", in: app)
            app.terminate()
        }
    }

    private var settingsJSON: String { #"{"settings":{"group":"morningSummary"}}"# }
    private var deviceJSON: String { #"{"device":{"id":"my-whoop"}}"# }

    private func launch(_ app: XCUIApplication, size: TextSize, destinations: [String]) throws {
        #if targetEnvironment(simulator)
        let isSimulator = true
        #else
        let isSimulator = false
        #endif
        try XCTSkipUnless(isSimulator, "Notification destination qualification runs only on Simulator")
        continueAfterFailure = false
        app.terminate()
        app.launchArguments = [
            "--noop-coach-shell-qa", "--demo-seed", "--noop-lift-demo", "fresh", "--demo-tab", "today",
            "-UIPreferredContentSizeCategoryName", size.rawValue,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark",
        ]
        for destination in destinations {
            app.launchArguments += ["--noop-qa-notification-destination", destination]
        }
        app.launch()
    }

    private func json(_ value: [String: [String: String]]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }

    private func demoDate(daysAgo: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -daysAgo, to: Calendar.current.startOfDay(for: Date()))!
    }

    private func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func assertDone(_ identifier: String, in app: XCUIApplication) throws {
        let done = app.buttons[identifier]
        try require(done, in: app)
        XCTAssertEqual(done.label, "Done")
        XCTAssertTrue(done.isEnabled && done.isHittable && app.frame.contains(done.frame))
        XCTAssertGreaterThanOrEqual(done.frame.width + roundingTolerance, 44)
        XCTAssertGreaterThanOrEqual(done.frame.height + roundingTolerance, 44)
    }

    private func dismiss(_ identifier: String, in app: XCUIApplication) throws {
        try assertDone(identifier, in: app)
        app.buttons[identifier].tap()
        try waitFor(app.buttons[identifier], predicate: "exists == false", in: app)
        let root = app.buttons["app.deviceStatus"]
        try require(root, in: app)
        XCTAssertTrue(root.label.contains("Today"), "Done restores the original root tab")
        XCTAssertTrue(app.frame.contains(root.frame))
        capture(app, "\(identifier)-dismissed-root")
    }

    private func assertSettingsCanOpenAgain(in app: XCUIApplication) throws {
        let settings = app.buttons["app.settings"]
        try require(settings, in: app)
        settings.tap()
        try require(app.navigationBars["Settings"], in: app)
        XCTAssertFalse(app.navigationBars["Notifications"].exists)
        XCTAssertFalse(app.navigationBars["WHOOP"].exists)
        try dismiss("settings.done", in: app)
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func require(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval = 10) throws {
        guard element.waitForExistence(timeout: timeout) else {
            try fail("Required destination element did not appear", in: app)
        }
    }

    private func waitFor(_ element: XCUIElement, predicate: String, in app: XCUIApplication) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: 10) == .completed else {
            try fail("Destination dismissal did not complete", in: app)
        }
    }

    private func usableFrame(_ frame: CGRect) -> Bool {
        !frame.isEmpty && !frame.isNull && !frame.isInfinite
            && frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
    }

    private func presentationHost(done identifier: String, in app: XCUIApplication) throws -> XCUIElement {
        // The covered root remains in the AX tree. The smallest visible ancestor that owns
        // both this presentation's Done and its scrolling content excludes the covered page.
        let candidates = app.otherElements.containing(.button, identifier: identifier).allElementsBoundByIndex
        let hosts = candidates.filter { candidate in
            guard candidate.exists, usableFrame(candidate.frame) else { return false }
            let visible = candidate.frame.intersection(app.frame)
            return usableFrame(visible) && visible.width > 100 && visible.height > 100
                && (candidate.scrollViews.firstMatch.exists || candidate.collectionViews.firstMatch.exists
                    || candidate.tables.firstMatch.exists)
        }
        guard let host = hosts.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            try fail("No foreground destination host owned Done and scrolling content", in: app)
        }
        XCTAssertEqual(host.buttons.matching(identifier: identifier).count, 1,
                       "The foreground destination owns its exact Done button")
        return host
    }

    private func scrollSurface(within scope: XCUIElement, in app: XCUIApplication) throws -> XCUIElement {
        // Native collection containers can report false isHittable even when their rows work.
        // Geometry selects the drag surface; interactive targets still require hit testing.
        for query in [scope.collectionViews, scope.tables, scope.scrollViews] where query.firstMatch.exists {
            if let surface = query.allElementsBoundByIndex.first(where: { candidate in
                guard candidate.exists, usableFrame(candidate.frame) else { return false }
                let visible = candidate.frame.intersection(app.frame)
                return usableFrame(visible) && visible.width > 100 && visible.height > 100
            }) { return surface }
        }
        try fail("No destination scroll surface was available", in: app)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, needsHitTarget: Bool = true,
                        within scope: XCUIElement? = nil, viewport: XCUIElement? = nil,
                        usesInteriorLaneWhenStalled: Bool = false) throws {
        // Native Lists create rows lazily. Keep the full-frame and target hit checks while
        // scrolling only the foreground destination, using its empty horizontal gutter.
        var previousTargetY: CGFloat?
        for _ in 0..<40 {
            if let viewport, !usableFrame(viewport.frame) { try fail("Invalid raw destination viewport", in: app) }
            var bounds = viewport.map { $0.frame.intersection(app.frame) } ?? app.frame
            let bars = (scope ?? app).navigationBars
            if viewport != nil, bars.firstMatch.exists {
                for bar in bars.allElementsBoundByIndex where bar.exists && usableFrame(bar.frame) {
                    let chrome = bar.frame.intersection(bounds)
                    if usableFrame(chrome), bar.frame.minY <= bounds.minY + 32 {
                        bounds = CGRect(x: bounds.minX, y: chrome.maxY,
                                        width: bounds.width, height: bounds.maxY - chrome.maxY)
                    }
                }
            }
            guard usableFrame(bounds) else { try fail("Invalid destination viewport", in: app) }
            if element.exists && usableFrame(element.frame) && bounds.contains(element.frame)
                && (!needsHitTarget || element.isHittable) { return }
            let surface = try viewport ?? scrollSurface(within: scope ?? app, in: app)
            let visible = surface.frame.intersection(bounds)
            guard usableFrame(surface.frame), usableFrame(visible) else {
                try fail("Invalid destination scroll surface frame", in: app)
            }
            let above = element.exists && usableFrame(element.frame) && element.frame.maxY < visible.midY
            let targetY = element.exists && usableFrame(element.frame) ? element.frame.minY : nil
            let useInteriorLane = usesInteriorLaneWhenStalled && targetY.map { y in
                previousTargetY.map { abs(y - $0) < 1 } ?? false
            } == true
            previousTargetY = targetY
            // The dated Today capture stalled at the outer x8 lane after four successful
            // scrolls. Its usual lower start point then aligned with the Stress scrubber.
            // On a stalled heading only, start inside the content and higher in the viewport.
            let x = visible.minX + (useInteriorLane ? visible.width * 0.10 : min(8, visible.width * 0.04))
            func point(_ y: CGFloat) -> XCUICoordinate {
                app.coordinate(withNormalizedOffset: .zero).withOffset(
                    CGVector(dx: x - app.frame.minX, dy: visible.minY + visible.height * y - app.frame.minY))
            }
            let upper: CGFloat = useInteriorLane ? 0.25 : 0.42
            let lower: CGFloat = useInteriorLane ? 0.65 : 0.78
            point(above ? upper : lower).press(forDuration: 0.05, thenDragTo: point(above ? lower : upper))
        }
        try fail("Required destination row was not fully visible after bounded scrolling", in: app)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func fail(_ message: String, in app: XCUIApplication) throws -> Never {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "typed-notification-failure-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        capture(app, "typed-notification-failure")
        XCTFail(message)
        throw HarnessError.unreachable(message)
    }
}
