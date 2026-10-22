import Foundation

struct LiftSevenDaySummary: Equatable, Sendable {
  let workoutCount: Int
  let workingSetCount: Int
  let volume: Double

  static let zero = LiftSevenDaySummary(workoutCount: 0, workingSetCount: 0, volume: 0)
}

/// The THIS WEEK card: the calendar week the date falls in, never a rolling seven days.
struct LiftWeekSummary: Equatable, Sendable {
  let interval: DateInterval
  let workouts: Int
  /// Workouts scheduled inside the week, finished or not.
  let plannedThisWeek: Int
  let workingSets: Int
  /// Working sets this week minus last week's.
  let workingSetsDeltaVsLastWeek: Int
  /// Total volume in pounds, warm-ups included, the same figure `LiftSession.totalVolume` reports.
  let volume: Double
}

enum LiftTodayMath {
  nonisolated static func weekSummary(
    in sessions: [LiftSession],
    scheduled: [ScheduledWorkout],
    asOf date: Date,
    calendar: Calendar
  ) -> LiftWeekSummary {
    let interval = calendar.dateInterval(of: .weekOfYear, for: date) ?? DateInterval(start: date, duration: 7 * 86_400)
    let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: interval.start) ?? interval.start
    let lastWeek = DateInterval(start: lastWeekStart, end: interval.start)

    var workouts = 0
    var workingSets = 0
    var lastWeekSets = 0
    var volume = 0.0
    for session in sessions where session.endedAt != nil {
      // Calendar buckets include their start and exclude the next week's start.
      // DateInterval.contains includes both endpoints and can count next Monday twice.
      if session.startedAt >= interval.start && session.startedAt < interval.end {
        workouts += 1
        volume += session.totalVolume
        workingSets += session.workingSets.count
      } else if session.startedAt >= lastWeek.start && session.startedAt < lastWeek.end {
        lastWeekSets += session.workingSets.count
      }
    }
    let planned = scheduled.filter { $0.plannedAt >= interval.start && $0.plannedAt < interval.end }.count
    return LiftWeekSummary(
      interval: interval, workouts: workouts, plannedThisWeek: planned, workingSets: workingSets,
      workingSetsDeltaVsLastWeek: workingSets - lastWeekSets, volume: volume)
  }

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
