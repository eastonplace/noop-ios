import WidgetKit
import SwiftUI
import ActivityKit
import StrandDesign

/// Live Activity for an active live-HR session — shown on the Lock Screen and in the Dynamic Island.
struct NOOPLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NOOPActivityAttributes.self) { context in
            Group {
                if context.state.isWorkout { workoutBanner(context: context) }
                else { liveHRBanner(context: context) }
            }
            .activityBackgroundTint(StrandPalette.surfaceBase)
            .activitySystemActionForegroundColor(StrandPalette.textPrimary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(context.state.bpm.map(String.init) ?? "—")", systemImage: "heart.fill")
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    statColumn(label: "Strain", value: strainLabel(context.state))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.isWorkout {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(context.state.sport ?? "Workout").font(.caption.weight(.semibold))
                                if let start = context.state.workoutStartedAt {
                                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            zoneSplit(context.state.zoneSeconds)
                        }
                    } else {
                        Text(context.attributes.title).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
                    Text(context.state.bpm.map(String.init) ?? "—")
                }
            } compactTrailing: {
                Text(context.state.isWorkout ? strainLabel(context.state)
                                             : (context.state.bpm.map(String.init) ?? "—"))
            } minimal: {
                Image(systemName: "heart.fill").foregroundStyle(StrandPalette.statusCritical)
            }
        }
    }
}

@ViewBuilder
private func liveHRBanner(context: ActivityViewContext<NOOPActivityAttributes>) -> some View {
    HStack(spacing: 14) {
        Image(systemName: "waveform.path.ecg").font(.title2).foregroundStyle(StrandPalette.statusCritical)
        VStack(alignment: .leading, spacing: 2) {
            Text(context.attributes.title).font(.caption).foregroundStyle(StrandPalette.textSecondary)
            Text("\(context.state.bpm.map(String.init) ?? "—") bpm")
                .font(.system(size: 26, weight: .bold, design: .rounded))
        }
        Spacer()
        if let recovery = context.state.recovery { bannerStat(label: "Recovery", value: "\(recovery)%") }
        bannerStat(label: "Strain", value: strainLabel(context.state))
    }
    .padding()
}

@ViewBuilder
private func workoutBanner(context: ActivityViewContext<NOOPActivityAttributes>) -> some View {
    VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(context.state.sport ?? "Workout").font(.headline)
                if let start = context.state.workoutStartedAt {
                    Text(timerInterval: start...Date.distantFuture, countsDown: false)
                        .font(.caption.monospacedDigit()).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer()
            bannerStat(label: "HR", value: "\(context.state.bpm.map(String.init) ?? "—")")
            bannerStat(label: "Strain", value: strainLabel(context.state))
            if let calories = context.state.calories { bannerStat(label: "kcal", value: "\(calories)") }
        }
        HStack(spacing: 8) {
            miniTrace(context.state.hrTrace)
            zoneSplit(context.state.zoneSeconds)
        }
    }
    .padding()
}

private func strainLabel(_ state: NOOPActivityAttributes.ContentState) -> String {
    if state.strainBuilding == true { return "Building" }
    return state.effort.map { String(format: "%.1f", $0) } ?? "—"
}

@ViewBuilder
private func zoneSplit(_ seconds: [Int]?) -> some View {
    let values = seconds ?? []
    let total = max(1, values.reduce(0, +))
    HStack(spacing: 2) {
        ForEach(Array(values.enumerated()), id: \.offset) { index, value in
            Capsule()
                .fill([Color.blue, .green, .yellow, .orange, .red][min(index, 4)])
                .frame(width: max(3, CGFloat(value) / CGFloat(total) * 54), height: 5)
        }
    }
    .accessibilityLabel("Workout heart rate zone distribution")
}

@ViewBuilder
private func miniTrace(_ samples: [Int]?) -> some View {
    GeometryReader { geometry in
        let values = samples ?? []
        if values.count > 1, let low = values.min(), let high = values.max() {
            Path { path in
                for (index, value) in values.enumerated() {
                    let x = geometry.size.width * CGFloat(index) / CGFloat(values.count - 1)
                    let y = geometry.size.height * (1 - CGFloat(value - low) / CGFloat(max(1, high - low)))
                    if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                    else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(StrandPalette.statusCritical, style: .init(lineWidth: 2, lineCap: .round))
        }
    }
    .frame(height: 20)
}

/// Lock-Screen banner stat column (label over value). File-scope because the `ActivityConfiguration`
/// content closure isn't a method of `NOOPLiveActivity`.
///
/// #759 - the label and value are CENTRE-aligned so each value sits directly under its own label. The
/// old `.trailing` alignment right-pinned both to the column's edge: when the value was narrower than
/// the label (e.g. "12" under "Strain") it drifted to the label's right edge instead of under it, which
/// read as "the number doesn't line up with its label". `fixedSize` stops either line truncating so the
/// pairing is never clipped at narrow widths.
@ViewBuilder
private func bannerStat(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 2) {
        Text(label).font(.caption2).foregroundStyle(StrandPalette.textSecondary)
        Text(value).font(.headline).foregroundStyle(StrandPalette.textPrimary)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}

/// Dynamic Island expanded-region stat column (label over value). File-scope for the same reason as
/// `bannerStat`. #759 - centre-aligned + `fixedSize` for the same value-under-its-label fix as the banner.
@ViewBuilder
private func statColumn(label: String, value: String) -> some View {
    VStack(alignment: .center, spacing: 1) {
        Text(label).font(.caption2).foregroundStyle(.secondary)
        Text(value).font(.headline)
    }
    .multilineTextAlignment(.center)
    .fixedSize()
}
