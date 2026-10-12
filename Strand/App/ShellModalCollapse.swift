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

    /// Calls `present` once nothing is presented. With nothing up it is called at once, synchronously.
    ///
    /// - Parameters:
    ///   - clearShellState: closes the shell's own sheets (and bumps the router's collapse generation).
    ///   - isModalPresented / forceDismiss / sleep: the system seams, replaceable in tests.
    static func run(
        clearShellState: () -> Void,
        isModalPresented: @escaping @MainActor () -> Bool = { ModalPresentationProbe.isAnyModalPresented },
        forceDismiss: @escaping @MainActor () -> Void = { ModalPresentationProbe.dismissAll() },
        sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        then present: @escaping @MainActor () -> Void
    ) {
        guard isModalPresented() else {
            present()
            return
        }
        clearShellState()
        Task { @MainActor in
            var waited: Duration = .zero
            while isModalPresented(), waited < patience {
                await sleep(pollInterval)
                waited += pollInterval
            }
            if isModalPresented() {
                forceDismiss()
                await sleep(settle)
            }
            present()
        }
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
