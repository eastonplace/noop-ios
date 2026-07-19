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
                    widgetStage(width: 158, height: 158) {
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
                            steps: 11_204, calories: 2_140)
                    }
                }
                section("LOCK SCREEN · ACCESSORIES") {
                    VStack(spacing: 20) {
                        HStack(spacing: 30) {
                            lockStage(width: 62, height: 62) {
                                NOOPAccessoryCircularGaugeView(
                                    value: Double(recovery), maximum: 100, accent: .white,
                                    accessibilityName: "Recovery")
                            }
                            lockStage(width: 62, height: 62) {
                                NOOPAccessoryCircularGaugeView(
                                    value: strain, maximum: 21, accent: .white,
                                    accessibilityName: "Strain", decimal: true)
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
                        widgetStage(width: 158, height: 158) {
                            NOOPRecoverySmallWidgetView(
                                recovery: nil, delta: nil, sleepMinutes: nil, batteryPercentage: nil)
                        }
                        lockStage(width: 62, height: 62) {
                            NOOPAccessoryCircularGaugeView(
                                value: nil, maximum: 21, accent: .white,
                                accessibilityName: "Strain", decimal: true)
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

    private func widgetStage<Content: View>(width: CGFloat, height: CGFloat,
                                            @ViewBuilder content: () -> Content) -> some View {
        content().frame(width: width, height: height)
            .background(StrandPalette.surfaceBase)
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
    enum Kind { case home, large, lock, live }
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
                qaWidget(width: 158, height: 158) {
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
                                         steps: 11_204, calories: 2_140)
            }
        case .lock:
            VStack(spacing: 22) {
                HStack(spacing: 34) {
                    qaLock(width: 62, height: 62) {
                        NOOPAccessoryCircularGaugeView(value: 78, maximum: 100, accent: .white,
                                                        accessibilityName: "Recovery")
                    }
                    qaLock(width: 62, height: 62) {
                        NOOPAccessoryCircularGaugeView(value: 8.2, maximum: 21, accent: .white,
                                                        accessibilityName: "Strain", decimal: true)
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
            VStack(spacing: 24) {
                NOOPWorkoutLiveActivityView(title: "Outdoor Run", startedAt: Date().addingTimeInterval(-2_734),
                                            bpm: 152, strain: 6.8, strainBuilding: false,
                                            calories: 438, hrSpark: hr)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                HStack(spacing: 0) {
                    NOOPDynamicIslandHeartRateView(bpm: 152).padding(.leading, 12)
                    Spacer(minLength: 0)
                    Capsule().fill(Color(white: 0.08)).frame(width: 90, height: 24)
                    Spacer(minLength: 0)
                    NOOPDynamicIslandStrainView(strain: 6.8, building: false).padding(.trailing, 12)
                }
                .frame(width: 250, height: 36).background(Capsule().fill(Color.black))
                VStack(spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        NOOPDynamicIslandIdentityView(sport: "Outdoor Run", startedAt: Date().addingTimeInterval(-2_734))
                        Spacer(minLength: 8)
                        NOOPDynamicIslandVitalsView(bpm: 152, strain: 6.8, building: false)
                    }
                    NOOPZoneSplitView(seconds: [180, 620, 1_180, 650, 104])
                }
                .padding(16).frame(width: 356)
                .background(RoundedRectangle(cornerRadius: 30).fill(Color.black))
            }
        }
    }

    private var title: String {
        switch kind { case .home: "HOME"; case .large: "LARGE"; case .lock: "LOCK SCREEN"; case .live: "LIVE + ISLAND" }
    }

    private func qaWidget<Content: View>(width: CGFloat, height: CGFloat,
                                         @ViewBuilder content: () -> Content) -> some View {
        content().frame(width: width, height: height).background(StrandPalette.surfaceBase)
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
