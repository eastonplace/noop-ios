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

    // MARK: Waiting out another modal

    func testABlockedRunPresentsOnceTheModalIsGone() {
        var policy = Policy()
        // "What's New" is up at launch with a workout restored underneath it.
        XCTAssertNil(policy.sceneBecameActive(context(run: true, otherPresentation: true)))

        XCTAssertEqual(policy.otherPresentationEnded(context(run: true)), .run)
        XCTAssertNil(policy.otherPresentationEnded(context(run: true)))
    }

    func testABlockedLiftPresentsOnceTheModalIsGone() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(lift: true, otherPresentation: true)))
        XCTAssertEqual(policy.otherPresentationEnded(context(lift: true)), .lift)
    }

    func testAStillBlockedRetryStaysArmed() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(run: true, otherPresentation: true)))

        // A second modal took the first one's place before the delay elapsed.
        XCTAssertNil(policy.otherPresentationEnded(context(run: true, otherPresentation: true)))
        XCTAssertEqual(policy.otherPresentationEnded(context(run: true)), .run)
    }

    func testNothingBlockedMeansNothingToRetry() {
        var policy = Policy()
        XCTAssertEqual(policy.sceneBecameActive(context(run: true)), .run)
        // The user dismissed the run, then opened and closed some other sheet.
        XCTAssertNil(policy.otherPresentationEnded(context(run: true)))

        var idle = Policy()
        XCTAssertNil(idle.sceneBecameActive(context(otherPresentation: true)))
        XCTAssertNil(idle.otherPresentationEnded(context(run: true)))
    }

    func testRetryDropsWhenTheWorkoutEndedWhileBlocked() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(run: true, otherPresentation: true)))
        XCTAssertNil(policy.otherPresentationEnded(context()))
        // Cleared, so a later run is not revived by a stale retry.
        XCTAssertNil(policy.otherPresentationEnded(context(run: true)))
    }

    func testRetryDropsWhenTheUserOpenedTheWorkoutByHand() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(run: true, otherPresentation: true)))
        XCTAssertNil(policy.otherPresentationEnded(context(run: true, surfaceVisible: true)))
        XCTAssertNil(policy.otherPresentationEnded(context(run: true)))
    }

    func testBackgroundingForgetsAPendingRetry() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(run: true, otherPresentation: true)))
        policy.sceneEnteredBackground()
        XCTAssertNil(policy.otherPresentationEnded(context(run: true)))
    }

    // MARK: Opened on request while blocked

    /// A Live Activity tap while Settings is up: the policy held the run back for the Settings sheet, then the
    /// shell closed Settings and opened the workout itself. Closing that workout must not bring it back.
    func testARunOpenedOnRequestWhileBlockedIsNotRepresentedAfterItsDismissal() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(run: true, otherPresentation: true)))

        policy.workoutOpenedByRequest()

        // The workout was on screen and got dismissed; the shell's blocker flag then flips and the retry runs.
        XCTAssertNil(policy.otherPresentationEnded(context(run: true)))
    }

    func testALiftOpenedOnRequestWhileBlockedIsNotRepresentedAfterItsDismissal() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(lift: true, otherPresentation: true)))

        policy.workoutOpenedByRequest()

        XCTAssertNil(policy.otherPresentationEnded(context(lift: true)))
    }

    func testALateLiftRestoreHeldBackThenOpenedOnRequestIsNotRepresented() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(otherPresentation: true)))
        XCTAssertNil(policy.liftSessionRestored(context(lift: true, otherPresentation: true)))

        policy.workoutOpenedByRequest()

        XCTAssertNil(policy.otherPresentationEnded(context(lift: true)))
    }

    /// The request can also land before the foreground edge is evaluated (the tap that launches the app): the
    /// edge then has nothing left to present, and neither does a lift that finishes restoring afterwards.
    func testARequestBeforeTheForegroundEdgeSpendsTheSession() {
        var run = Policy()
        run.workoutOpenedByRequest()
        XCTAssertNil(run.sceneBecameActive(context(run: true, otherPresentation: true)))
        XCTAssertNil(run.otherPresentationEnded(context(run: true)))

        var lift = Policy()
        lift.workoutOpenedByRequest()
        XCTAssertNil(lift.sceneBecameActive(context(lift: true, otherPresentation: true)))
        XCTAssertNil(lift.liftSessionRestored(context(lift: true, otherPresentation: true)))
        XCTAssertNil(lift.otherPresentationEnded(context(lift: true)))
    }

    func testARequestOnlyCoversTheSessionItWasMadeIn() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(run: true, otherPresentation: true)))
        policy.workoutOpenedByRequest()

        policy.sceneEnteredBackground()

        XCTAssertEqual(policy.sceneBecameActive(context(run: true)), .run)
    }

    // MARK: Automatic presentation never dismisses

    /// The app comes back with a run in progress while a screen's own sheet is up (a manual workout, a journal edit). The
    /// shell's sheets are all closed, but the window reports a modal: the run is held back, not forced through, because
    /// presenting it would dismiss that sheet and its unsaved input. The resume bar is the way back meanwhile.
    func testARunIsHeldBackByAScreensOwnSheetNotForcedThroughIt() {
        var policy = Policy()
        let screenSheetUp = Policy.Context(hasActiveRun: true, hasActiveLift: false, workoutSurfaceVisible: false,
                                           shellPresentationActive: false, anyModalPresented: true)
        XCTAssertTrue(screenSheetUp.otherPresentationActive)
        XCTAssertNil(policy.sceneBecameActive(screenSheetUp))
        // A retry while that sheet is still up presents nothing either.
        XCTAssertNil(policy.otherPresentationEnded(screenSheetUp))

        let bare = Policy.Context(hasActiveRun: true, hasActiveLift: false, workoutSurfaceVisible: false,
                                  shellPresentationActive: false, anyModalPresented: false)
        XCTAssertFalse(bare.otherPresentationActive)
        XCTAssertEqual(policy.otherPresentationEnded(bare), .run, "once nothing is up the held-back run is presented")
    }

    func testALiftIsHeldBackByAScreensOwnSheetToo() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(Policy.Context(hasActiveRun: false, hasActiveLift: true,
                                                             workoutSurfaceVisible: false, shellPresentationActive: false,
                                                             anyModalPresented: true)))
    }

    func testALateLiftRestoreBlockedByAModalRetriesAsALift() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(otherPresentation: true)))
        XCTAssertNil(policy.liftSessionRestored(context(lift: true, otherPresentation: true)))

        XCTAssertEqual(policy.otherPresentationEnded(context(lift: true)), .lift)
    }

    func testARetryNeverReplacesABlockedRunWithALift() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(run: true, otherPresentation: true)))
        XCTAssertNil(policy.liftSessionRestored(context(run: true, lift: true, otherPresentation: true)))

        XCTAssertEqual(policy.otherPresentationEnded(context(run: true, lift: true)), .run)
    }

    func testARetryForALiftNeverPresentsARunStartedMeanwhile() {
        var policy = Policy()
        XCTAssertNil(policy.sceneBecameActive(context(lift: true, otherPresentation: true)))
        XCTAssertNil(policy.otherPresentationEnded(context(run: true, lift: true)))
    }

    func testBlockersAreTrackedByIdentity() {
        var blockers = AutoPresentBlockers()
        let whatsNew = UUID()
        let terms = UUID()
        XCTAssertFalse(blockers.isBlocked)

        blockers.set(true, id: whatsNew)
        blockers.set(true, id: whatsNew)
        blockers.set(true, id: terms)
        XCTAssertTrue(blockers.isBlocked)

        blockers.set(false, id: whatsNew)
        XCTAssertTrue(blockers.isBlocked)
        blockers.set(false, id: terms)
        XCTAssertFalse(blockers.isBlocked)

        blockers.set(false, id: UUID())
        XCTAssertFalse(blockers.isBlocked)
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
