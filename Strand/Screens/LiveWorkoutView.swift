import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Live workout mode (#238) — the in-exercise screen: a big live heart rate, the current HR zone,
/// elapsed time, and live effort building, all from the SAME live feed and scorers the rest of the
/// app uses (no invented numbers). Presented while a manual workout is active, entered from the
/// Start-workout control on Live. End stops the workout and dismisses.
///
/// Live HR is the smoothed `AppModel.bpm`; the zone is derived from the user's HR-max via the shared
/// `HRZones` model; elapsed time ticks from the workout's start (a TimelineView, no manual Timer);
/// effort is the running `ActiveWorkout.liveStrain` (StrainScorer over the captured window).
struct LiveWorkoutView: View {
    @EnvironmentObject private var model: AppModel
    // PERF (scroll/recompose): this screen deliberately does NOT observe `LiveState` directly. A connected
    // strap publishes `LiveState` ~1 Hz (HR + each R-R packet, plus sensor frames), and an
    // `@EnvironmentObject live` here would invalidate the WHOLE body on every tick — the HR hero, effort
    // gauge, zone rail and stats grid all re-evaluate even though they read from `model` (smoothed bpm +
    // scorers), not `live`. The only region that genuinely needs `live` is the additive sensor readout
    // (speed / cadence / power), so it's extracted into the small `SensorRowIfPresent` leaf below that
    // owns its OWN `@EnvironmentObject live`. A sensor/R-R packet now re-renders just that row, not the
    // hero. (`model.live` is its own ObservableObject, so the leaf's `live` is the one that sees the
    // @Published changes — exactly as the parent's direct observation did before.)
    let onClose: () -> Void

    /// Strain display scale (#268) — routes the live Strain read-out through the shared helper so it
    /// matches every other surface. Display-only; the captured value stays stored 0–100.
    @AppStorage(UnitPrefs.effortScaleKey) private var effortScaleRaw = EffortScale.whoop.rawValue
    private var effortScale: EffortScale { UnitPrefs.resolveEffortScale(effortScaleRaw) }

    /// Keep the screen awake while recording (#703). Opt-in, default off; the toggle lives in Settings.
    /// Read here so we can hold the idle timer off only while this in-exercise screen is up and release it
    /// the moment it leaves, which is exactly the bounded usage Apple asks for. iOS-only (no-op on Mac).
    @AppStorage("workoutKeepScreenOn") private var keepScreenOn = false

    private var zoneSet: HRZoneSet { HRZones.zones(maxHR: Double(model.profile.hrMax)) }
    private var zone: Int { model.bpm.map { zoneSet.zoneNumber(forBPM: Double($0)) } ?? 0 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                header.staggeredAppear(index: 0)
                timerBlock.staggeredAppear(index: 1)
                PaperLiveWorkoutStatsGrid(recorder: model.gpsRecorder)
                    .staggeredAppear(index: 2)
                PaperWorkoutMapCard(recorder: model.gpsRecorder)
                    .staggeredAppear(index: 3)
                paperHeartRateCard.staggeredAppear(index: 4)
                controlRow
                // Existing Strain and zone reads remain available below the S25 composition.
                effortGauge
                zoneRail
            }
            .screenPadding()
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // If the workout ended elsewhere (process restart cleared it), close the screen.
        .onChangeCompat(of: model.activeWorkout == nil) { gone in if gone { onClose() } }
        // Arm the realtime HR stream while the in-exercise screen is up (#681). On a WHOOP 5/MG live HR
        // only flows while the puffin realtime stream is armed; previously only the Live tab armed it, so
        // starting a manual workout straight from Workouts (Live never opened) left `model.bpm == nil` —
        // captureWorkoutSample bailed on every sample and endWorkout silently discarded the empty
        // session. Ref-counted in AppModel, so when this sheet sits over an already-armed Live tab the
        // two balance and neither disarms the other (mirrors Android LiveWorkoutScreen's DisposableEffect
        // requestRealtimeHr/releaseRealtimeHr). Balanced: one start on appear, one stop on disappear.
        .onAppear {
            model.startRealtimeHR()
            // Hold the display awake for the session only if the user opted in (#703).
            if keepScreenOn { ScreenIdle.keepAwake(true) }
        }
        .onDisappear {
            model.stopRealtimeHR()
            // Always release on the way out so the system idle timer resumes. Even if the toggle was
            // flipped off mid-workout, this clears any hold we placed.
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

    private var paperHeartRateCard: some View {
        let values = model.activeWorkout?.samples.suffix(360).map { Double($0.bpm) } ?? []
        return PaperCard {
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
                    Sparkline(values: values,
                              gradient: Gradient(colors: [StrandPalette.chargeAccent,
                                                          StrandPalette.chargeAccent]),
                              range: 100...180, lineWidth: 2,
                              // D15: Sparkline's shared area wash is 6% alpha, safely under 12%.
                              showsArea: true, showsHead: false, showsHover: false)
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

    private var controlRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.open.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 44, height: 44)
                .background(StrandPalette.card, in: Circle())
                .overlay(Circle().strokeBorder(StrandPalette.cardBorder, lineWidth: 1))
                .accessibilityLabel("Screen controls unlocked")
            // C9 limitation branch: preserve the reference's three-part geometry
            // without inventing a Paused state while samples continue recording.
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
            endButton
        }
    }

    private var heroHeartRate: some View {
        let tint = zone >= 1 ? StrandPalette.hrZoneColor(zone) : StrandPalette.effortColor
        return NoopCard(padding: NoopMetrics.space6, tint: StrandPalette.effortColor) {
            VStack(spacing: NoopMetrics.space2) {
                Text("HEART RATE")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                // The big live HR ticks up to its new reading on each beat — crisp, flat, no halo.
                if let bpm = model.bpm {
                    CountUpText(value: Double(bpm),
                                format: { "\(Int($0.rounded()))" },
                                font: StrandFont.rounded(80, weight: .semibold),
                                color: tint)
                } else {
                    Text("—")
                        .font(StrandFont.rounded(80, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text("bpm").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Text(zone >= 1 ? "Zone \(zone) · \(Self.zoneName(zone))" : "Below Zone 1")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(tint)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// The accumulating Strain, on the same layered StrainGauge the rest of the app uses — the live
    /// `liveStrain` is on NOOP's 0–100 Strain axis. The gauge renders on the user's selected Strain
    /// scale (#313): 0–100 native, or rescaled to WHOOP's 0–21, matching the rest of the app's
    /// read-outs (mirrors TodayView's effort hero). Display-only — the captured value stays 0–100.
    private var effortGauge: some View {
        let strain = model.activeWorkout?.liveStrain ?? 0
        return NoopCard(padding: NoopMetrics.cardInnerPadding, tint: StrandPalette.effortColor) {
            VStack(spacing: NoopMetrics.rowSpacing) {
                Text("STRAIN BUILDING")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.effortColor)
                StrainGauge(
                    strain: UnitFormatter.effortValue(strain, scale: effortScale),
                    outOf: 21,
                    diameter: 150, lineWidth: 14, showsHover: false,
                    valueFormat: { _ in UnitFormatter.effortDisplay(strain, scale: effortScale) }
                )
                .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var zoneRail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HR ZONE")
                .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            HStack(spacing: 6) {
                ForEach(1...5, id: \.self) { z in
                    let active = z == zone
                    let color = StrandPalette.hrZoneColor(z)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(active ? color : color.opacity(0.18))
                        .frame(height: active ? 44 : 34)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(active ? color : StrandPalette.hairline, lineWidth: 1)
                        )
                        .overlay(
                            Text("Z\(z)")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(active ? StrandPalette.surfaceBase : StrandPalette.textTertiary)
                        )
                }
            }
            if let band = zoneSet.zones.first(where: { $0.number == zone }) {
                Text("Zone \(zone): \(Int(band.lower))-\(Int(band.upper)) bpm (\(Int(band.lowerPct * 100))-\(Int(band.upperPct * 100))% max HR)")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            } else {
                Text("Warming up. Keep moving to climb into Zone 1.")
                    .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    private var statsGrid: some View {
        let w = model.activeWorkout
        return HStack(spacing: NoopMetrics.gap) {
            stat(String(localized: "AVG"), (w?.avgHr ?? 0) > 0 ? "\(w!.avgHr)" : "—",
                 tint: (w?.avgHr ?? 0) > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
            stat(String(localized: "PEAK"), (w?.peakHr ?? 0) > 0 ? "\(w!.peakHr)" : "—",
                 tint: (w?.peakHr ?? 0) > 0 ? StrandPalette.metricRose : StrandPalette.textPrimary)
            stat(String(localized: "STRAIN"), UnitFormatter.effortDisplay(w?.liveStrain ?? 0, scale: effortScale),
                 tint: StrandPalette.strainColor(w?.liveStrain ?? 0))
        }
    }

    private func stat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        NoopCard(padding: 14, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value)
                    .font(StrandFont.number(26))
                    .foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var endButton: some View {
        NoopButton("Finish", systemImage: "flag.checkered", kind: .destructive) {
            model.endWorkout()
            onClose()
        }
    }

    // MARK: - Helpers

    private static func elapsed(since start: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private static func zoneName(_ zone: Int) -> String {
        switch zone {
        case 1: return String(localized: "Recovery")
        case 2: return String(localized: "Fat burn")
        case 3: return String(localized: "Aerobic")
        case 4: return String(localized: "Threshold")
        case 5: return String(localized: "Maximum")
        default: return ""
        }
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

    private func metric(_ label: String, _ value: String, _ unit: String?,
                        tint: Color = StrandPalette.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(StrandFont.micro.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(StrandFont.metricValue).foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.65)
                if let unit {
                    Text(unit).font(StrandFont.micro).foregroundStyle(StrandPalette.textTertiary)
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
        let amount = unitSystem == .imperial ? recorder.distanceM / 1609.344 : recorder.distanceM / 1000
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
                                                 ? StrandPalette.link : StrandPalette.textTertiary)
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

// MARK: - Live-observing leaf (scroll-stutter isolation)

/// Additive readout for a connected standard fitness sensor (a footpod / bike speed-cadence sensor /
/// power meter) feeding RSC/CSC/CPS ALONGSIDE heart rate. Only the fields the sensor actually sent
/// render — each tile is dropped when its value is absent, and the WHOLE block (row + entrance stagger)
/// is hidden when nothing is present (`live.hasSensorMetrics`), so a plain HR-only workout looks exactly
/// as before. Honest units: speed km/h, cadence per-minute (steps for running / rpm for cycling), power
/// watts. Tinted with the Strain world so it reads as part of the hero, not a competing accent. Nothing
/// here touches HR / zone / effort.
///
/// This is a standalone leaf that owns its OWN `@EnvironmentObject live` (the parent `LiveWorkoutView`
/// no longer observes `LiveState`), so an incoming sensor / R-R packet re-renders only this row, not the
/// HR hero / effort gauge / zone rail above. The gate, layout and `staggeredAppear(index: 5)` are
/// preserved verbatim, so the rendered output is byte-for-byte the previous inline code.
private struct SensorRowIfPresent: View {
    @EnvironmentObject private var live: LiveState

    var body: some View {
        if live.hasSensorMetrics {
            let speed = LiveState.formatSpeedKmh(live.sensorSpeedKmh)
            let cadence = LiveState.formatCadence(live.sensorCadence)
            let power = LiveState.formatPowerWatts(live.sensorPowerWatts)
            VStack(alignment: .leading, spacing: 8) {
                Text("SENSOR")
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                HStack(spacing: NoopMetrics.gap) {
                    if let speed { stat(String(localized: "SPEED"), "\(speed) km/h", tint: StrandPalette.effortColor) }
                    if let cadence { stat(String(localized: "CADENCE"), "\(cadence)/min", tint: StrandPalette.effortColor) }
                    if let power { stat(String(localized: "POWER"), "\(power) W", tint: StrandPalette.effortColor) }
                }
            }
            .staggeredAppear(index: 5)
        }
    }

    /// Same metric tile as `LiveWorkoutView.stat` (the HR stats grid) — duplicated here, unchanged, so the
    /// leaf is self-contained and the rendered tile is identical.
    private func stat(_ title: String, _ value: String, tint: Color = StrandPalette.textPrimary) -> some View {
        NoopCard(padding: 14, tint: tint) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(StrandFont.overline).tracking(StrandFont.overlineTracking)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text(value)
                    .font(StrandFont.number(26))
                    .foregroundStyle(tint)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
