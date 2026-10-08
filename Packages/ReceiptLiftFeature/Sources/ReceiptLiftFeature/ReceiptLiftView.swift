import StrandDesign
import SwiftUI

/// NOOP's embedded Lift feature. The host owns source identity and durable storage.
public struct ReceiptLiftView: View {
    @ObservedObject private var coordinator: ReceiptLiftCoordinator
    @Environment(\.scenePhase) private var scenePhase

    private let destination: LiftDestination
    private let host: LiftHostChrome

    /// `onBack` and `onClose` let the host place its own back/close actions in Lift's page headers, so the
    /// feature reads as one screen inside the host's sheet rather than a second header stacked under a bar.
    public init(
        coordinator: ReceiptLiftCoordinator,
        destination: LiftDestination = .start,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.destination = destination
        self.coordinator = coordinator
        self.host = LiftHostChrome(onBack: onBack, onClose: onClose)
    }

    public var body: some View {
        Group {
            if coordinator.store.isLoaded { LiftRootView(destination: destination) }
            else if let error = coordinator.saveError {
                LiftScreen(
                    title: "Lift",
                    backAction: host.onBack,
                    trailing: { LiftHeaderTrailing() }
                ) {
                    LiftStateMessage(
                        symbol: "dumbbell",
                        title: "Couldn’t open Lift",
                        message: error,
                        actionTitle: "Try again"
                    ) { Task { await coordinator.load() } }
                }
            } else {
                LiftScreen(
                    title: "Lift",
                    backAction: host.onBack,
                    trailing: { LiftHeaderTrailing() }
                ) {
                    LiftStateMessage(isLoading: true, title: "Opening your workout log…")
                }
            }
        }
            .environment(\.liftHostChrome, host)
            .environmentObject(coordinator.store)
            .contentSurfacePresentation(.flat)
            .preferredColorScheme(.dark)
            .safeAreaInset(edge: .bottom) {
                if coordinator.store.isLoaded, let error = coordinator.saveError {
                    HStack(spacing: 12) {
                        Text("Not saved yet: \(error)")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ChipButton("Retry save") { coordinator.store.flushPendingSave() }
                    }
                    .liftFooterBar()
                }
            }
            .task { await coordinator.load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { coordinator.applicationDidEnterBackground() }
            }
    }
}
