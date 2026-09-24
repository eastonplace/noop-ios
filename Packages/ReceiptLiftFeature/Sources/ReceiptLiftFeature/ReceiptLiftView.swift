import SwiftUI

/// NOOP's embedded Lift feature. The host owns source identity and durable storage.
public struct ReceiptLiftView: View {
    @ObservedObject private var coordinator: ReceiptLiftCoordinator
    @Environment(\.scenePhase) private var scenePhase

    public init(coordinator: ReceiptLiftCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        Group {
            if coordinator.store.isLoaded { LiftRootView() }
            else if let error = coordinator.saveError {
                ContentUnavailableView {
                    Label("Couldn’t open Lift", systemImage: "dumbbell")
                } description: { Text(error) } actions: {
                    Button("Try again") { Task { await coordinator.load() } }
                }
            } else { ProgressView("Opening your workout log…") }
        }
            .environmentObject(coordinator.store)
            .preferredColorScheme(.dark)
            .safeAreaInset(edge: .bottom) {
                if let error = coordinator.saveError {
                    VStack(spacing: 8) {
                        Text("Not saved yet: \(error)").font(.caption)
                        Button("Retry save") { coordinator.store.flushPendingSave() }
                    }.padding(12).background(LiftTheme.paper)
                }
            }
            .task { await coordinator.load() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { coordinator.store.applicationDidEnterBackground() }
            }
    }
}
