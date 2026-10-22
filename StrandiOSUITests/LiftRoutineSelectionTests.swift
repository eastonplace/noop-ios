import XCTest

/// Exercises the saved-routine rows used by Strength's "Pick a routine" action. Routing these rows to the
/// editor instead of the preview must fail before a workout can start.
@MainActor
final class LiftRoutineSelectionTests: XCTestCase {
    func testSwitchingSavedRoutinesPreviewsThenStartsTheSelectedRoutine() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }

        let pickRoutine = app.buttons["Pick a routine"]
        XCTAssertTrue(pickRoutine.waitForExistence(timeout: 60))
        pickRoutine.tap()

        openRoutine("Upper A", in: app)
        _ = readyAction("lift.progression.startAsPlanned", in: app)
        XCTAssertNil(visibleAction("Save", in: app), "Selecting a saved routine opens its preview")
        XCTAssertNil(visibleAction("Finish workout", in: app), "Previewing must not start a session")
        readyAction("Back", in: app).tap()

        openRoutine("Lower A", in: app)
        let start = readyAction("lift.progression.startAsPlanned", in: app)
        XCTAssertNil(visibleAction("Finish workout", in: app), "Switching routines must not start a session")
        start.tap()

        _ = readyAction("Finish workout", in: app)
        let lowerRecording = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'Recording' AND label CONTAINS[c] 'Lower A'")
        ).firstMatch
        XCTAssertTrue(lowerRecording.exists, "The workout uses the second selection")
        XCTAssertNil(visibleAction("lift.progression.startAsPlanned", in: app))
        XCTAssertNil(visibleAction("lift.progression.applyAndStart", in: app))
        capture(app, "selected-lower-a-workout")

        readyAction("Close workout", in: app).tap()
        openRoutine("Upper A", in: app)
        XCTAssertNil(visibleAction("lift.progression.startAsPlanned", in: app), "An active workout cannot be replaced by another selection")
        XCTAssertNil(visibleAction("lift.progression.applyAndStart", in: app), "Reviewed targets cannot replace an active workout")
        readyAction("Back", in: app).tap()
        readyAction("Resume lift", in: app).tap()
        _ = readyAction("Finish workout", in: app)
        XCTAssertTrue(lowerRecording.exists, "The original selected workout remains active")
    }

    func testRoutineEditAndSaveRemainSeparateFromStarting() {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }

        let pickRoutine = app.buttons["Pick a routine"]
        XCTAssertTrue(pickRoutine.waitForExistence(timeout: 60))
        pickRoutine.tap()

        let actions = app.buttons["Routine actions"].firstMatch
        reveal(actions, in: app)
        actions.tap()
        let save = openRoutineEditor(in: app)
        XCTAssertNil(visibleAction("lift.progression.startAsPlanned", in: app))
        XCTAssertNil(visibleAction("lift.progression.applyAndStart", in: app))
        XCTAssertNil(visibleAction("Finish workout", in: app))
        save.tap()

        openRoutine("Upper A", in: app)
        _ = readyAction("lift.progression.startAsPlanned", in: app)
        XCTAssertNil(visibleAction("Save", in: app), "The saved routine opens its preview")
        XCTAssertNil(visibleAction("Finish workout", in: app), "Saving a routine must not start it")
        capture(app, "saved-routine-preview")
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--noop-coach-shell-qa",
            "--demo-seed", "--noop-qa-route", "lift", "--noop-lift-demo", "fresh",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-AppleInterfaceStyle", "Dark",
        ]
        app.launch()
        return app
    }

    private func openRoutine(_ name: String, in app: XCUIApplication) {
        // Dismissing the preview's boolean navigation destination can return to Strength's root. Reopen the
        // saved list from that root, including when its active-workout card replaces "Pick a routine".
        if let menu = visibleAction("Lift menu", in: app) {
            menu.tap()
            readyAction("Routines and schedule", in: app).tap()
        }
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        reveal(row, in: app)
        row.tap()
    }

    private func visibleAction(_ label: String, in app: XCUIApplication) -> XCUIElement? {
        app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
            .allElementsBoundByIndex.first { $0.isHittable }
    }

    private func openRoutineEditor(in app: XCUIApplication) -> XCUIElement {
        let edit = readyAction("Edit", in: app)
        edit.tap()
        let save = app.buttons.matching(NSPredicate(format: "label == 'Save' OR identifier == 'Save'")).firstMatch
        if !save.waitForExistence(timeout: 5), edit.exists && edit.isHittable {
            // Native menu taps can leave the same popup open on Simulator. Retry once on
            // the label side only while Edit is still visible; never bypass the menu route.
            capture(app, "edit-menu-still-open-before-retry")
            edit.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)).tap()
        }
        return readyAction("Save", in: app)
    }

    private func readyAction(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let query = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 15), "\(label) is available")
        let action = visibleAction(label, in: app) ?? query.firstMatch
        XCTAssertTrue(action.isHittable, "\(label) must be visible and ready to tap")
        return action
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isHittable)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
