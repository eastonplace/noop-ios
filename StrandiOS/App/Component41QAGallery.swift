#if DEBUG
import SwiftUI
import StrandDesign

/// True-size simulator proof for component 41. Every specimen below is the same public view
/// instantiated by the widget/ActivityKit extension; this file contains no alternate UI.
struct Component41QAGallery: View {
    private let now = Date()
    private let recovery = 78
    private let strain = 8.2
    private let sleep = 86
    private let bpm = 152
    private let stress: [Double?] = [
        0.3, 0.4, 0.3, 0.2, 0.3, 0.5, 0.7, 0.9, 1.2, 1.5, 1.8, 1.4,
        1.0, 1.2, 1.6, 2.0, 1.7, 1.1, 0.8, 0.7, 0.6, nil, nil, nil,
    ]
    private let hr = [88, 96, 108, 121, 115, 132, 146, 139, 152, 144, 158, 152]
    private let hrv = [52, 55, 53, 59, 61, 58, 64, 62, 67, 64]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                title
                section("HOME · SMALL") {
                    widgetStage(width: 158, height: 158, tint: .recovery(score: Double(recovery))) {
                        NOOPRecoverySmallWidgetView(
                            recovery: recovery, delta: 6, sleepMinutes: 432, batteryPercentage: 82)
                    }
                }
                section("HOME · MEDIUM") {
                    widgetStage(width: 338, height: 158) {
                        NOOPPillarsMediumWidgetView(
                            recovery: recovery, strain: strain, sleep: sleep, stressHours: stress,
                            batteryPercentage: 82, hrv: 64, restingHeartRate: 52, steps: 11_204)
                    }
                }
                section("HOME · LARGE") {
                    widgetStage(width: 338, height: 354) {
                        NOOPTodayLargeWidgetView(
                            date: now, recovery: recovery, strain: strain, sleep: sleep, bpm: bpm,
                            hrSpark: hr, stressHours: stress, stressSummary: "Moderate · easing",
                            batteryPercentage: 82, hrv: 64, restingHeartRate: 52,
                            steps: 11_204, calories: 2_140, maxHR: 187)
                    }
                }
                section("LOCK SCREEN · ACCESSORIES") {
                    VStack(spacing: 20) {
                        HStack(spacing: 30) {
                            lockStage(width: 62, height: 62) {
                                NOOPAccessoryCircularGaugeView(
                                    value: Double(recovery), maximum: 100, accent: .white,
                                    accessibilityName: NOOPWidgetLabel.recovery)
                            }
                            lockStage(width: 62, height: 62) {
                                NOOPAccessoryCircularGaugeView(
                                    value: strain, maximum: 21, accent: .white,
                                    accessibilityName: NOOPWidgetLabel.strain, decimal: true)
                            }
                        }
                        lockStage(width: 172, height: 72) {
                            NOOPAccessoryRectangularView(
                                recovery: recovery, strain: strain, hrv: 64, hrvSpark: hrv)
                                .padding(.horizontal, 10)
                        }
                        lockStage(width: 280, height: 34) {
                            NOOPAccessoryInlineView(recovery: recovery, strain: strain)
                        }
                    }
                }
                section("LOCK SCREEN · WORKOUT LIVE ACTIVITY") {
                    NOOPWorkoutLiveActivityView(
                        title: "Outdoor Run", startedAt: now.addingTimeInterval(-2_734), bpm: bpm,
                        strain: 6.8, strainBuilding: false, calories: 438, hrSpark: hr)
                        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
                }
                section("DYNAMIC ISLAND · COMPACT") {
                    HStack(spacing: 0) {
                        NOOPDynamicIslandHeartRateView(bpm: bpm).padding(.leading, 12)
                        Spacer(minLength: 0)
                        Capsule(style: .continuous).fill(Color(white: 0.08)).frame(width: 90, height: 24)
                        Spacer(minLength: 0)
                        NOOPDynamicIslandStrainView(strain: 6.8, building: false).padding(.trailing, 12)
                    }
                    .frame(width: 250, height: 36)
                    .background(Capsule(style: .continuous).fill(Color.black))
                }
                section("DYNAMIC ISLAND · EXPANDED") {
                    VStack(spacing: 10) {
                        HStack(alignment: .firstTextBaseline) {
                            NOOPDynamicIslandIdentityView(
                                sport: "Outdoor Run", startedAt: now.addingTimeInterval(-2_734))
                            Spacer(minLength: 8)
                            NOOPDynamicIslandVitalsView(bpm: bpm, strain: 6.8, building: false)
                        }
                        NOOPZoneSplitView(seconds: [180, 620, 1_180, 650, 104])
                    }
                    .padding(16)
                    .frame(width: 356)
                    .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.black))
                }
                section("HONEST MISSING STATE") {
                    HStack(spacing: 14) {
                        widgetStage(width: 158, height: 158, tint: .recovery(score: nil)) {
                            NOOPRecoverySmallWidgetView(
                                recovery: nil, delta: nil, sleepMinutes: nil, batteryPercentage: nil)
                        }
                        lockStage(width: 62, height: 62) {
                            NOOPAccessoryCircularGaugeView(
                                value: nil, maximum: 21, accent: .white,
                                accessibilityName: NOOPWidgetLabel.strain, decimal: true)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StrandPalette.appCanvas.ignoresSafeArea())
        .navigationTitle("Widgets & Live")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COMPONENT 41 · PRODUCTION")
                .font(StrandFont.overline).tracking(1.4).foregroundStyle(StrandPalette.textTertiary)
            Text("Widgets & Live").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            Text("Same views used by WidgetKit and ActivityKit, rendered at their real point sizes.")
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func section<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label).font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1)
                .foregroundStyle(StrandPalette.textTertiary)
            content()
        }
    }

    private func widgetStage<Content: View>(width: CGFloat, height: CGFloat, tint: DomainTint = .neutral,
                                            @ViewBuilder content: () -> Content) -> some View {
        // Simulate WidgetKit's ~16 pt home-screen content margins; the widget views carry none.
        content().padding(16).frame(width: width, height: height)
            .background(NOOPWidgetBackground(tint))
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(StrandPalette.hairline, lineWidth: 1))
    }

    private func lockStage<Content: View>(width: CGFloat, height: CGFloat,
                                          @ViewBuilder content: () -> Content) -> some View {
        content().frame(width: width, height: height)
            .foregroundStyle(.white).environment(\.colorScheme, .dark)
            .background(Color.black.opacity(0.86))
            .clipShape(RoundedRectangle(cornerRadius: min(width, height) / 2.8, style: .continuous))
    }
}

#Preview("Component 41 production") {
    NavigationStack { Component41QAGallery() }
        .frame(width: 402, height: 874)
}

/// One-screen capture plates used by the simulator gate. Splitting the long gallery prevents
/// off-screen content from being mistaken for visual QA.
struct Component41QAShot: View {
    enum Kind { case home, large, largeZones, stress, lock, live, livePaused, liveStale, liveFinishing, lift, liftRest, liftStale }

    /// Narrow DEBUG launch route for rendered Simulator proof. This avoids restoring the obsolete
    /// all-screen demo router while keeping the production widget/ActivityKit views directly auditable.
    static var requestedKind: Kind? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--component41-shot"),
              arguments.indices.contains(index + 1) else { return nil }
        return switch arguments[index + 1].lowercased() {
        case "home": .home
        case "large": .large
        case "large-zones": .largeZones
        case "stress": .stress
        case "lock": .lock
        case "live": .live
        case "live-paused": .livePaused
        case "live-stale": .liveStale
        case "live-finishing": .liveFinishing
        case "lift": .lift
        case "lift-rest": .liftRest
        case "lift-stale": .liftStale
        default: nil
        }
    }

    let kind: Kind
    private let stress: [Double?] = [0.3, 0.4, 0.3, 0.2, 0.3, 0.5, 0.7, 0.9, 1.2, 1.5, 1.8, 1.4,
                                             1.0, 1.2, 1.6, 2.0, 1.7, 1.1, 0.8, 0.7, 0.6, nil, nil, nil]
    private let hr = [88, 96, 108, 121, 115, 132, 146, 139, 152, 144, 158, 152]
    private let hrv = [52, 55, 53, 59, 61, 58, 64, 62, 67, 64]

    var body: some View {
        VStack(spacing: 18) {
            Text("COMPONENT 41 · \(title)")
                .font(.system(size: 10, weight: .bold, design: .rounded)).tracking(1)
                .foregroundStyle(StrandPalette.textTertiary)
            content
            Spacer(minLength: 0)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.appCanvas.ignoresSafeArea())
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .home:
            VStack(spacing: 18) {
                qaWidget(width: 158, height: 158, tint: .recovery(score: 78)) {
                    NOOPRecoverySmallWidgetView(recovery: 78, delta: 6, sleepMinutes: 432, batteryPercentage: 82)
                }
                qaWidget(width: 338, height: 158) {
                    NOOPPillarsMediumWidgetView(recovery: 78, strain: 8.2, sleep: 86, stressHours: stress,
                                                batteryPercentage: 82, hrv: 64, restingHeartRate: 52, steps: 11_204)
                }
            }
        case .large:
            qaWidget(width: 338, height: 354) {
                NOOPTodayLargeWidgetView(date: Date(), recovery: 78, strain: 8.2, sleep: 86, bpm: 152,
                                         hrSpark: hr, stressHours: stress, stressSummary: "Moderate · easing",
                                         batteryPercentage: 82, hrv: 64, restingHeartRate: 52,
                                         steps: 11_204, calories: 2_140, maxHR: 187)
            }
        case .largeZones:
            // The same 120 bpm reading against the wearer's own maximum (187: steady) and the fixed split (push).
            VStack(spacing: 14) {
                ForEach([Optional(187.0), nil], id: \.self) { maxHR in
                    qaWidget(width: 338, height: 354) {
                        NOOPTodayLargeWidgetView(date: Date(), recovery: 78, strain: 8.2, sleep: 86, bpm: 120,
                                                 hrSpark: hr, stressHours: stress, stressSummary: "Moderate · easing",
                                                 batteryPercentage: 82, hrv: 64, restingHeartRate: 52,
                                                 steps: 11_204, calories: 2_140, maxHR: maxHR)
                    }
                    .scaleEffect(0.62).frame(width: 338 * 0.62, height: 354 * 0.62)
                }
            }
        case .stress:
            VStack(spacing: 18) {
                HStack(spacing: 14) {
                    qaWidget(width: 158, height: 158, tint: .stress) {
                        NOOPStressWidgetContent(summary: "Moderate · easing", hours: stress, hasData: true,
                                                updated: Date())
                    }
                    qaWidget(width: 158, height: 158, tint: .stress) {
                        NOOPStressWidgetContent(summary: nil, hours: nil, hasData: false, updated: Date())
                    }
                }
                qaWidget(width: 338, height: 158, tint: .stress) {
                    NOOPStressWidgetContent(summary: "Moderate · easing", hours: stress, hasData: true,
                                            updated: Date())
                }
            }
        case .lock:
            VStack(spacing: 22) {
                HStack(spacing: 34) {
                    qaLock(width: 62, height: 62) {
                        NOOPAccessoryCircularGaugeView(value: 78, maximum: 100, accent: .white,
                                                        accessibilityName: NOOPWidgetLabel.recovery)
                    }
                    qaLock(width: 62, height: 62) {
                        NOOPAccessoryCircularGaugeView(value: 8.2, maximum: 21, accent: .white,
                                                        accessibilityName: NOOPWidgetLabel.strain, decimal: true)
                    }
                }
                qaLock(width: 172, height: 72) {
                    NOOPAccessoryRectangularView(recovery: 78, strain: 8.2, hrv: 64, hrvSpark: hrv)
                        .padding(.horizontal, 10)
                }
                qaLock(width: 280, height: 34) {
                    NOOPAccessoryInlineView(recovery: 78, strain: 8.2)
                }
            }
        case .live:
            liveSpecimens(paused: false, stale: false)
        case .livePaused:
            liveSpecimens(paused: true, stale: false)
        case .liveStale:
            liveSpecimens(paused: false, stale: true)
        case .liveFinishing:
            liveSpecimens(paused: false, stale: false, finishing: true)
        case .lift:
            liftSpecimens(resting: false, stale: false)
        case .liftRest:
            liftSpecimens(resting: true, stale: false)
        case .liftStale:
            liftSpecimens(resting: false, stale: true)
        }
    }

    /// The workout Live Activity on every surface, at real point sizes: the Lock Screen card, the Dynamic Island compact,
    /// expanded and minimal. The pause button is the shared label; the extension wraps the same label in `Button(intent:)`.
    private func liveSpecimens(paused: Bool, stale: Bool, finishing: Bool = false) -> some View {
        let startedAt = Date().addingTimeInterval(-2_052)
        let pausedAt: Date? = paused ? Date().addingTimeInterval(-180) : nil
        // While the workout is ending every clock stands at the moment the save will end it (a minute ago here), however
        // long the retry takes.
        let frozenAt: Date? = finishing ? Date().addingTimeInterval(-60) : nil
        let maxHR = 187.0
        let bpm = 152
        return VStack(spacing: 22) {
            NOOPWorkoutLiveActivityView(
                title: "Outdoor Run", startedAt: startedAt, pausedAt: pausedAt, frozenAt: frozenAt, bpm: bpm, strain: 6.8,
                strainBuilding: false, calories: 438, hrSpark: hr, maxHR: maxHR, isStale: stale
            ) {
                // The extension wraps this label in a disabled Button(intent:) at 0.35 opacity while the workout is ending.
                NOOPLivePauseButtonLabel(isPaused: paused).opacity(finishing ? 0.35 : 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            islandCompact(startedAt: startedAt, pausedAt: pausedAt, frozenAt: frozenAt, bpm: bpm, maxHR: maxHR, stale: stale)
            islandExpanded(startedAt: startedAt, pausedAt: pausedAt, frozenAt: frozenAt, bpm: bpm, maxHR: maxHR,
                           stale: stale, finishing: finishing)
            islandMinimal(bpm: bpm, maxHR: maxHR, paused: paused, stale: stale)
        }
    }

    /// The strength Live Activity on every surface, at real point sizes.
    private func liftSpecimens(resting: Bool, stale: Bool) -> some View {
        let startedAt = Date().addingTimeInterval(-1_374)
        let restEndsAt: Date? = resting ? Date().addingTimeInterval(74) : nil
        return VStack(spacing: 22) {
            NOOPLiftLiveActivityView(
                workoutName: "Upper Body A", startedAt: startedAt, move: "Incline Press", setProgress: "7/18",
                volume: 4_820, restEndsAt: restEndsAt, isStale: stale)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            HStack(spacing: 0) {
                NOOPLiftIslandGlyph(isResting: resting).padding(.leading, 12)
                Spacer(minLength: 0)
                Capsule().fill(Color(white: 0.08)).frame(width: 90, height: 24)
                Spacer(minLength: 0)
                NOOPLiftIslandClock(startedAt: startedAt, restEndsAt: restEndsAt).padding(.trailing, 12)
            }
            .frame(width: 250, height: 36).background(Capsule().fill(Color.black))
            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    NOOPLiftIslandGlyph(isResting: resting).font(.system(size: 20, weight: .bold))
                    NOOPLiftIslandTitle(workoutName: "Upper Body A", move: "Incline Press")
                    Spacer(minLength: 8)
                    NOOPLiftIslandClock(startedAt: startedAt, restEndsAt: restEndsAt, size: 22)
                }
                NOOPLiftFacts(move: nil, setProgress: "7/18", volume: 4_820)
            }
            .padding(16).frame(width: 356)
            .background(RoundedRectangle(cornerRadius: 30).fill(Color.black))
            NOOPLiftIslandGlyph(isResting: resting)
                .frame(width: 36, height: 36).background(Circle().fill(Color.black))
        }
    }

    private func islandCompact(startedAt: Date, pausedAt: Date?, frozenAt: Date? = nil, bpm: Int, maxHR: Double,
                               stale: Bool) -> some View {
        HStack(spacing: 0) {
            NOOPDynamicIslandHeartRateView(bpm: bpm, maxHR: maxHR, isPaused: pausedAt != nil, isDimmed: pausedAt != nil || stale)
                .padding(.leading, 12)
            Spacer(minLength: 0)
            Capsule().fill(Color(white: 0.08)).frame(width: 90, height: 24)
            Spacer(minLength: 0)
            NOOPDynamicIslandTimerView(startedAt: startedAt, pausedAt: pausedAt, frozenAt: frozenAt).padding(.trailing, 12)
        }
        .frame(width: 250, height: 36).background(Capsule().fill(Color.black))
    }

    private func islandExpanded(startedAt: Date, pausedAt: Date?, frozenAt: Date? = nil, bpm: Int, maxHR: Double,
                                stale: Bool, finishing: Bool = false) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                NOOPDynamicIslandIdentityView(sport: "Outdoor Run", startedAt: startedAt, pausedAt: pausedAt,
                                              frozenAt: frozenAt)
                Spacer(minLength: 8)
                NOOPDynamicIslandVitalsView(bpm: bpm, strain: 6.8, building: false, maxHR: maxHR,
                                            isDimmed: pausedAt != nil || stale)
            }
            HStack(spacing: 12) {
                LiveZoneRail(bpm: bpm, thresholds: HRZoneStyle.Thresholds(hrMax: maxHR),
                             isDimmed: pausedAt != nil || stale, style: .bar)
                NOOPLivePauseButtonLabel(isPaused: pausedAt != nil, isCompact: true).opacity(finishing ? 0.35 : 1)
            }
        }
        .padding(16).frame(width: 356)
        .background(RoundedRectangle(cornerRadius: 30).fill(Color.black))
    }

    private func islandMinimal(bpm: Int, maxHR: Double, paused: Bool, stale: Bool) -> some View {
        NOOPDynamicIslandMinimalView(bpm: bpm, maxHR: maxHR, isPaused: paused, isDimmed: stale)
            .frame(width: 36, height: 36).background(Circle().fill(Color.black))
    }

    private var title: String {
        switch kind {
        case .home: "HOME"
        case .large: "LARGE"
        case .largeZones: "LARGE · PERSONAL ZONES"
        case .stress: "STRESS"
        case .lock: "LOCK SCREEN"
        case .live: "LIVE + ISLAND"
        case .livePaused: "LIVE + ISLAND · PAUSED"
        case .liveStale: "LIVE + ISLAND · STALE"
        case .liveFinishing: "LIVE + ISLAND · ENDING"
        case .lift: "LIFT + ISLAND"
        case .liftRest: "LIFT + ISLAND · REST"
        case .liftStale: "LIFT + ISLAND · STALE"
        }
    }

    private func qaWidget<Content: View>(width: CGFloat, height: CGFloat, tint: DomainTint = .neutral,
                                         @ViewBuilder content: () -> Content) -> some View {
        // Simulate WidgetKit's family-aware content margins (~16 pt on the home screen). The
        // widget views deliberately carry no internal padding — hosting them bare clips the edges
        // and misrepresents what WidgetKit renders.
        content().padding(16).frame(width: width, height: height).background(NOOPWidgetBackground(tint))
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(StrandPalette.hairline))
    }

    private func qaLock<Content: View>(width: CGFloat, height: CGFloat,
                                       @ViewBuilder content: () -> Content) -> some View {
        content().frame(width: width, height: height).foregroundStyle(.white).environment(\.colorScheme, .dark)
            .background(Color.black.opacity(0.86)).clipShape(RoundedRectangle(cornerRadius: min(width, height) / 2.8))
    }
}
#endif
