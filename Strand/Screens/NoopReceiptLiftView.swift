import SwiftUI
import StrandDesign
import ReceiptLiftFeature

struct LiftLogView: View {
    var destination: LiftDestination = .start
    var onBack: (() -> Void)? = nil
    @EnvironmentObject private var lift: NoopReceiptLiftIntegration
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let onBack {
                    Button("Back", systemImage: "chevron.left", action: onBack)
                        .font(.subheadline)
                } else {
                    Text("NOOP / WORKOUTS").font(.caption.weight(.semibold)).tracking(1)
                }
                Spacer()
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly).frame(width: 44, height: 44)
            }
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 20).background(StrandPalette.appCanvas)
            content
        }
        .overlay(alignment: .bottom) {
            if lift.owner != repo.deviceId, lift.coordinator?.hasActiveSession == true {
                Text("This workout stays with its original source.")
                    .font(.caption).padding(12).background(StrandPalette.card, in: Capsule())
                    .padding(.bottom, 16)
            }
        }
        .task { await lift.selectCurrentSource() }
        .tracksWorkoutSurface()
    }

    @ViewBuilder private var content: some View {
        if let coordinator = lift.coordinator {
            ReceiptLiftView(coordinator: coordinator, destination: destination)
        } else if let error = lift.error {
            ContentUnavailableView {
                Label("Lift is unavailable", systemImage: "dumbbell")
            } description: { Text(error) } actions: {
                Button("Try again") { Task { await lift.selectCurrentSource() } }
            }
        } else { ProgressView("Opening your workout log…").frame(maxHeight: .infinity) }
    }
}

/// The shell's "Resume Lift" prompt. The sheet it opens is owned by the shell (`RootTabView`), not by this
/// card: the card only exists while a session is active, so state held here was thrown away whenever the card
/// left the tree, and the shell could not present the same sheet on its own after a relaunch.
struct LiftResumeCard: View {
    @EnvironmentObject private var lift: NoopReceiptLiftIntegration
    let onResume: () -> Void
    var body: some View {
        if lift.coordinator?.hasActiveSession == true {
            Button(action: onResume) {
                HStack(spacing: 12) {
                    Image(systemName: "dumbbell.fill").foregroundStyle(StrandPalette.accent)
                    Text("Resume Lift").font(.headline)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                }.padding(16).foregroundStyle(StrandPalette.textPrimary)
                    .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 14))
            }.buttonStyle(.plain)
        }
    }
}
