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
    restTimerEndDate: Date?
  ) {
    guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

    let state = contentState(
      session: session,
      progress: progress,
      currentMove: currentMove,
      restTimerEndDate: restTimerEndDate
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
    restTimerEndDate: Date?
  ) {
    let finalState = contentState(
      session: session,
      progress: progress,
      currentMove: currentMove,
      restTimerEndDate: restTimerEndDate
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

  private func contentState(
    session: LiftSession,
    progress: LiftRoutineProgress?,
    currentMove: String,
    restTimerEndDate: Date?
  ) -> LiftLiveActivityAttributes.ContentState {
    LiftLiveActivityAttributes.ContentState(
      currentMove: currentMove,
      completedSets: progress?.completedSets ?? session.workingSets.count,
      targetSets: progress?.targetSets ?? 0,
      volume: session.totalVolume,
      restTimerEndDate: restTimerEndDate,
      updatedAt: Date()
    )
  }
}
