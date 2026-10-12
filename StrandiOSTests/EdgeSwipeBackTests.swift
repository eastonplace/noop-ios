import SwiftUI
import UIKit
import XCTest
@testable import NOOP
@testable import StrandDesign
import StrandAnalytics

/// The edge swipe that pops a custom-header screen (or backs out of a modal root) is back.
@MainActor
final class EdgeSwipeBackTests: XCTestCase {
    /// A stack of `depth` screens whose top one hosts a probe, the way a SwiftUI screen embeds it.
    private func stack(depth: Int, rootBack: (() -> Void)? = nil) -> (UINavigationController, EdgeSwipeBack.Probe) {
        let nav = UINavigationController(rootViewController: UIViewController())
        for _ in 1..<max(depth, 1) { nav.pushViewController(UIViewController(), animated: false) }
        nav.loadViewIfNeeded()
        return (nav, embed(rootBack: rootBack, in: nav))
    }

    private func embed(rootBack: (() -> Void)?, in nav: UINavigationController) -> EdgeSwipeBack.Probe {
        let top = nav.topViewController!
        top.loadViewIfNeeded()
        let probe = EdgeSwipeBack.Probe()
        probe.rootBackAction = rootBack
        top.addChild(probe)
        top.view.addSubview(probe.view)
        probe.didMove(toParent: top)   // registers it on `nav`
        return probe
    }

    private func rootRecognizer(_ nav: UINavigationController) -> UIGestureRecognizer? {
        nav.view.gestureRecognizers?.first { $0 is EdgeSwipeBackInstaller.RootBackRecognizer }
    }

    func testThePopGestureBeginsOnlyWhenTheStackIsDeeperThanOne() throws {
        let (single, singleProbe) = stack(depth: 1)
        defer { withExtendedLifetime(singleProbe) {} }
        let pop1 = try XCTUnwrap(single.interactivePopGestureRecognizer)
        XCTAssertTrue(pop1.delegate === EdgeSwipeBackInstaller.shared)
        XCTAssertFalse(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(pop1))

        let (deep, deepProbe) = stack(depth: 3)
        defer { withExtendedLifetime(deepProbe) {} }
        let pop3 = try XCTUnwrap(deep.interactivePopGestureRecognizer)
        XCTAssertTrue(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(pop3))
    }

    func testTheRootBackSwipeExistsOnlyOnAModalRootWithABackAction() throws {
        let (withBack, withBackProbe) = stack(depth: 1, rootBack: {})
        let (without, withoutProbe) = stack(depth: 1, rootBack: nil)
        let (deep, deepProbe) = stack(depth: 2, rootBack: {})
        try withExtendedLifetime((withBackProbe, withoutProbe, deepProbe)) {
            let recognizer = try XCTUnwrap(rootRecognizer(withBack))
            XCTAssertEqual((recognizer as? UIScreenEdgePanGestureRecognizer)?.edges, .left)
            XCTAssertTrue(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(recognizer))

            // A root with no action of its own (a tab's stack) never gets the recogniser at all.
            XCTAssertNil(rootRecognizer(without))
            // A pushed screen's action is for popping, not for a root swipe: no recogniser on a stack already deeper.
            XCTAssertNil(rootRecognizer(deep))
        }
    }

    func testInstallingTwiceKeepsOneRootRecogniser() {
        let (nav, probe) = stack(depth: 1, rootBack: {})
        EdgeSwipeBackInstaller.install(on: nav, probe: probe)
        let count = nav.view.gestureRecognizers?.filter { $0 is EdgeSwipeBackInstaller.RootBackRecognizer }.count
        XCTAssertEqual(count, 1)
    }

    /// A swipe on one tab's root must not run a hidden screen's back action in another tab. Each stack answers for its
    /// own screen only, and a screen that is gone answers for nothing.
    func testASwipeOnOneStackNeverReachesAnotherStacksScreen() throws {
        // The Trends tab: a modal-style root with its own back action, showing.
        let (trends, trendsProbe) = stack(depth: 1, rootBack: {})
        // The Today tab: a root with nothing to go back to.
        let (today, todayProbe) = stack(depth: 1, rootBack: nil)
        try withExtendedLifetime((trendsProbe, todayProbe)) {
            XCTAssertNil(rootRecognizer(today), "a tab root has no root swipe")
            let trendsSwipe = try XCTUnwrap(rootRecognizer(trends))
            XCTAssertTrue(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(trendsSwipe))
            // Today's probe appearing later does not become Trends' probe.
            XCTAssertTrue(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(trendsSwipe))
        }
    }

    func testAScreenThatDisappearedNoLongerAnswersItsStacksSwipe() throws {
        let (nav, probe) = stack(depth: 1, rootBack: {})
        let swipe = try XCTUnwrap(rootRecognizer(nav))
        XCTAssertTrue(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(swipe))
        probe.viewDidDisappear(false)
        XCTAssertFalse(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(swipe))
        probe.viewWillAppear(false)
        XCTAssertTrue(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(swipe))
    }

    func testAProbeOnAnotherScreenOfTheStackIsNotTheVisibleOne() throws {
        let (nav, rootProbe) = stack(depth: 1, rootBack: {})
        let swipe = try XCTUnwrap(rootRecognizer(nav))
        // A screen is pushed over the root: the root's probe is no longer the one showing, and the stack pops instead.
        nav.pushViewController(UIViewController(), animated: false)
        withExtendedLifetime(rootProbe) {
            XCTAssertFalse(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(swipe))
        }
        nav.popViewController(animated: false)
        withExtendedLifetime(rootProbe) {
            XCTAssertTrue(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(swipe))
        }
    }
}
