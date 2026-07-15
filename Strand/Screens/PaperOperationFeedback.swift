import SwiftUI
import StrandDesign

/// Screen-local operation grammar adopted from the design-lab specimen. It owns no
/// work: callers continue to own idle/running/failure/retry state and pass the exact
/// backend message through unchanged.
struct PaperOperationPresentation: Equatable {
    enum Phase: Equatable {
        case running
        case failed
    }

    let title: String
    let message: String
    let phase: Phase

    var showsRetry: Bool { phase == .failed }
    var remainsVisibleUntilOwnerChangesState: Bool { phase == .failed }
}

struct PaperOperationFeedback: View {
    typealias Phase = PaperOperationPresentation.Phase

    let title: String
    let message: String
    let phase: Phase
    var actionTitle: LocalizedStringKey = "Retry"
    var retry: (() -> Void)?

    var body: some View {
        let presentation = PaperOperationPresentation(title: title, message: message, phase: phase)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(title)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                StatePill(
                    phase == .running ? "Running" : "Failed",
                    tone: phase == .running ? .accent : .critical,
                    pulsing: phase == .running
                )
            }

            if phase == .running {
                ProgressView()
                    .controlSize(.small)
                    .tint(StrandPalette.accent)
            }

            Text(message)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if presentation.showsRetry, let retry {
                NoopButton(actionTitle, systemImage: "arrow.clockwise", kind: .secondary) {
                    retry()
                }
            }
        }
        .padding(14)
        .background(
            StrandPalette.surfaceInset,
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    (phase == .failed ? StrandPalette.statusCritical : StrandPalette.accent).opacity(0.24),
                    lineWidth: 1
                )
        )
        .accessibilityElement(children: .contain)
    }
}
