import Combine
import SwiftUI
import Foundation
import AVFoundation
import StrandDesign
import StrandAnalytics

/// HRV haptic breathing biofeedback trainer — Strand's flagship novel feature, now a closed-loop
/// biofeedback instrument with three layers (v5 "the strap that breathes you down").
///
/// The strap both *measures* HRV (via R-R intervals) and *buzzes* (haptic strap motor), so we can pace
/// the user's breath with a felt cue and watch their HRV respond in real time — and now also *find* the
/// user's personal resonance pace (L1) and offer a below-HR "Calm me" metronome (L2). A passive stress
/// check-in card (L3) surfaces when the shipped StressOnsetDetector fires. All layers are opt-in,
/// user-stoppable, and quiet-hours-aware.
///
/// Mode switch:
///  • **Breathe** — the shipped fixed-pace trainer (presets + the locked resonance pill), unchanged.
///  • **Resonance** — the one-time "find your pace" sweep + the dated result card.
///  • **Calm me** — the L2 below-HR relaxation metronome.
///
/// Public entry point keeps its zero-arg init (every existing call site — RootView, RootTabView,
/// StressView — constructs `BreathingView()`), then defers to `BreathingContent` once the environment's
/// `AppModel`/`LiveState` are available so the `BiofeedbackController` `@StateObject` can be built from
/// them. The L3 `StressNudgeCenter` is OPTIONAL via the environment: Wave 3 injects a shared instance;
/// absent that we fall back to a local one, so the view always compiles + the card surface always exists.
struct BreathingView: View {
    var body: some View { BreathingContent() }
}

private struct BreathingContent: View {

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var live: LiveState
    /// Reduce Motion hides the moving timeline cursor; the phase word and haptics still cue the breath.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var timelineHeight: CGFloat = 70
    @ScaledMetric(relativeTo: .title3) private var readoutValueSize: CGFloat = 20
    @ScaledMetric(relativeTo: .subheadline) private var modeFontSize: CGFloat = 14
    @ScaledMetric(relativeTo: .subheadline) private var modeChipHeight: CGFloat = 34

    /// The L1/L2 session controller (walks the engines, fires the buzz path). View-owned, created lazily
    /// from the environment model + live state on first appear (a `@StateObject` can't read the
    /// environment at init, so we build it in `.onAppear`). Self-contained — the spec's view-specific
    /// controller; it never edits the shared AppModel.
    @StateObject private var controllerBox = ControllerBox()
    /// The L3 passive-nudge surface — Wave 3 injects a shared instance; this local fallback keeps the
    /// card surface present whether or not central wiring has landed.
    @StateObject private var fallbackNudge = StressNudgeCenter()
    @Environment(\.stressNudgeCenter) private var injectedNudge

    private var controller: BiofeedbackController { controllerBox.controller(model: model, live: live) }
    private var nudgeCenter: StressNudgeCenter { injectedNudge ?? fallbackNudge }

    // MARK: Mode

    private enum Mode: Hashable, CaseIterable {
        case breathe, resonance, calm
        var label: String {
            switch self {
            case .breathe:   return String(localized: "Breathe")
            case .resonance: return String(localized: "Resonance")
            case .calm:      return String(localized: "Calm me")
            }
        }
    }
    @State private var mode: Mode = .breathe

    // MARK: Pace presets

    private enum Pace: Hashable {
        case relax          // 4s inhale / 6s exhale
        case coherence      // 5.5s / 5.5s
        case box            // 4s / 4s
        case resonance      // the user's locked pace (br/min)

        var label: String {
            switch self {
            case .relax:      return String(localized: "Relax 4-6")
            case .coherence:  return String(localized: "Coherence 5.5")
            case .box:        return String(localized: "Box 4-4")
            case .resonance:  return String(localized: "Resonance")
            }
        }

        /// Inhale seconds — for `.resonance` it derives from the locked bpm at a 40:60 inhale:exhale split.
        func inhale(lockedBpm: Double?) -> Double {
            switch self {
            case .relax:     return 4.0
            case .coherence: return 5.5
            case .box:       return 4.0
            case .resonance:
                let cycle = 60.0 / (lockedBpm ?? ResonanceEngine.fallbackBpm)
                return cycle * BreathPacer.defaultInhaleFraction
            }
        }

        func exhale(lockedBpm: Double?) -> Double {
            switch self {
            case .relax:     return 6.0
            case .coherence: return 5.5
            case .box:       return 4.0
            case .resonance:
                let cycle = 60.0 / (lockedBpm ?? ResonanceEngine.fallbackBpm)
                return cycle * (1 - BreathPacer.defaultInhaleFraction)
            }
        }

        func cycle(lockedBpm: Double?) -> Double { inhale(lockedBpm: lockedBpm) + exhale(lockedBpm: lockedBpm) }
        func bpm(lockedBpm: Double?) -> Double { 60.0 / cycle(lockedBpm: lockedBpm) }

        func tagline(lockedBpm: Double?) -> String {
            switch self {
            case .relax:     return String(localized: "Long exhale · downshift to rest")
            case .coherence: return String(localized: "Equal breath · ~5.5 br/min coherence")
            case .box:       return String(localized: "Square breath · steady focus")
            case .resonance:
                return String(localized: "Your locked pace · \(String(format: "%.1f", lockedBpm ?? ResonanceEngine.fallbackBpm)) br/min")
            }
        }
    }

    private enum Phase { case inhale, exhale }

    // MARK: State (fixed-pace Breathe — unchanged behaviour)

    @State private var pace: Pace = .coherence
    @State private var running = false

    /// 0 = fully contracted, 1 = fully expanded. Drives the orb scale.
    @State private var orbProgress: CGFloat = 0
    @State private var phase: Phase = .inhale
    @State private var phaseDeadline: Date = .distantFuture

    @State private var sessionSeconds: Int = 0
    @State private var breathCount: Int = 0

    /// Rolling buffer of the most recent R-R intervals (ms) for RMSSD.
    @State private var rrBuffer: [Int] = []
    @State private var rmssd: Double? = nil

    @State private var baselineRmssd: Double? = nil
    @State private var sessionRmssdSum: Double = 0
    @State private var sessionRmssdCount: Int = 0
    @State private var sessionRmssdPeak: Double = 0
    @State private var endedOutcome: String? = nil

    @AppStorage("breathe.lastOutcome") private var lastStoredOutcome = ""

    /// Opt-in audio pacer — a soft tone at each phase change (rising on the inhale, falling on the
    /// exhale). Default OFF (manual-first). The tones go through an ambient session category, so the
    /// iOS silent switch mutes them like any other ambient sound. Persists across launches.
    @AppStorage("breathe.audioCues") private var audioCues = false
    /// The on-device tone player. View-owned, lazily wired the first time the pacer is enabled, torn
    /// down on disappear so we never hold the audio session when off-screen.
    @StateObject private var tonePlayer = BreathTonePlayer()

    private let phaseTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()
    private let secondTimer = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    private let rrWindow = 30

    /// The user's locked resonance pace, read fresh each render (set by the sweep).
    private var lockedBpm: Double? { BiofeedbackPrefs.lockedPace }

    var body: some View {
        ScreenScaffold(title: "Breathe",
                       subtitle: "Haptic-paced breathing · find your pace · calm down",
                       // Liquid finish: the same full-bleed day-of-sky backdrop Today + the other liquid
                       // tabs carry, so Breathe sits in one atmosphere.
                       topBackground: nil,
                       usesCompactUtilityHeader: true) {

            modeSwitch
            StressCheckInCard(center: nudgeCenter) { startOneMinuteCue() }

            switch mode {
            case .breathe:   breatheMode
            case .resonance: ResonanceModeView(controller: controller, live: live, lockedBpm: lockedBpm)
            case .calm:      CalmModeView(controller: controller, live: live, model: model)
            }
        }
        .onReceive(phaseTimer) { now in
            guard running else { return }
            advance(now: now)
        }
        .onReceive(secondTimer) { _ in
            guard running else { return }
            sessionSeconds += 1
        }
        .onChangeCompat(of: live.rr) { rr in
            ingest(rr)
        }
        .onChangeCompat(of: pace) { _ in
            if running { armPhase(.inhale, from: Date(), buzz: false) }
        }
        .onChangeCompat(of: mode) { _ in
            // Leaving a mode stops any session it owns so two clocks never run at once.
            if running { stop() }
            controller.stop()
        }
        .onChangeCompat(of: audioCues) { on in
            // Spin the audio engine up the moment the user opts in (so the first phase tone isn't
            // swallowed by start-up latency); tear it back down when they switch it off.
            on ? tonePlayer.activate() : tonePlayer.deactivate()
        }
        .onAppear {
            controllerBox.prepare(model: model, live: live)
            if audioCues { tonePlayer.activate() }
        }
        .onDisappear { stop(); controller.stop(); tonePlayer.deactivate() }
    }

    // MARK: - Mode switch

    private var modeSwitch: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NoopMetrics.space2))
            : AnyLayout(HStackLayout(spacing: NoopMetrics.space2))
        return layout {
            ForEach(Mode.allCases, id: \.self) { item in
                Button {
                    mode = item
                } label: {
                    Text(verbatim: item.label)
                        .font(StrandFont.sized(modeFontSize, weight: mode == item ? .bold : .semibold))
                        .foregroundStyle(mode == item ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, NoopMetrics.space2)
                        .padding(.vertical, typeSize.isAccessibilitySize ? NoopMetrics.space2 : 0)
                        .frame(maxWidth: .infinity, minHeight: modeChipHeight)
                        .background(mode == item ? StrandPalette.inset : .clear,
                                    in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(mode == item ? StrandPalette.hairlineStrong : StrandPalette.pillStroke,
                                              lineWidth: 1)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(mode == item ? .isSelected : [])
                .accessibilityIdentifier("breathe.mode.\(String(describing: item))")
            }
        }
        .segmentedPillTint(nil)
        .strandHaptic(.selection, trigger: mode)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Breathe mode")
    }

    // MARK: - Breathe mode (the shipped fixed-pace trainer)

    @ViewBuilder private var breatheMode: some View {
        statusRow
        breathTimeline
        sessionReadout
        readoutRow
        pacePills
        audioCueToggle
        controlRow
        coherenceCard
        if let line = outcomeLine { outcomeCard(line) }
        if !live.bonded { hapticHint }
    }

    /// Start a one-minute haptic breathing cue at the user's locked resonance pace (or 5.5 fallback) —
    /// the L3 card's "Breathe now" action. Switches to Resonance/Breathe context and runs the controller.
    private func startOneMinuteCue() {
        if running { stop() }
        let bpm = lockedBpm ?? ResonanceEngine.fallbackBpm
        let cycles = max(1, Int((60.0 * bpm / 60.0).rounded()))   // ~1 minute of breaths
        controller.startResonanceSession(bpm: bpm, cycles: cycles)
    }

    // MARK: - Status row

    private var statusRow: some View {
        HStack(spacing: 10) {
            StatePill(running ? "Session live" : "Ready",
                      tone: running ? .accent : .neutral,
                      pulsing: running)
                .accessibilityIdentifier("breathe.status")
            Spacer()
            Text(live.bonded ? "Haptics on" : "Visual only")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    // MARK: - Breath timeline (display only; the existing phase clock owns pacing)

    private var breathTimeline: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Text(running ? phaseWord : String(localized: "Ready to breathe"))
                    .font(StrandFont.largeTitle.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("breathe.phase")
                Text("\(pace.label) · \(durationText(pace.cycle(lockedBpm: lockedBpm)))-second cycle")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if typeSize.isAccessibilitySize {
                VStack(spacing: NoopMetrics.space2) {
                    phaseSegment(.inhale)
                    phaseSegment(.exhale)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Breathing cycle")
                .accessibilityValue("Inhale \(durationText(pace.inhale(lockedBpm: lockedBpm))) seconds, exhale \(durationText(pace.exhale(lockedBpm: lockedBpm))) seconds")
                .accessibilityIdentifier("breathe.timeline")
            } else {
                timelineTrack
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timelineTrack: some View {
        VStack(spacing: NoopMetrics.space2) {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !running || reduceMotion)) { context in
                GeometryReader { geometry in
                    let gap = NoopMetrics.space1
                    let width = max(0, geometry.size.width - gap)
                    let inhale = pace.inhale(lockedBpm: lockedBpm)
                    let cycle = pace.cycle(lockedBpm: lockedBpm)
                    let inhaleWidth = width * CGFloat(inhale / cycle)

                    HStack(spacing: gap) {
                        phaseSegment(.inhale).frame(width: inhaleWidth)
                        phaseSegment(.exhale).frame(width: width - inhaleWidth)
                    }
                    .overlay(alignment: .leading) {
                        if running && !reduceMotion {
                            // Read the existing deadline without writing phase, timing, or session state.
                            let duration = phase == .inhale ? inhale : cycle - inhale
                            let elapsed = min(max(duration - phaseDeadline.timeIntervalSince(context.date), 0), duration)
                            let x = phase == .inhale
                                ? inhaleWidth * CGFloat(elapsed / duration)
                                : inhaleWidth + gap + (width - inhaleWidth) * CGFloat(elapsed / duration)
                            // Paired edge ticks retain the exact time position without
                            // drawing a moving stroke through either duration label.
                            VStack(spacing: 0) {
                                Rectangle().frame(height: NoopMetrics.space2)
                                Spacer(minLength: 0)
                                Rectangle().frame(height: NoopMetrics.space2)
                            }
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: 2, height: timelineHeight)
                                .offset(x: min(max(x, 0), max(0, geometry.size.width - 2)))
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(height: timelineHeight)
            }
            // The durations below are spoken once; cursor updates are decorative.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Breathing cycle")
            .accessibilityValue("Inhale \(durationText(pace.inhale(lockedBpm: lockedBpm))) seconds, exhale \(durationText(pace.exhale(lockedBpm: lockedBpm))) seconds")
            .accessibilityIdentifier("breathe.timeline")

            HStack {
                Text("0")
                Spacer()
                Text("\(durationText(pace.inhale(lockedBpm: lockedBpm)))s in")
                Spacer()
                Text("\(durationText(pace.cycle(lockedBpm: lockedBpm)))s cycle")
            }
            .font(StrandFont.captionNumber)
            .foregroundStyle(StrandPalette.textTertiary)
            .accessibilityHidden(true)
        }
    }

    private func phaseSegment(_ segment: Phase) -> some View {
        let active = running && phase == segment
        let duration = segment == .inhale ? pace.inhale(lockedBpm: lockedBpm) : pace.exhale(lockedBpm: lockedBpm)
        return VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(segment == .inhale ? "IN" : "OUT")
                .font(StrandFont.overline)
                .tracking(StrandFont.overlineTracking)
                .foregroundStyle(StrandPalette.textSecondary)
            Text("\(durationText(duration)) s")
                .font(StrandFont.number(readoutValueSize))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
        .background(active ? StrandPalette.inset : StrandPalette.surfaceRaised,
                    in: RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: NoopMetrics.radius2, style: .continuous)
                .strokeBorder(active ? StrandPalette.hairlineStrong : StrandPalette.hairline, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(segment == .inhale ? "Inhale" : "Exhale")
        .accessibilityValue("\(durationText(duration)) seconds")
    }

    private var sessionReadout: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NoopMetrics.space2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline))
        return layout {
            Text(timeString(sessionSeconds))
                .font(StrandFont.title2.monospacedDigit())
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityLabel("Elapsed time \(timeString(sessionSeconds))")
            if !typeSize.isAccessibilitySize { Spacer() }
            Text("\(breathCount) breaths")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func durationText(_ seconds: Double) -> String {
        seconds.formatted(.number.precision(.fractionLength(0...1)))
    }

    /// Opt-in audio pacer toggle, next to the breathing setup.
    /// Default off; flipping it primes/tears down the tone engine via the onChange hook above.
    private var audioCueToggle: some View {
        HStack(spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text("Audio cues")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Phase tones · respects silent mode")
                    .font(StrandFont.micro)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $audioCues)
                .labelsHidden().toggleStyle(.switch).tint(StrandPalette.textSecondary)
                .accessibilityLabel("Audio cues")
                .accessibilityIdentifier("breathe.audioCues")
        }
        .frame(minHeight: 44)
    }

    /// Preset pills — the locked-resonance pill only shows once a pace has been locked (it reads the
    /// stored value), so a never-swept user sees the three shipped presets exactly as before.
    private var availablePaces: [Pace] {
        lockedBpm != nil ? [.relax, .coherence, .box, .resonance] : [.relax, .coherence, .box]
    }

    private var pacePills: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) { paceChoices }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: NoopMetrics.space2) { paceChoices }
                }
            }
        }
        .segmentedPillTint(nil)
        .strandHaptic(.selection, trigger: pace)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Breathing pace")
    }

    private var paceChoices: some View {
        ForEach(availablePaces, id: \.self) { item in
            ChoiceChipButton(verbatimTitle: item.label, isSelected: pace == item) { pace = item }
                .frame(minHeight: 44)
                .accessibilityIdentifier("breathe.pace.\(String(describing: item))")
        }
    }

    private var phaseWord: String {
        switch phase {
        case .inhale: return String(localized: "Breathe in…")
        case .exhale: return String(localized: "Breathe out…")
        }
    }

    // MARK: - Controls

    private var controlRow: some View {
        VStack(spacing: NoopMetrics.space2) {
            Button(role: running ? .destructive : nil) {
                running ? stop() : start()
            } label: {
                Text(running ? "Stop session" : "Start session")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(PrimaryPillButtonStyle())
            .accessibilityIdentifier(running ? "breathe.stop" : "breathe.start")

            Button {
                model.buzz(loops: 1)
            } label: {
                HStack(spacing: NoopMetrics.space3) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Test buzz").font(StrandFont.subhead)
                        Text("Single pulse · bonded strap required")
                            .font(StrandFont.micro)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "waveform.path").accessibilityHidden(true)
                }
                .foregroundStyle(live.bonded ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                .padding(.vertical, NoopMetrics.space1)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(FlatRowPressStyle())
            .disabled(!live.bonded)
            .accessibilityIdentifier("breathe.testBuzz")
            .help("Fire a single haptic pulse on the strap (requires a bonded connection)")
        }
    }

    // MARK: - Session outcome

    private var outcomeLine: String? {
        if running { return nil }
        if let endedOutcome {
            return endedOutcome == "—" ? String(localized: "No RMSSD · not enough R-R data")
                                       : String(localized: "RMSSD \(endedOutcome)")
        }
        if !lastStoredOutcome.isEmpty { return String(localized: "Last session: \(lastStoredOutcome)") }
        return nil
    }

    private func outcomeCard(_ line: String) -> some View {
        StrandCard(padding: 14, tint: StrandPalette.restColor) {
            HStack(spacing: 10) {
                Image(systemName: "wind")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(StrandPalette.restBright)
                    .accessibilityHidden(true)
                Text(line)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let chip = outcomeTrend {
                    TrendChip(text: chip.text, color: chip.color)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outcomeTrend: (text: String, color: Color)? {
        guard let source = endedOutcome ?? (lastStoredOutcome.isEmpty ? nil : lastStoredOutcome),
              source != "—",
              let pct = Self.leadingSignedPercent(source) else { return nil }
        let sign = pct >= 0 ? "+" : "−"
        let color = pct >= 0 ? StrandPalette.statusPositive : StrandPalette.textTertiary
        return ("\(sign)\(abs(pct))% HRV", color)
    }

    private static func leadingSignedPercent(_ s: String) -> Int? {
        guard let pctRange = s.range(of: "%") else { return nil }
        let head = s[s.startIndex..<pctRange.lowerBound]
            .replacingOccurrences(of: "+", with: "")
            .trimmingCharacters(in: .whitespaces)
        return Int(head)
    }

    // MARK: - Readouts

    private var readoutRow: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: NoopMetrics.space4))
            : AnyLayout(HStackLayout(alignment: .top, spacing: NoopMetrics.space3))
        return layout {
            readoutTile(label: String(localized: "Heart rate"),
                        value: model.bpm.map { "\($0)" } ?? "—",
                        unit: "bpm",
                        caption: !live.worn ? String(localized: "Strap not worn")
                            : model.bpm == nil ? String(localized: "No reading") : String(localized: "Latest reading"))

            readoutTile(label: String(localized: "HRV (RMSSD)"),
                        value: rmssd.map { String(format: "%.0f", $0) } ?? "—",
                        unit: "ms",
                        caption: rrBuffer.isEmpty ? String(localized: "Waiting for R-R") : String(localized: "Last \(rrBuffer.count) beats"))

            readoutTile(label: String(localized: "Pace"),
                        value: String(format: "%.1f", pace.bpm(lockedBpm: lockedBpm)),
                        unit: "br/min",
                        caption: String(localized: "\(durationText(pace.inhale(lockedBpm: lockedBpm)))s in · \(durationText(pace.exhale(lockedBpm: lockedBpm)))s out"))
        }
        .padding(.vertical, NoopMetrics.space3)
        .overlay(alignment: .top) { Divider().overlay(StrandPalette.hairline) }
        .overlay(alignment: .bottom) { Divider().overlay(StrandPalette.hairline) }
    }

    private func readoutTile(label: String, value: String, unit: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(label)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(value)
                    .font(StrandFont.number(readoutValueSize))
                    .foregroundStyle(value == "—" ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                if value != "—" {
                    Text(unit)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Text(caption)
                .font(StrandFont.micro)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Coherence estimate

    private var coherenceCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: NoopMetrics.space2))
                : AnyLayout(HStackLayout())
            layout {
                Text("Coherence estimate")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                if !typeSize.isAccessibilitySize { Spacer() }
                HStack(spacing: NoopMetrics.space1) {
                    Circle()
                        .fill(coherenceTone.color)
                        .frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                    Text(coherenceLabel)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }

            if rmssd != nil {
                PaperProgressBar(frac: coherenceFraction, tint: StrandPalette.restBright, height: 10)
                    .accessibilityLabel("Coherence estimate")
                    .accessibilityValue("\(Int(coherenceFraction * 100)) percent")
                    .accessibilityIdentifier("breathe.coherenceProgress")
            }

            Text("Estimate only: a higher RMSSD while paced usually means your parasympathetic \"rest\" branch is engaging. It is not a clinical reading; trends over a session matter more than any single number.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, NoopMetrics.space3)
        .overlay(alignment: .top) { Divider().overlay(StrandPalette.hairline) }
    }

    private var coherenceFraction: CGFloat {
        guard let r = rmssd else { return 0 }
        return CGFloat(min(max(r / 120.0, 0), 1))
    }

    private var coherenceLabel: String {
        guard let r = rmssd else { return String(localized: "No data") }
        switch r {
        case ..<20:  return String(localized: "Building")
        case ..<45:  return String(localized: "Settling")
        case ..<80:  return String(localized: "Coherent")
        default:     return String(localized: "Deep calm")
        }
    }

    private var coherenceTone: StrandTone {
        guard let r = rmssd else { return .neutral }
        switch r {
        case ..<20:  return .warning
        case ..<45:  return .neutral
        default:     return .positive
        }
    }

    // MARK: - Haptic hint

    private var hapticHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .foregroundStyle(StrandPalette.statusWarning)
            Text("Connect your strap for haptic guidance. You'll feel one pulse on the inhale, two on the exhale, so you can breathe with your eyes closed.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(StrandPalette.statusWarning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .strokeBorder(StrandPalette.statusWarning.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: - Session control (fixed-pace Breathe — unchanged)

    private func start() {
        running = true
        ScreenIdle.keepAwake(true)
        sessionSeconds = 0
        breathCount = 0
        endedOutcome = nil
        baselineRmssd = rmssd
        sessionRmssdSum = 0
        sessionRmssdCount = 0
        sessionRmssdPeak = 0
        armPhase(.inhale, from: Date(), buzz: true)
    }

    private func stop() {
        let wasRunning = running
        running = false
        ScreenIdle.keepAwake(false)
        phaseDeadline = .distantFuture
        // #769: this trainer fires per-phase buzzes (armPhase -> model.buzz). Stopping halts NEW pulses but
        // can't recall one the strap is mid-pattern on, which could wedge the strap if the link drops. Tell
        // the strap to stop haptics too (best-effort; no-op when unbonded / on a 5/MG). Only when we were
        // actually buzzing, so a stop on an idle trainer stays silent.
        if wasRunning { model.stopHaptics() }
        if wasRunning { captureOutcome() }
        if reduceMotion {
            orbProgress = 0
        } else {
            withAnimation(.easeInOut(duration: 0.8)) {
                orbProgress = 0
            }
        }
    }

    private let reducedSteadyOrb: CGFloat = 0.5

    private func captureOutcome() {
        guard sessionSeconds >= 120 else { return }
        guard let base = baselineRmssd, base > 0, sessionRmssdCount > 0 else {
            endedOutcome = "—"
            return
        }
        let mean = sessionRmssdSum / Double(sessionRmssdCount)
        let pct = Int(((mean - base) / base * 100).rounded())
        let pctStr = String(format: "%+d%%", pct)
        let peakStr = String(format: "%.0f", sessionRmssdPeak)
        let core = String(localized: "\(pctStr) vs start · peak \(peakStr) ms")
        endedOutcome = core
        lastStoredOutcome = core
    }

    private func armPhase(_ newPhase: Phase, from now: Date, buzz: Bool) {
        phase = newPhase
        let duration = (newPhase == .inhale)
            ? pace.inhale(lockedBpm: lockedBpm)
            : pace.exhale(lockedBpm: lockedBpm)
        phaseDeadline = now.addingTimeInterval(duration)

        if reduceMotion {
            orbProgress = reducedSteadyOrb
        } else {
            withAnimation(.easeInOut(duration: duration)) {
                orbProgress = (newPhase == .inhale) ? 1.0 : 0.0
            }
        }

        if buzz {
            model.buzz(loops: newPhase == .inhale ? 1 : 2)
            if audioCues {
                tonePlayer.play(newPhase == .inhale ? .inhale : .exhale)
            }
        }
    }

    private func advance(now: Date) {
        guard now >= phaseDeadline else { return }
        switch phase {
        case .inhale:
            armPhase(.exhale, from: now, buzz: true)
        case .exhale:
            breathCount += 1
            armPhase(.inhale, from: now, buzz: true)
        }
    }

    // MARK: - HRV (RMSSD)

    private func ingest(_ rr: [Int]) {
        guard !rr.isEmpty else { return }
        rrBuffer.append(contentsOf: rr)
        if rrBuffer.count > rrWindow {
            rrBuffer.removeFirst(rrBuffer.count - rrWindow)
        }
        rmssd = computeRMSSD(rrBuffer)
        if running, let r = rmssd {
            if baselineRmssd == nil && sessionSeconds <= 60 { baselineRmssd = r }
            sessionRmssdSum += r
            sessionRmssdCount += 1
            sessionRmssdPeak = max(sessionRmssdPeak, r)
        }
    }

    private func computeRMSSD(_ intervals: [Int]) -> Double? {
        guard intervals.count >= 2 else { return nil }
        var sumSq = 0.0
        for i in 1..<intervals.count {
            let d = Double(intervals[i] - intervals[i - 1])
            sumSq += d * d
        }
        let meanSq = sumSq / Double(intervals.count - 1)
        return meanSq.squareRoot()
    }

    // MARK: - Formatting

    private func timeString(_ total: Int) -> String {
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - Lazy controller holder

/// Holds the `BiofeedbackController` so it can be created from the environment model/live on first
/// appear (a `@StateObject`'s value can't read the environment at init). `prepare` is idempotent.
@MainActor
private final class ControllerBox: ObservableObject {
    private var made: BiofeedbackController?
    func prepare(model: AppModel, live: LiveState) {
        if made == nil { made = BiofeedbackController(model: model, live: live) }
    }
    func controller(model: AppModel, live: LiveState) -> BiofeedbackController {
        if let made { return made }
        let c = BiofeedbackController(model: model, live: live)
        made = c
        return c
    }
}

// MARK: - Audio pacer (opt-in soft phase tones)

/// A tiny on-device tone player for the opt-in audio pacer. It synthesises a short, soft sine "ding"
/// for each phase (a higher note on the inhale, a lower one on the exhale) and plays it through an
/// **ambient** audio session, so the iOS silent switch mutes it like any other ambient sound and it
/// never interrupts other audio. No bundled assets — the buffers are generated once and reused.
///
/// Self-contained and view-owned: `activate()` spins the engine up when the user opts in, `deactivate()`
/// tears it down when they switch off or leave the screen, so we hold the audio session only while it's
/// actually wanted.
@MainActor
final class BreathTonePlayer: ObservableObject {

    enum Tone { case inhale, exhale }

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var inhaleBuffer: AVAudioPCMBuffer?
    private var exhaleBuffer: AVAudioPCMBuffer?
    private var active = false

    /// Phase tone frequencies (Hz). A gentle rising/falling pair — a soft cue, not a chime.
    private let inhaleHz: Double = 440   // A4, brighter for "in"
    private let exhaleHz: Double = 330   // E4, lower for "out"
    private let toneSeconds: Double = 0.45
    private let sampleRate: Double = 44_100

    /// Bring the engine and audio session up. Idempotent — safe to call on every appear.
    func activate() {
        guard !active else { return }
#if os(iOS)
        // Ambient: obeys the silent switch and mixes politely with anything else playing.
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true, options: [])
#endif
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
        guard let format else { return }

        if inhaleBuffer == nil { inhaleBuffer = makeTone(frequency: inhaleHz, format: format) }
        if exhaleBuffer == nil { exhaleBuffer = makeTone(frequency: exhaleHz, format: format) }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            player.play()
            active = true
        } catch {
            // Audio is a nicety, never load-bearing — if it can't start we just stay silent.
            active = false
        }
    }

    /// Stop and release the engine + session so nothing lingers when the pacer is off.
    func deactivate() {
        guard active else { return }
        player.stop()
        engine.stop()
        engine.disconnectNodeOutput(player)
        engine.detach(player)
#if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
#endif
        active = false
    }

    /// Play the phase tone. No-op if the engine isn't up (e.g. start-up race) — the haptic + visual cues
    /// still carry the pace, so a missed tone is harmless.
    func play(_ tone: Tone) {
        guard active else { return }
        let buffer = (tone == .inhale) ? inhaleBuffer : exhaleBuffer
        guard let buffer else { return }
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
    }

    /// Generate a single soft sine tone with a short attack/decay envelope so it fades in and out rather
    /// than clicking. Built once per frequency and reused.
    private func makeTone(frequency: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(toneSeconds * sampleRate)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let total = Int(frameCount)
        let attack = Int(0.02 * sampleRate)
        let release = Int(0.18 * sampleRate)
        let peak: Float = 0.28   // kept quiet — a gentle cue, not a beep

        for i in 0..<total {
            let t = Double(i) / sampleRate
            let sample = Float(sin(2.0 * Double.pi * frequency * t))
            // Linear attack, sustain, then a longer linear release so the tail is soft.
            var env: Float = 1.0
            if i < attack {
                env = Float(i) / Float(max(attack, 1))
            } else if i > total - release {
                env = Float(total - i) / Float(max(release, 1))
            }
            channel[i] = sample * env * peak
        }
        return buffer
    }
}

// MARK: - L3 nudge-center environment key (optional injection point for Wave 3)

private struct StressNudgeCenterKey: EnvironmentKey {
    static let defaultValue: StressNudgeCenter? = nil
}
extension EnvironmentValues {
    /// The shared L3 nudge center. Wave 3 sets this (`.environment(\.stressNudgeCenter, model.stressNudge)`)
    /// from the same instance its BLEManager hook posts to; nil → BreathingView uses a local fallback.
    var stressNudgeCenter: StressNudgeCenter? {
        get { self[StressNudgeCenterKey.self] }
        set { self[StressNudgeCenterKey.self] = newValue }
    }
}

// MARK: - L1: Resonance mode (the "find my pace" sweep + result)

/// The L1 surface: an explainer, the full/quick sweep start, a live "Testing 5.5 br/min…" label + RSA
/// progress while sweeping, and the dated result card (locked pace + per-pace RSA curve, or the honest
/// "couldn't lock today" fallback). Self-contained — drives the shared `BiofeedbackController`.
private struct ResonanceModeView: View {
    @ObservedObject var controller: BiofeedbackController
    @ObservedObject var live: LiveState
    let lockedBpm: Double?

    private var sweeping: Bool {
        if case .resonanceSweep = controller.session { return true }
        return false
    }

    var body: some View {
        VStack(spacing: NoopMetrics.gap) {
            explainerCard
            if sweeping { sweepProgressCard } else { startCard }
            if let result = controller.lastSweep { resultCard(result) }
            else if let bpm = lockedBpm { lockedCard(bpm) }
            if !live.bonded { connectHint }
        }
    }

    private var explainerCard: some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Find your resonance pace").strandOverline()
                    Spacer()
                    StatePill(live.bonded ? "Haptics on" : "Visual only",
                              tone: live.bonded ? .positive : .warning, showsDot: true)
                }
                Text("Everyone has a breathing pace (usually between 4.5 and 7 breaths a minute) where the heart's rhythm swings the most with each breath. We pace you through a few candidate paces, measure how your HRV responds, and lock the one that resonates best for you.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Estimate from PPG-derived R-R: relaxation guidance, not a clinical reading. Your pace drifts, so we date it and you can re-measure anytime.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var startCard: some View {
        StrandCard {
            VStack(spacing: NoopMetrics.space3) {
                NoopButton("Full sweep · ~13 min", systemImage: "waveform.path.ecg",
                           kind: .primary, fullWidth: true) {
                    controller.startSweep(quick: false)
                }

                NoopButton("Quick sweep · ~7 min", systemImage: "bolt",
                           kind: .secondary, fullWidth: true) {
                    controller.startSweep(quick: true)
                }

                Text("Sit still and breathe with the buzz. You can stop anytime; a stopped sweep won't lock a pace.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sweepProgressCard: some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(controller.sweepLabel ?? String(localized: "Sweeping…"))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    StatePill("Live", tone: .accent, showsDot: true, pulsing: true)
                }

                // Sweep progress as a filling liquid tube (the liquid idiom used across the redesign),
                // Sleep-tinted so it reads as one with the breathe world.
                PaperProgressBar(frac: controller.sweepProgress, tint: StrandPalette.restColor, height: 10)
                    .accessibilityLabel("Sweep progress")
                    .accessibilityValue("\(Int(controller.sweepProgress * 100)) percent")

                NoopButton("Stop sweep", systemImage: "stop.fill", kind: .destructive, fullWidth: true) {
                    controller.stop()
                }
            }
        }
    }

    private func resultCard(_ result: ResonanceEngine.SweepResult) -> some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(result.didLock ? "Your resonance pace" : "Couldn't lock today").strandOverline()
                    Spacer()
                    StatePill(result.didLock ? "Locked" : "Fallback",
                              tone: result.didLock ? .positive : .neutral, showsDot: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    CountUpText(value: result.lockedBpm,
                                format: { String(format: "%.1f", $0) },
                                font: StrandFont.number(40),
                                color: StrandPalette.textPrimary)
                    Text("br/min")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                if !result.didLock {
                    Text("Not enough clean beat data to lock a pace today. Try again rested, sitting still with the strap snug. For now we'll pace you at 5.5 br/min (coherence).")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                rsaCurve(result.scores)

                if let date = BiofeedbackPrefs.lockedPaceDate, result.didLock {
                    Text("Locked \(date.formatted(date: .abbreviated, time: .omitted)) · paces drift, re-measure anytime.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func lockedCard(_ bpm: Double) -> some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Your locked pace").strandOverline()
                    Spacer()
                    StatePill("Locked", tone: .positive, showsDot: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    CountUpText(value: bpm,
                                format: { String(format: "%.1f", $0) },
                                font: StrandFont.number(34),
                                color: StrandPalette.textPrimary)
                    Text("br/min")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                if let date = BiofeedbackPrefs.lockedPaceDate {
                    Text("Locked \(date.formatted(date: .abbreviated, time: .omitted)). Switch to Breathe to use it, or re-measure above.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// A compact text + bar summary of the RSA-amplitude per pace (the resonance curve). The text summary
    /// is the a11y win; the bars are decorative. Unscored paces read "—".
    private func rsaCurve(_ scores: [ResonanceEngine.PaceScore]) -> some View {
        let maxRsa = scores.compactMap(\.rsaAmplitude).max() ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            Text("RSA RESPONSE BY PACE").strandOverline()
            ForEach(scores, id: \.bpm) { s in
                HStack(spacing: 8) {
                    Text(String(format: "%.1f", s.bpm))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 34, alignment: .leading)
                    // Each pace's RSA amplitude as a static liquid tube — the same horizontal vessel used
                    // across the redesign. An unscored pace reads muted via a dimmed Sleep tint.
                    PaperProgressBar(frac: (s.rsaAmplitude ?? 0) / max(maxRsa, 0.0001),
                               tint: StrandPalette.restBright.opacity(s.scored ? 1 : 0.35),
                               height: 8, animated: false)
                    Text(s.rsaAmplitude.map { String(format: "%.1f", $0) } ?? "—")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(s.scored ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("RSA response by pace")
        .accessibilityValue(rsaTextSummary(scores))
    }

    private func rsaTextSummary(_ scores: [ResonanceEngine.PaceScore]) -> String {
        scores.map { s in
            let v = s.rsaAmplitude.map { String(format: "%.1f", $0) } ?? String(localized: "unscored")
            return String(localized: "\(String(format: "%.1f", s.bpm)) breaths per minute: \(v)")
        }.joined(separator: ", ")
    }

    private var connectHint: some View {
        HStack(spacing: 10) {
            Image(systemName: "applewatch.radiowaves.left.and.right")
                .foregroundStyle(StrandPalette.statusWarning)
            Text("Connect your strap for the felt cue. The sweep paces you with one buzz on the inhale, two on the exhale.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(StrandPalette.statusWarning.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
    }
}

// MARK: - L2: "Calm me" mode (below-HR relaxation metronome)

/// The L2 surface: a "Calm me · 3 min" button that runs `HRDownPacer`, a minimal live "HR 78 → settling"
/// readout, a stop control, and an honest outcome line. Haptic-first → disabled (not faked) when the
/// encrypted channel isn't up. Self-contained — drives the shared `BiofeedbackController`.
private struct CalmModeView: View {
    @ObservedObject var controller: BiofeedbackController
    @ObservedObject var live: LiveState
    @ObservedObject var model: AppModel

    private var running: Bool {
        if case .calmMe = controller.session { return true }
        return false
    }

    var body: some View {
        VStack(spacing: NoopMetrics.gap) {
            explainerCard
            if running { liveCard } else { startCard }
            if let outcome = controller.calmOutcome, !running { outcomeCard(outcome) }
        }
    }

    private var explainerCard: some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Calm me").strandOverline()
                    Spacer()
                    StatePill(canRun ? "Ready" : "Strap needed",
                              tone: canRun ? .neutral : .warning, showsDot: true)
                }
                Text("The strap buzzes a gentle rhythm just below your current heart rate, a felt metronome to relax toward. It trails your heart down rather than yanking it, and stops on its own.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("A relaxation rhythm, not cardiac control. It never paces below a safe rate and you can stop anytime. If your heart rate doesn't settle, we'll say so plainly.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// L2 needs the encrypted channel (haptic-first) and a resting-band HR to read H₀.
    private var canRun: Bool { controller.canBuzz && (model.bpm.map { $0 >= 55 && $0 <= 120 } ?? false) }

    private var startCard: some View {
        StrandCard {
            VStack(spacing: NoopMetrics.rowSpacing) {
                NoopButton("Calm me · 3 min", systemImage: "heart.fill",
                           kind: .primary, fullWidth: true) {
                    controller.startCalmMe()
                }
                .disabled(!canRun)

                if !controller.canBuzz {
                    Text("Connect your strap. Calm me is a felt rhythm on the wrist, so it needs a bonded connection.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !canRun {
                    Text("Waiting for a resting heart rate. Start a live reading first, or come back when you're still.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var liveCard: some View {
        StrandCard(tint: StrandPalette.restColor) {
            VStack(spacing: 14) {
                HStack {
                    Text("Settling").strandOverline()
                    Spacer()
                    StatePill("Live", tone: .accent, showsDot: true, pulsing: true)
                }

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    if let bpm = model.bpm {
                        CountUpText(value: Double(bpm),
                                    format: { "\(Int($0.rounded()))" },
                                    font: StrandFont.number(48),
                                    color: StrandPalette.textPrimary)
                    } else {
                        Text("—")
                            .font(StrandFont.number(48))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Image(systemName: "arrow.right")
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("target")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text(controller.calmTargetBpm.map { String(format: "%.0f", $0) } ?? "—")
                            .font(StrandFont.number(22))
                            .foregroundStyle(StrandPalette.restBright)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let h0 = controller.calmStartHR {
                    Text("Started at \(h0) bpm · the rhythm trails your heart down.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                NoopButton("Stop", systemImage: "stop.fill", kind: .destructive, fullWidth: true) {
                    controller.stop()
                }
            }
        }
    }

    private func outcomeCard(_ line: String) -> some View {
        StrandCard(padding: 14, tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: controller.calmDidNotFall ? "minus.circle" : "checkmark.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(controller.calmDidNotFall ? StrandPalette.textTertiary : StrandPalette.statusPositive)
                        .accessibilityHidden(true)
                    Text(line)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                if controller.calmDidNotFall {
                    Text("That's normal. A paced breath often settles things when a metronome alone doesn't.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
