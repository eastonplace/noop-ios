import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// ActivityKit host for Design Lab component 41. Workout mode uses the same shared visual
/// leaves as the simulator QA gallery; passive live HR intentionally remains the simpler mode.
struct NOOPLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            Group {
                if context.state.isWorkout {
                    NOOPWorkoutLiveActivityView(
                        title: context.state.sport ?? "Workout",
                        startedAt: context.state.workoutStartedAt,
                        bpm: context.state.bpm,
                        strain: context.state.effort,
                        strainBuilding: context.state.strainBuilding == true,
                        calories: context.state.calories,
                        hrSpark: context.state.hrTrace)
                } else {
                    liveHRBanner(context: context)
                }
            }
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if context.state.isWorkout {
                        NOOPDynamicIslandIdentityView(
                            sport: context.state.sport ?? "Workout",
                            startedAt: context.state.workoutStartedAt)
                    } else {
                        NOOPDynamicIslandHeartRateView(bpm: context.state.bpm)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isWorkout {
                        NOOPDynamicIslandVitalsView(
                            bpm: context.state.bpm, strain: context.state.effort,
                            building: context.state.strainBuilding == true)
                    } else if let recovery = context.state.recovery {
                        Text("Recovery \(recovery)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isWorkout {
                        NOOPZoneSplitView(seconds: context.state.zoneSeconds)
                            .padding(.top, 6)
                    } else {
                        Text(context.attributes.title)
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
            } compactLeading: {
                NOOPDynamicIslandHeartRateView(bpm: context.state.bpm)
            } compactTrailing: {
                if context.state.isWorkout {
                    NOOPDynamicIslandStrainView(
                        strain: context.state.effort,
                        building: context.state.strainBuilding == true)
                } else {
                    Text(context.state.bpm.map(String.init) ?? "—")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.white)
                }
            } minimal: {
                Image(systemName: "heart.fill")
                    .foregroundStyle(context.state.bpm.map { HRZoneStyle.color(for: Double($0)) }
                                     ?? Color.white.opacity(0.5))
            }
        }
    }
}

@ViewBuilder
private func liveHRBanner(context: ActivityViewContext<NOOPActivityAttributes>) -> some View {
    HStack(spacing: 14) {
        Image(systemName: "waveform.path.ecg")
            .font(.title2).foregroundStyle(StrandPalette.metricRose)
        VStack(alignment: .leading, spacing: 2) {
            Text("LIVE · NOOP")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .tracking(0.8).foregroundStyle(.white.opacity(0.5))
            Text("\(context.state.bpm.map(String.init) ?? "—") BPM")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .monospacedDigit().foregroundStyle(.white)
        }
        Spacer()
        if let recovery = context.state.recovery {
            liveStat(label: "Recovery", value: "\(recovery)%")
        }
        liveStat(label: "Strain", value: strainLabel(context.state))
    }
    .padding(14)
    .background(Color.black)
}

private func strainLabel(_ state: NOOPActivityAttributes.ContentState) -> String {
    if state.strainBuilding == true { return "Building" }
    return state.effort.map { String(format: "%.1f", $0) } ?? "—"
}

@ViewBuilder
private func liveStat(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label.uppercased())
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
        Text(value).font(.system(size: 15, weight: .bold, design: .rounded))
            .monospacedDigit().foregroundStyle(.white)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}
