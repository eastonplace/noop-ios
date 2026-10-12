#if os(iOS)
import SwiftUI

/// Gets the app shell to a state where it can present one full-screen cover, even when a screen below it is presenting a
/// sheet or a cover of its own.
///
/// A cover on the root fails silently while any descendant presents something, so the shell first lets go of its own sheets,
/// bumps `NavRouter.modalCollapseGeneration` (every presenter that applies `collapsesForWorkoutJourney` closes itself), waits
/// for the system to report nothing presented, and only then presents. If something is still up after the patience runs
/// out, it is dismissed outright. Nothing is presented while a dismissal is still animating.
@MainActor
enum ShellModalCollapse {
    /// How often the probe is polled, and for how long, before the fallback.
    static let pollInterval: Duration = .milliseconds(100)
    static let patience: Duration = .milliseconds(1200)
    /// Air left after a forced dismissal, so the presentation that follows does not meet a half-dismissed controller.
    static let settle: Duration = .milliseconds(150)

    /// True from the moment a collapse starts waiting until it has presented. Requests that arrive meanwhile are coalesced into
    /// it: a second poll would find the cover the first one just presented and take it for something in the way.
    private(set) static var isCollapsing = false

    /// Calls `present` once nothing is presented. With nothing up it is called at once, synchronously. Returns false when a
    /// collapse is already under way: that one will present, so this request changes nothing (and `clearShellState` and
    /// `present` are not called).
    ///
    /// - Parameters:
    ///   - clearShellState: closes the shell's own sheets (and bumps the router's collapse generation).
    ///   - isSatisfied: whether what is being presented is already up. The wait ends then, and nothing is dismissed: the modal
    ///     the probe reports is the target itself.
    ///   - isModalPresented / forceDismiss / sleep: the system seams, replaceable in tests.
    @discardableResult
    static func run(
        clearShellState: () -> Void,
        isSatisfied: @escaping @MainActor () -> Bool = { false },
        isModalPresented: @escaping @MainActor () -> Bool = { ModalPresentationProbe.isAnyModalPresented },
        forceDismiss: @escaping @MainActor () -> Void = { ModalPresentationProbe.dismissAll() },
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        then present: @escaping @MainActor () -> Void
    ) -> Bool {
        guard !isCollapsing else { return false }
        guard isModalPresented() else {
            present()
            return true
        }
        clearShellState()
        isCollapsing = true
        Task { @MainActor in
            defer { isCollapsing = false }
            var waited: Duration = .zero
            while isModalPresented(), !isSatisfied(), waited < patience {
                await sleep(pollInterval)
                waited += pollInterval
            }
            if isModalPresented(), !isSatisfied() {
                forceDismiss()
                await sleep(settle)
            }
            present()
        }
        return true
    }

    /// The auto-presenter's way in: `present` runs only onto a bare shell. Unlike `run` it never closes, collapses or
    /// force-dismisses anything, because a sheet below may hold unsaved input (a manual workout, a journal edit): with a
    /// modal up, or a collapse under way, it does nothing and returns false, and the resume bar stays the way back. Only a
    /// person's request (the resume bar, a Live Activity tap, a deep link, Start) goes through `run`.
    @discardableResult
    static func presentIfNothingIsUp(
        isModalPresented: @MainActor () -> Bool = { ModalPresentationProbe.isAnyModalPresented },
        then present: () -> Void
    ) -> Bool {
        guard !isCollapsing, !isModalPresented() else { return false }
        present()
        return true
    }
}

// MARK: - Presenters follow the collapse

private struct CollapsesForWorkoutJourney: ViewModifier {
    @EnvironmentObject private var router: NavRouter
    let collapse: () -> Void

    func body(content: Content) -> some View {
        content.onReceive(router.$modalCollapseGeneration.dropFirst()) { _ in collapse() }
    }
}

extension View {
    /// Closes this view's sheet or cover when the shell asks every presenter to let go, so the workout journey can present
    /// at the root. Apply it to each `.sheet` / `.fullScreenCover` that can be open while a workout is started or
    /// resumed (from Quick Actions, a Live Activity, or a deep link).
    func collapsesForWorkoutJourney(_ isPresented: Binding<Bool>) -> some View {
        modifier(CollapsesForWorkoutJourney { if isPresented.wrappedValue { isPresented.wrappedValue = false } })
    }

    func collapsesForWorkoutJourney<Item>(_ item: Binding<Item?>) -> some View {
        modifier(CollapsesForWorkoutJourney { if item.wrappedValue != nil { item.wrappedValue = nil } })
    }

    /// The same for a screen that presents several things: `close` closes all of them.
    func collapsesForWorkoutJourney(close: @escaping () -> Void) -> some View {
        modifier(CollapsesForWorkoutJourney(collapse: close))
    }
}
#endif
