import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - The minimized workout
//
// Closing the workout screen does not stop the recording; the resume bar says so. It sits above the tab bar on every tab
// (Today included) for as long as a workout is in flight and its screen is not up: the sport, the clock, the number the
// workout is about, and a Pause or Resume that works without opening anything. Tapping the rest of it opens the workout.

/// The resume bar's value-typed view model: the sport label, the workout's start and its pauses so far, derived
/// from `AppModel.ActiveWorkout`. Equatable, and the elapsed clock is formatted from a pure function the tests pin.
///
/// The clock is the time the workout RAN, the live screen's number: a paused stretch is left out and the clock stands
/// still while one is open. Counting wall-clock time here would keep ticking through a pause and stay ahead of the
/// live screen and the Lock Screen for the rest of the workout.
struct ActiveWorkoutIndicatorModel: Equatable {
    let sport: String
    let startedAt: Date
    /// The pauses so far (closed stretches and the one still open).
    var pauses = WorkoutPauseLedger()
    /// Set while a finish is pending: the clock stops at the end the save will use, like the live screen's.
    var frozenAt: Date?

    var isPaused: Bool { pauses.isPaused }
    /// End was tried: the clock is frozen and the bar says "Ending".
    var isEnding: Bool { frozenAt != nil }

    static func make(from workout: AppModel.ActiveWorkout?) -> ActiveWorkoutIndicatorModel? {
        guard let workout else { return nil }
        return ActiveWorkoutIndicatorModel(sport: workout.sport, startedAt: workout.start, pauses: workout.pauseLedger,
                                           frozenAt: workout.frozenAt)
    }

    /// The clock at `now`: the time the workout has run, M:SS up to an hour and H:MM:SS after, frozen while paused and
    /// once a finish is pending.
    func elapsedText(at now: Date) -> String {
        let end = frozenAt.map { min($0, now) } ?? now
        return LiveWorkoutTiles.elapsedText(pauses.activeSeconds(from: startedAt.timeIntervalSince1970,
                                                                 to: end.timeIntervalSince1970))
    }

    /// Elapsed time since `start`, formatted M:SS up to an hour and H:MM:SS once an hour has passed (so a
    /// 90-minute session reads "1:30:00", not "90:00"). Clamped at zero so a clock-skew negative reads 0:00.
    /// Pure + injectable `now` for deterministic tests. (StrandFont.bodyNumber already applies tabular figures,
    /// so the call site does NOT add `.monospacedDigit()`.)
    static func elapsed(since start: Date, now: Date = Date()) -> String {
        LiveWorkoutTiles.elapsedText(now.timeIntervalSince(start))
    }
}

#if os(iOS)
/// Places the resume bar in the shell: visible while a workout is in flight and the journey's cover is not up.
///
/// It watches only `AppModel.activeWorkout` (through a zero-size leaf that copies it into state), never the whole model, so
/// the tab shell does not redraw for every heart-rate sample.
struct WorkoutResumeBarHost: View {
    /// The journey's cover is up: the bar is behind it and not needed.
    let coverIsUp: Bool
    @State private var workout: AppModel.ActiveWorkout?

    var body: some View {
        ZStack {
            ActiveWorkoutWatcher { workout = $0 }
            if let workout, !coverIsUp {
                WorkoutResumeBar(workout: workout)
                    .padding(.horizontal, NoopMetrics.space4)
                    .padding(.bottom, NoopMetrics.space2)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: workout == nil)
        .animation(.easeInOut(duration: 0.2), value: coverIsUp)
    }
}

private struct ActiveWorkoutWatcher: View {
    @EnvironmentObject private var model: AppModel
    let onChange: (AppModel.ActiveWorkout?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onReceive(model.$activeWorkout) { onChange($0) }
    }
}

struct WorkoutResumeBar: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var router: NavRouter
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let state = WorkoutResumeBarState.make(
            isPaused: workout.isPaused, isEnding: workout.isEnding,
            finish: model.workoutFinishState, finishPending: model.isWorkoutFinishPending)
        HStack(spacing: NoopMetrics.space2) {
            Button {
                StrandHaptic.selection.play()
                router.openActiveWorkout()
            } label: {
                label(state)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenSummary(state))
            .accessibilityHint("Double-tap to open.")
            WorkoutResumeBarPauseButton(model: model, workout: workout, state: state)
        }
        .padding(.leading, NoopMetrics.space3)
        .padding(.trailing, NoopMetrics.space2)
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: 56)
        .background(WidgetCardSurface(tint: .workout))
    }

    // MARK: The body of the bar

    @ViewBuilder private func label(_ state: WorkoutResumeBarState) -> some View {
        if typeSize.isAccessibilitySize {
            // Accessibility sizes stack the bar: the sport (it may take two lines), the clock on its own line so it never
            // wraps inside its digits, then the metric and the chevron.
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                HStack(spacing: NoopMetrics.space2) {
                    icon(state)
                    sportName(lines: 2)
                }
                clock(state)
                HStack(spacing: NoopMetrics.space2) {
                    statusOrMetric(state)
                    Spacer(minLength: 0)
                    chevron
                }
            }
        } else {
            HStack(alignment: .center, spacing: NoopMetrics.space3) {
                HStack(spacing: NoopMetrics.space2) {
                    icon(state)
                    sportName(lines: 1)
                    clock(state)
                }
                HStack(spacing: NoopMetrics.space2) {
                    statusOrMetric(state)
                    Spacer(minLength: 0)
                    chevron
                }
            }
        }
    }

    private func icon(_ state: WorkoutResumeBarState) -> some View {
        EyebrowPulseIcon(systemName: state.isPausedLook ? "pause.fill" : "waveform.path.ecg",
                         color: state.isPausedLook ? StrandPalette.statusWarning : StrandPalette.liveRed,
                         pulses: state.pulses)
    }

    private func sportName(lines: Int) -> some View {
        Text(verbatim: WorkoutSource.displaySport(workout.sport))
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(lines)
            .minimumScaleFactor(0.8)
    }

    private var chevron: some View {
        Image(systemName: "chevron.up")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(StrandPalette.textTertiary)
            .accessibilityHidden(true)
    }

    private func clock(_ state: WorkoutResumeBarState) -> some View {
        let model = ActiveWorkoutIndicatorModel.make(from: workout)
        return TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(model?.elapsedText(at: context.date) ?? "")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(state.isPausedLook ? 0.45 : 1)
        }
    }

    @ViewBuilder private func statusOrMetric(_ state: WorkoutResumeBarState) -> some View {
        switch state {
        case .saving:
            Text("Saving…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        case .failed:
            Text("Couldn't save · tap to retry").font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                .lineLimit(2)
        case .running, .paused:
            ResumeBarMetric(workout: workout, recorder: model.gpsRecorder, live: model.live)
        }
    }

    private func spokenSummary(_ state: WorkoutResumeBarState) -> String {
        let seconds = workout.activeElapsed()
        let spoken = LiveWorkoutTiles.spokenElapsed(seconds)
        let sport = WorkoutSource.displaySport(workout.sport)
        switch state {
        case .saving: return "\(sport), \(String(localized: "Saving…"))"
        case .failed: return "\(sport), \(String(localized: "Couldn't save · tap to retry"))"
        case .running, .paused: return "\(sport), \(spoken)"
        }
    }
}

/// What the bar is doing. Pure, so the rule is tested without a view.
enum WorkoutResumeBarState: Equatable {
    case running, paused, saving, failed

    static func make(isPaused: Bool, isEnding: Bool, finish: WorkoutFinishState, finishPending: Bool) -> Self {
        if finish == .saving { return .saving }
        if finishPending { return .failed }
        return isPaused ? .paused : .running
    }

    var isPausedLook: Bool { self == .paused }
    /// Pulses as "recording" only while it is: the same rule as every surface (`NOOPLiveWorkoutPulse`).
    var pulses: Bool { NOOPLiveWorkoutPulse.isActive(isPaused: self == .paused, isEnding: self == .saving || self == .failed) }
    /// Pause or Resume is available only when the workout is running or paused.
    var allowsPauseToggle: Bool { self == .running || self == .paused }
}

/// The number the workout is about, small: distance for a route, heart rate otherwise (the clock is already beside it).
private struct ResumeBarMetric: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    let live: LiveState
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    var body: some View {
        let imperial = unitSystemRaw == UnitSystem.imperial.rawValue
        let tracksRoute = recorder.isRecording && recorder.canRecordRoute
        let distance = LiveWorkoutTiles.distanceText(meters: recorder.distanceM, imperial: imperial)
        if tracksRoute, distance != LiveWorkoutTiles.missing {
            Text(verbatim: "\(distance) \(imperial ? "mi" : "km")")
                .font(StrandFont.subhead).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
        } else if let bpm = workout.currentBPM {
            TimelineView(.periodic(from: .now, by: 2)) { context in
                let stale = LiveWorkoutSignals.heartRateIsStale(
                    lastReadingAt: workout.lastReadingAt, workoutStart: workout.start,
                    isPaused: workout.isPaused, isEnding: workout.isEnding, now: context.date)
                Text(verbatim: "\(bpm) bpm")
                    .font(StrandFont.subhead).monospacedDigit().foregroundStyle(StrandPalette.textSecondary)
                    .opacity(stale ? 0.6 : 1)
            }
        }
    }
}

/// The 44 pt circle at the end of the bar. Pauses or resumes without opening anything; unavailable while a finish is pending.
private struct WorkoutResumeBarPauseButton: View {
    @ObservedObject var model: AppModel
    @ObservedObject var workout: AppModel.ActiveWorkout
    let state: WorkoutResumeBarState

    var body: some View {
        let paused = workout.isPaused
        Button {
            StrandHaptic.commit.play()
            model.setWorkoutPaused(!paused)
        } label: {
            Image(systemName: paused ? "play.fill" : "pause.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(state.allowsPauseToggle ? StrandPalette.onInk : StrandPalette.textTertiary)
                .frame(width: 44, height: 44)
                .background(Circle().fill(state.allowsPauseToggle ? StrandPalette.ink : StrandPalette.chipFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!state.allowsPauseToggle)
        .accessibilityLabel(paused ? "Resume workout" : "Pause workout")
    }
}
#endif
