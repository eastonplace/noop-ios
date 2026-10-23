import XCTest

/// Presentation proof for the Heads-Up card under Health Monitor, its page in every state, and the one-page Journal.
/// Heads-Up states come from the DEBUG `--demo-heads-up <state>` fixture over the demo seed, so each capture is the
/// same read on every run. The Journal check answers one question "No" on the demo day; nothing else is written and no
/// device command is sent.
@MainActor
final class HeadsUpJournalUITests: XCTestCase {
    private enum HarnessError: Error {
        case unreachable(String)
    }

    // MARK: Heads-Up

    func testHeadsUpRaisedCardBannerAndPage() throws {
        continueAfterFailure = false
        let app = launch(headsUp: "raised")
        defer { app.terminate() }
        try requireDemoReady(in: app)

        let banner = element("today.headsUp.banner", in: app)
        try require(banner, in: app, timeout: 30)
        XCTAssertTrue(banner.label.contains("Heads-up"), "A raised read shows the one-line banner")
        capture(app, "heads-up-raised-today-banner")

        let card = element("today.headsUp.card", in: app)
        try reveal(card, in: app)
        let cardLabel = card.label
        XCTAssertTrue(cardLabel.contains("3 of 4 signals up"),
                      "The card must count the signals that moved. Actual label: \(cardLabel)")
        XCTAssertTrue(app.frame.contains(card.frame), "The card sits fully on screen once revealed")
        capture(app, "heads-up-raised-today-card")

        card.tap()
        let page = element("headsUp.detail", in: app)
        try require(page, in: app, timeout: 15)
        capture(app, "heads-up-raised-page-1-hero")
        for index in 2...6 {
            gutterDrag(in: app)
            capture(app, "heads-up-raised-page-\(index)")
        }
    }

    func testHeadsUpQuietAndLearningStates() throws {
        continueAfterFailure = false
        for state in ["off", "learning", "unavailable", "clear", "mild"] {
            let app = launch(headsUp: state)
            try requireDemoReady(in: app)
            // Off is not a button as a whole; its Turn on action is what can be revealed and tapped.
            let card = element(state == "off" ? "today.headsUp.turnOn" : "today.headsUp.card", in: app)
            try reveal(card, in: app)
            capture(app, "heads-up-\(state)-today-card")
            if state == "unavailable" {
                XCTAssertTrue(card.label.contains("No reading"))
                XCTAssertFalse(card.label.contains("All clear"), "An untrusted comparison must not reassure")
            }
            if state == "off" {
                XCTAssertTrue(element("today.headsUp.off", in: app).exists, "Off shows the explainer card")
            } else {
                card.tap()
                try require(element("headsUp.detail", in: app), in: app, timeout: 15)
                capture(app, "heads-up-\(state)-page-1-hero")
                if state == "unavailable" {
                    XCTAssertTrue(app.staticTexts["No reliable read yet"].exists)
                    XCTAssertFalse(app.staticTexts["All clear"].exists)
                }
                gutterDrag(in: app)
                capture(app, "heads-up-\(state)-page-2")
            }
            app.terminate()
        }
    }

    func testHeadsUpExplainedAndRestPages() throws {
        continueAfterFailure = false
        for state in ["explained", "unwell"] {
            let app = launch(headsUp: state)
            try requireDemoReady(in: app)
            let card = element("today.headsUp.card", in: app)
            try reveal(card, in: app)
            capture(app, "heads-up-\(state)-today-card")
            card.tap()
            try require(element("headsUp.detail", in: app), in: app, timeout: 15)
            capture(app, "heads-up-\(state)-page-1-hero")
            for index in 2...4 {
                gutterDrag(in: app)
                capture(app, "heads-up-\(state)-page-\(index)")
            }
            app.terminate()
        }
    }

    // MARK: Journal

    func testJournalIsOnePageThatSavesAsYouTap() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = baseArguments + ["--noop-qa-route", "journal"]
        app.launch()
        defer { app.terminate() }

        let home = element("journal.home", in: app)
        try require(home, in: app, timeout: 60)
        XCTAssertFalse(app.buttons["Save check-in"].exists, "Answers save as they are tapped")
        capture(app, "journal-home-1-top")

        // One tile per question; a plain Yes/No question is not a counted one, so a tap is exactly Yes, then No.
        let tile = element("journal.tile.Did you read before bed?", in: app)
        try require(tile, in: app, timeout: 10)
        // A re-run on the same simulator keeps the last run's answer: a tap on a Yes switches it to No, so tap
        // again until it reads Yes.
        if !tile.label.hasSuffix(", yes") {
            let before = tile.label
            tile.tap()
            try waitFor(tile, predicate: "label != '\(before)'", in: app)
            if tile.label.hasSuffix(", no") { tile.tap() }
        }
        try waitFor(tile, predicate: "label ENDSWITH ', yes'", in: app)
        XCTAssertTrue(element("journal.progress", in: app).exists, "The progress line counts the tap")
        capture(app, "journal-home-2-answered")

        for index in 3...6 {
            gutterDrag(in: app)
            capture(app, "journal-home-\(index)")
        }
    }

    func testJournalRefreshesRenamedAndRetypedQuestionAfterEditing() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = baseArguments + ["--noop-qa-route", "journal"]
        app.launch()
        defer { app.terminate() }
        try require(element("journal.home", in: app), in: app, timeout: 60)
        let edit = element("journal.editQuestions", in: app)
        try reveal(edit, in: app)
        edit.tap()
        let question = element("journal.question.did-you-read-before-bed", in: app)
        try reveal(question, in: app)
        question.tap()
        let name = app.textFields["journal.question.did-you-read-before-bed.name"]
        try require(name, in: app, timeout: 10)
        name.tap()
        let current = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + "Bedtime reading")
        app.buttons["Done"].firstMatch.tap()
        let answer = element("journal.question.did-you-read-before-bed.answer", in: app)
        answer.tap()
        app.buttons["Number"].tap()
        // Both pages use the scaffold's explicit Back action.
        app.buttons["Back"].firstMatch.tap()
        app.buttons["Back"].firstMatch.tap()
        let tile = element("journal.tile.Did you read before bed?", in: app)
        try require(tile, in: app, timeout: 10)
        // Scroll toward the top after returning from the bottom link.
        for _ in 0..<10 where !tile.isHittable { app.swipeDown() }
        try waitFor(tile, predicate: "label BEGINSWITH 'Bedtime reading'", in: app)
        let previous = tile.label
        tile.tap()
        try waitFor(tile, predicate: "label != '\(previous)'", in: app)
        XCTAssertFalse(tile.label.hasSuffix(", yes"), "The changed Number type is reflected by the Journal tile")
        XCTAssertFalse(tile.label.hasSuffix(", no"), "A Number tap stores an amount after returning")
        capture(app, "journal-edit-return-updated-tile")
        // Restore this shared demo question so later Journal cases still exercise its plain Yes/No type.
        try reveal(edit, in: app)
        edit.tap()
        try reveal(question, in: app)
        question.tap()
        name.tap()
        let editedName = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: editedName.count) + "Read before bed")
        app.buttons["Done"].firstMatch.tap()
        answer.tap()
        app.buttons["Yes / No"].tap()
        app.buttons["Back"].firstMatch.tap()
        app.buttons["Back"].firstMatch.tap()
    }

    // MARK: Harness

    private let baseArguments = [
        "--noop-coach-shell-qa", "--demo-seed", "--noop-lift-demo", "fresh",
        "--demo-tab", "today",
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL",
        "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark",
    ]

    private func launch(headsUp state: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = baseArguments + ["--demo-heads-up", state]
        app.launch()
        return app
    }

    /// The demo seed writes after the shell is interactive; its strap battery is the last thing it sets.
    private func requireDemoReady(in app: XCUIApplication) throws {
        let battery = app.buttons["app.battery"]
        try require(battery, in: app, timeout: 60)
        try waitFor(battery, predicate: "label == 'Strap battery 68 percent'", in: app, timeout: 60)
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// One upward drag in the left gutter, outside every chart's scrub area, so the page scrolls instead.
    private func gutterDrag(in app: XCUIApplication) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.78))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.30))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Scroll until `element` is on screen above the tab bar and can be tapped.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) throws {
        let visible = app.frame.insetBy(dx: 0, dy: 90)
        for _ in 0..<16 {
            if element.exists, element.frame.width > 0, element.isHittable,
               visible.intersects(element.frame), element.frame.minY < visible.maxY - 60 {
                return
            }
            gutterDrag(in: app)
        }
        captureFailure(in: app)
        throw HarnessError.unreachable("Could not reveal \(element.identifier)")
    }

    private func require(_ element: XCUIElement, in app: XCUIApplication, timeout: TimeInterval) throws {
        guard element.waitForExistence(timeout: timeout) else {
            captureFailure(in: app)
            throw HarnessError.unreachable("Missing \(element.identifier)")
        }
    }

    private func waitFor(_ element: XCUIElement, predicate: String, in app: XCUIApplication,
                         timeout: TimeInterval = 8) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            captureFailure(in: app)
            throw HarnessError.unreachable("Expected \(predicate) for \(element.identifier)")
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
        hierarchy.name = "heads-up-journal-failure-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        capture(app, "heads-up-journal-failure-screen")
    }
}
