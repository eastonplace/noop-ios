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
        StableLiveWorkoutContent(model: model)
            .equatable()
            .overlay {
                WorkoutGoneObserver(model: model, onClose: onClose)
            }
    }
}

private struct StableLiveWorkoutContent: View, Equatable {
    let model: AppModel
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                header.staggeredAppear(index: 0)
                timerBlock.staggeredAppear(index: 1)
                PaperLiveWorkoutStatsGrid(recorder: model.gpsRecorder)
                    .staggeredAppear(index: 2)
                PaperWorkoutMapCard(recorder: model.gpsRecorder)
                    .staggeredAppear(index: 3)
                LiveWorkoutHeartCard(model: model)
                    .staggeredAppear(index: 4)
                LiveWorkoutControlRow(model: model)
                LiveWorkoutFailureMessage(model: model)
                LiveWorkoutEffortAndZone(model: model)
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

/// Per-sample heart history leaf. Its bounded 360-value projection is the only chart work performed for an
/// HR update; GPS, map, header, timer chrome, and controls are outside this observation scope.
private struct LiveWorkoutHeartCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let values = model.activeWorkout?.samples.suffix(360).map { Double($0.bpm) } ?? []
        PaperCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("HEART RATE (LAST 3 HOURS)")
                        .font(StrandFont.sectionOverline)
                        .tracking(StrandFont.sectionOverlineTracking)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer()
                    Text(model.bpm.map { "\($0) bpm" } ?? "—")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.liveRed)
                }
                if values.count > 1 {
                    Sparkline(
                        values: values,
                        gradient: Gradient(colors: [
                            StrandPalette.chargeAccent,
                            StrandPalette.chargeAccent,
                        ]),
                        range: 100...180,
                        lineWidth: 2,
                        showsArea: true,
                        showsHead: false,
                        showsHover: false
                    )
                    .frame(height: 90)
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
            Image(systemName: "lock.open.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 44, height: 44)
                .background(StrandPalette.card, in: Circle())
                .overlay(Circle().strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
                .accessibilityLabel("Screen controls unlocked")
            HStack(spacing: 7) {
                Image(systemName: "record.circle")
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

private struct LiveWorkoutEffortAndZone: View {
    @ObservedObject var model: AppModel
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue

    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }
    private var zoneSet: HRZoneSet { HRZones.zones(maxHR: Double(model.profile.hrMax)) }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        effortGauge
        zoneRail
    }

    private var effortGauge: some View {
        NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.effortColor) {
            VStack(spacing: NoopMetrics.rowSpacing) {
                switch model.activeWorkout?.liveStrainState
                    ?? .building(readings: 0, coverageSeconds: 0)
                {
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

    private var zoneRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HR ZONE")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { value in
                    let active = value == zone
                    let color = StrandPalette.hrZoneColor(value)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? color : color.opacity(0.18))
                        .frame(height: active ? 44 : 34)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(active ? color : StrandPalette.hairline, lineWidth: 1))
                        .overlay(Text("Z\(value)")
                            .font(StrandFont.captionNumber)
                            .foregroundStyle(active
                                ? StrandPalette.surfaceBase
                                : StrandPalette.textTertiary))
                }
            }
            if let band = zoneSet.zones.first(where: { $0.number == zone }) {
                Text("Zone \(zone): \(Int(band.lower))-\(Int(band.upper)) bpm (\(Int(band.lowerPct * 100))-\(Int(band.upperPct * 100))% max HR)")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("Warming up. Keep moving to climb into Zone 1.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private static func elapsedCoverage(_ seconds: Int) -> String {
        String(format: "%d:%02d", max(0, seconds) / 60, max(0, seconds) % 60)
    }
}

private struct PaperLiveWorkoutStatsGrid: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    @ObservedObject var recorder: GpsWorkoutRecorder
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }

    var body: some View {
        PaperCard(padding: 0) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 3), spacing: 0) {
                metric("DISTANCE", distanceText, nil)
                metric("PACE", paceText, unitSystem == .imperial ? "/mi" : "/km")
                metric("HEART RATE", model.bpm.map(String.init) ?? "—", "bpm", tint: StrandPalette.liveRed)
                metric("CALORIES", "—", "kcal")
                metric("CADENCE", live.sensorCadence.map { "\(Int($0.rounded()))" } ?? "—", "spm")
                metric("ELEVATION", "—", unitSystem == .imperial ? "ft" : "m")
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
        PaperCard(padding: 0) {
            ZStack(alignment: .bottomLeading) {
                Group {
                    if recorder.routePoints.count >= 2 {
                        WorkoutRouteMap(points: recorder.routePoints, showsEndpoints: false)
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
