import XCTest
@testable import NOOP

/// Pins when the shell re-presents an in-flight run or lift without a tap: once per foreground session,
/// never stacked on a visible workout screen, run before lift, and never fighting a deliberate dismissal.
/// Pure value types, no UI host needed.
final class ActiveSessionAutoPresentPolicyTests: XCTestCase {
    private typealias Policy = ActiveSessionAutoPresentPolicy

    private func context(
        run: Bool = false,
        lift: Bool = false,
        surfaceVisible: Bool = false,
        otherPresentation: Bool = false
    ) -> Policy.Context {
        Policy.Context(
            hasActiveRun: run,
            hasActiveLift: lift,
            workoutSurfaceVisible: surfaceVisible,
            otherPresentationActive: otherPresentation
        )
    }

    // MARK: Foreground edge

    func testColdLaunchWithRestoredRunPresentsTheRun() {
        var policy = Policy()
        XCTAssertEqual(policy.sceneBecameActive(context(run: true)), .run)
    }

    func testColdLaunchWithRestoredLiftPresentsTheLift() {
        var policy = Policy()
        XCTAssertEqual(policy.sceneBecameActive(context(lift: true)), .lift)
    }

    func testRunWinsWhenBothAreActive() {
        var policy = Policy()
        XCTAssertEqual(policy.sceneBecameActive(context(run: true, lift: true)), .run)
    }

    func testNothingActivePresentsNothing() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context()))
    }

    func testVisibleWorkoutSurfaceIsNeverStackedOn() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(run: true, surfaceVisible: true)))
    }

    func testAnotherShellSheetIsNeverStackedOn() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(run: true, otherPresentation: true)))
    }

    // MARK: Foreground sessions

    func testOnlyTheFirstActiveEdgeOfASessionDecides() {
        var policy = Policy()
        XCTAssertEqual(policy.sceneBecameActive(context(run: true)), .run)
        // The user dismissed the workout, then a Control Center pull-down bounced the scene through
        // .inactive and back to .active without ever reaching .background.
        XCTAssertNil(policy.sceneBecameActive(context(run: true)))
    }

    func testAnEdgeThatFoundNothingStillSpendsTheSession() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context()))
        // A run started and dismissed later in the session must not be revived by a .inactive blip.
        XCTAssertNil(policy.sceneBecameActive(context(run: true)))
    }

    func testReturningFromBackgroundStartsANewSession() {
        var policy = Policy()
        XCTAssertEqual(policy.sceneBecameActive(context(run: true)), .run)
        policy.sceneEnteredBackground()
        XCTAssertEqual(policy.sceneBecameActive(context(run: true)), .run)
    }

    func testReturningFromBackgroundWithTheWorkoutStillVisibleDoesNothing() {
        var policy = Policy()
        XCTAssertEqual(policy.sceneBecameActive(context(run: true)), .run)
        policy.sceneEnteredBackground()
        XCTAssertNil(policy.sceneBecameActive(context(run: true, surfaceVisible: true)))
    }

    // MARK: Lift restored after the edge

    func testLiftRestoredAfterTheEdgeGetsOneChance() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context()))
        XCTAssertEqual(policy.liftSessionRestored(context(lift: true)), .lift)
        XCTAssertNil(policy.liftSessionRestored(context(lift: true)))
    }

    func testLiftRestoredNeverPresentsOverARun() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(otherPresentation: true)))
        XCTAssertNil(policy.liftSessionRestored(context(run: true, lift: true)))
    }

    func testLiftRestoredNeverRevivesADismissedRun() {
        var policy = Policy()
        XCTAssertEqual(policy.sceneBecameActive(context(run: true)), .run)
        XCTAssertNil(policy.liftSessionRestored(context(run: true)))
    }

    func testLiftRestoredAfterSomethingWasPresentedThisSessionDoesNothing() {
        var policy = Policy()
        XCTAssertEqual(policy.sceneBecameActive(context(lift: true)), .lift)
        XCTAssertNil(policy.liftSessionRestored(context(lift: true)))
    }

    func testLiftRestoredWhileASurfaceIsVisibleDoesNothing() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context()))
        XCTAssertNil(policy.liftSessionRestored(context(lift: true, surfaceVisible: true)))
    }

    func testBackgroundingReopensTheLiftRestoreWindow() {
        var policy = Policy()
        XCTAssertEqual(policy.sceneBecameActive(context(lift: true)), .lift)
        policy.sceneEnteredBackground()
        XCTAssertNil(policy.sceneBecameActive(context(otherPresentation: true)))
        XCTAssertEqual(policy.liftSessionRestored(context(lift: true)), .lift)
    }

    // MARK: Surface visibility

    func testSurfaceVisibilityTracksIdentitiesNotCounts() {
        var surfaces = WorkoutSurfaceVisibility()
        let first = UUID()
        let second = UUID()
        XCTAssertFalse(surfaces.isVisible)

        // A repeated onAppear for the same view must not need a repeated onDisappear.
        surfaces.appeared(first)
        surfaces.appeared(first)
        XCTAssertTrue(surfaces.isVisible)
        surfaces.disappeared(first)
        XCTAssertFalse(surfaces.isVisible)

        surfaces.appeared(first)
        surfaces.appeared(second)
        surfaces.disappeared(first)
        XCTAssertTrue(surfaces.isVisible)
        surfaces.disappeared(second)
        XCTAssertFalse(surfaces.isVisible)
    }

    func testDisappearingAnUnknownSurfaceIsHarmless() {
        var surfaces = WorkoutSurfaceVisibility()
        surfaces.disappeared(UUID())
        XCTAssertFalse(surfaces.isVisible)
    }
}
