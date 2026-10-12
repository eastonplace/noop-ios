import ActivityKit
import Foundation

public struct LiftLiveActivityAttributes: ActivityAttributes {
  public struct ContentState: Codable, Hashable {
    public init(currentMove: String, completedSets: Int, targetSets: Int, volume: Double, restTimerEndDate: Date?, updatedAt: Date,
                volumeUnit: String? = nil) {
      self.currentMove = currentMove; self.completedSets = completedSets; self.targetSets = targetSets
      self.volume = volume; self.restTimerEndDate = restTimerEndDate; self.updatedAt = updatedAt
      self.volumeUnit = volumeUnit
    }
    public var currentMove: String
    public var completedSets: Int
    public var targetSets: Int
    /// The total lifted, already in the person's unit (`volumeUnit`).
    public var volume: Double
    /// The unit `volume` is in: "lb" or "kg". nil (an activity started by an older build) reads as a bare number, as it
    /// always did, so an old payload still decodes and still draws.
    public var volumeUnit: String?
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
