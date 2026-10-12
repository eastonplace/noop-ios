#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Heart page

/// The heart on its own: the bpm at 96 pt with the zone it is in, the wearer's zones with a marker, the time spent in each,
/// and the heart-rate trace of the workout so far. With no strap it says so and offers Manage devices.
struct LiveHeartPage: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @ObservedObject var profile: ProfileStore
    let live: LiveState
    var isVisible = true
    let onManageDevices: () -> Void

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder, live: live, isVisible: isVisible) { signals in
            content(signals)
        }
    }

    @ViewBuilder private func content(_ signals: LiveWorkoutSignals.Snapshot) -> some View {
        let thresholds = ProfileStore.hrZoneThresholds(override: profile.hrMaxOverride, age: profile.age)
        let bpm = workout.currentBPM
        let zone = bpm.map { thresholds.zone(for: Double($0)) }
        let paused = workout.isPaused
        let stale = signals.heartRateIsStale
        let dim = paused ? GlanceMetricLayout.pausedOpacity : 1.0
        VStack(alignment: .leading, spacing: 0) {
            numeral(bpm: bpm, zone: zone, paused: paused, stale: stale)
            if signals.strapNeverConnected && bpm == nil { noStrap }
            FlatSectionSeparator()
            LiveZoneRail(bpm: bpm, thresholds: thresholds, isDimmed: stale && !paused, style: .full)
                .opacity(dim)
            FlatSectionSeparator()
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text("Time in zone").strandOverlineFitted().lineLimit(2)
                ZoneMinutesBar(seconds: workout.personalZoneSeconds, currentZone: zone)
            }
            .opacity(dim)
            FlatSectionSeparator()
            LiveWorkoutHeartSection(workout: workout, recorder: recorder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func numeral(bpm: Int?, zone: Int?, paused: Bool, stale: Bool) -> some View {
        let state: GlanceMetricView.State = bpm == nil ? .missing : (paused ? .paused : (stale ? .stale : .live))
        let word = zone.map { LiveFocusPage.word($0) }
        let spoken: String = {
            guard let bpm else { return String(localized: "No reading") }
            var parts = [LiveWorkoutTiles.spokenHeartRate(bpm)]
            if let word { parts.append(word) }
            if stale { parts.append(String(localized: "no signal")) }
            return parts.joined(separator: ", ")
        }()
        return GlanceMetricView(
            eyebrow: "\(String(localized: "Heart rate")) · bpm", value: bpm.map(String.init) ?? WidgetMetrics.missingValue,
            size: .page, state: state, micro: stale ? String(localized: "no signal") : nil,
            spokenLabel: String(localized: "Heart rate"), spokenValue: spoken,
            accessory: zone.map { GlanceMetricView.Accessory(LiveFocusPage.word($0), color: HRZoneStyle.zoneColor($0)) })
    }

    private var noStrap: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text("No strap connected")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Button("Manage devices", action: onManageDevices)
                .buttonStyle(SecondaryPillButtonStyle())
        }
        .padding(.top, NoopMetrics.space3)
    }
}

// MARK: - Route page

/// The route so far on a map that fills the page, with the distance, pace (or speed) and time along its bottom edge. Before
/// the first fix it says what it is waiting for. The map is built only while the page is showing or next to the one that is,
/// so a swipe finds it ready and a page two away costs nothing.
struct LiveRoutePage: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    var isVisible = true
    var isNear = true
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    private typealias Glance = LiveWorkoutGlance

    var body: some View {
        // The facts sit under the map, not over it: Apple's logo and Legal link at the map's bottom edge must stay visible.
        VStack(spacing: 0) {
            mapOrWaiting
            facts
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: NoopMetrics.radius3, style: .continuous)
            .strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
    }

    @ViewBuilder private var mapOrWaiting: some View {
        if recorder.routeSegments.contains(where: { $0.count >= 2 }) {
            if isNear {
                WorkoutRouteMap(segments: recorder.routeSegments, showsEndpoints: false)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Live GPS route")
            } else {
                StrandPalette.inset
            }
        } else {
            VStack(spacing: NoopMetrics.space2) {
                Image(systemName: recorder.pointCount > 0 ? "location.fill" : "location.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(recorder.pointCount > 0 ? StrandPalette.link : StrandPalette.textTertiary)
                Text(recorder.pointCount > 0 ? "\(recorder.pointCount) GPS points recorded" : "Waiting for GPS route")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(StrandPalette.inset)
        }
    }

    @ViewBuilder private var facts: some View {
        if isVisible {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                strip(elapsed: workout.activeElapsed(at: context.date))
            }
        } else {
            strip(elapsed: workout.activeElapsed(at: Date()))
        }
    }

    private func strip(elapsed: TimeInterval) -> some View {
        let tracksRoute = recorder.isRecording && recorder.canRecordRoute
        let sportClass = Glance.sportClass(sport: workout.sport, tracksRoute: tracksRoute)
        let input = LiveWorkoutTiles.Input(
            sport: workout.sport, tracksRoute: tracksRoute, distanceMeters: recorder.distanceM,
            paceSecPerKm: recorder.paceSecPerKm, bpm: workout.currentBPM, calories: workout.liveCalories,
            averageHR: workout.avgHr, peakHR: workout.peakHr, imperial: unitSystemRaw == UnitSystem.imperial.rawValue)
        let strain = workout.liveStrainState
        let pace: Glance.Metric = sportClass == .routeSpeed ? .speed : .pace
        let values = [Glance.Metric.distance, pace, .time].map {
            Glance.value($0, input: input, elapsed: elapsed, strain: strain)
        }
        return FactStrip(facts: values.map(fact), labelStyle: .eyebrow)
            .padding(NoopMetrics.space3)
            .frame(maxWidth: .infinity)
            .background(StrandPalette.appCanvas)
            .opacity(workout.isPaused ? GlanceMetricLayout.pausedOpacity : 1)
    }

    private func fact(_ value: Glance.Value) -> FactStrip.Fact {
        // The eyebrow ends with the unit ("Distance · km"); the strip shows it after the number.
        let unit = value.eyebrow.components(separatedBy: " · ").dropFirst().first.map { LocalizedStringKey($0) }
        switch value.metric {
        case .distance: return FactStrip.Fact("Distance", value: value.text, unit: unit)
        case .pace: return FactStrip.Fact("Avg pace", value: value.text, unit: unit)
        case .speed: return FactStrip.Fact("Avg speed", value: value.text, unit: unit)
        default: return FactStrip.Fact("Time", value: value.text)
        }
    }
}

// MARK: - Devices

/// The device manager as the workout screens show it: a sheet inside the journey's cover, so it never presents a second
/// full-screen surface.
struct WorkoutDevicesSheet: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            DevicesView(onClose: onClose)
                .background(StrandPalette.appCanvas.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .sheetScreenScaffoldEnvironment()
        }
        .drillInDestinationEnvironment()
    }
}
#endif
