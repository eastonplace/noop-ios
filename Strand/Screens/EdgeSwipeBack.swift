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

/// Placed in the background of a custom-header screen. It installs once per navigation stack and costs nothing
/// per frame.
struct EdgeSwipeBack: UIViewControllerRepresentable {
    /// What the swipe does on a screen with nothing to pop. nil leaves the swipe to the stack.
    let rootBackAction: (() -> Void)?

    func makeUIViewController(context: Context) -> Probe { Probe() }

    func updateUIViewController(_ probe: Probe, context: Context) {
        probe.rootBackAction = rootBackAction
    }

    @MainActor
    final class Probe: UIViewController {
        var rootBackAction: (() -> Void)?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
            view.backgroundColor = .clear
            view.isAccessibilityElement = false
            view.accessibilityElementsHidden = true
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            attach()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            attach()
        }

        private func attach() {
            guard let stack = navigationController else { return }
            EdgeSwipeBackInstaller.install(on: stack, probe: self)
        }
    }
}

/// The delegate of the system's pop recogniser and of the one that backs out of a modal root.
@MainActor
final class EdgeSwipeBackInstaller: NSObject, UIGestureRecognizerDelegate {
    static let shared = EdgeSwipeBackInstaller()

    /// The probe of the screen showing now, so the root swipe runs the visible screen's own back action.
    private weak var visibleProbe: EdgeSwipeBack.Probe?

    static func install(on stack: UINavigationController, probe: EdgeSwipeBack.Probe) {
        shared.visibleProbe = probe
        if let pop = stack.interactivePopGestureRecognizer, pop.delegate !== shared {
            pop.delegate = shared
        }
        shared.installRootBackRecognizer(on: stack)
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
        visibleProbe?.rootBackAction?()
    }

    // MARK: UIGestureRecognizerDelegate

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let stack = gestureRecognizer.view?.next as? UINavigationController
                ?? (gestureRecognizer.view?.next as? UIViewController)?.navigationController else { return false }
        // Starting a pop while the stack is still pushing or popping leaves it stuck between screens.
        guard stack.transitionCoordinator == nil else { return false }
        if gestureRecognizer is RootBackRecognizer {
            return stack.viewControllers.count == 1 && visibleProbe?.rootBackAction != nil
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
