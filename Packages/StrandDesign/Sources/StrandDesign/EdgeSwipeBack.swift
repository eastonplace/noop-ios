#if os(iOS)
import SwiftUI
import UIKit

// MARK: - Edge swipe back
//
// Every pushed screen draws its own header (a back chevron beside its title) and hides the system navigation bar.
// UIKit only lets the edge swipe pop a screen while the stack's own bar is showing, so the swipe stopped working
// across the app the day the bar was hidden. This brings it back for the screens that use the custom header:
//
//   - a screen pushed onto a stack pops with the native interactive transition, the same one the bar's chevron
//     would have given it (only when the stack is deeper than one screen, and never while it is mid-transition);
//   - a screen that roots a modal stack (a pillar detail opened as a full-screen cover) has nothing to pop, so the
//     same swipe runs the screen's own back action instead, which is what its chevron does.
//
// The recogniser is the system's screen-edge pan, so it begins only within a thumb's width of the leading edge. A
// chart's scrub or pan (the HR timeline, the Trends hero chart, the Stress ribbon) starts anywhere else and is
// untouched; a chart that could start inside that strip stands aside for the swipe (`HRTimelineTouchSurface`).
// Settings keeps its native bar and its native swipe, and never installs this.
//
// It lives in StrandDesign so every package that draws its own header can ask for the swipe: Lift's pushed pages hide the
// navigation bar for the same reason the app's do, and ask for it back the same way (`LiftPage`).

/// Placed in the background of a custom-header screen. It installs once per navigation stack and costs nothing
/// per frame.
public struct EdgeSwipeBack: UIViewControllerRepresentable {
    /// What the swipe does on a screen with nothing to pop. nil leaves the swipe to the stack.
    let rootBackAction: (() -> Void)?

    public init(rootBackAction: (() -> Void)?) { self.rootBackAction = rootBackAction }

    public func makeUIViewController(context: Context) -> Probe { Probe() }

    public func updateUIViewController(_ probe: Probe, context: Context) {
        probe.rootBackAction = rootBackAction
    }

    @MainActor
    public final class Probe: UIViewController {
        var rootBackAction: (() -> Void)? {
            didSet { attach() }
        }
        /// The stack this probe is registered on, so it can be withdrawn after the stack no longer has a parent for it.
        private weak var attachedStack: UINavigationController?

        public override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            view.isAccessibilityElement = false
            view.accessibilityElementsHidden = true
        }

        public override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            attach()
        }

        public override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            attach()
        }

        public override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            // Gone from the stack's top (popped, covered): it must not answer a swipe on its stack any more.
            EdgeSwipeBackInstaller.shared.forget(self, on: attachedStack)
        }

        private func attach() {
            guard let stack = navigationController else { return }
            attachedStack = stack
            EdgeSwipeBackInstaller.install(on: stack, probe: self)
        }

        /// Whether this probe belongs to the screen showing on top of `stack` now.
        func isShowing(in stack: UINavigationController) -> Bool {
            guard navigationController === stack, let top = stack.topViewController else { return false }
            var node: UIViewController? = self
            while let current = node {
                if current === top { return true }
                node = current.parent
            }
            return false
        }
    }
}

/// The delegate of the system's pop recogniser and of the one that backs out of a modal root.
@MainActor
final class EdgeSwipeBackInstaller: NSObject, UIGestureRecognizerDelegate {
    static let shared = EdgeSwipeBackInstaller()

    /// The probe of the screen showing on each stack, so a root swipe runs the back action of the screen that was
    /// swiped on and never another stack's (the tabs each have a stack). Weak both ways: a screen owns its probe and a
    /// stack its screens.
    private let probes = NSMapTable<UINavigationController, EdgeSwipeBack.Probe>.weakToWeakObjects()

    static func install(on stack: UINavigationController, probe: EdgeSwipeBack.Probe) {
        shared.probes.setObject(probe, forKey: stack)
        if let pop = stack.interactivePopGestureRecognizer, pop.delegate !== shared {
            pop.delegate = shared
        }
        // Only a stack whose root screen has a back action of its own (a pillar opened as a cover) needs the root
        // swipe; a tab's stack, and a pushed screen's, never get it.
        if stack.viewControllers.count == 1, probe.rootBackAction != nil {
            shared.installRootBackRecognizer(on: stack)
        }
    }

    func forget(_ probe: EdgeSwipeBack.Probe, on stack: UINavigationController?) {
        guard let stack, probes.object(forKey: stack) === probe else { return }
        probes.removeObject(forKey: stack)
    }

    /// The probe of the screen showing on top of `stack`, nil when none is.
    private func visibleProbe(in stack: UINavigationController) -> EdgeSwipeBack.Probe? {
        guard let probe = probes.object(forKey: stack), probe.isShowing(in: stack) else { return nil }
        return probe
    }

    // MARK: Root of a modal stack

    /// Its own type, so the one this installs is told apart from the system's own edge recognisers on the same view.
    final class RootBackRecognizer: UIScreenEdgePanGestureRecognizer {}

    private func installRootBackRecognizer(on stack: UINavigationController) {
        let hasOne = stack.view.gestureRecognizers?.contains { $0 is RootBackRecognizer } ?? false
        guard !hasOne else { return }
        let recognizer = RootBackRecognizer(target: self, action: #selector(rootBack(_:)))
        let isRightToLeft = UIView.userInterfaceLayoutDirection(for: stack.view.semanticContentAttribute) == .rightToLeft
        recognizer.edges = isRightToLeft ? .right : .left
        recognizer.delegate = self
        stack.view.addGestureRecognizer(recognizer)
    }

    @objc private func rootBack(_ recognizer: UIScreenEdgePanGestureRecognizer) {
        guard recognizer.state == .ended, let view = recognizer.view else { return }
        let translation = recognizer.translation(in: view).x
        let velocity = recognizer.velocity(in: view).x
        let direction: CGFloat = recognizer.edges == .right ? -1 : 1
        guard translation * direction > 70 || velocity * direction > 600 else { return }
        guard let stack = (view.next as? UINavigationController) ?? (view.next as? UIViewController)?.navigationController
        else { return }
        visibleProbe(in: stack)?.rootBackAction?()
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let stack = gestureRecognizer.view?.next as? UINavigationController
                ?? (gestureRecognizer.view?.next as? UIViewController)?.navigationController else { return false }
        // Starting a pop while the stack is still pushing or popping leaves it stuck between screens.
        guard stack.transitionCoordinator == nil else { return false }
        if gestureRecognizer is RootBackRecognizer {
            return stack.viewControllers.count == 1 && visibleProbe(in: stack)?.rootBackAction != nil
        }
        return stack.viewControllers.count > 1
    }

    /// The pop never runs beside another recogniser: a page scroll waits for it at the edge, and a chart's own
    /// recognisers stand aside for it (they see a touch that began in the strip and decline).
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { false }
}
#endif
