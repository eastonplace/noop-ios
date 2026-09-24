import ActivityKit
import Foundation

public struct LiftLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public init(currentMove: String, completedSets: Int, targetSets: Int, volume: Double, restTimerEndDate: Date?, updatedAt: Date) {
      self.currentMove = currentMove; self.completedSets = completedSets; self.targetSets = targetSets
      self.volume = volume; self.restTimerEndDate = restTimerEndDate; self.updatedAt = updatedAt
    }
    public var currentMove: String
    public var completedSets: Int
    public var targetSets: Int
    public var volume: Double
    public var restTimerEndDate: Date?
    public var updatedAt: Date

    public var setProgressLabel: String {
      guard targetSets > 0 else { return "\(max(completedSets, 0))" }
      return "\(min(max(completedSets, 0), targetSets))/\(targetSets)"
    }

    public var isResting: Bool {
      guard let restTimerEndDate else { return false }
      return restTimerEndDate > updatedAt
    }

    public var restStaleDate: Date? {
      isResting ? restTimerEndDate : nil
    }
  }

  public init(sessionID: UUID, workoutName: String, startedAt: Date) {
    self.sessionID = sessionID; self.workoutName = workoutName; self.startedAt = startedAt
  }
  public var sessionID: UUID
  public var workoutName: String
  public var startedAt: Date
}
