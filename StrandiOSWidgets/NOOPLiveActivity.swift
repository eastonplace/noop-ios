import WidgetKit
import SwiftUI
import ActivityKit
import AppIntents
import StrandDesign

/// ActivityKit host for Design Lab component 41. Workout mode uses the same shared visual
/// leaves as the simulator QA gallery; passive live HR intentionally remains the simpler mode.
///
/// The workout's Pause / Resume button is a `Button(intent:)` on a `LiveActivityIntent`, so a press runs in the app's
/// process and reaches the recorder. The intent names the state it wants, never a toggle, and the activity is rewritten
/// from the app's own state on every pause edge, so the Lock Screen and the app cannot disagree for longer than a push.
struct NOOPLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            Group {
                if context.state.isWorkout {
                    NOOPWorkoutLiveActivityView(
                        title: context.state.sport ?? "Workout",
                        startedAt: context.state.workoutStartedAt,
                        pausedAt: context.state.pausedAt,
                        frozenAt: context.state.frozenAt,
                        bpm: context.state.bpm,
                        strain: context.state.effort,
                        strainBuilding: context.state.strainBuilding == true,
                        calories: context.state.calories,
                        hrSpark: context.state.hrTrace,
                        maxHR: liveMaxHR(context.state),
                        isStale: context.isStale,
                        heartRateIsLive: context.state.heartRateIsLive,
                        isEnding: context.state.finishing
                    ) {
                        PauseResumeButton(isPaused: context.state.pausedAt != nil, isCompact: false, isAvailable: !context.state.finishing)
                    }
                } else {
                    liveHRBanner(context: context)
                }
            }
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.white)
            .widgetURL(context.state.isWorkout ? WorkoutDeepLink.activeRun.url : nil)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    if context.state.isWorkout {
                        NOOPDynamicIslandIdentityView(
                            sport: context.state.sport ?? "Workout",
                            startedAt: context.state.workoutStartedAt,
                            pausedAt: context.state.pausedAt,
                            frozenAt: context.state.frozenAt,
                            isEnding: context.state.finishing)
                    } else {
                        NOOPDynamicIslandHeartRateView(bpm: context.state.bpm, maxHR: liveMaxHR(context.state))
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.isWorkout {
                        NOOPDynamicIslandVitalsView(
                            bpm: context.state.bpm, strain: context.state.effort,
                            building: context.state.strainBuilding == true, maxHR: liveMaxHR(context.state),
                            isDimmed: context.state.pausedAt != nil || context.isStale || !context.state.heartRateIsLive)
                    } else if let recovery = context.state.recovery {
                        Text("Recovery \(recovery)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isWorkout {
                        HStack(spacing: 12) {
                            LiveZoneRail(
                                bpm: context.state.bpm,
                                thresholds: liveMaxHR(context.state).map { HRZoneStyle.Thresholds(hrMax: $0) } ?? .default,
                                isDimmed: context.state.pausedAt != nil || context.isStale || !context.state.heartRateIsLive,
                                style: .bar)
                            // Why the Pause beside it has gone quiet: the workout is ending.
                            if context.state.finishing { NOOPLiveEndingPill() }
                            PauseResumeButton(isPaused: context.state.pausedAt != nil, isCompact: true, isAvailable: !context.state.finishing)
                        }
                        .padding(.top, 6)
                    } else {
                        Text(context.attributes.title)
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
            } compactLeading: {
                if context.state.isWorkout {
                    NOOPDynamicIslandHeartRateView(
                        bpm: context.state.bpm, maxHR: liveMaxHR(context.state), isPaused: context.state.pausedAt != nil,
                        isDimmed: context.state.pausedAt != nil || context.isStale || !context.state.heartRateIsLive)
                } else {
                    // Passive HR is shown in compactTrailing. Repeating it here
                    // crowds the compact island and clips the duplicate digits.
                    Image(systemName: "heart.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(context.state.bpm.map { HRZoneStyle.color(for: Double($0), thresholds: liveThresholds(context.state)) }
                                         ?? Color.white.opacity(0.5))
                }
            } compactTrailing: {
                if context.state.isWorkout {
                    NOOPDynamicIslandTimerView(
                        startedAt: context.state.workoutStartedAt, pausedAt: context.state.pausedAt,
                        frozenAt: context.state.frozenAt)
                } else {
                    Text(context.state.bpm.map(String.init) ?? "—")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit().foregroundStyle(.white)
                }
            } minimal: {
                if context.state.isWorkout {
                    NOOPDynamicIslandMinimalView(
                        bpm: context.state.bpm, maxHR: liveMaxHR(context.state), isPaused: context.state.pausedAt != nil,
                        isDimmed: context.isStale || !context.state.heartRateIsLive)
                } else {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(context.state.bpm.map { HRZoneStyle.color(for: Double($0), thresholds: liveThresholds(context.state)) }
                                         ?? Color.white.opacity(0.5))
                }
            }
            .widgetURL(context.state.isWorkout ? WorkoutDeepLink.activeRun.url : nil)
        }
    }
}

/// The wearer's maximum heart rate: the one the app put in the activity, else the one it shared with the widgets, else nil
/// (the fixed 60 / 110 split).
private func liveMaxHR(_ state: NOOPActivityAttributes.ContentState) -> Double? {
    state.maxHR ?? WidgetPersonalZones.hrMax()
}

private func liveThresholds(_ state: NOOPActivityAttributes.ContentState) -> HRZoneStyle.Thresholds {
    liveMaxHR(state).map { HRZoneStyle.Thresholds(hrMax: $0) } ?? .default
}

/// The button that pauses a running workout and resumes a paused one.
private struct PauseResumeButton: View {
    let isPaused: Bool
    let isCompact: Bool
    /// False while the workout is being ended: the recorder refuses a pause or resume then, so the button is shown
    /// unavailable instead of offering a tap that does nothing.
    var isAvailable = true

    var body: some View {
        Button(intent: SetWorkoutPausedIntent(paused: !isPaused)) {
            NOOPLivePauseButtonLabel(isPaused: isPaused, isCompact: isCompact)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .opacity(isAvailable ? 1 : 0.35)
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
