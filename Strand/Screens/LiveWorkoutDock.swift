#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - The dock
//
// Pause takes one tap. End is only offered while paused, and it is a hold, not a tap: a thumb that meant Pause cannot finish a
// run. Discard is always there beneath it, and a save that failed says so and offers Try again. Everything is a calm circle or
// a quiet capsule: Resume (or Start) is the one solid-mint control, and nothing is louder than the data above it.

/// What sits under the page: Pause (running), Hold to End and Resume with Discard under them (paused), "Saving…", or the panel
/// for a save that failed or had nothing to save. The running and paused docks are the same height, so the controls do not move
/// when the workout pauses.
struct WorkoutLiveDock: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The accessibility path to End: VoiceOver and Switch Control cannot hold, so the hold button's action opens this.
    @State private var confirmingEnd = false
    @State private var confirmingDiscard = false
    /// The Discard line's height: a touch target, and the room the running dock keeps free so it matches the paused one. It
    /// grows with the text but stops at a size the accessibility sizes' two lines of capped text fit in.
    @ScaledMetric(relativeTo: .body) private var scaledDiscardHeight: CGFloat = 44
    private var discardHeight: CGFloat { min(scaledDiscardHeight, 64) }

    /// QA only: draws the Hold to End ring filled to this share, with no gesture (`--demo-hold-progress 0.55`).
    private var previewHoldProgress: Double? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--demo-hold-progress"), arguments.indices.contains(flag + 1) else { return nil }
        return Double(arguments[flag + 1])
        #else
        return nil
        #endif
    }

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
                // reaches it; above them it may, and then its controls scroll rather than push the page out of view.
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
        VStack(spacing: NoopMetrics.space3) {
            LiveCircleButton(title: String(localized: "Pause"), systemImage: "pause.fill",
                             accessibilityLabel: String(localized: "Pause workout")) {
                StrandHaptic.commit.play()
                model.setWorkoutPaused(true)
            }
            // Where Discard Workout sits once paused, so Pause and Resume are the same distance from the page.
            Color.clear.frame(height: discardHeight)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Paused

    private var paused: some View {
        VStack(spacing: NoopMetrics.space3) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(HStackLayout(spacing: 20))
                : AnyLayout(HStackLayout(spacing: 38))
            layout {
                LiveHoldCircleButton(
                    title: String(localized: "Hold to End"),
                    completedTitle: String(localized: "Ending"),
                    tapHint: String(localized: "Keep holding"),
                    previewProgress: previewHoldProgress,
                    accessibilityConfirm: { confirmingEnd = true },
                    action: endNow)
                // The hold's "confirmed" flag is sticky: a new identity re-arms it when the finish comes back to End.
                .id(model.finishAttemptID)
                LiveCircleButton(title: String(localized: "Resume"), systemImage: "play.fill", solid: true,
                                 accessibilityLabel: String(localized: "Resume workout")) {
                    StrandHaptic.commit.play()
                    model.setWorkoutPaused(false)
                }
            }
            .frame(maxWidth: .infinity)
            Button { confirmingDiscard = true } label: {
                Text("Discard Workout")
                    .foregroundStyle(LivePalette.quietAction)
                    .liveText(17, weight: .medium, maxSize: 22, lines: 2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: discardHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Saving

    /// A quiet spinner and "Saving…" where the controls were, as tall as they were so nothing around it moves.
    private var saving: some View {
        HStack(spacing: NoopMetrics.space3) {
            ProgressView().tint(LivePalette.secondaryText)
            Text("Saving…")
                .foregroundStyle(LivePalette.secondaryText)
                .liveText(17, weight: .medium, maxSize: 22, lines: 2)
        }
        .frame(maxWidth: .infinity, minHeight: LiveCircleMetrics.diameter(accessibilitySize: typeSize.isAccessibilitySize) + 12 + 11 + 20 + discardHeight + NoopMetrics.space3)
        .accessibilityElement(children: .ignore)
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

/// The dock when End did not end the workout: the save failed (Try again; the workout is still on the phone), or there was
/// nothing in it to save (Keep recording). A short message, then two quiet capsules.
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
        VStack(spacing: NoopMetrics.space3) {
            // The message scrolls (with its indicator showing) if the panel is taller than the room the screen gives the
            // dock, so a sentence is never cut off and the capsules stay in view. It is as tall as its text otherwise.
            FittingScroll { messages.frame(maxWidth: .infinity) }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: NoopMetrics.space2))
                : AnyLayout(HStackLayout(spacing: NoopMetrics.space3))
            layout {
                LiveCapsuleButton(kind == .nothingToSave ? String(localized: "Keep recording") : String(localized: "Try again"),
                                  action: onPrimary)
                LiveCapsuleButton(String(localized: "Discard"), isGrey: true, action: onDiscard)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// What happened and what is safe.
    @ViewBuilder private var messages: some View {
        VStack(spacing: NoopMetrics.space2) {
            switch kind {
            case .failed(let message):
                Text("Couldn't save")
                    .foregroundStyle(LivePalette.amber)
                    .liveText(19, weight: .semibold, maxSize: 26, lines: 2)
                    .accessibilityAddTraits(.isHeader)
                if !message.isEmpty {
                    Text(verbatim: message)
                        .foregroundStyle(LivePalette.quietAction)
                        .liveText(15, weight: .regular, maxSize: 21, lines: 8)
                }
                Text("Your workout is still on this phone.")
                    .foregroundStyle(LivePalette.secondaryText)
                    .liveText(14, weight: .regular, maxSize: 20, lines: 4)
            case .nothingToSave:
                Text("Nothing to save yet")
                    .foregroundStyle(StrandPalette.textPrimary)
                    .liveText(19, weight: .semibold, maxSize: 26, lines: 2)
                    .accessibilityAddTraits(.isHeader)
                Text("NOOP needs heart rate or a GPS route to save a workout.")
                    .foregroundStyle(LivePalette.quietAction)
                    .liveText(15, weight: .regular, maxSize: 21, lines: 6)
            }
        }
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
