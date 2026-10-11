import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Live workout sections
//
// The leaves of the in-exercise screen. Each one observes only what it draws (the workout's own published values or the
// recorder), so a heart-rate sample redraws the tile, the rail and the chart and never the whole screen.

// MARK: Hero

/// The elapsed time, large, and a "Paused" pill when the clock is stopped, or "Ending" once End has been tried (the clock
/// stands at the end the save will use).
struct LiveWorkoutHero: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let paused = workout.isPaused
        let ending = workout.isEnding
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NoopMetrics.space2))
            : AnyLayout(HStackLayout(alignment: .center, spacing: NoopMetrics.space3))
        layout {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let elapsed = workout.activeElapsed(at: context.date)
                HeroValue(
                    value: LiveWorkoutTiles.elapsedText(elapsed),
                    caption: workout.sport,
                    captionPlacement: .below,
                    size: typeSize.isAccessibilitySize ? 34 : 64
                )
                .monospacedDigit()
                .opacity(paused ? 0.4 : 1)
                // Spoken from the same tick as the digits: outside the timeline this value was fixed at the last time
                // the workout published (a heart-rate sample), so with no strap streaming it never moved.
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("Elapsed time"))
                .accessibilityValue(Text(verbatim: LiveWorkoutTiles.spokenElapsed(elapsed)))
            }
            if ending {
                Spacer(minLength: 0)
                StatePill("Ending")
                    .transition(.opacity)
            } else if paused {
                Spacer(minLength: 0)
                StatePill("Paused", tone: .warning)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: paused)
        .animation(.easeInOut(duration: 0.2), value: ending)
    }

}

// MARK: Signal notices

/// Reads the two live signals every two seconds and hands what it found to `content`. A signal going quiet publishes
/// nothing (no reading arrives), so it has to be asked on a clock. The pills, the tiles and the zone rail all read
/// through this, so none of them can show a number at full strength that another has already called stale.
struct LiveWorkoutSignalReader<Content: View>: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @ViewBuilder let content: (LiveWorkoutSignals.Snapshot) -> Content

    var body: some View {
        let tracksRoute = recorder.isRecording && recorder.canRecordRoute
        TimelineView(.periodic(from: .now, by: 2)) { context in
            content(LiveWorkoutSignals.Snapshot(
                heartRateIsStale: LiveWorkoutSignals.heartRateIsStale(
                    lastReadingAt: workout.lastReadingAt, workoutStart: workout.start,
                    isPaused: workout.isPaused, now: context.date),
                gps: tracksRoute ? recorder.signalState(now: context.date) : nil))
        }
    }
}

/// Pills for a heart-rate strap or a GPS fix that has gone quiet. Nothing is drawn while both are fine.
struct LiveWorkoutSignalNotices: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder) { signals in
            let notices = LiveWorkoutSignals.notices(heartRateIsStale: signals.heartRateIsStale, gps: signals.gps)
            if !notices.isEmpty {
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: NoopMetrics.space2))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: NoopMetrics.space2))
                layout {
                    ForEach(notices, id: \.self) { notice in
                        StatePill(Self.title(notice), tone: .warning)
                    }
                    if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
                }
                // The gap above the pills belongs to them: with none to show, the hero is followed directly by what is next.
                .padding(.top, NoopMetrics.space3)
            }
        }
    }

    private static func title(_ notice: LiveWorkoutSignals.Notice) -> LocalizedStringKey {
        switch notice {
        case .heartRate: "No heart-rate signal"
        case .gpsSearching: "Searching for GPS"
        case .gpsWeak: "Weak GPS signal"
        case .gpsLost: "GPS signal lost"
        }
    }
}

// MARK: Tiles

/// Distance, pace or speed, heart rate and energy as widget tiles, two across. A tile that does not apply is not drawn.
struct LiveWorkoutTileGrid: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize

    private var tiles: [LiveWorkoutTiles.Tile] {
        LiveWorkoutTiles.tiles(for: LiveWorkoutTiles.Input(
            sport: workout.sport,
            tracksRoute: recorder.isRecording && recorder.canRecordRoute,
            distanceMeters: recorder.distanceM,
            paceSecPerKm: recorder.paceSecPerKm,
            bpm: workout.currentBPM,
            calories: workout.liveCalories,
            averageHR: workout.avgHr,
            peakHR: workout.peakHr,
            imperial: unitSystemRaw == UnitSystem.imperial.rawValue))
    }

    var body: some View {
        let columns = typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible(), spacing: NoopMetrics.space3), GridItem(.flexible())]
        LiveWorkoutSignalReader(workout: workout, recorder: recorder) { signals in
            LazyVGrid(columns: columns, spacing: NoopMetrics.space3) {
                ForEach(tiles) { tile in
                    StatTile(
                        label: Self.label(tile.kind),
                        value: tile.value,
                        accent: Self.accent(tile.kind),
                        systemImage: Self.symbol(tile.kind),
                        tint: Self.tint(tile.kind),
                        unit: tile.unit)
                        // A reading whose source has gone quiet keeps its last number, quieter, never at full strength.
                        .opacity(LiveWorkoutTiles.isStale(tile.kind, signals: signals) ? Self.staleOpacity : 1)
                }
            }
        }
        // A frozen reading is not a live one: the tiles keep their numbers but step back.
        .opacity(workout.isPaused ? 0.7 : 1)
    }

    /// How far a stale reading steps back: the island's "not updating" strength.
    private static let staleOpacity = 0.6

    private static func label(_ kind: LiveWorkoutTiles.Kind) -> LocalizedStringKey {
        switch kind {
        case .distance: "Distance"
        case .pace: "Pace"
        case .speed: "Speed"
        case .heartRate: "Heart rate"
        case .energy: "Calories"
        case .averageHeartRate: "Avg HR"
        case .peakHeartRate: "Peak HR"
        }
    }

    private static func symbol(_ kind: LiveWorkoutTiles.Kind) -> String {
        switch kind {
        case .distance: "location.fill"
        case .pace, .speed: "speedometer"
        case .heartRate, .averageHeartRate, .peakHeartRate: "heart.fill"
        case .energy: "flame.fill"
        }
    }

    private static func tint(_ kind: LiveWorkoutTiles.Kind) -> DomainTint {
        switch kind {
        case .distance, .pace, .speed: .accent
        case .heartRate, .averageHeartRate, .peakHeartRate: .heart
        case .energy: .strain
        }
    }

    private static func accent(_ kind: LiveWorkoutTiles.Kind) -> Color {
        switch kind {
        case .heartRate: StrandPalette.liveRed
        default: StrandPalette.textPrimary
        }
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

// MARK: Strain

/// Strain so far, on the 0 to 21 scale once there is enough heart rate to score it; until then how much is still needed.
struct LiveWorkoutStrainSection: View {
    @ObservedObject var workout: AppModel.ActiveWorkout

    var body: some View {
        switch workout.liveStrainState {
        case .building(let readings, let coverageSeconds):
            FlatSection("Live strain", systemImage: "flame.fill", tint: .strain,
                        trailing: .pill("Building", tone: .neutral)) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HeroValue(value: Self.clock(coverageSeconds), unit: String(localized: "of 10:00"))
                    ProgressView(value: min(1, Double(coverageSeconds) / Double(StrainScorerV2.minCoverageSeconds)))
                        .tint(StrandPalette.strainAccent)
                        .accessibilityHidden(true)
                    Text("\(Self.clock(coverageSeconds)) of 10:00 coverage · \(readings) readings")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        case .scored(let strain):
            FlatSection("Live strain", systemImage: "flame.fill", tint: .strain,
                        trailing: .text(StrainScale.band(StrainScale.displayValue(fromStored: strain)).title)) {
                PillarDial(
                    value: StrainScale.displayValue(fromStored: strain),
                    maximum: StrainScale.displayRange.upperBound,
                    valueText: StrainScale.formatted(strain),
                    accent: DomainTint.strain.accent,
                    caption: String(localized: "of 21"),
                    scaleLabels: ("0", "21"),
                    accessibilityText: String(localized: "Strain \(StrainScale.formatted(strain)) of 21"))
            }
        }
    }

    private static func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
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

// MARK: Messages

struct LiveWorkoutMessages: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let failure: String? = if case .failed(let message) = model.workoutFinishState { message } else { nil }
        if model.workoutDurabilityWarning != nil || failure != nil {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                if let warning = model.workoutDurabilityWarning {
                    Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Workout recovery warning. \(warning)")
                }
                if let failure {
                    Text(failure)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.statusWarning)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Workout save failed. \(failure)")
                }
            }
            .padding(.top, NoopMetrics.space3)
        }
    }
}
