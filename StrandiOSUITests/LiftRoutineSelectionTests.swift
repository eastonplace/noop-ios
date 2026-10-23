import XCTest

/// Exercises the saved-routine rows used by Strength's "Pick a routine" action. Routing these rows to the
/// editor instead of the preview must fail before a workout can start.
@MainActor
final class LiftRoutineSelectionTests: XCTestCase {
    private enum HarnessError: Error {
        case unreachable(String)
    }

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

    func testRoutineEditAndSaveRemainSeparateFromStarting() throws {
        continueAfterFailure = false
        let app = launch()
        defer { app.terminate() }

        let pickRoutine = app.buttons["Pick a routine"]
        XCTAssertTrue(pickRoutine.waitForExistence(timeout: 60))
        pickRoutine.tap()

        let actions = app.buttons["Routine actions"].firstMatch
        reveal(actions, in: app)
        actions.tap()
        let save = try openRoutineEditor(in: app)
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
        let query = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
        // Optional actions are absent on some valid pages. Avoid asking XCTest to resolve
        // an empty matching snapshot before the per-element visibility checks can run.
        guard query.firstMatch.exists else { return nil }
        return query.allElementsBoundByIndex.first { element in
                guard element.exists else { return false }
                let frame = element.frame
                guard !frame.isEmpty, !frame.isNull, !frame.isInfinite,
                      frame.origin.x.isFinite, frame.origin.y.isFinite,
                      frame.width.isFinite, frame.height.isFinite,
                      app.frame.contains(frame) else { return false }
                return element.isHittable
            }
    }

    private func openRoutineEditor(in app: XCUIApplication) throws -> XCUIElement {
        let edit = app.buttons.matching(NSPredicate(format: "label == 'Edit'")).firstMatch
        guard edit.waitForExistence(timeout: 15) else {
            capture(app, "routine-edit-menu-missing")
            throw HarnessError.unreachable("The native Edit menu option must exist before activation")
        }
        let frame = edit.frame
        guard !frame.isEmpty, !frame.isNull, !frame.isInfinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite, app.frame.contains(frame), edit.isEnabled else {
            capture(app, "routine-edit-menu-not-ready")
            throw HarnessError.unreachable("The native Edit option must be enabled and fully visible before activation")
        }
        // iOS 26 can report a visible native menu option as non-hittable. Exercise the
        // actual menu touch, then require both dismissal and the editor's ready Save control.
        edit.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let menuDismissed = edit.waitForNonExistence(timeout: 5)
        if !menuDismissed { capture(app, "routine-edit-menu-did-not-dismiss") }
        XCTAssertTrue(menuDismissed, "Activating Edit must close the native routine menu")
        return readyAction("Save", in: app)
    }

    private func readyAction(_ label: String, in app: XCUIApplication) -> XCUIElement {
        let query = app.buttons.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label))
        let deadline = Date().addingTimeInterval(15)
        repeat {
            if let action = visibleAction(label, in: app) { return action }
            _ = query.firstMatch.waitForExistence(timeout: 0.5)
        } while Date() < deadline
        XCTFail("\(label) must be visible and ready to tap")
        return query.firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists, !element.frame.isEmpty, !element.frame.isInfinite,
               app.frame.contains(element.frame), element.isHittable { break }
            if element.exists, !element.frame.isEmpty, element.frame.maxY < app.frame.midY {
                app.swipeDown()
            } else {
                app.swipeUp()
            }
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
