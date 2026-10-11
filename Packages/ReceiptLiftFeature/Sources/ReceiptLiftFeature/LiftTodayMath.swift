import Foundation

struct LiftSevenDaySummary: Equatable, Sendable {
  let workoutCount: Int
  let workingSetCount: Int
  let volume: Double

  static let zero = LiftSevenDaySummary(workoutCount: 0, workingSetCount: 0, volume: 0)
}

enum LiftTodayMath {
  nonisolated static func sevenDaySummary(
    in sessions: [LiftSession],
    asOf date: Date,
    calendar: Calendar
  ) -> LiftSevenDaySummary {
    let start = calendar.date(byAdding: .day, value: -7, to: date) ?? date
    var workoutCount = 0
    var workingSetCount = 0
    var volume = 0.0

    for session in sessions where session.endedAt != nil
      && session.startedAt >= start
      && session.startedAt <= date {
      workoutCount += 1
      for set in session.sets {
        volume += set.volume
        if !set.isWarmup {
          workingSetCount += 1
        }
      }
    }

    return LiftSevenDaySummary(
      workoutCount: workoutCount,
      workingSetCount: workingSetCount,
      volume: volume
    )
  }

  nonisolated static func recentCompletedSessions(
    in sessions: [LiftSession],
    limit: Int
  ) -> [LiftSession] {
    guard limit > 0 else { return [] }
    var recent: [LiftSession] = []
    recent.reserveCapacity(min(limit, sessions.count))

    for session in sessions where session.endedAt != nil {
      let insertionIndex = recent.firstIndex { candidate in
        isMoreRecent(session, than: candidate)
      } ?? recent.endIndex
      recent.insert(session, at: insertionIndex)
      if recent.count > limit {
        recent.removeLast()
      }
    }

    return recent
  }

  private nonisolated static func isMoreRecent(
    _ lhs: LiftSession,
    than rhs: LiftSession
  ) -> Bool {
    if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
    return lhs.id.uuidString < rhs.id.uuidString
  }
}
