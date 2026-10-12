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
                WorkoutFinishPanel(kind: .failed(failureText), onPrimary: endNow, onDiscard: { confirmingDiscard = true })
            } else if model.finishNeedsMoreEvidence {
                WorkoutFinishPanel(kind: .nothingToSave, onPrimary: keepRecording, onDiscard: { confirmingDiscard = true })
            } else if workout.isPaused {
                paused
            } else {
                running
            }
        }
        .confirmationDialog("End this workout?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End and save", role: .destructive) { endNow() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("It is saved to your Workouts. A finished workout can't be resumed.")
        }
        .confirmationDialog("Discard this workout?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
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
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        } else {
            Text("Nothing to save yet · no heart rate or route")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusWarning)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var previewText: String {
        var parts = [String(localized: "Saves \(LiveWorkoutTiles.elapsedText(workout.activeElapsed()))")]
        if model.activeWorkoutIsGps, recorder.pointCount >= 2, recorder.distanceM > 0 {
            let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
            parts.append(UnitFormatter.distanceFromMeters(recorder.distanceM, system: system))
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
            switch kind {
            case .failed(let message):
                StatePill("Couldn't save", tone: .warning)
                if !message.isEmpty {
                    Text(verbatim: message)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Your workout is still on this phone.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            case .nothingToSave:
                Text("Nothing to save yet")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("NOOP needs heart rate or a GPS route to save a workout.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: NoopMetrics.space2))
                : AnyLayout(HStackLayout(spacing: NoopMetrics.space3))
            layout {
                Button(action: onPrimary) {
                    Text(kind == .nothingToSave ? "Keep recording" : "Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryPillButtonStyle())
                Button(action: onDiscard) {
                    Text("Discard").frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryPillButtonStyle())
            }
        }
        .widgetCardSurface(tint: .neutral)
        .accessibilityElement(children: .contain)
    }
}
#endif
