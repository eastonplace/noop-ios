import Foundation

enum LiftHistorySegment: String, CaseIterable, Identifiable, Sendable {
  case receipts
  case progress

  var id: String { rawValue }
  var title: String { rawValue.uppercased() }
}

enum LiftProgressRange: String, CaseIterable, Identifiable, Sendable {
  case fourWeeks
  case twelveWeeks
  case sixMonths
  case all

  var id: String { rawValue }

  var title: String {
    switch self {
    case .fourWeeks: "4W"
    case .twelveWeeks: "12W"
    case .sixMonths: "6M"
    case .all: "ALL"
    }
  }
}

struct LiftProgressWindow: Equatable, Sendable {
  let startInclusive: Date
  let endInclusive: Date
  let weekStarts: [Date]
  let displayEndExclusive: Date
}

struct LiftWeeklyVolume: Identifiable, Equatable, Sendable {
  var id: Date { weekStart }
  let weekStart: Date
  let volume: Double
  let workoutCount: Int
}

struct LiftProgressMetrics: Equatable, Sendable {
  let workDone: Double
  let workouts: Int
  let workingSets: Int
  let averageDuration: TimeInterval
  let consistencyPercent: Double
  let exerciseCount: Int

  static let zero = LiftProgressMetrics(
    workDone: 0,
    workouts: 0,
    workingSets: 0,
    averageDuration: 0,
    consistencyPercent: 0,
    exerciseCount: 0
  )
}

struct LiftTopExercise: Identifiable, Equatable, Sendable {
  var id: UUID { exerciseID }
  let exerciseID: UUID
  let name: String
  let volume: Double
}

struct LiftProgressSnapshot: Equatable, Sendable {
  let range: LiftProgressRange
  let window: LiftProgressWindow
  let weeklyVolume: [LiftWeeklyVolume]
  let metrics: LiftProgressMetrics
  let topExercises: [LiftTopExercise]
}

enum LiftExerciseProgressMode: String, CaseIterable, Identifiable, Sendable {
  case strength
  case volume
  case reps

  var id: String { rawValue }
  var title: String { rawValue.uppercased() }
}

struct LiftRecentSetRow: Identifiable, Equatable, Sendable {
  var id: UUID { self.set.id }
  let session: LiftSession
  let set: LiftSet
  let setIndex: Int
}

struct LiftHistoricalPRLedger: Equatable, Sendable {
  let recordsBySetID: [UUID: LiftPersonalRecord]

  subscript(setID: UUID) -> LiftPersonalRecord? {
    recordsBySetID[setID]
  }
}

struct LiftExerciseProgressSnapshot: Equatable, Sendable {
  let points: [VolumePoint]
  let recentSets: [LiftRecentSetRow]
  let bestSet: LiftSet?
  let historicalPersonalRecords: LiftHistoricalPRLedger
  let latestPersonalRecord: LiftPersonalRecord?
}

enum LiftProgressMath {
  nonisolated static func window(
    for range: LiftProgressRange,
    sessions: [LiftSession],
    now: Date,
    calendar: Calendar
  ) -> LiftProgressWindow {
    let currentWeek = weekStart(for: now, calendar: calendar)
    let start: Date

    switch range {
    case .fourWeeks:
      start = calendar.date(byAdding: .weekOfYear, value: -3, to: currentWeek) ?? currentWeek
    case .twelveWeeks:
      start = calendar.date(byAdding: .weekOfYear, value: -11, to: currentWeek) ?? currentWeek
    case .sixMonths:
      let currentMonth = calendar.dateInterval(of: .month, for: now)?.start
        ?? calendar.startOfDay(for: now)
      start = calendar.date(byAdding: .month, value: -5, to: currentMonth) ?? currentMonth
    case .all:
      let earliest = sessions.lazy
        .filter { $0.endedAt != nil && $0.startedAt <= now }
        .map(\.startedAt)
        .min()
      start = weekStart(for: earliest ?? now, calendar: calendar)
    }

    var weeks: [Date] = []
    var cursor = weekStart(for: start, calendar: calendar)
    while cursor <= currentWeek {
      weeks.append(cursor)
      guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor), next > cursor else {
        break
      }
      cursor = next
    }
    if weeks.isEmpty {
      weeks = [currentWeek]
    }

    let displayEnd = calendar.date(byAdding: .weekOfYear, value: 1, to: currentWeek) ?? now
    return LiftProgressWindow(
      startInclusive: start,
      endInclusive: now,
      weekStarts: weeks,
      displayEndExclusive: displayEnd
    )
  }

  nonisolated static func snapshot(
    sessions: [LiftSession],
    range: LiftProgressRange,
    now: Date,
    calendar: Calendar,
    exerciseNames: [UUID: String]
  ) -> LiftProgressSnapshot {
    let progressWindow = window(
      for: range,
      sessions: sessions,
      now: now,
      calendar: calendar
    )
    let eligible = sessions.filter {
      $0.endedAt != nil
        && $0.startedAt >= progressWindow.startInclusive
        && $0.startedAt <= now
    }

    var buckets = Dictionary(
      uniqueKeysWithValues: progressWindow.weekStarts.map {
        ($0, (volume: 0.0, workouts: 0))
      }
    )
    var workDone = 0.0
    var workingSets = 0
    var duration = 0.0
    var activeWeeks = Set<Date>()
    var exercised = Set<UUID>()
    var volumeByExercise: [UUID: Double] = [:]

    for session in eligible {
      let volume = session.totalVolume
      let sessionWeek = weekStart(for: session.startedAt, calendar: calendar)
      if buckets[sessionWeek] != nil {
        buckets[sessionWeek, default: (0, 0)].volume += volume
        buckets[sessionWeek, default: (0, 0)].workouts += 1
        activeWeeks.insert(sessionWeek)
      }
      workDone += volume
      workingSets += session.workingSets.count
      duration += max((session.endedAt ?? session.startedAt).timeIntervalSince(session.startedAt), 0)

      for set in session.sets {
        exercised.insert(set.exerciseID)
        volumeByExercise[set.exerciseID, default: 0] += set.volume
      }
    }

    let weekly = progressWindow.weekStarts.map { week in
      let bucket = buckets[week] ?? (0, 0)
      return LiftWeeklyVolume(
        weekStart: week,
        volume: bucket.volume,
        workoutCount: bucket.workouts
      )
    }
    let workouts = eligible.count
    let denominator = progressWindow.weekStarts.count
    let consistency = denominator > 0
      ? Double(activeWeeks.count) / Double(denominator) * 100
      : 0
    let metrics = LiftProgressMetrics(
      workDone: workDone,
      workouts: workouts,
      workingSets: workingSets,
      averageDuration: workouts > 0 ? duration / Double(workouts) : 0,
      consistencyPercent: consistency,
      exerciseCount: exercised.count
    )

    let top = volumeByExercise.compactMap { exerciseID, volume -> LiftTopExercise? in
      guard volume > 0 else { return nil }
      return LiftTopExercise(
        exerciseID: exerciseID,
        name: exerciseNames[exerciseID] ?? "EXERCISE",
        volume: volume
      )
    }
    .sorted { left, right in
      if left.volume != right.volume { return left.volume > right.volume }
      let leftInjected = exerciseNames[left.exerciseID]
      let rightInjected = exerciseNames[right.exerciseID]
      let leftKey = foldedSortKey(leftInjected ?? left.exerciseID.uuidString)
      let rightKey = foldedSortKey(rightInjected ?? right.exerciseID.uuidString)
      if leftKey != rightKey { return leftKey < rightKey }
      let leftExact = leftInjected ?? left.exerciseID.uuidString
      let rightExact = rightInjected ?? right.exerciseID.uuidString
      if leftExact != rightExact { return leftExact < rightExact }
      return left.exerciseID.uuidString < right.exerciseID.uuidString
    }

    return LiftProgressSnapshot(
      range: range,
      window: progressWindow,
      weeklyVolume: weekly,
      metrics: metrics,
      topExercises: Array(top.prefix(5))
    )
  }

  nonisolated static func exercisePoints(
    sessions: [LiftSession],
    exerciseID: UUID,
    now: Date,
    calendar: Calendar
  ) -> [VolumePoint] {
    struct Aggregate {
      var volume = 0.0
      var bestEstimatedOneRepMax = 0.0
      var bestReps = 0
    }

    var days: [Date: Aggregate] = [:]
    for session in sessions where session.endedAt != nil && session.startedAt <= now {
      for set in session.sets where set.exerciseID == exerciseID && set.completedAt <= now {
        let day = calendar.startOfDay(for: set.completedAt)
        var aggregate = days[day, default: Aggregate()]
        aggregate.volume += set.volume
        if !set.isWarmup {
          aggregate.bestEstimatedOneRepMax = max(
            aggregate.bestEstimatedOneRepMax,
            set.estimatedOneRepMax
          )
          aggregate.bestReps = max(aggregate.bestReps, set.reps)
        }
        days[day] = aggregate
      }
    }

    return days.map { date, aggregate in
      VolumePoint(
        date: date,
        volume: aggregate.volume,
        bestEstimatedOneRepMax: aggregate.bestEstimatedOneRepMax,
        bestReps: aggregate.bestReps
      )
    }
    .sorted { $0.date < $1.date }
  }

  nonisolated static func exerciseProgressSnapshot(
    sessions: [LiftSession],
    exerciseID: UUID,
    now: Date,
    calendar: Calendar
  ) -> LiftExerciseProgressSnapshot {
    struct DayAggregate {
      var volume = 0.0
      var bestEstimatedOneRepMax = 0.0
      var bestReps = 0
    }
    struct RecordState {
      var hasWorkingHistory = false
      var bestEstimatedOneRepMax = 0.0
      var frontier = LiftRepFrontier()
    }

    let orderedSessions = sessions
      .filter { $0.endedAt != nil && $0.startedAt <= now }
      .sorted { left, right in
        if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
        if left.endedAt != right.endedAt {
          return (left.endedAt ?? left.startedAt) < (right.endedAt ?? right.startedAt)
        }
        return left.id.uuidString < right.id.uuidString
      }

    var days: [Date: DayAggregate] = [:]
    var recentRows: [LiftRecentSetRow] = []
    var bestLoadedSet: LiftSet?
    var bestBodyweightSet: LiftSet?
    var recordState = RecordState()
    var records: [UUID: LiftPersonalRecord] = [:]

    for session in orderedSessions {
      for (index, set) in session.sets.enumerated()
      where set.exerciseID == exerciseID && set.completedAt <= now {
        let day = calendar.startOfDay(for: set.completedAt)
        var aggregate = days[day, default: DayAggregate()]
        aggregate.volume += set.volume
        if !set.isWarmup {
          aggregate.bestEstimatedOneRepMax = max(
            aggregate.bestEstimatedOneRepMax,
            set.estimatedOneRepMax
          )
          aggregate.bestReps = max(aggregate.bestReps, set.reps)
        }
        days[day] = aggregate

        guard !set.isWarmup else { continue }
        recentRows.append(LiftRecentSetRow(session: session, set: set, setIndex: index))

        if set.weight > 0 {
          if let currentBest = bestLoadedSet {
            if isWeakerLoadedSet(currentBest, set) {
              bestLoadedSet = set
            }
          } else {
            bestLoadedSet = set
          }
        } else if set.weight == 0 {
          if let currentBest = bestBodyweightSet {
            if isWeakerBodyweightSet(currentBest, set) {
              bestBodyweightSet = set
            }
          } else {
            bestBodyweightSet = set
          }
        }

        if recordState.hasWorkingHistory {
          if set.weight > 0 && set.estimatedOneRepMax > recordState.bestEstimatedOneRepMax {
            records[set.id] = LiftPersonalRecord(
              kind: .estimatedOneRepMax,
              value: set.estimatedOneRepMax,
              previousBest: recordState.bestEstimatedOneRepMax
            )
          } else if let previousReps = recordState.frontier.bestReps(atOrAbove: set.weight),
                    set.reps > previousReps {
            records[set.id] = LiftPersonalRecord(
              kind: .reps,
              value: Double(set.reps),
              previousBest: Double(previousReps)
            )
          }
        }

        recordState.hasWorkingHistory = true
        if set.weight > 0 {
          recordState.bestEstimatedOneRepMax = max(
            recordState.bestEstimatedOneRepMax,
            set.estimatedOneRepMax
          )
        }
        recordState.frontier.insert(weight: set.weight, reps: set.reps)
      }
    }

    recentRows.sort { left, right in
      if left.session.startedAt != right.session.startedAt {
        return left.session.startedAt > right.session.startedAt
      }
      let leftSessionID = left.session.id.uuidString
      let rightSessionID = right.session.id.uuidString
      if leftSessionID != rightSessionID { return leftSessionID > rightSessionID }
      return left.setIndex > right.setIndex
    }

    let points = days.map { date, aggregate in
      VolumePoint(
        date: date,
        volume: aggregate.volume,
        bestEstimatedOneRepMax: aggregate.bestEstimatedOneRepMax,
        bestReps: aggregate.bestReps
      )
    }
    .sorted { $0.date < $1.date }
    let ledger = LiftHistoricalPRLedger(recordsBySetID: records)

    return LiftExerciseProgressSnapshot(
      points: points,
      recentSets: Array(recentRows.prefix(20)),
      bestSet: bestLoadedSet ?? bestBodyweightSet,
      historicalPersonalRecords: ledger,
      latestPersonalRecord: recentRows.lazy.compactMap { ledger[$0.set.id] }.first
    )
  }

  nonisolated static func recentSets(
    sessions: [LiftSession],
    exerciseID: UUID,
    now: Date,
    limit: Int = 20
  ) -> [LiftRecentSetRow] {
    guard limit > 0 else { return [] }
    var rows: [LiftRecentSetRow] = []

    for session in sessions where session.endedAt != nil && session.startedAt <= now {
      for (index, set) in session.sets.enumerated()
      where set.exerciseID == exerciseID && !set.isWarmup && set.completedAt <= now {
        rows.append(LiftRecentSetRow(session: session, set: set, setIndex: index))
      }
    }

    rows.sort { left, right in
      if left.session.startedAt != right.session.startedAt {
        return left.session.startedAt > right.session.startedAt
      }
      let leftSessionID = left.session.id.uuidString
      let rightSessionID = right.session.id.uuidString
      if leftSessionID != rightSessionID { return leftSessionID > rightSessionID }
      return left.setIndex > right.setIndex
    }
    return Array(rows.prefix(limit))
  }

  nonisolated static func bestSet(
    sessions: [LiftSession],
    exerciseID: UUID,
    now: Date
  ) -> LiftSet? {
    let candidates = sessions.lazy
      .filter { $0.endedAt != nil && $0.startedAt <= now }
      .flatMap(\.sets)
      .filter {
        $0.exerciseID == exerciseID
          && !$0.isWarmup
          && $0.completedAt <= now
      }
    let loaded = candidates.filter { $0.weight > 0 }
    if !loaded.isEmpty {
      return loaded.max(by: isWeakerLoadedSet)
    }
    return candidates.filter { $0.weight == 0 }.max(by: isWeakerBodyweightSet)
  }

  nonisolated static func historicalPersonalRecords(
    sessions: [LiftSession],
    exerciseID: UUID? = nil
  ) -> LiftHistoricalPRLedger {
    struct RecordState {
      var hasWorkingHistory = false
      var bestEstimatedOneRepMax = 0.0
      var frontier = LiftRepFrontier()
    }

    let orderedSessions = sessions
      .filter { $0.endedAt != nil }
      .sorted { left, right in
        if left.startedAt != right.startedAt { return left.startedAt < right.startedAt }
        if left.endedAt != right.endedAt { return (left.endedAt ?? left.startedAt) < (right.endedAt ?? right.startedAt) }
        return left.id.uuidString < right.id.uuidString
      }
    var states: [UUID: RecordState] = [:]
    var records: [UUID: LiftPersonalRecord] = [:]

    for session in orderedSessions {
      for set in session.sets
      where !set.isWarmup && (exerciseID == nil || set.exerciseID == exerciseID) {
        var state = states[set.exerciseID, default: RecordState()]
        if state.hasWorkingHistory {
          if set.weight > 0 && set.estimatedOneRepMax > state.bestEstimatedOneRepMax {
            records[set.id] = LiftPersonalRecord(
              kind: .estimatedOneRepMax,
              value: set.estimatedOneRepMax,
              previousBest: state.bestEstimatedOneRepMax
            )
          } else if let previousReps = state.frontier.bestReps(atOrAbove: set.weight),
                    set.reps > previousReps {
            records[set.id] = LiftPersonalRecord(
              kind: .reps,
              value: Double(set.reps),
              previousBest: Double(previousReps)
            )
          }
        }

        state.hasWorkingHistory = true
        if set.weight > 0 {
          state.bestEstimatedOneRepMax = max(
            state.bestEstimatedOneRepMax,
            set.estimatedOneRepMax
          )
        }
        state.frontier.insert(weight: set.weight, reps: set.reps)
        states[set.exerciseID] = state
      }
    }

    return LiftHistoricalPRLedger(recordsBySetID: records)
  }

  nonisolated static func latestPersonalRecord(
    sessions: [LiftSession],
    exerciseID: UUID,
    now: Date
  ) -> LiftPersonalRecord? {
    let ledger = historicalPersonalRecords(sessions: sessions, exerciseID: exerciseID)
    return recentSets(
      sessions: sessions,
      exerciseID: exerciseID,
      now: now,
      limit: Int.max
    )
    .lazy
    .compactMap { ledger[$0.set.id] }
    .first
  }

  private nonisolated static func weekStart(for date: Date, calendar: Calendar) -> Date {
    calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
  }

  private nonisolated static func foldedSortKey(_ value: String) -> String {
    value.folding(
      options: [.caseInsensitive, .diacriticInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
  }

  private nonisolated static func isWeakerLoadedSet(_ left: LiftSet, _ right: LiftSet) -> Bool {
    if left.estimatedOneRepMax != right.estimatedOneRepMax {
      return left.estimatedOneRepMax < right.estimatedOneRepMax
    }
    if left.weight != right.weight { return left.weight < right.weight }
    if left.reps != right.reps { return left.reps < right.reps }
    if left.completedAt != right.completedAt { return left.completedAt < right.completedAt }
    return left.id.uuidString < right.id.uuidString
  }

  private nonisolated static func isWeakerBodyweightSet(_ left: LiftSet, _ right: LiftSet) -> Bool {
    if left.reps != right.reps { return left.reps < right.reps }
    if left.completedAt != right.completedAt { return left.completedAt < right.completedAt }
    return left.id.uuidString < right.id.uuidString
  }
}

private struct LiftRepFrontier {
  private var bestByExactWeight: [Double: Int] = [:]

  mutating func insert(weight: Double, reps: Int) {
    bestByExactWeight[weight] = max(bestByExactWeight[weight] ?? 0, reps)
  }

  func bestReps(atOrAbove weight: Double) -> Int? {
    var best: Int?
    for (candidateWeight, reps) in bestByExactWeight where candidateWeight >= weight {
      if reps > (best ?? .min) {
        best = reps
      }
    }
    return best
  }
}
