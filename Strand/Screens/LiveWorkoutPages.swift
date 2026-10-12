#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Heart page

/// The heart on its own: the reading large in its zone's colour with the zone beside it, the wearer's three zones as one row
/// (the zone the heart is in lit, the time spent in each under its bar), and strain and calories under them. With no strap it
/// says so and offers Manage devices. The heart-rate trace the page used to carry is not here: the page is one glance.
struct LiveHeartPage: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @ObservedObject var profile: ProfileStore
    let live: LiveState
    var isVisible = true
    let onManageDevices: () -> Void
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize

    private typealias Glance = LiveWorkoutGlance

    /// Air between the figure and the zones, and between the zones and strain.
    private static let heroGap: CGFloat = 34
    private static let zoneGap: CGFloat = 30
    /// What the no-strap line and its button add.
    private static let noStrapHeight: CGFloat = 76

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder, live: live, isVisible: isVisible) { signals in
            content(signals)
        }
    }

    /// The page's height at scale 1.
    static func naturalHeight(accessibilitySize: Bool, noStrap: Bool) -> CGFloat {
        LiveNumeralMetrics.digitHeight(LiveNumeralMetrics.focusPointSize) + heroGap
            + LiveZoneRow.height(scale: 1, accessibilitySize: accessibilitySize) + zoneGap
            + 2 * LiveNumeralMetrics.digitHeight(LiveNumeralMetrics.secondaryPointSize) + LiveNumeralMetrics.secondaryGap
            + (noStrap ? noStrapHeight : 0) + 4
    }

    @ViewBuilder private func content(_ signals: LiveWorkoutSignals.Snapshot) -> some View {
        let thresholds = ProfileStore.hrZoneThresholds(override: profile.hrMaxOverride, age: profile.age)
        let zones = LiveWorkoutZones(bpm: workout.currentBPM, averageHR: workout.avgHr, thresholds: thresholds)
        let input = LiveWorkoutTiles.Input(
            sport: workout.sport, tracksRoute: false, bpm: workout.currentBPM, calories: workout.liveCalories,
            averageHR: workout.avgHr, peakHR: workout.peakHr, imperial: unitSystemRaw == UnitSystem.imperial.rawValue)
        let strain = workout.liveStrainState
        let value = { (metric: Glance.Metric) in
            Glance.value(metric, input: input, elapsed: 0, strain: strain, zoneWord: zones.word(for: metric))
        }
        let noStrap = signals.strapNeverConnected && workout.currentBPM == nil
        let paused = workout.isPaused

        LivePageFrame(naturalHeight: Self.naturalHeight(accessibilitySize: typeSize.isAccessibilitySize, noStrap: noStrap)) { scale in
            VStack(alignment: .leading, spacing: 0) {
                LiveWorkoutFigure(value: value(.heartRate), size: .focus, scale: scale, isPaused: paused, signals: signals,
                                  zone: zones.currentZone)
                LiveZoneRow(seconds: workout.personalZoneSeconds, thresholds: thresholds, currentZone: zones.currentZone,
                            isPaused: paused, scale: scale)
                    .padding(.top, Self.heroGap * scale)
                LiveWorkoutFigure(value: value(.strain), scale: scale, isPaused: paused, signals: signals)
                    .padding(.top, Self.zoneGap * scale)
                LiveWorkoutFigure(value: value(.calories), scale: scale, isPaused: paused, signals: signals)
                    .padding(.top, LiveNumeralMetrics.secondaryGap * scale)
                if noStrap { noStrapLine.padding(.top, 18) }
            }
        }
    }

    private var noStrapLine: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No strap connected")
                .foregroundStyle(LivePalette.secondaryText)
                .liveText(15, weight: .medium, maxSize: 20, lines: 2)
            LiveCapsuleButton(String(localized: "Manage devices"), action: onManageDevices)
                .fixedSize(horizontal: true, vertical: false)
        }
    }
}

// MARK: - Route page

/// The route so far on a large rounded map, with the distance, pace (or speed) and time under it in the same figures as the
/// other pages. Before the first fix it says what it is waiting for. The map is built only while the page is showing or next
/// to the one that is, so a swipe finds it ready and a page two away costs nothing. Apple's logo and Legal link sit on the
/// map's own bottom edge, clear of everything.
struct LiveRoutePage: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    let live: LiveState
    var isVisible = true
    var isNear = true
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize

    private typealias Glance = LiveWorkoutGlance

    /// The room between the map and the first figure.
    private static let mapGap: CGFloat = 22
    /// The map is never shorter than this at scale 1 before the figures give way.
    private static let minimumMap: CGFloat = 180

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder, live: live, isVisible: isVisible) { signals in
            if isVisible {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    page(signals: signals, elapsed: workout.activeElapsed(at: context.date))
                }
            } else {
                page(signals: signals, elapsed: workout.activeElapsed(at: Date()))
            }
        }
    }

    /// The scale of the figures and the height of the map for a page `region` tall: the figures give way (to the smallest
    /// scale) before the map is smaller than `minimumMap`.
    static func fit(region: CGFloat, band: CGFloat) -> (scale: CGFloat, map: CGFloat, scrolls: Bool) {
        let figures = LiveNumeralMetrics.stackHeight(rows: 3, hasFocus: false)
        let room = max(0, region - band - mapGap)
        let wanted = (room - minimumMap) / figures
        let scale = min(1, max(LiveNumeralMetrics.minimumScale, wanted))
        let map = max(minimumMap * 0.6, room - figures * scale)
        return (scale, map, wanted < LiveNumeralMetrics.minimumScale)
    }

    private func page(signals: LiveWorkoutSignals.Snapshot, elapsed: TimeInterval) -> some View {
        GeometryReader { proxy in
            let fit = Self.fit(region: max(0, proxy.size.height - LivePageMetrics.bottomReserve),
                               band: LivePageMetrics.band(accessibility: typeSize.isAccessibilitySize))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: LivePageMetrics.band(accessibility: typeSize.isAccessibilitySize))
                    map.frame(height: fit.map)
                    figures(signals: signals, elapsed: elapsed, scale: fit.scale)
                        .padding(.top, Self.mapGap)
                }
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .topLeading)
                .screenPadding()
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var map: some View {
        mapOrWaiting
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            // The wearer's own trace is the content: it stays reachable for VoiceOver as one picture, not a map to pan.
            .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var mapOrWaiting: some View {
        if recorder.routeSegments.contains(where: { $0.count >= 2 }) {
            if isNear {
                WorkoutRouteMap(segments: recorder.routeSegments, showsEndpoints: false)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Live GPS route")
            } else {
                LivePalette.fill
            }
        } else {
            VStack(spacing: NoopMetrics.space2) {
                Image(systemName: recorder.pointCount > 0 ? "location.fill" : "location.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(recorder.pointCount > 0 ? LivePalette.mint : LivePalette.secondaryText)
                Text(recorder.pointCount > 0 ? "\(recorder.pointCount) GPS points recorded" : "Waiting for GPS route")
                    .foregroundStyle(LivePalette.secondaryText)
                    .liveText(15, weight: .medium, maxSize: 20, lines: 3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LivePalette.fill)
        }
    }

    private func figures(signals: LiveWorkoutSignals.Snapshot, elapsed: TimeInterval, scale: CGFloat) -> some View {
        let tracksRoute = recorder.isRecording && recorder.canRecordRoute
        let sportClass = Glance.sportClass(sport: workout.sport, tracksRoute: tracksRoute)
        let input = LiveWorkoutTiles.Input(
            sport: workout.sport, tracksRoute: tracksRoute, distanceMeters: recorder.distanceM,
            paceSecPerKm: recorder.paceSecPerKm, bpm: workout.currentBPM, calories: workout.liveCalories,
            averageHR: workout.avgHr, peakHR: workout.peakHr, imperial: unitSystemRaw == UnitSystem.imperial.rawValue)
        let strain = workout.liveStrainState
        let pace: Glance.Metric = sportClass == .routeSpeed ? .speed : .pace
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array([Glance.Metric.distance, pace, .time].enumerated()), id: \.element) { index, metric in
                LiveWorkoutFigure(value: Glance.value(metric, input: input, elapsed: elapsed, strain: strain),
                                  scale: scale, isPaused: workout.isPaused, signals: signals)
                    .padding(.top, index == 0 ? 0 : LiveNumeralMetrics.secondaryGap * scale)
            }
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
