import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Live workout mode, in the widget language: a recording eyebrow, the elapsed time, tiles for what the sport measures,
/// the wearer's own heart-rate zones, strain so far, the route and the heart-rate trace, with Pause and End within
/// thumb reach underneath.
///
/// The environment wrapper receives AppModel's high-frequency notifications, but its expensive/static content is
/// Equatable and identity-stable. Only the dedicated leaves in `LiveWorkoutSections` observe AppModel and continue
/// updating for every available HR sample.
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void

    var body: some View {
        StableLiveWorkoutContent(model: model, workout: model.activeWorkout, onClose: onClose)
            .equatable()
            .overlay {
                WorkoutGoneObserver(model: model, onClose: onClose)
            }
            .tracksWorkoutSurface()
    }
}

private struct StableLiveWorkoutContent: View, @preconcurrency Equatable {
    let model: AppModel
    let workout: AppModel.ActiveWorkout?
    /// Hides the workout surface; the recording keeps running. Not part of equality: it only flips
    /// presentation state in the host, so a fresh closure from a host re-render must not rebuild the content.
    let onClose: () -> Void
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false
    @Environment(\.dynamicTypeSize) private var typeSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.workout === rhs.workout
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WidgetMetrics.sectionSpacing) {
                if let workout {
                    LiveWorkoutHeader(workout: workout, onClose: onClose)
                    VStack(alignment: .leading, spacing: 0) {
                        LiveWorkoutHero(workout: workout)
                        LiveWorkoutSignalNotices(workout: workout, recorder: model.gpsRecorder)
                        LiveWorkoutMessages(model: model)
                    }
                    // The accessibility sizes are too tall to pin the controls under the content, so they sit right
                    // under the timer instead, where they are reachable without scrolling.
                    if typeSize.isAccessibilitySize {
                        LiveWorkoutControls(model: model, workout: workout)
                    }
                    LiveWorkoutTileGrid(workout: workout, recorder: model.gpsRecorder)
                    LiveWorkoutZoneSection(workout: workout, profile: model.profile, recorder: model.gpsRecorder)
                    LiveWorkoutStrainSection(workout: workout)
                    LiveWorkoutRouteSection(recorder: model.gpsRecorder)
                    LiveWorkoutHeartSection(workout: workout, recorder: model.gpsRecorder)
                }
            }
            .screenPadding()
            .padding(.vertical, NoopMetrics.space4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let workout, !typeSize.isAccessibilitySize {
                LiveWorkoutControls(model: model, workout: workout)
                    .screenPadding()
                    .padding(.top, NoopMetrics.space3)
                    .padding(.bottom, NoopMetrics.space2)
                    .background(StrandPalette.appCanvas.ignoresSafeArea(edges: .bottom))
                    .overlay(alignment: .top) {
                        Rectangle().fill(StrandPalette.hairline).frame(height: 1).accessibilityHidden(true)
                    }
            }
        }
        .onAppear {
            model.startRealtimeHR()
            if keepScreenOn { ScreenIdle.keepAwake(true) }
        }
        .onDisappear {
            model.stopRealtimeHR()
            ScreenIdle.keepAwake(false)
        }
    }
}

// MARK: - Header

/// The recording eyebrow with its pulse, and the screen's single close control (modals carry no system navigation bar).
/// When the workout is paused the eyebrow says so, as the Live Activity's does: a yellow pause glyph that does not pulse
/// and "Paused". The recording is still open, but nothing is being counted. Once End has been tried it says "Ending", as
/// the Live Activity's pill does: the clock has stopped at the end the save will use, whether the save is running or failed
/// and is waiting for a retry.
private struct LiveWorkoutHeader: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    let onClose: () -> Void

    var body: some View {
        let paused = workout.isPaused
        let ending = workout.isEnding
        let title: LocalizedStringKey = ending ? "Ending" : (paused ? "Paused" : "Recording")
        HStack(spacing: NoopMetrics.space2) {
            EyebrowPulseIcon(systemName: paused ? "pause.fill" : "waveform.path.ecg",
                             color: paused ? StrandPalette.statusWarning : StrandPalette.liveRed,
                             pulses: !paused && !ending)
            Text(title)
                .strandOverlineFitted()
                .lineLimit(2)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NoopMetrics.space2)
            NoopIconButton("xmark", accessibilityLabel: "Close", action: onClose)
        }
        .frame(minHeight: 40)
    }
}

// MARK: - Controls

/// Pause or Resume as the one big primary action, and a deliberate End beside it: End asks first, so a thumb that meant
/// Pause cannot finish a run.
private struct LiveWorkoutControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var confirmingEnd = false

    var body: some View {
        let saving = model.workoutFinishState == .saving
        // A finish that was tried and failed leaves the workout frozen at the moment it ended: it can be ended again, and
        // a Pause that silently did nothing would only look broken.
        let finishing = saving || model.isWorkoutFinishPending
        let paused = workout.isPaused
        let pauseTitle: LocalizedStringKey = paused ? "Resume" : "Pause"
        let pauseLabel: LocalizedStringKey = paused ? "Resume workout" : "Pause workout"
        let endTitle: LocalizedStringKey = saving ? "Saving…" : "End"
        let endLabel: LocalizedStringKey = saving ? "Saving…" : "End workout"
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: NoopMetrics.space3))
            : AnyLayout(HStackLayout(spacing: NoopMetrics.space3))
        layout {
            Button {
                model.setWorkoutPaused(!paused)
            } label: {
                Label(pauseTitle, systemImage: paused ? "play.fill" : "pause.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(LiveWorkoutPillStyle(kind: .primary))
            .disabled(finishing)
            .accessibilityLabel(pauseLabel)

            Button {
                confirmingEnd = true
            } label: {
                Label(endTitle, systemImage: saving ? "hourglass" : "stop.fill")
                    .frame(maxWidth: typeSize.isAccessibilitySize ? .infinity : nil)
            }
            .buttonStyle(LiveWorkoutPillStyle(kind: .end))
            .disabled(saving)
            // The saving state is in the label too: VoiceOver reads what is on screen, "Saving…", not a dimmed "End workout".
            .accessibilityLabel(endLabel)
        }
        .confirmationDialog("End this workout?", isPresented: $confirmingEnd, titleVisibility: .visible) {
            Button("End and save", role: .destructive) {
                Task { _ = await model.endWorkout() }
            }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("It is saved to your Workouts. A finished workout can't be resumed.")
        }
    }
}

/// The two pills under the content. Primary is Today's Start pill (brand ink, dark label) at the size of a control that
/// is pressed mid-stride; End is the same shape washed and outlined in the live red, so it reads as the other kind of
/// action without competing with Pause.
private struct LiveWorkoutPillStyle: ButtonStyle {
    enum Kind { case primary, end }
    let kind: Kind
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .headline) private var height: CGFloat = NoopMetrics.controlHeight

    func makeBody(configuration: Configuration) -> some View {
        let tint = kind == .end ? StrandPalette.liveRed : StrandPalette.ink
        configuration.label
            .font(StrandFont.headline)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .foregroundStyle(foreground)
            .padding(.horizontal, NoopMetrics.space5)
            .frame(minHeight: height)
            .background {
                switch kind {
                case .primary:
                    Capsule(style: .continuous).fill(isEnabled ? StrandPalette.ink : StrandPalette.chipFill)
                case .end:
                    Capsule(style: .continuous).fill(tint.opacity(0.12))
                }
            }
            .overlay {
                if kind == .end {
                    Capsule(style: .continuous).stroke(tint.opacity(isEnabled ? 0.5 : 0.2), lineWidth: 1.5)
                }
            }
            .contentShape(Capsule(style: .continuous))
            .opacity(isEnabled && configuration.isPressed ? 0.78 : 1)
    }

    private var foreground: Color {
        guard isEnabled else { return StrandPalette.textTertiary }
        return kind == .primary ? StrandPalette.onInk : StrandPalette.liveRed
    }
}

// MARK: - Close on end

private struct WorkoutGoneObserver: View {
    @ObservedObject var model: AppModel
    let onClose: () -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChangeCompat(of: model.activeWorkout == nil) { gone in
                if gone { onClose() }
            }
    }
}
