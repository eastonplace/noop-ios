import SwiftUI
import StrandDesign
import ReceiptLiftFeature

struct LiftLogView: View {
    var destination: LiftDestination = .start
    var onBack: (() -> Void)? = nil
    @EnvironmentObject private var lift: NoopReceiptLiftIntegration
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    /// Lift stores pounds; the unit setting only changes how loads are drawn and stepped.
    private var weightUnit: LiftWeightUnit {
        (UnitSystem(rawValue: unitSystemRaw) ?? .metric) == .imperial ? .pounds : .kilograms
    }

    var body: some View {
        content
            .overlay(alignment: .bottom) {
                if lift.owner != repo.deviceId, lift.coordinator?.hasActiveSession == true {
                    InlineAlertRow("This workout stays with its original source.", style: .info)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }
            }
            .task { await lift.selectCurrentSource() }
            .tracksWorkoutSurface()
    }

    /// Lift's own pages carry the sheet's back/close in their header (the shared `NoopScreenHeader`), so the
    /// host no longer stacks a second bar above them. Until the coordinator exists the host draws the same
    /// header itself around the loading or error state.
    @ViewBuilder private var content: some View {
        if let coordinator = lift.coordinator {
            ReceiptLiftView(
                coordinator: coordinator,
                destination: destination,
                weightUnit: weightUnit,
                onBack: onBack,
                onClose: { dismiss() }
            )
        } else {
            ScreenScaffold(
                title: "Lift",
                backAction: onBack,
                trailing: { NoopIconButton("xmark", accessibilityLabel: "Close") { dismiss() } }
            ) {
                if let error = lift.error {
                    LiftHostState(
                        symbol: "dumbbell",
                        title: "Lift is unavailable",
                        message: error,
                        actionTitle: "Try again"
                    ) { Task { await lift.selectCurrentSource() } }
                } else {
                    LiftHostState(title: "Opening your workout log…")
                }
            }
            .sheetScreenScaffoldEnvironment()
        }
    }
}

/// Loading / error state shown by the host before Lift's coordinator exists.
private struct LiftHostState: View {
    var symbol: String? = nil
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            } else {
                ProgressView().tint(StrandPalette.textSecondary)
            }
            Text(title)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                NoopButton(LocalizedStringKey(actionTitle), kind: .secondary, action: action)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
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
                    Text("Resume Lift").font(StrandFont.headline)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(16)
                .foregroundStyle(StrandPalette.textPrimary)
                .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous).strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
            }.buttonStyle(.plain)
        }
    }
}
