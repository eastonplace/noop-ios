#if os(iOS)
import SwiftUI
import StrandDesign

/// The label is event-driven. Only this small ornament animates; it never invents task stages or progress percentages.
/// Flat like the rest of the transcript (no box): the ornament leads, the stage reads as a row under the Coach eyebrow,
/// and Stop is the same chip family as the answer actions.
struct CoachProgressView: View {
    let stage: CoachResponseStage
    var onStop: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            ornament.frame(width: 22, height: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(stage.title))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .contentTransition(.opacity)
                if !stage.detail.isEmpty {
                    Text(LocalizedStringKey(stage.detail)).font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: stage)
            if stage.isActive, let onStop {
                Button(action: onStop) {
                    WidgetChip(appTitle: "Stop", systemImage: "stop.fill", showsChevron: false, overhangs: false)
                        .chipHitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop response")
                .accessibilityIdentifier("coach.progress.stop")
            }
        }
        .frame(minHeight: 44)
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
            Image(systemName: finishedSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(finishedTint)
                .frame(width: 22, height: 22)
                .background(Circle().fill(finishedTint.opacity(0.14)))
        }
    }

    /// Finished stages keep their meaning: done is the Coach accent, a failure is a warning, a stop is neutral.
    private var finishedSymbol: String {
        switch stage {
        case .complete: "checkmark"
        case .failed: "exclamationmark"
        default: "pause.fill"
        }
    }

    private var finishedTint: Color {
        switch stage {
        case .complete: StrandPalette.accent
        case .failed: StrandPalette.statusWarning
        default: StrandPalette.textSecondary
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
            VStack(alignment: .leading, spacing: 0) {
                LocalCoachFixtureLabel().padding(.bottom, NoopMetrics.space3)
                Text("Response states").font(StrandFont.title1)
                Text("Synthetic component review. Enable Reduce Motion to compare the still treatment.")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .padding(.top, NoopMetrics.space2)
                ForEach(Array(stages.enumerated()), id: \.offset) { index, stage in
                    FlatSectionSeparator.coach
                    // The first stage shows the Stop chip, as a live answer does.
                    CoachProgressView(stage: stage, onStop: index == 0 ? {} : nil)
                        .accessibilityIdentifier("coach.progressFixture.\(index)")
                }
            }
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.top, NoopMetrics.space5)
            .padding(.bottom, CoachRhythm.pageBottom)
        }
        .background(StrandPalette.appCanvas)
    }
}
#endif
#endif
