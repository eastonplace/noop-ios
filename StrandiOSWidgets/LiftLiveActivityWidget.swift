import ActivityKit
import Foundation
import SwiftUI
import WidgetKit
import ReceiptLiftActivity
import StrandDesign

struct LiftLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiftLiveActivityAttributes.self) { context in
      LiftLockScreenActivity(context: context)
        .activityBackgroundTint(LiftActivityStyle.paper)
        .activitySystemActionForegroundColor(LiftActivityStyle.ink)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          LiftActivityMark()
        }

        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 2) {
            Text(context.attributes.workoutName.uppercased())
              .font(.system(.headline, design: .rounded).weight(.black))
              .lineLimit(1)
            Text(context.state.currentMove.uppercased())
              .font(.system(.caption2, design: .monospaced).weight(.bold))
              .foregroundStyle(LiftActivityStyle.secondary)
              .lineLimit(1)
          }
        }

        DynamicIslandExpandedRegion(.trailing) {
          LiftActivityClock(context: context)
            .font(.system(.headline, design: .rounded).weight(.bold).monospacedDigit())
        }

        DynamicIslandExpandedRegion(.bottom) {
          LiftActivityMetrics(context: context, showsMove: false)
        }
      } compactLeading: {
        Image(
          systemName: liftActivityIsResting(context)
            ? "timer"
            : "figure.strengthtraining.traditional"
        )
          .foregroundStyle(
            liftActivityIsResting(context) ? LiftActivityStyle.clay : LiftActivityStyle.green
          )
      } compactTrailing: {
        LiftActivityClock(context: context)
          .font(.system(.caption2, design: .rounded).weight(.bold).monospacedDigit())
      } minimal: {
        Image(
          systemName: liftActivityIsResting(context)
            ? "timer"
            : "figure.strengthtraining.traditional"
        )
          .foregroundStyle(
            liftActivityIsResting(context) ? LiftActivityStyle.clay : LiftActivityStyle.green
          )
      }
      .keylineTint(
        liftActivityIsResting(context) ? LiftActivityStyle.clay : LiftActivityStyle.green
      )
    }
  }
}

private func liftActivityIsResting(
  _ context: ActivityViewContext<LiftLiveActivityAttributes>
) -> Bool {
  context.state.isResting && !context.isStale
}

private struct LiftLockScreenActivity: View {
  let context: ActivityViewContext<LiftLiveActivityAttributes>

  var body: some View {
    let isResting = liftActivityIsResting(context)

    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .center, spacing: 12) {
        LiftActivityMark()

        VStack(alignment: .leading, spacing: 2) {
          Text("ACTIVE LIFT")
            .font(.system(size: 10, weight: .black, design: .monospaced))
            .tracking(1.1)
            .foregroundStyle(LiftActivityStyle.clay)
          Text(context.attributes.workoutName.uppercased())
            .font(.system(size: 22, weight: .black, design: .rounded))
            .foregroundStyle(LiftActivityStyle.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }

        Spacer(minLength: 8)

        VStack(alignment: .trailing, spacing: 2) {
          Text(isResting ? "REST" : "ELAPSED")
            .font(.system(size: 9, weight: .black, design: .monospaced))
            .foregroundStyle(LiftActivityStyle.secondary)
          LiftActivityClock(context: context)
            .font(.system(size: 24, weight: .black, design: .rounded).monospacedDigit())
        }
      }

      Rectangle()
        .fill(LiftActivityStyle.ink.opacity(0.18))
        .frame(height: 1)

      LiftActivityMetrics(context: context)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 14)
  }
}

private struct LiftActivityMark: View {
  var body: some View {
    Image(systemName: "figure.strengthtraining.traditional")
      .font(.system(size: 20, weight: .black))
      .foregroundStyle(LiftActivityStyle.paper)
      .frame(width: 42, height: 42)
      .background(LiftActivityStyle.ink, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }
}

private struct LiftActivityClock: View {
  let context: ActivityViewContext<LiftLiveActivityAttributes>

  var body: some View {
    if let restTimerEndDate = context.state.restTimerEndDate, liftActivityIsResting(context) {
      Text(restTimerEndDate, style: .timer)
        .foregroundStyle(LiftActivityStyle.clay)
    } else {
      Text(context.attributes.startedAt, style: .timer)
        .foregroundStyle(LiftActivityStyle.green)
    }
  }
}

private struct LiftActivityMetrics: View {
  let context: ActivityViewContext<LiftLiveActivityAttributes>
  var showsMove = true

  var body: some View {
    HStack(spacing: 16) {
      if showsMove {
        metric(value: context.state.currentMove, label: "MOVE", color: LiftActivityStyle.ink)
      }
      metric(value: context.state.setProgressLabel, label: "SETS", color: LiftActivityStyle.clay)
      metric(value: volumeLabel, label: "VOLUME", color: LiftActivityStyle.green)
    }
  }

  private var volumeLabel: String {
    let volume = max(context.state.volume, 0)
    if volume >= 1_000 {
      return String(format: "%.1fk", volume / 1_000)
    }
    return "\(Int(volume.rounded()))"
  }

  private func metric(value: String, label: String, color: Color) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(value.uppercased())
        .font(.system(size: 14, weight: .black, design: .rounded))
        .foregroundStyle(color)
        .lineLimit(1)
        .minimumScaleFactor(0.62)
      Text(label)
        .font(.system(size: 8, weight: .black, design: .monospaced))
        .foregroundStyle(LiftActivityStyle.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

private enum LiftActivityStyle {
  static let ink = StrandPalette.textPrimary
  static let paper = StrandPalette.card
  static let secondary = StrandPalette.textSecondary
  static let clay = StrandPalette.stressAccent
  static let green = StrandPalette.accent
}
