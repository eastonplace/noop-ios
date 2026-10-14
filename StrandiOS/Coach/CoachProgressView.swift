#if os(iOS)
import SwiftUI
import StrandDesign

/// The label is event-driven. Only this small ornament animates; it never invents task stages or progress percentages.
struct CoachProgressView: View {
    let stage: CoachResponseStage
    var onStop: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            ornament.frame(width: 22, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(stage.title))
                    .font(StrandFont.footnote.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                if !stage.detail.isEmpty {
                    Text(LocalizedStringKey(stage.detail)).font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if stage.isActive, let onStop {
                Button(action: onStop) {
                    Image(systemName: "stop.fill").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Stop response")
            }
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 8)
        .background(StrandPalette.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1).fill(StrandPalette.accent.opacity(0.55))
                .frame(width: 2).padding(.vertical, 12).accessibilityHidden(true)
        }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.responseProgress")
    }

    @ViewBuilder private var ornament: some View {
        if stage.isActive {
            if reduceMotion || scenePhase != .active || !visible {
                bars(time: 0, still: true)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { clock in
                    bars(time: clock.date.timeIntervalSinceReferenceDate, still: false)
                }
            }
        } else {
            Image(systemName: stage == .complete ? "checkmark" : stage == .failed ? "exclamationmark" : "pause")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func bars(time: Double, still: Bool) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { index in
                let phase = still ? 0.45 : (sin(time * 2 * .pi / 1.05 - Double(index) * 0.72) + 1) / 2
                Capsule().fill(StrandPalette.accent.opacity(0.42 + phase * 0.5))
                    .frame(width: 3, height: 5 + phase * 11)
            }
        }
        .frame(width: 22, height: 22)
    }
}

#if DEBUG
/// Uses the real component and explicit fixture labels. No real generation or personal records are involved.
struct CoachProgressGallery: View {
    private let stages: [CoachResponseStage] = [.preparing, .checkingAccess,
        .reading(tool: "workout_history", days: 7), .evidenceReady, .writing, .complete, .stopped, .failed]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LocalCoachFixtureLabel()
                Text("Response states").font(StrandFont.title1)
                Text("Synthetic component review. Enable Reduce Motion to compare the still treatment.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    CoachProgressView(stage: stage).accessibilityIdentifier("coach.progressFixture.\(index)")
                }
            }.padding(20)
        }
        .background(StrandPalette.appCanvas)
    }
}
#endif
#endif
