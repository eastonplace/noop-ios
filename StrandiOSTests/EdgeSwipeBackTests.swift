import SwiftUI
import UIKit
import XCTest
@testable import NOOP
import StrandDesign
import StrandAnalytics

/// The edge swipe that pops a custom-header screen (or backs out of a modal root) is back.
@MainActor
final class EdgeSwipeBackTests: XCTestCase {
    private func stack(depth: Int, rootBack: (() -> Void)? = nil) -> (UINavigationController, EdgeSwipeBack.Probe) {
        let nav = UINavigationController(rootViewController: UIViewController())
        for _ in 1..<max(depth, 1) { nav.pushViewController(UIViewController(), animated: false) }
        nav.loadViewIfNeeded()
        let probe = EdgeSwipeBack.Probe()
        probe.rootBackAction = rootBack
        EdgeSwipeBackInstaller.install(on: nav, probe: probe)
        return (nav, probe)
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
        // The installer holds the visible probe weakly (as the screen owns it), so the test keeps them alive.
        let (withBack, withBackProbe) = stack(depth: 1, rootBack: {})
        let (without, withoutProbe) = stack(depth: 1, rootBack: nil)
        let (deep, deepProbe) = stack(depth: 2, rootBack: {})
        try withExtendedLifetime((withBackProbe, withoutProbe, deepProbe)) {
            // `install` makes the last probe the visible one; point it back at each stack's own before asking.
            EdgeSwipeBackInstaller.install(on: withBack, probe: withBackProbe)
            let recognizer = try XCTUnwrap(withBack.view.gestureRecognizers?.first { $0 is EdgeSwipeBackInstaller.RootBackRecognizer })
            XCTAssertEqual((recognizer as? UIScreenEdgePanGestureRecognizer)?.edges, .left)
            XCTAssertTrue(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(recognizer))

            EdgeSwipeBackInstaller.install(on: without, probe: withoutProbe)
            let none = try XCTUnwrap(without.view.gestureRecognizers?.first { $0 is EdgeSwipeBackInstaller.RootBackRecognizer })
            XCTAssertFalse(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(none))

            // Pushed deeper, the stack pops and the root action stays quiet.
            EdgeSwipeBackInstaller.install(on: deep, probe: deepProbe)
            let deepRoot = try XCTUnwrap(deep.view.gestureRecognizers?.first { $0 is EdgeSwipeBackInstaller.RootBackRecognizer })
            XCTAssertFalse(EdgeSwipeBackInstaller.shared.gestureRecognizerShouldBegin(deepRoot))
        }
    }

    func testInstallingTwiceKeepsOneRootRecogniser() {
        let (nav, probe) = stack(depth: 1, rootBack: {})
        EdgeSwipeBackInstaller.install(on: nav, probe: probe)
        let count = nav.view.gestureRecognizers?.filter { $0 is EdgeSwipeBackInstaller.RootBackRecognizer }.count
        XCTAssertEqual(count, 1)
    }
}
