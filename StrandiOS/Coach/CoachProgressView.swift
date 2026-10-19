#if os(iOS)
import SwiftUI
import StrandDesign

/// The label is event-driven; it never invents task stages or progress percentages. While Coach works it is one
/// shimmering secondary line in the answer's own text slot ("Reading sleep history…"), static under Reduce Motion.
/// A finished stage keeps its meaning as a small glyph and the stage's own words. Stop is a quiet text button; the
/// composer's send button stops the reply too.
struct CoachProgressView: View {
    let stage: CoachResponseStage
    var onStop: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            Group {
                if stage.isActive {
                    CoachShimmerText(text: Text(verbatim: activeLine))
                } else {
                    finished
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(LocalizedStringKey(spokenText)))
            if stage.isActive, let onStop {
                Button(action: onStop) {
                    Text("Stop").coachFont(14, .medium, relativeTo: .subheadline)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Stop response")
                .accessibilityIdentifier("coach.progress.stop")
            }
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coach.responseProgress")
    }

    /// "Reading sleep history…": the stage's words with an ellipsis while it is under way. A phase that has just
    /// finished ("Record check complete") keeps its own full stop of meaning and gets none.
    private var activeLine: String {
        let title = String(localized: String.LocalizationValue(stage.title))
        if case .evidenceReady = stage { return title }
        return title + "…"
    }

    /// What VoiceOver hears: the stage and what it is doing, the one line the eye reads plus its detail.
    private var spokenText: String { stage.detail.isEmpty ? stage.title : stage.title + ". " + stage.detail }

    private var finished: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: finishedSymbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(finishedTint)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(stage.title)).coachFont(16.5, .medium)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !stage.detail.isEmpty {
                Text(LocalizedStringKey(stage.detail)).coachFont(13, .regular, relativeTo: .footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                    // The first stage shows the Stop button, as a live answer does.
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
