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
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

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
        // A dark capsule of the live screen's own language: no border, the clock in mint, the glyph a 15% mint circle.
        .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(white: 0.12)))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
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
        } else if state == .failed {
            // The failed-save line is a sentence ("Speichern fehlgeschlagen · tippen für neuen Versuch"): it gets the bar's
            // whole width on a row of its own instead of the few points left beside the sport and the clock.
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
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

    @ViewBuilder private func icon(_ state: WorkoutResumeBarState) -> some View {
        if state.isPausedLook {
            Image(systemName: "pause.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(LivePalette.amber)
                .accessibilityHidden(true)
        } else {
            LiveStateDot(color: LivePalette.mint, pulses: state.pulses)
        }
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
            // Time is mint; a paused workout's is the flat grey of the live screen's frozen figures.
            Text(model?.elapsedText(at: context.date) ?? "")
                .font(StrandFont.bodyNumber)
                .foregroundStyle(state.isPausedLook ? LivePalette.frozenNumeral : LivePalette.time)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
    }

    @ViewBuilder private func statusOrMetric(_ state: WorkoutResumeBarState) -> some View {
        switch state {
        case .saving:
            Text("Saving…").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        case .failed:
            Text("Couldn't save · tap to retry").font(StrandFont.subhead).foregroundStyle(StrandPalette.statusWarning)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        case .running, .paused:
            ResumeBarMetric(workout: workout, recorder: model.gpsRecorder, profile: model.profile, isPaused: state.isPausedLook)
        }
    }

    /// "<Sport>, <paused>, <spoken elapsed>, <the metric>": what is on the bar, said in the order it is read.
    private func spokenSummary(_ state: WorkoutResumeBarState) -> String {
        let seconds = workout.activeElapsed()
        let spoken = LiveWorkoutTiles.spokenElapsed(seconds)
        let sport = WorkoutSource.displaySport(workout.sport)
        switch state {
        case .saving: return "\(sport), \(String(localized: "Saving…"))"
        case .failed: return "\(sport), \(String(localized: "Couldn't save · tap to retry"))"
        case .running, .paused:
            let imperial = unitSystemRaw == UnitSystem.imperial.rawValue
            let distance = LiveWorkoutTiles.distanceText(meters: model.gpsRecorder.distanceM, imperial: imperial)
            let metric: String? = if model.gpsRecorder.isRecording, model.gpsRecorder.canRecordRoute,
                                     distance != LiveWorkoutTiles.missing {
                LiveWorkoutTiles.spokenDistance(distance, imperial: imperial)
            } else {
                workout.currentBPM.map(LiveWorkoutTiles.spokenHeartRate)
            }
            return WorkoutResumeBarState.spokenSummary(state, sport: sport, spokenElapsed: spoken, spokenMetric: metric)
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

    /// What VoiceOver says for the bar's body while the workout runs or is paused: the sport, "Paused" when it is, the
    /// time it has run and the number the bar shows (distance, or heart rate).
    static func spokenSummary(_ state: Self, sport: String, spokenElapsed: String, spokenMetric: String?) -> String {
        [sport, state == .paused ? String(localized: "Paused") : nil, spokenElapsed, spokenMetric]
            .compactMap { $0 }.joined(separator: ", ")
    }

    var isPausedLook: Bool { self == .paused }
    /// Pulses as "recording" only while it is: the same rule as every surface (`NOOPLiveWorkoutPulse`).
    var pulses: Bool { NOOPLiveWorkoutPulse.isActive(isPaused: self == .paused, isEnding: self == .saving || self == .failed) }
    /// Pause or Resume is available only when the workout is running or paused.
    var allowsPauseToggle: Bool { self == .running || self == .paused }
}

/// The number the workout is about, small: distance for a route, heart rate otherwise (the clock is already beside it). In the
/// colours of the live screen: distance white, heart rate in its zone's colour, both flat grey while paused.
private struct ResumeBarMetric: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @ObservedObject var profile: ProfileStore
    let isPaused: Bool
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    var body: some View {
        let imperial = unitSystemRaw == UnitSystem.imperial.rawValue
        let tracksRoute = recorder.isRecording && recorder.canRecordRoute
        let distance = LiveWorkoutTiles.distanceText(meters: recorder.distanceM, imperial: imperial)
        if tracksRoute, distance != LiveWorkoutTiles.missing {
            Text(verbatim: "\(distance) \(LiveWorkoutGlance.Units.distance(imperial: imperial))")
                .font(StrandFont.subhead).monospacedDigit()
                .foregroundStyle(isPaused ? LivePalette.frozenNumeral : LivePalette.distance)
        } else if let bpm = workout.currentBPM {
            let thresholds = ProfileStore.hrZoneThresholds(override: profile.hrMaxOverride, age: profile.age)
            TimelineView(.periodic(from: .now, by: 2)) { context in
                let stale = LiveWorkoutSignals.heartRateIsStale(
                    lastReadingAt: workout.lastReadingAt, workoutStart: workout.start,
                    isPaused: workout.isPaused, isEnding: workout.isEnding, now: context.date)
                Text(verbatim: "\(bpm) \(LiveWorkoutGlance.Units.heartRate)")
                    .font(StrandFont.subhead).monospacedDigit()
                    .foregroundStyle(isPaused ? LivePalette.frozenNumeral : LivePalette.zone(thresholds.zone(for: Double(bpm))))
                    .opacity(stale ? 0.6 : 1)
            }
        }
    }
}

/// The 44 pt circle at the end of the bar: a 15% mint circle with a mint glyph. Pauses or resumes without opening anything; unavailable while a finish is pending.
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
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(state.allowsPauseToggle ? LivePalette.mint : LivePalette.missing)
                .frame(width: 44, height: 44)
                .background(Circle().fill(state.allowsPauseToggle ? LivePalette.mint.opacity(0.15) : LivePalette.fill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!state.allowsPauseToggle)
        .accessibilityLabel(paused ? "Resume workout" : "Pause workout")
    }
}
#endif
