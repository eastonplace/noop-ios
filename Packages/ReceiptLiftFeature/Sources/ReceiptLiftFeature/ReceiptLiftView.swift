import StrandDesign
import SwiftUI

/// NOOP's embedded Lift feature. The host owns source identity and durable storage.
public struct ReceiptLiftView: View {
    @ObservedObject private var coordinator: ReceiptLiftCoordinator
    @Environment(\.scenePhase) private var scenePhase

    private let destination: LiftDestination
    private let host: LiftHostChrome
    private let weightUnit: LiftWeightUnit

    /// `onBack` and `onClose` let the host place its own back/close actions in Lift's page headers, so the
    /// feature reads as one screen inside the host's sheet rather than a second header stacked under a bar.
    /// `weightUnit` is the person's unit setting: Lift stores pounds and draws, and steps by, this unit.
    public init(
        coordinator: ReceiptLiftCoordinator,
        destination: LiftDestination = .start,
        weightUnit: LiftWeightUnit = .pounds,
        onBack: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.destination = destination
        self.weightUnit = weightUnit
        self.coordinator = coordinator
        self.host = LiftHostChrome(onBack: onBack, onClose: onClose)
    }

    public var body: some View {
        Group {
            if coordinator.store.isLoaded { LiftRootView(destination: destination) }
            else if let error = coordinator.saveError {
                LiftPage(title: "Lift") {
                    LiftMessage(
                        symbol: "dumbbell",
                        title: "Couldn’t open Lift",
                        message: LocalizedStringKey(error),
                        actionTitle: "Try again"
                    ) { Task { await coordinator.load() } }
                }
            } else {
                LiftPage(title: "Lift") {
                    LiftMessage(isLoading: true, title: "Opening your workout log…")
                }
            }
        }
            .environment(\.liftHostChrome, host)
            .environment(\.liftWeightUnit, weightUnit)
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
                        ChoiceChipButton(title: "Retry save") { coordinator.store.flushPendingSave() }
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
