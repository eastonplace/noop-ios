@preconcurrency import ActivityKit
import Foundation
import ReceiptLiftActivity

@MainActor
final class LiftLiveActivityManager {
  static let shared = LiftLiveActivityManager()

  private var liveActivity: Activity<LiftLiveActivityAttributes>?

  private init() {}

  func sync(
    session: LiftSession,
    progress: LiftRoutineProgress?,
    currentMove: String,
    restTimerEndDate: Date?,
    weightUnit: LiftWeightUnit
  ) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

    let state = Self.contentState(
      session: session,
      progress: progress,
      currentMove: currentMove,
      restTimerEndDate: restTimerEndDate,
      weightUnit: weightUnit
    )
    let content = ActivityContent(state: state, staleDate: state.restStaleDate)

    if let activity = matchingActivity(for: session.id) {
      liveActivity = activity
      Task { @MainActor [activity] in
        await activity.update(content)
      }
      return
    }

    endActivities(except: session.id, dismissalPolicy: .immediate)

    let attributes = LiftLiveActivityAttributes(
      sessionID: session.id,
      workoutName: session.title,
      startedAt: session.startedAt
    )

    do {
      liveActivity = try Activity.request(
        attributes: attributes,
        content: content,
        pushType: nil
      )
    } catch {
      NSLog("Lift Live Activity start failed: \(String(describing: error))")
    }
  }

  func finish(
    session: LiftSession,
    progress: LiftRoutineProgress?,
    currentMove: String,
    restTimerEndDate: Date?,
    weightUnit: LiftWeightUnit
  ) {
    let finalState = Self.contentState(
      session: session,
      progress: progress,
      currentMove: currentMove,
      restTimerEndDate: restTimerEndDate,
      weightUnit: weightUnit
    )
    guard let activity = matchingActivity(for: session.id) else { return }
    liveActivity = nil
    Task { @MainActor [activity] in
      await activity.end(
        ActivityContent(state: finalState, staleDate: nil),
        dismissalPolicy: .after(Date().addingTimeInterval(60))
      )
    }
  }

  func discard(sessionID: UUID?) {
    liveActivity = nil
    let activities = Activity<LiftLiveActivityAttributes>.activities.filter { activity in
      sessionID == nil || activity.attributes.sessionID == sessionID
    }
    for activity in activities {
      Task { @MainActor [activity] in
        await activity.end(nil, dismissalPolicy: .immediate)
      }
    }
  }

  private func matchingActivity(for sessionID: UUID) -> Activity<LiftLiveActivityAttributes>? {
    if let liveActivity, liveActivity.attributes.sessionID == sessionID {
      return liveActivity
    }
    return Activity<LiftLiveActivityAttributes>.activities.first {
      $0.attributes.sessionID == sessionID
    }
  }

  private func endActivities(
    except sessionID: UUID,
    dismissalPolicy: ActivityUIDismissalPolicy
  ) {
    for activity in Activity<LiftLiveActivityAttributes>.activities where activity.attributes.sessionID != sessionID {
      Task { @MainActor [activity] in
        await activity.end(nil, dismissalPolicy: dismissalPolicy)
      }
    }
  }

  /// The Lock Screen and Dynamic Island show the volume in the person's unit like everywhere else in Lift (loads are
  /// stored in pounds), so it is converted here rather than left as the stored pound total, and the unit rides with it
  /// ("lb" or "kg") so the figure is never a bare number.
  nonisolated static func contentState(
    session: LiftSession,
    progress: LiftRoutineProgress?,
    currentMove: String,
    restTimerEndDate: Date?,
    weightUnit: LiftWeightUnit,
    now: Date = Date()
  ) -> LiftLiveActivityAttributes.ContentState {
    LiftLiveActivityAttributes.ContentState(
      currentMove: currentMove,
      completedSets: progress?.completedSets ?? session.workingSets.count,
      targetSets: progress?.targetSets ?? 0,
      volume: weightUnit.fromPounds(session.totalVolume),
      restTimerEndDate: restTimerEndDate,
      updatedAt: now,
      volumeUnit: weightUnit == .pounds ? "lb" : "kg"
    )
  }
}
