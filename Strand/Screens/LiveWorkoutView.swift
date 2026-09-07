import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Live workout mode. The environment wrapper receives AppModel's high-frequency notifications, but its
/// expensive/static content is Equatable and identity-stable. Only the dedicated heart/zone/strain leaves
/// observe AppModel and continue updating for every available HR sample.
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    let onClose: () -> Void

    var body: some View {
        StableLiveWorkoutContent(model: model, workout: model.activeWorkout)
            .equatable()
            .overlay {
                WorkoutGoneObserver(model: model, onClose: onClose)
            }
    }
}

private struct StableLiveWorkoutContent: View, @preconcurrency Equatable {
    let model: AppModel
    let workout: AppModel.ActiveWorkout?
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.workout === rhs.workout
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                header.staggeredAppear(index: 0)
                timerBlock.staggeredAppear(index: 1)
                if let workout {
                    PaperLiveWorkoutStatsGrid(workout: workout, recorder: model.gpsRecorder)
                        .staggeredAppear(index: 2)
                    LiveWorkoutZoneCard(workout: workout, profile: model.profile)
                    LiveWorkoutSignalStatus(workout: workout)
                    PaperWorkoutMapCard(recorder: model.gpsRecorder)
                }
                if let workout = model.activeWorkout {
                    LiveWorkoutHeartCard(workout: workout)
                        .staggeredAppear(index: 4)
                }
                LiveWorkoutControlRow(model: model)
                LiveWorkoutDurabilityWarning(model: model)
                LiveWorkoutFailureMessage(model: model)
                if let workout = model.activeWorkout {
                    LiveWorkoutEffortAndZone(workout: workout, profile: model.profile)
                }
            }
            .screenPadding()
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .onAppear {
            model.startRealtimeHR()
            if keepScreenOn { ScreenIdle.keepAwake(true) }
        }
        .onDisappear {
            model.stopRealtimeHR()
            ScreenIdle.keepAwake(false)
        }
    }

    private var header: some View {
        ZStack {
            Text("N O O P")
                .font(StrandFont.wordmark)
                .tracking(StrandFont.wordmarkTracking)
                .foregroundStyle(StrandPalette.textPrimary)
            HStack {
                Text(model.activeWorkout?.sport ?? String(localized: "Workout"))
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                Spacer()
                StatusBadge("Live", style: .live)
            }
        }
        .frame(minHeight: 32)
    }

    @ViewBuilder
    private var timerBlock: some View {
        if let start = model.activeWorkout?.start {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(spacing: 3) {
                    Text(Self.elapsed(since: start))
                        .font(StrandFont.timer)
                        .tracking(StrandFont.timerTracking)
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("Elapsed Time")
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private static func elapsed(since start: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

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

/// Per-sample heart history leaf. `ActiveWorkout` publishes an already-bounded incremental projection, so
/// this view never observes broad AppModel invalidations or scans the complete retained workout.
private struct LiveWorkoutHeartCard: View {
    @ObservedObject var workout: AppModel.ActiveWorkout

    var body: some View {
        let projection = workout.chartProjection
        PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("HEART RATE")
                        .font(StrandFont.sectionOverline)
                        .tracking(StrandFont.sectionOverlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text(workout.currentBPM.map { "\($0) bpm" } ?? "—")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.liveRed)
                }
                if projection.values.count > 1 {
                    Sparkline(
                        values: projection.values,
                        gradient: Gradient(colors: [
                            StrandPalette.liveRed.opacity(0.75),
                            StrandPalette.liveRed,
                        ]),
                        range: projection.range,
                        lineWidth: 2,
                        showsArea: true,
                        showsHead: false,
                        showsHover: false
                    )
                    .frame(height: 96)
                    .accessibilityLabel(
                        "Workout heart rate, \(projection.values.count) plotted points over \(projection.observedSeconds) seconds"
                    )
                    HStack {
                        Text("\(Int(projection.values.min() ?? 0))–\(Int(projection.values.max() ?? 0)) bpm")
                        Spacer()
                        Text("\(max(1, Int(ceil(Double(projection.observedSeconds) / 60)))) min window")
                    }
                    .font(StrandFont.footnote).monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("Heart-rate history will draw as the workout records.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
                }
            }
        }
    }
}

private struct LiveWorkoutControlRow: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Circle().fill(StrandPalette.liveRed).frame(width: 6, height: 6)
                Text("Recording")
            }
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(StrandPalette.card,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(StrandPalette.cardBorder, lineWidth: 1))

            let saving = model.workoutFinishState == .saving
            let title: LocalizedStringKey = saving ? "Saving…" : "Finish"
            NoopButton(
                title,
                systemImage: saving ? "hourglass" : "flag.checkered",
                kind: .destructive
            ) {
                Task { _ = await model.endWorkout() }
            }
            .disabled(saving)
        }
    }
}

private struct LiveWorkoutFailureMessage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if case .failed(let message) = model.workoutFinishState {
            Text(message)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .accessibilityLabel("Workout save failed. \(message)")
        }
    }
}

private struct LiveWorkoutDurabilityWarning: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let warning = model.workoutDurabilityWarning {
            Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.statusWarning)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Workout recovery warning. \(warning)")
        }
    }
}

private struct LiveWorkoutEffortAndZone: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var profile: ProfileStore
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var zoneSet: HRZoneSet { HRZones.zones(maxHR: Double(profile.hrMax)) }
    private var zone: Int { workout.currentBPM.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        effortGauge
    }

    private var effortGauge: some View {
        NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.effortColor) {
            VStack(spacing: NoopMetrics.rowSpacing) {
                switch workout.liveStrainState {
                case .building(let readings, let coverageSeconds):
                    Text("STRAIN BUILDING")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.effortColor)
                    Text("Building")
                        .font(StrandFont.metricValue)
                        .foregroundStyle(StrandPalette.textPrimary)
                    ProgressView(value: min(
                        1,
                        Double(coverageSeconds) / Double(StrainScorerV2.minCoverageSeconds)
                    ))
                    .tint(StrandPalette.effortColor)
                    Text("\(Self.elapsedCoverage(coverageSeconds)) of 10:00 coverage · \(readings) readings")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                case .scored(let strain):
                    Text("LIVE STRAIN")
                        .font(StrandFont.overline)
                        .tracking(StrandFont.overlineTracking)
                        .foregroundStyle(StrandPalette.effortColor)
                    StrainGauge(
                        strain: UnitFormatter.effortValue(strain, scale: effortScale),
                        outOf: 21,
                        diameter: 150,
                        lineWidth: 14,
                        showsHover: false,
                        valueFormat: { _ in
                            UnitFormatter.effortDisplay(strain, scale: effortScale)
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private static func elapsedCoverage(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}

private struct PaperLiveWorkoutStatsGrid: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    var body: some View {
        PaperCard(padding: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                if recorder.isRecording && recorder.canRecordRoute {
                    metric("DISTANCE", distanceText, unitSystem == .imperial ? "mi" : "km")
                    metric("PACE", paceText, unitSystem == .imperial ? "/mi" : "/km")
                }
                metric("HEART RATE", workout.currentBPM.map(String.init) ?? "—", "bpm", tint: StrandPalette.liveRed)
                if !recorder.isRecording || !recorder.canRecordRoute {
                    metric("AVG HR", workout.avgHr > 0 ? String(workout.avgHr) : "—", "bpm")
                    metric("PEAK HR", workout.peakHr > 0 ? String(workout.peakHr) : "—", "bpm")
                }
            }
        }
    }

    private func metric(
        _ label: String,
        _ value: String,
        _ unit: String?,
        tint: Color = StrandPalette.textPrimary
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(StrandFont.micro.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(StrandFont.metricValue)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                if let unit {
                    Text(unit)
                        .font(StrandFont.micro)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(.horizontal, 11)
        .overlay(alignment: .trailing) {
            Rectangle().fill(StrandPalette.hairline).frame(width: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(StrandPalette.hairline).frame(height: 1)
        }
    }

    private var distanceText: String {
        guard recorder.distanceM > 0 else { return "—" }
        let amount = unitSystem == .imperial
            ? recorder.distanceM / 1609.344
            : recorder.distanceM / 1000
        return String(format: "%.2f", amount)
    }

    private var paceText: String {
        guard let secPerKm = recorder.paceSecPerKm else { return "—" }
        let seconds = Int((unitSystem == .imperial ? secPerKm * 1.609344 : secPerKm).rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PaperWorkoutMapCard: View {
    @ObservedObject var recorder: GpsWorkoutRecorder

    var body: some View {
        if recorder.isRecording && recorder.canRecordRoute {
        PaperCard(padding: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if recorder.routeSegments.contains(where: { $0.count >= 2 }) {
                        WorkoutRouteMap(segments: recorder.routeSegments, showsEndpoints: false)
                            .allowsHitTesting(false)
                            .accessibilityLabel("Live GPS route")
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: recorder.pointCount > 0 ? "location.fill" : "location.slash")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(recorder.pointCount > 0
                                    ? StrandPalette.link
                                    : StrandPalette.textTertiary)
                            Text(recorder.pointCount > 0
                                ? "\(recorder.pointCount) GPS points recorded"
                                : "Waiting for GPS route")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(StrandPalette.inset)
                    }
                }
                .frame(height: 150)
                HStack(spacing: 6) {
                    Image(systemName: "map.fill")
                    Text("Route saving · Local only")
                }
                .font(StrandFont.micro.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(StrandPalette.card, in: Capsule())
                .padding(12)
            }
        }
    }
    }
}

private struct LiveWorkoutZoneCard: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var profile: ProfileStore

    var body: some View {
        PaperCard {
            NOOPHeartRateZoneRail(bpm: workout.currentBPM, maxHR: Double(profile.hrMax))
        }
    }
}

private struct LiveWorkoutSignalStatus: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            if let last = workout.samples.last,
               context.date.timeIntervalSince1970 - Double(last.ts) > 15 {
                Label("Waiting for fresh heart rate. Showing the last recorded reading.", systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
