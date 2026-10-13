import ActivityKit
import Foundation
import SwiftUI
import WidgetKit
import ReceiptLiftActivity
import StrandDesign

/// The strength-training Live Activity. Same black card, eyebrow and fact strip as the cardio one
/// (`NOOPLiveActivity`); the views live in StrandDesign so the simulator QA gallery draws the very same ones.
/// Behaviour is unchanged: no buttons, the clock is the system's own timer text, and a rest in progress is read as a
/// rest only until ActivityKit marks the activity stale.
struct LiftLiveActivityWidget: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: LiftLiveActivityAttributes.self) { context in
      NOOPLiftLiveActivityView(
        workoutName: context.attributes.workoutName,
        startedAt: context.attributes.startedAt,
        move: context.state.currentMove,
        setProgress: context.state.setProgressLabel,
        volume: context.state.volume,
        volumeUnit: context.state.volumeUnit,
        restEndsAt: liftActivityRestEnd(context),
        isStale: context.isStale)
        .activityBackgroundTint(.black)
        .activitySystemActionForegroundColor(.white)
        .widgetURL(WorkoutDeepLink.activeLift.url)
        // Rendered by the system against a watchdog: the eyebrow starts no task or repeating animation here.
        .environment(\.strandRendersStatically, true)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          NOOPLiftIslandGlyph(isResting: liftActivityIsResting(context))
            .font(.system(size: 20, weight: .bold))
        }

        DynamicIslandExpandedRegion(.center) {
          NOOPLiftIslandTitle(
            workoutName: context.attributes.workoutName, move: context.state.currentMove)
        }

        DynamicIslandExpandedRegion(.trailing) {
          NOOPLiftIslandClock(
            startedAt: context.attributes.startedAt, restEndsAt: liftActivityRestEnd(context), size: 22)
        }

        DynamicIslandExpandedRegion(.bottom) {
          NOOPLiftFacts(
            move: nil, setProgress: context.state.setProgressLabel, volume: context.state.volume,
            volumeUnit: context.state.volumeUnit)
            .padding(.top, 4)
        }
      } compactLeading: {
        NOOPLiftIslandGlyph(isResting: liftActivityIsResting(context))
      } compactTrailing: {
        NOOPLiftIslandClock(
          startedAt: context.attributes.startedAt, restEndsAt: liftActivityRestEnd(context))
      } minimal: {
        NOOPLiftIslandGlyph(isResting: liftActivityIsResting(context))
      }
      .keylineTint(
        liftActivityIsResting(context) ? StrandPalette.statusWarning : StrandPalette.strainAccent
      )
      .widgetURL(WorkoutDeepLink.activeLift.url)
    }
  }
}

private func liftActivityIsResting(
  _ context: ActivityViewContext<LiftLiveActivityAttributes>
) -> Bool {
  context.state.isResting && !context.isStale
}

/// The rest timer's end, only while it is still to be believed.
private func liftActivityRestEnd(
  _ context: ActivityViewContext<LiftLiveActivityAttributes>
) -> Date? {
  liftActivityIsResting(context) ? context.state.restTimerEndDate : nil
}
