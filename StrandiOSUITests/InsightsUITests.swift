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
        let cardHeader = try revealCardHeader(card, in: app)
        XCTAssertTrue(card.isEnabled)
        XCTAssertTrue(card.label.contains("Insights"), "The visible header belongs to the Insights link")
        capture(app, "insights-\(size)-1-trends-card")
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

    /// The whole compact card can be taller than the viewport at AX XXXL. Its title remains
    /// a real hit region of the NavigationLink, so require that header on screen before activating it.
    private func revealCardHeader(_ card: XCUIElement, in app: XCUIApplication) throws -> XCUICoordinate {
        for _ in 0..<30 {
            let appFrame = app.frame
            let visible = CGRect(x: appFrame.minX, y: appFrame.minY + 100,
                                 width: appFrame.width, height: appFrame.height - 200)
            if card.exists, card.isHittable, !card.frame.isEmpty {
                let header = CGRect(x: card.frame.minX, y: card.frame.minY,
                                    width: card.frame.width, height: min(44, card.frame.height))
                if visible.contains(header) {
                    return app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: header.midX - appFrame.minX, dy: header.midY - appFrame.minY))
                }
            }
            gutterDrag(in: app, down: card.exists && card.frame.minY < visible.minY)
        }
        captureFailure(in: app)
        throw HarnessError.unreachable("Could not reveal the Insights navigation header")
    }

    private func gutterDrag(in app: XCUIApplication, down: Bool) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: down ? 0.30 : 0.78))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: down ? 0.78 : 0.30))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Drag outside chart scrub areas. A LazyVStack can create the target only after scrolling.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, capturePrefix: String? = nil) throws {
        for attempt in 0..<30 {
            let appFrame = app.frame
            let visible = CGRect(x: appFrame.minX, y: appFrame.minY + 100,
                                 width: appFrame.width, height: appFrame.height - 200)
            if element.exists, element.isHittable, !element.frame.isEmpty, visible.contains(element.frame) { return }
            if let capturePrefix { capture(app, "\(capturePrefix)-scroll-\(attempt)") }
            gutterDrag(in: app, down: element.exists && element.frame.minY < visible.minY)
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
