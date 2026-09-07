import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The recorder stays in AppModel. Closing this screen never ends an active workout.
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void
    @State private var completed: WorkoutRow?

    var body: some View {
        NavigationStack {
            Group {
                if let completed {
                    WorkoutDetailView(row: completed, onClose: onClose)
                } else if let workout = model.activeWorkout {
                    StableWorkoutSession(model: model, workout: workout)
                        .equatable()
                        .navigationTitle(workout.sport)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Minimize", action: onClose)
                                    .accessibilityHint("Keeps this workout recording")
                                    .disabled(model.workoutFinishState == .saving)
                            }
                        }
                } else {
                    ExperienceMessage(title: "No workout is recording",
                                      message: "Close this view to start a new session.", symbol: "figure.run")
                        .padding(16)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) } }
                }
            }
            .noopFocusedTask()
            .tint(StrandPalette.accent)
        }
        .interactiveDismissDisabled(model.workoutFinishState == .saving)
        .onChange(of: model.workoutFinishState) { _, state in
            if case .saved(let row) = state { completed = row }
        }
    }
}

/// Stable shell: per-second time and streaming heart rate only invalidate their own leaves.
private struct StableWorkoutSession: View, @preconcurrency Equatable {
    let model: AppModel
    let workout: AppModel.ActiveWorkout
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.workout === rhs.workout
    }

    var body: some View {
        ExperienceScroll {
            LiveWorkoutTimeHero(workout: workout)
            LiveWorkoutHeartPanel(workout: workout, profile: model.profile)
            if WorkoutExperiencePolicy.kind(for: workout.sport).supportsRoute {
                LiveWorkoutRoutePanel(recorder: model.gpsRecorder, workout: workout)
            }
            LiveWorkoutEffortPanel(workout: workout)
            LiveWorkoutSaveStatus(model: model)
            Toggle("Keep screen awake", isOn: $keepScreenOn)
                .font(StrandFont.footnote).tint(StrandPalette.accent)
            Text("Minimize keeps recording. Finish workout saves this session.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { LiveWorkoutFinishBar(model: model) }
        .onAppear {
            model.startRealtimeHR()
            ScreenIdle.keepAwake(keepScreenOn)
        }
        .onChange(of: keepScreenOn) { _, value in ScreenIdle.keepAwake(value) }
        .onDisappear {
            model.stopRealtimeHR()
            ScreenIdle.keepAwake(false)
        }
    }
}

private struct LiveWorkoutTimeHero: View {
    let workout: AppModel.ActiveWorkout
    private var context: String {
        switch WorkoutExperiencePolicy.kind(for: workout.sport) {
        case .indoorCardio: "Indoor session · GPS off"
        case .strength: "Strength session · Heart-rate tracking"
        case .mobility: "Mindful movement · Heart-rate tracking"
        case .timed: "Timed session · Heart-rate tracking"
        default: "Outdoor session"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(LocalizedStringKey(context), systemImage: WorkoutExperiencePolicy.symbol(for: workout.sport))
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                Text(WorkoutExperiencePolicy.elapsed(timeline.date.timeIntervalSince(workout.start)))
                    .font(StrandFont.timer).monospacedDigit().foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.55)
                    .accessibilityLabel("Elapsed time")
                    .accessibilityValue(WorkoutExperiencePolicy.elapsed(timeline.date.timeIntervalSince(workout.start)))
            }
            Label("Recording", systemImage: "record.circle")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 12)
    }
}

private struct LiveWorkoutHeartPanel: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var profile: ProfileStore
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 18) {
                TimelineView(.periodic(from: .now, by: 1)) { timeline in
                    let last = workout.samples.last
                    let age = last.map { timeline.date.timeIntervalSince(Date(timeIntervalSince1970: Double($0.ts))) }
                    let fresh = age.map { (-5...20).contains($0) } ?? false
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(fresh ? workout.currentBPM.map(String.init) ?? "—" : "—")
                            .font(StrandFont.timer).monospacedDigit().foregroundStyle(StrandPalette.liveRed)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        Text("bpm").font(StrandFont.body).foregroundStyle(StrandPalette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    Text(fresh ? "Current heart rate" : "Waiting for a fresh heart-rate reading")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    if fresh, let bpm = workout.currentBPM {
                        let zones = HRZones.zones(maxHR: Double(profile.hrMax))
                        let zone = zones.zoneNumber(forBPM: Double(bpm))
                        Label(zone > 0 ? "Zone \(zone)" : "Below Zone 1", systemImage: "heart.fill")
                            .font(StrandFont.headline)
                            .foregroundStyle(zone > 0 ? StrandPalette.hrZoneColor(zone) : StrandPalette.textSecondary)
                    }
                }
                if workout.avgHr > 0 {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 24) { averages }
                        VStack(alignment: .leading, spacing: 8) { averages }
                    }
                }
                let projection = workout.chartProjection
                if projection.values.count > 1 {
                    Sparkline(values: projection.values,
                              gradient: Gradient(colors: [StrandPalette.liveRed, StrandPalette.liveRed]),
                              range: projection.range, lineWidth: 2,
                              showsArea: false, showsHead: false, showsHover: false)
                        .frame(height: typeSize.isAccessibilitySize ? 120 : 80)
                        .accessibilityLabel("Recent recorded heart-rate samples")
                    Text("HEART RATE (LAST 3 HOURS)")
                        .font(StrandFont.micro).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private var averages: some View {
        Label("Average \(workout.avgHr) bpm", systemImage: "heart")
        Label("Peak \(workout.peakHr) bpm", systemImage: "arrow.up")
    }
}

private struct LiveWorkoutRoutePanel: View {
    @ObservedObject var recorder: GpsWorkoutRecorder
    let workout: AppModel.ActiveWorkout
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize
    private var imperial: Bool { unitSystemRaw == UnitSystem.imperial.rawValue }
    private var ownsRoute: Bool {
        WorkoutExperiencePolicy.hasLiveRoute(sport: workout.sport, isRecording: recorder.isRecording,
                                              recordedSession: recorder.persistenceCheckpoint()?.sessionID,
                                              activeSession: workout.sessionID)
    }
    var body: some View {
        if ownsRoute {
            if let distance = WorkoutExperiencePolicy.distance(recorder.distanceM, imperial: imperial) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 240 : 140))], spacing: 12) {
                    ExperienceMetricTile(label: distance.label, value: distance.value, unit: distance.unit, symbol: "location")
                    if let pace = recorder.paceSecPerKm,
                       let rate = WorkoutExperiencePolicy.rate(sport: workout.sport, meters: 1000,
                                                                seconds: pace, imperial: imperial) {
                        ExperienceMetricTile(label: rate.label, value: rate.value, unit: rate.unit, symbol: "speedometer")
                    }
                }
                LiveWorkoutRoutePreview(recorder: recorder, sessionID: workout.sessionID).equatable()
            } else {
                ExperienceMessage(title: recorder.canRecordRoute ? "Finding your route" : "Location is unavailable",
                                  message: recorder.canRecordRoute
                                    ? "Distance appears after enough GPS points arrive. Heart-rate tracking continues."
                                    : "Heart-rate tracking continues. Enable location in Settings to record a route.",
                                  symbol: "location")
            }
        }
    }
}

/// Refresh only while visible, at most every five seconds. The preview retains at most 800 real points.
private struct LiveWorkoutRoutePreview: View, @preconcurrency Equatable {
    let recorder: GpsWorkoutRecorder
    let sessionID: UUID
    @State private var segments: [[RouteMath.LatLng]] = []
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.recorder === rhs.recorder && lhs.sessionID == rhs.sessionID }
    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 12) {
                ExperienceSectionHeading(title: "Recent route", detail: "GPS preview · Full distance shown above")
                if segments.contains(where: { $0.count >= 2 }) {
                    WorkoutRouteMap(segments: segments, showsEndpoints: false)
                        .frame(height: 160).clipShape(RoundedRectangle(cornerRadius: 12))
                        .allowsHitTesting(false)
                        .accessibilityLabel("Recent recorded route preview")
                }
            }
        }
        .task(id: sessionID) {
            while !Task.isCancelled {
                guard recorder.isRecording, recorder.persistenceCheckpoint()?.sessionID == sessionID else { return }
                var remaining = 800
                var recent: [[RouteMath.LatLng]] = []
                for segment in recorder.routeSegments.reversed() where remaining > 0 {
                    let part = Array(segment.suffix(remaining))
                    recent.append(part)
                    remaining -= part.count
                }
                segments = recent.reversed()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}

private struct LiveWorkoutEffortPanel: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @AppStorage(UnitPrefs.effortScaleKey) private var scaleRaw = EffortScale.whoop.rawValue
    var body: some View {
        PaperCard {
            VStack(alignment: .leading, spacing: 12) {
                ExperienceSectionHeading(title: "Session strain")
                switch workout.liveStrainState {
                case .building(let readings, let seconds):
                    ProgressView(value: min(1, Double(seconds) / Double(StrainScorerV2.minCoverageSeconds)))
                        .tint(StrandPalette.strainAccent)
                    Text("Building from \(readings) readings")
                        .font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    Text("\(WorkoutExperiencePolicy.elapsed(Double(seconds))) of \(WorkoutExperiencePolicy.elapsed(Double(StrainScorerV2.minCoverageSeconds))) heart-rate coverage")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                case .scored(let strain):
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(UnitFormatter.effortDisplay(strain, scale: UnitPrefs.resolveEffortScale(scaleRaw)))
                            .font(StrandFont.metricValue).monospacedDigit().foregroundStyle(StrandPalette.strainAccent)
                        Text("Strain").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text("Calculated from this session’s recorded heart rate.")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct LiveWorkoutSaveStatus: View {
    @ObservedObject var model: AppModel
    var body: some View {
        if let warning = model.workoutDurabilityWarning {
            ExperienceMessage(title: "Recording recovery needs attention", message: warning,
                              symbol: "externaldrive.badge.exclamationmark", tint: StrandPalette.statusWarning)
        }
        if case .failed(let message) = model.workoutFinishState {
            ExperienceMessage(title: "Workout has not saved", message: message,
                              symbol: "exclamationmark.triangle", tint: StrandPalette.statusWarning)
        }
    }
}

private struct LiveWorkoutFinishBar: View {
    @ObservedObject var model: AppModel
    @State private var confirming = false
    private var saving: Bool { model.workoutFinishState == .saving }
    var body: some View {
        VStack(spacing: 8) {
            NoopButton(saving ? "Saving workout…" : "Finish workout", systemImage: saving ? "hourglass" : "flag.checkered",
                       kind: .primary, fullWidth: true) { confirming = true }
                .disabled(saving)
        }
        .padding(16)
        .background(StrandPalette.appCanvas)
        .overlay(alignment: .top) { Rectangle().fill(StrandPalette.hairline).frame(height: 1) }
        .confirmationDialog("Finish and save this workout?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Finish and save") { Task { _ = await model.endWorkout() } }
            Button("Keep recording", role: .cancel) {}
        } message: {
            Text("The summary opens after the saved workout is verified.")
        }
    }
}
