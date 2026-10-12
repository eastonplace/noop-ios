#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// The live screen's first page: the number the sport is about, large, and under it three smaller ones (time, pace and heart
/// rate for a run). One figure per metric in its own colour with its unit beside it; no labels over the numbers, no rules
/// between them. Read in under a second: nothing on it moves when a signal changes (the notice under the header and the
/// glyphs say so instead), and a number whose source has gone quiet steps back instead of showing as live.
struct LiveFocusPage: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @ObservedObject var profile: ProfileStore
    let live: LiveState
    /// Only the page being looked at has a clock; the others draw once and wait to be redrawn.
    var isVisible = true
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    /// The big number the wearer chose, one per kind of sport (see `LiveWorkoutGlance.FocusPreference`).
    @AppStorage(LiveWorkoutGlance.FocusPreference.key(for: .routePace)) private var focusRoutePace = ""
    @AppStorage(LiveWorkoutGlance.FocusPreference.key(for: .routeSpeed)) private var focusRouteSpeed = ""
    @AppStorage(LiveWorkoutGlance.FocusPreference.key(for: .indoor)) private var focusIndoor = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private typealias Glance = LiveWorkoutGlance

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder, live: live, isVisible: isVisible) { signals in
            if isVisible {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(signals: signals, elapsed: workout.activeElapsed(at: context.date))
                }
            } else {
                content(signals: signals, elapsed: workout.activeElapsed(at: Date()))
            }
        }
    }

    // MARK: Chosen focus

    private func chosenFocus(for sportClass: Glance.SportClass) -> Glance.Metric? {
        let raw: String
        switch sportClass {
        case .routePace: raw = focusRoutePace
        case .routeSpeed: raw = focusRouteSpeed
        case .indoor: raw = focusIndoor
        }
        return Glance.FocusPreference.metric(from: raw)
    }

    private func choose(_ metric: Glance.Metric, for sportClass: Glance.SportClass) {
        let apply = {
            switch sportClass {
            case .routePace: focusRoutePace = metric.rawValue
            case .routeSpeed: focusRouteSpeed = metric.rawValue
            case .indoor: focusIndoor = metric.rawValue
            }
        }
        if reduceMotion { apply() } else { withAnimation(.easeInOut(duration: 0.2)) { apply() } }
        StrandHaptic.selection.play()
    }

    // MARK: Content

    @ViewBuilder private func content(signals: LiveWorkoutSignals.Snapshot, elapsed: TimeInterval) -> some View {
        let tracksRoute = recorder.isRecording && recorder.canRecordRoute
        let sportClass = Glance.sportClass(sport: workout.sport, tracksRoute: tracksRoute)
        let layout = Glance.layout(for: sportClass, chosenFocus: chosenFocus(for: sportClass))
        let thresholds = ProfileStore.hrZoneThresholds(override: profile.hrMaxOverride, age: profile.age)
        let input = LiveWorkoutTiles.Input(
            sport: workout.sport, tracksRoute: tracksRoute, distanceMeters: recorder.distanceM,
            paceSecPerKm: recorder.paceSecPerKm, bpm: workout.currentBPM, calories: workout.liveCalories,
            averageHR: workout.avgHr, peakHR: workout.peakHr, imperial: unitSystemRaw == UnitSystem.imperial.rawValue)
        let strain = workout.liveStrainState
        let zones = LiveWorkoutZones(bpm: workout.currentBPM, averageHR: workout.avgHr, thresholds: thresholds)
        let value = { (metric: Glance.Metric) in
            Glance.value(metric, input: input, elapsed: elapsed, strain: strain, zoneWord: zones.word(for: metric))
        }

        LivePageFrame(naturalHeight: LiveNumeralMetrics.stackHeight(rows: layout.stack.count)) { scale in
            VStack(alignment: .leading, spacing: 0) {
                figure(value(layout.focus), size: .focus, scale: scale, signals: signals, zone: zones.zone(for: layout.focus))
                    .contentShape(Rectangle())
                    // Press and hold the big number to choose which number it is.
                    .contextMenu {
                        Section("Make focus") {
                            ForEach(Glance.FocusPreference.choices(for: sportClass), id: \.self) { metric in
                                Button { choose(metric, for: sportClass) } label: {
                                    if metric == layout.focus {
                                        Label(Glance.name(of: metric), systemImage: "checkmark")
                                    } else {
                                        Text(verbatim: Glance.name(of: metric))
                                    }
                                }
                            }
                        }
                    }
                ForEach(Array(layout.stack.enumerated()), id: \.element) { index, metric in
                    figure(value(metric), size: .secondary, scale: scale, signals: signals, zone: zones.zone(for: metric))
                        .padding(.top, (index == 0 ? LiveNumeralMetrics.focusGap : LiveNumeralMetrics.secondaryGap) * scale)
                }
            }
        }
    }

    private func figure(_ value: Glance.Value, size: LiveNumeral.Size, scale: CGFloat,
                        signals: LiveWorkoutSignals.Snapshot, zone: Int?) -> some View {
        LiveWorkoutFigure(value: value, size: size, scale: scale, isPaused: workout.isPaused, signals: signals, zone: zone)
    }

    static func word(_ zone: Int) -> String { LiveZoneRow.word(zone) }
}

/// The zone the heart is in, now and on average, for the colour and the name beside a heart-rate figure.
struct LiveWorkoutZones {
    let bpm: Int?
    let averageHR: Int
    let thresholds: HRZoneStyle.Thresholds

    var currentZone: Int? { bpm.map { thresholds.zone(for: Double($0)) } }

    func zone(for metric: LiveWorkoutGlance.Metric) -> Int? {
        switch metric {
        case .heartRate: currentZone
        case .averageHeartRate: averageHR > 0 ? thresholds.zone(for: Double(averageHR)) : nil
        default: nil
        }
    }

    /// "Push": the word that goes with the live reading (the average has none: it is "Avg").
    func word(for metric: LiveWorkoutGlance.Metric) -> String? {
        metric == .heartRate ? currentZone.map(LiveZoneRow.word) : nil
    }
}
#endif
