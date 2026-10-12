#if os(iOS)
import SwiftUI
import StrandDesign
import StrandAnalytics

/// The live screen's one page: the session number the sport is about, two smaller ones, the zone the heart is in, and two
/// facts under them. Read in under a second; nothing on it moves when a signal changes (`LiveNoticeSlot` and the header
/// glyphs say so instead), and a number whose source has gone quiet steps back instead of showing as live.
struct LiveFocusPage: View {
    @ObservedObject var workout: AppModel.ActiveWorkout
    @ObservedObject var recorder: GpsWorkoutRecorder
    @ObservedObject var profile: ProfileStore
    let live: LiveState
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @Environment(\.dynamicTypeSize) private var typeSize

    private typealias Glance = LiveWorkoutGlance

    var body: some View {
        LiveWorkoutSignalReader(workout: workout, recorder: recorder, live: live) { signals in
            TimelineView(.periodic(from: .now, by: 1)) { context in
                content(signals: signals, elapsed: workout.activeElapsed(at: context.date))
            }
        }
    }

    // MARK: Content

    @ViewBuilder private func content(signals: LiveWorkoutSignals.Snapshot, elapsed: TimeInterval) -> some View {
        let tracksRoute = recorder.isRecording && recorder.canRecordRoute
        let layout = Glance.layout(for: Glance.sportClass(sport: workout.sport, tracksRoute: tracksRoute))
        let input = LiveWorkoutTiles.Input(
            sport: workout.sport, tracksRoute: tracksRoute, distanceMeters: recorder.distanceM,
            paceSecPerKm: recorder.paceSecPerKm, bpm: workout.currentBPM, calories: workout.liveCalories,
            averageHR: workout.avgHr, peakHR: workout.peakHr, imperial: unitSystemRaw == UnitSystem.imperial.rawValue)
        let strain = workout.liveStrainState
        let value = { (metric: Glance.Metric) in Glance.value(metric, input: input, elapsed: elapsed, strain: strain) }

        VStack(alignment: .leading, spacing: 0) {
            // The one flexible part: when the page has room to spare, it goes here and the number sits in the middle of it,
            // with everything else held together underneath.
            metricView(value(layout.focus), size: .focus, signals: signals)
                .frame(maxHeight: .infinity, alignment: .center)
            FlatSectionSeparator()
            secondaries(layout.secondaries.map(value), signals: signals)
            FlatSectionSeparator()
            zoneLine(layout: layout, signals: signals)
            FlatSectionSeparator()
            footer(layout.footer.map(value))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metricView(_ value: Glance.Value, size: GlanceMetricView.Size,
                            signals: LiveWorkoutSignals.Snapshot) -> some View {
        let state = state(of: value, signals: signals)
        return GlanceMetricView(
            eyebrow: value.eyebrow, value: value.text, size: size, state: state,
            micro: state == .stale ? String(localized: "no signal") : value.micro,
            spokenLabel: value.name, spokenValue: value.spoken)
    }

    /// Paused numbers are frozen (0.4); a reading whose source has gone quiet keeps its last number at 0.6. Totals and
    /// averages are never stale.
    private func state(of value: Glance.Value, signals: LiveWorkoutSignals.Snapshot) -> GlanceMetricView.State {
        if value.isMissing { return .missing }
        if workout.isPaused { return .paused }
        switch value.metric {
        case .heartRate: return signals.heartRateIsStale ? .stale : .live
        case .pace, .speed: return signals.paceIsStale ? .stale : .live
        case .time, .distance, .strain, .calories, .averageHeartRate: return .live
        }
    }

    // MARK: Secondaries

    @ViewBuilder private func secondaries(_ values: [Glance.Value], signals: LiveWorkoutSignals.Snapshot) -> some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                ForEach(values, id: \.metric) { metricView($0, size: .secondary, signals: signals) }
            }
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(values.enumerated()), id: \.element.metric) { index, item in
                    if index > 0 {
                        Rectangle().fill(StrandPalette.hairline).frame(width: 1)
                            .padding(.horizontal, NoopMetrics.space3)
                            .accessibilityHidden(true)
                    }
                    metricView(item, size: .secondary, signals: signals)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Zone

    private func zoneLine(layout: Glance.Layout, signals: LiveWorkoutSignals.Snapshot) -> some View {
        let thresholds = ProfileStore.hrZoneThresholds(override: profile.hrMaxOverride, age: profile.age)
        let bpm = workout.currentBPM
        let zone = bpm.map { thresholds.zone(for: Double($0)) }
        let paused = workout.isPaused
        let stale = signals.heartRateIsStale
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                if let zone {
                    Text(verbatim: Self.word(zone))
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(HRZoneStyle.zoneColor(zone))
                } else {
                    Text(verbatim: WidgetMetrics.missingValue)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if layout.zoneLineShowsBPM, let bpm {
                    Text(verbatim: "\(bpm)").font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                        + Text(verbatim: " bpm").font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .opacity(paused ? GlanceMetricLayout.pausedOpacity : (stale ? GlanceMetricLayout.staleOpacity : 1))
            // The rail below speaks the zone and the reading; saying them twice would only repeat.
            .accessibilityHidden(true)
            LiveZoneRail(bpm: bpm, thresholds: thresholds, isDimmed: stale && !paused, style: .bar)
                .opacity(paused ? GlanceMetricLayout.pausedOpacity : 1)
        }
    }

    private static func word(_ zone: Int) -> String {
        switch zone {
        case 0: String(localized: "Rest")
        case 1: String(localized: "Steady")
        default: String(localized: "Push")
        }
    }

    // MARK: Footer

    @ViewBuilder private func footer(_ values: [Glance.Value]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            // The same caps eyebrow the numbers above are named with, a size down.
            FactStrip(facts: values.map(fact), labelStyle: .eyebrow)
            // Strain needs ten minutes of heart rate before it is a number; until then it says when.
            if let building = values.first(where: { $0.metric == .strain && $0.isMissing }) {
                Text(verbatim: building.spoken)
                    .font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
            }
        }
        // A paused workout is a frozen one: the footer steps back with the numbers above it.
        .opacity(workout.isPaused ? GlanceMetricLayout.pausedOpacity : 1)
    }

    private func fact(_ value: Glance.Value) -> FactStrip.Fact {
        switch value.metric {
        case .strain: FactStrip.Fact("Strain", value: value.text)
        case .calories: FactStrip.Fact("Calories", value: value.text, unit: "kcal")
        case .averageHeartRate: FactStrip.Fact("Avg HR", value: value.text, unit: "bpm")
        case .time: FactStrip.Fact("Time", value: value.text)
        case .distance: FactStrip.Fact("Distance", value: value.text)
        case .pace: FactStrip.Fact("Avg pace", value: value.text)
        case .speed: FactStrip.Fact("Avg speed", value: value.text)
        case .heartRate: FactStrip.Fact("Heart rate", value: value.text, unit: "bpm")
        }
    }
}
#endif
