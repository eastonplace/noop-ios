#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - The dock
//
// Pause takes one tap. End is only offered while paused, and it is a hold, not a tap: a thumb that meant Pause cannot
// finish a run. Discard is always there beside it, and a save that failed says so and offers Try again.

/// What sits under the page: Pause (running), Resume and Hold to end with what would be saved and Discard (paused),
/// "Saving…", or the panel for a save that failed or had nothing to save.
struct WorkoutLiveDock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The accessibility path to End: VoiceOver and Switch Control cannot hold, so the hold button's action opens this.
    @State private var confirmingEnd = false
    @State private var confirmingDiscard = false

    var body: some View {
        VStack(spacing: NoopMetrics.space3) {
            if model.workoutFinishState == .saving {
                saving
            } else if model.isWorkoutFinishPending {
                WorkoutFinishPanel(kind: .failed(failureText), onPrimary: endNow,
                                   onDiscard: { confirmingDiscard = true })
            } else if model.finishNeedsMoreEvidence {
                WorkoutFinishPanel(kind: .nothingToSave, onPrimary: keepRecording,
                                   onDiscard: { confirmingDiscard = true })
            } else if workout.isPaused {
                // The screen caps the dock at a share of its height. Short of the accessibility sizes the paused dock never
                // reaches it; above them it may, and then its buttons scroll rather than push the page out of view.
                if typeSize.isAccessibilitySize {
                    FittingScroll { paused }
                } else {
                    paused
                }
            } else {
                running
            }
        }
        // Alerts, not action sheets: on iOS 26 a confirmation dialog from a button is a small popover with no visible Cancel,
        // and at accessibility sizes its title and message are cut off. An alert scrolls, wraps and always shows both choices.
        .alert("End this workout?", isPresented: $confirmingEnd) {
            Button("End and save", role: .destructive) { endNow() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("It is saved to your Workouts. A finished workout can't be resumed.")
        }
        .alert("Discard this workout?", isPresented: $confirmingDiscard) {
            Button("Discard workout", role: .destructive) {
                StrandHaptic.commit.play()
                model.discardWorkout()
            }
            Button("Keep workout", role: .cancel) {}
        } message: {
            Text("Nothing will be saved. This can't be undone.")
        }
        // A save that failed, or had nothing in it, is a warning the hand should feel as the panel arrives.
        .onChange(of: model.workoutFinishState) { _, state in
            if case .failed = state { StrandHaptic.warning.play() }
        }
        .animation(.easeInOut(duration: 0.2), value: model.workoutFinishState)
    }

    private var failureText: String {
        if case .failed(let message) = model.workoutFinishState { return message }
        return ""
    }

    private func endNow() {
        Task { _ = await model.endWorkout() }
    }

    /// Nothing to save: the workout carries on. End was held while paused, so it goes back to running.
    private func keepRecording() {
        model.acknowledgeFinishState()
        model.setWorkoutPaused(false)
    }

    // MARK: Running

    private var running: some View {
        Button {
            StrandHaptic.commit.play()
            model.setWorkoutPaused(true)
        } label: {
            Label("Pause", systemImage: "pause.fill")
        }
        .buttonStyle(GlanceActionButtonStyle(.primary))
        .accessibilityLabel("Pause workout")
    }

    // MARK: Paused

    private var paused: some View {
        VStack(spacing: NoopMetrics.space3) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: NoopMetrics.space3))
                : AnyLayout(HStackLayout(spacing: NoopMetrics.space3))
            layout {
                Button {
                    StrandHaptic.commit.play()
                    model.setWorkoutPaused(false)
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(GlanceActionButtonStyle(.primary))
                .accessibilityLabel("Resume workout")

                HoldToConfirmButton(
                    title: String(localized: "Hold to end"),
                    completedTitle: String(localized: "Ending"),
                    style: .glanceEnd,
                    tapHint: String(localized: "Keep holding"),
                    accessibilityConfirm: { confirmingEnd = true },
                    action: endNow)
                // The hold's "confirmed" flag is sticky: a new identity re-arms it when the finish comes back to End.
                .id(model.finishAttemptID)
            }
            preview
            Button { confirmingDiscard = true } label: {
                Text("Discard workout")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .modifier(DockLabelFit())
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// What End would save, so the hold is never a leap of faith. The same gate `endWorkout()` applies.
    @ViewBuilder private var preview: some View {
        if model.workoutWouldSave {
            Text(verbatim: previewText)
                .foregroundStyle(StrandPalette.textSecondary)
                .modifier(DockCaption())
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else {
            Text("Nothing to save yet · no heart rate or route")
                .foregroundStyle(StrandPalette.statusWarning)
                .modifier(DockCaption())
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var previewText: String {
        var parts = [String(localized: "Saves \(LiveWorkoutTiles.elapsedText(workout.activeElapsed()))")]
        if model.activeWorkoutIsGps, recorder.hasDrawableRoute, recorder.distanceM > 0 {
            // The same text as the page's distance and the resume bar (locale decimal separator, the chosen unit).
            let imperial = unitSystemRaw == UnitSystem.imperial.rawValue
            let distance = LiveWorkoutTiles.distanceText(meters: recorder.distanceM, imperial: imperial)
            parts.append("\(distance) \(imperial ? "mi" : "km")")
        }
        switch workout.liveStrainState {
        case .scored(let stored): parts.append(String(localized: "strain \(StrainScale.formatted(stored))"))
        case .building: parts.append(String(localized: "strain not scored yet"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Saving

    private var saving: some View {
        Button {} label: {
            HStack(spacing: NoopMetrics.space3) {
                ProgressView().tint(StrandPalette.textTertiary)
                Text("Saving…")
            }
        }
        .buttonStyle(GlanceActionButtonStyle(.primary))
        .disabled(true)
        .accessibilityLabel("Saving…")
    }
}

/// A vertical scroll view that is exactly as tall as its content while the content fits, and scrolls (no more than the room
/// it is given) when it does not. While it fits, scrolling is off, so a hold or a tap inside it is never taken for a drag.
private struct FittingScroll<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Visible while there is more below, so a half-shown line reads as "scroll", not as cut off.
        .scrollIndicators(.visible)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
        .scrollDisabled(contentHeight <= viewportHeight + 0.5)
    }
}

/// The dock's small print: the caption role, and at the accessibility sizes a fixed, scaled size that wraps to three lines
/// and then shrinks instead of hyphenating a word or growing the dock past the screen.
private struct DockCaption: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.captionLabelFit(lines: 3)
        } else {
            content.font(StrandFont.caption)
        }
    }
}

/// A paragraph of the finish panel: its own text role below the accessibility sizes (exactly as it was); at the accessibility
/// sizes a fixed, scaled size that wraps and then shrinks, so a long word is never hyphenated ("Versu-che") or cut off.
private struct PanelText: ViewModifier {
    enum Role { case footnote, caption }
    let role: Role
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.captionLabelFit(lines: 5, weight: .regular).fixedSize(horizontal: false, vertical: true)
        } else {
            content.font(role == .footnote ? StrandFont.footnote : StrandFont.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A one-line dock label that, at the accessibility sizes, wraps once and then scales rather than growing the dock.
private struct DockLabelFit: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize {
            content.lineLimit(2).minimumScaleFactor(0.7)
        } else {
            content
        }
    }
}

/// The dock when End did not end the workout: the save failed (Try again; the workout is still on the phone), or there was
/// nothing in it to save (Keep recording).
struct WorkoutFinishPanel: View {
    enum Kind: Equatable {
        case failed(String)
        case nothingToSave
    }

    let kind: Kind
    /// Try again (failed) or Keep recording (nothing to save).
    let onPrimary: () -> Void
    let onDiscard: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            // The text above the buttons scrolls if the panel is taller than the room the screen gives the dock, so the
            // buttons stay in view. It is as tall as its text otherwise.
            FittingScroll { messages.frame(maxWidth: .infinity, alignment: .leading) }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: NoopMetrics.space2))
                : AnyLayout(HStackLayout(spacing: NoopMetrics.space3))
            layout {
                // Two lines, then smaller: a long translation wraps at its spaces and a long single word shrinks; neither
                // is cut off with an ellipsis.
                Button(action: onPrimary) {
                    Text(kind == .nothingToSave ? "Keep recording" : "Try again")
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                Button(action: onDiscard) {
                    Text("Discard")
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }
        }
        .widgetCardSurface(tint: .neutral)
        .accessibilityElement(children: .contain)
    }

    /// What happened and what is safe: the pill or headline and the sentences under it.
    @ViewBuilder private var messages: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            switch kind {
            case .failed(let message):
                StatePill("Couldn't save", tone: .warning)
                if !message.isEmpty {
                    Text(verbatim: message)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .modifier(PanelText(role: .footnote))
                }
                Text("Your workout is still on this phone.")
                    .foregroundStyle(StrandPalette.textTertiary)
                    .modifier(PanelText(role: .caption))
            case .nothingToSave:
                Text("Nothing to save yet")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .modifier(DockLabelFit())
                    .accessibilityAddTraits(.isHeader)
                Text("NOOP needs heart rate or a GPS route to save a workout.")
                    .foregroundStyle(StrandPalette.textSecondary)
                    .modifier(PanelText(role: .footnote))
            }
        }
    }
}
#endif
