import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Live workout sections
//
// The leaves the in-exercise screen shares: the signal reader every live number reads its freshness through, and the zone,
// route and heart-rate sections. Each one observes only what it draws (the workout's own published values or the recorder),
// so a heart-rate sample redraws the number, the rail and the chart and never the whole screen.

// MARK: Signal notices

/// Reads the two live signals every two seconds and hands what it found to `content`. A signal going quiet publishes
/// nothing (no reading arrives), so it has to be asked on a clock. The pills, the tiles and the zone rail all read
/// through this, so none of them can show a number at full strength that another has already called stale.
struct LiveWorkoutSignalReader<Content: View>: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    /// The strap's link, read at each tick (never observed): with it the snapshot can tell a strap that went quiet from one
    /// that never connected. nil leaves `strapNeverConnected` false.
    var live: LiveState?
    /// A page that is not on screen has no clock: it draws what is true now, once, and is redrawn when something it shows
    /// changes. Only the page being looked at ticks.
    var isVisible = true
    @ViewBuilder let content: (LiveWorkoutSignals.Snapshot) -> Content

    var body: some View {
        if isVisible {
            TimelineView(.periodic(from: .now, by: 2)) { context in
                content(snapshot(at: context.date))
            }
        } else {
            content(snapshot(at: Date()))
        }
    }

    private func snapshot(at now: Date) -> LiveWorkoutSignals.Snapshot {
        let tracksRoute = recorder.isRecording && recorder.canRecordRoute
        return LiveWorkoutSignals.Snapshot(
            heartRateIsStale: LiveWorkoutSignals.heartRateIsStale(
                lastReadingAt: workout.lastReadingAt, workoutStart: workout.start,
                isPaused: workout.isPaused, isEnding: workout.isEnding, now: now),
            gps: tracksRoute ? recorder.signalState(now: now) : nil,
            strapNeverConnected: live.map { workout.lastReadingAt == nil && !$0.connected } ?? false,
            locationIsOff: recorder.isRecording && !recorder.canRecordRoute)
    }
}

// MARK: Zone

/// The wearer's own Rest / Steady / Push zones with a marker on the current reading.
struct LiveWorkoutZoneSection: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var profile: ProfileStore
    @ObservedObject var recorder: GpsWorkoutRecorder

    var body: some View {
        FlatSection("Heart-rate zone", systemImage: "waveform.path.ecg", tint: .heart) {
            LiveWorkoutSignalReader(workout: workout, recorder: recorder) { signals in
                LiveZoneRail(
                    bpm: workout.currentBPM,
                    thresholds: ProfileStore.hrZoneThresholds(override: profile.hrMaxOverride, age: profile.age),
                    // The same rule as the Live Activity: a paused or silent heart rate is the last reading, quieter.
                    isDimmed: workout.isPaused || signals.heartRateIsStale)
            }
        }
    }
}

// MARK: Route

/// The route so far over a map, or what the recorder is waiting for.
struct LiveWorkoutRouteSection: View {
    @ObservedObject var recorder: GpsWorkoutRecorder

    private var message: LocalizedStringKey {
        recorder.pointCount > 0 ? "\(recorder.pointCount) GPS points recorded" : "Waiting for GPS route"
    }

    var body: some View {
        if recorder.isRecording && recorder.canRecordRoute {
            FlatSection("Route", systemImage: "map.fill", tint: .accent,
                        trailing: .text(String(localized: "Saved on this device"))) {
                Group {
                    if recorder.routeSegments.contains(where: { $0.count >= 2 }) {
                        WorkoutRouteMap(segments: recorder.routeSegments, showsEndpoints: false)
                            .allowsHitTesting(false)
                            .accessibilityLabel("Live GPS route")
                    } else {
                        VStack(spacing: NoopMetrics.space2) {
                            Image(systemName: recorder.pointCount > 0 ? "location.fill" : "location.slash")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(recorder.pointCount > 0 ? StrandPalette.link : StrandPalette.textTertiary)
                            Text(message)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(StrandPalette.inset)
                    }
                }
                .frame(height: 170)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous)
                    .strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
            }
        }
    }
}

// MARK: Heart rate

/// Heart rate over the workout so far. `ActiveWorkout` publishes an already-bounded incremental projection, so this
/// never scans the complete retained workout.
struct LiveWorkoutHeartSection: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder) { signals in
            // The number beside the title is the latest reading; with the strap silent it steps back like the tile does.
            section.opacity(signals.heartRateIsStale ? 0.6 : 1)
        }
    }

    @ViewBuilder private var section: some View {
        let projection = workout.chartProjection
        FlatSection("Heart rate", systemImage: "heart.fill", tint: .heart,
                    trailing: .text(workout.currentBPM.map { "\($0) bpm" } ?? WidgetMetrics.missingValue)) {
            if projection.values.count > 1 {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    Sparkline(
                        values: projection.values,
                        gradient: Gradient(colors: [StrandPalette.liveRed.opacity(0.75), StrandPalette.liveRed]),
                        range: projection.range,
                        lineWidth: 2,
                        showsArea: true,
                        showsHead: false,
                        showsHover: false
                    )
                    .frame(height: 96)
                    .accessibilityLabel(
                        "Workout heart rate, \(projection.values.count) plotted points over \(projection.observedSeconds) seconds")
                    HStack {
                        Text("\(Int(projection.values.min() ?? 0))–\(Int(projection.values.max() ?? 0)) bpm")
                        Spacer()
                        Text("\(max(1, Int(ceil(Double(projection.observedSeconds) / 60)))) min window")
                    }
                    .font(StrandFont.footnote).monospacedDigit()
                    .foregroundStyle(StrandPalette.textTertiary)
                }
            } else {
                Text("Heart-rate history will draw as the workout records.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
            }
        }
    }
}
