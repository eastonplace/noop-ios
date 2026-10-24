import XCTest

/// Real Trends-to-Insights navigation over the existing isolated simulator demo database.
/// Captures both supported text-size extremes without injecting an Insights-only report.
@MainActor
final class InsightsUITests: XCTestCase {
    private enum TextSize: String {
        case normal = "UICTContentSizeCategoryL"
        case accessibilityXXXL = "UICTContentSizeCategoryAccessibilityXXXL"
    }

    private enum HarnessError: Error {
        case unreachable(String)
        case unsettled(String)
    }

    func testTrendsInsightsNavigationNormal() throws { try assertInsights(size: .normal) }
    func testTrendsInsightsNavigationAccessibilityXXXL() throws { try assertInsights(size: .accessibilityXXXL) }

    private func assertInsights(size: TextSize) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Insights demo UI qualification runs only on Simulator")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "--noop-coach-shell-qa", "--demo-seed", "--noop-lift-demo", "fresh",
            "--demo-tab", "today",
            "-UIPreferredContentSizeCategoryName", size.rawValue,
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
        defer { app.terminate() }

        // The seed assigns the battery only after all demo writes complete. Navigate after that redraw.
        let battery = app.buttons["app.battery"]
        try require(battery, in: app, timeout: 60)
        try waitFor(in: app, description: "the completed demo seed", timeout: 60) {
            battery.label == "Strap battery 68 percent"
        }
        let trendsTab = app.buttons["app.tab.1"]
        try require(trendsTab, in: app, timeout: 15)
        trendsTab.tap()
        try waitFor(in: app, description: "the real Trends tab") {
            app.buttons["app.deviceStatus"].label.contains("Trends")
        }

        let card = element("trends.insights", in: app)
        _ = try revealCardHeader(card, in: app)
        try waitFor(in: app, description: "a settled Trends Insights result", timeout: 45) {
            guard card.exists else { return false }
            let labels = ([card.label] + card.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label))
                .joined(separator: " ")
            guard !labels.contains("Reading your patterns") else { return false }
            // A settled result can contain findings, no clear differences, or insufficient history.
            return labels.range(of: #"From \d+ days"#, options: .regularExpression) != nil
                || labels.contains("No clear patterns yet")
                || labels.contains("Insights appear after about 2 weeks of wear.")
        }
        _ = try revealCardHeader(card, in: app)
        XCTAssertTrue(card.isEnabled)
        XCTAssertTrue(card.label.contains("Insights"), "The visible header belongs to the Insights link")
        if size == .normal, card.frame.height <= usableViewport(in: app).height {
            try reveal(card, in: app)
        }
        capture(app, "insights-\(size)-1-trends-card")
        if size == .accessibilityXXXL {
            // Advance into the same real card to capture the stacked compact findings. Limit
            // the gesture by its measured height so a short card is not skipped entirely.
            let appFrame = app.frame
            let visible = usableViewport(in: app)
            let distance = min(visible.height * 0.48, card.frame.height * 0.5)
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(
                CGVector(dx: appFrame.width * 0.02, dy: visible.minY + visible.height * 0.85 - appFrame.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: -distance))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
            capture(app, "insights-\(size)-1b-trends-findings")
        }
        // Scrolling invalidates the earlier screen coordinate. Resolve the actual header again.
        let cardHeader = try revealCardHeader(card, in: app)
        cardHeader.tap()

        let page = element("insights.detail", in: app)
        try require(page, in: app, timeout: 20)
        let hero = element("insights.hero", in: app)
        try require(hero, in: app, timeout: 10)
        try waitFor(in: app, description: "a settled Insights hub", timeout: 45) {
            let basis = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[cd] 'days of your data'")).firstMatch
            let insufficient = app.staticTexts["Insights need about 2 weeks of wear"]
            return basis.exists || insufficient.exists
        }
        XCTAssertFalse(app.staticTexts["Reading your patterns"].exists)
        XCTAssertTrue(hero.frame.intersects(app.frame), "The real hub opens at its hero")
        capture(app, "insights-\(size)-2-hub-hero")

        // These controls only appear after the report and dose cards have completed loading.
        // Scroll through the real content so the screenshots include the intervening findings and dose rows.
        let journal = element("insights.openJournal", in: app)
        try reveal(journal, in: app, capturePrefix: "insights-\(size)-3-hub")
        XCTAssertTrue(journal.isEnabled)
        XCTAssertTrue(journal.label.contains("Open Journal"))
        capture(app, "insights-\(size)-4-add-your-own")

        let how = app.staticTexts.matching(NSPredicate(format: "label ==[cd] 'How insights work'")).firstMatch
        try reveal(how, in: app)
        capture(app, "insights-\(size)-5-how-it-works")
        let enough = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@", "At least 5 nights on each side. Solid means 10 or more, Building means 5 to 9."
        )).firstMatch
        try reveal(enough, in: app)
        XCTAssertTrue(enough.exists, "The sample-size explanation is accessible")
        let footer = app.staticTexts["Patterns in your own data, not causes and not medical advice."]
        try reveal(footer, in: app, capturePrefix: "insights-\(size)-6-explanation")
        capture(app, "insights-\(size)-7-footer")
        #endif
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Root chrome grows to several rows at AX sizes. A lower part of the card being hittable
    /// does not prove that its title is exposed, so measure the visible chrome before choosing a tap.
    private func usableViewport(in app: XCUIApplication) -> CGRect {
        let frame = app.frame
        var top = frame.minY + 150
        for identifier in ["app.deviceStatus", "app.battery"] {
            let chrome = app.buttons[identifier]
            if chrome.exists, chrome.isHittable {
                let bounds = chrome.frame
                if !bounds.isEmpty, frame.intersects(bounds) { top = max(top, bounds.maxY + 12) }
            }
        }
        return CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, frame.maxY - 100 - top))
    }

    /// The whole compact card can be taller than the viewport at AX XXXL. Require its real
    /// title hit region to sit below all visible app chrome before activating the NavigationLink.
    private func revealCardHeader(_ card: XCUIElement, in app: XCUIApplication) throws -> XCUICoordinate {
        for _ in 0..<30 {
            let visible = usableViewport(in: app)
            let appFrame = app.frame
            let exists = card.exists
            let cardFrame = exists ? card.frame : .zero
            let header = CGRect(x: cardFrame.minX, y: cardFrame.minY,
                                width: cardFrame.width, height: min(44, cardFrame.height))
            if exists, card.isHittable, !header.isEmpty, visible.contains(header) {
                print("[insights-navigation] header=\(header) viewport=\(visible)")
                return app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: header.midX - appFrame.minX, dy: header.midY - appFrame.minY))
            }
            scrollToward(header, exists: exists, within: visible, in: app)
        }
        captureFailure(in: app)
        throw HarnessError.unreachable("Could not reveal the Insights navigation header")
    }

    private func gutterDrag(in app: XCUIApplication, down: Bool, within visible: CGRect) {
        let frame = app.frame
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: frame.width * 0.02,
                                              dy: visible.minY + visible.height * (down ? 0.15 : 0.85) - frame.minY))
        let end = origin.withOffset(CGVector(dx: frame.width * 0.02,
                                            dy: visible.minY + visible.height * (down ? 0.85 : 0.15) - frame.minY))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    private func scrollToward(_ target: CGRect, exists: Bool, within visible: CGRect, in app: XCUIApplication) {
        if !exists || target.isEmpty {
            gutterDrag(in: app, down: false, within: visible)
        } else if target.maxY < visible.minY || target.minY > visible.maxY {
            // Materialized rows can still be many screens away at AX XXXL.
            gutterDrag(in: app, down: target.maxY < visible.minY, within: visible)
        } else {
            // Correct near targets with a measured held drag rather than jumping across
            // their containment band. This also brings a partially obscured header below chrome.
            let overflow = target.minY < visible.minY
                ? visible.minY + 8 - target.minY
                : visible.maxY - 8 - target.maxY
            let limit = min(160, visible.height * 0.25)
            let distance = min(limit, max(12, abs(overflow))) * (overflow > 0 ? 1 : -1)
            print("[insights-reveal] target=\(target) viewport=\(visible) correction=\(distance)")
            let frame = app.frame
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let startY = visible.minY + visible.height * (distance > 0 ? 0.3 : 0.7)
            let start = origin.withOffset(CGVector(dx: frame.width * 0.02, dy: startY - frame.minY))
            let end = start.withOffset(CGVector(dx: 0, dy: distance))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
        }
    }

    /// A LazyVStack can create the target only after scrolling. Require the full target frame
    /// below the measured chrome, while allowing its text to occupy the entire remaining viewport.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, capturePrefix: String? = nil) throws {
        for attempt in 0..<30 {
            let visible = usableViewport(in: app)
            let exists = element.exists
            let target = exists ? element.frame : .zero
            if exists, element.isHittable, !target.isEmpty, visible.contains(target) { return }
            if let capturePrefix { capture(app, "\(capturePrefix)-scroll-\(attempt)") }
            scrollToward(target, exists: exists, within: visible, in: app)
        }
        captureFailure(in: app)
        throw HarnessError.unreachable("Could not fully reveal \(element.identifier)")
    }

    private func require(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) throws {
        guard element.waitForExistence(timeout: timeout) else {
            captureFailure(in: app)
            throw HarnessError.unreachable("Missing \(element.identifier)")
        }
    }

    private func waitFor(in app: XCUIApplication, description: String, timeout: TimeInterval = 15,
                         condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            captureFailure(in: app)
            throw HarnessError.unsettled("Timed out waiting for \(description)")
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
        hierarchy.name = "insights-failure-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        capture(app, "insights-failure-screen")
    }
}
