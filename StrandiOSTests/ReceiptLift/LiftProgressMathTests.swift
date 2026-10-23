import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Lift progress math")
struct LiftProgressMathTests {
  private let exerciseA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
  private let exerciseB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

  @Test("Progress cache key tracks semantic session, calendar, time, and name changes")
  func progressCacheKeySemantics() {
    let now = date(2026, 1, 14, 12)
    let workingSet = set(
      id: 1,
      exerciseID: exerciseA,
      weight: 100,
      reps: 5,
      at: date(2026, 1, 12, 9)
    )
    let completed = session(
      id: 1,
      startedAt: date(2026, 1, 12, 8),
      endedAt: date(2026, 1, 12, 10),
      sets: [workingSet]
    )
    let names = [exerciseA: "Press"]
    let baseline = LiftProgressCacheKey(
      range: .twelveWeeks,
      now: now,
      calendar: fixedCalendar,
      sessions: [completed],
      exerciseNames: names
    )

    #expect(baseline == LiftProgressCacheKey(
      range: .twelveWeeks,
      now: now,
      calendar: fixedCalendar,
      sessions: [completed],
      exerciseNames: names
    ))
    #expect(baseline != LiftProgressCacheKey(
      range: .fourWeeks,
      now: now,
      calendar: fixedCalendar,
      sessions: [completed],
      exerciseNames: names
    ))
    #expect(baseline != LiftProgressCacheKey(
      range: .twelveWeeks,
      now: now.addingTimeInterval(1),
      calendar: fixedCalendar,
      sessions: [completed],
      exerciseNames: names
    ))

    var shiftedCalendar = fixedCalendar
    shiftedCalendar.timeZone = TimeZone(secondsFromGMT: 3_600)!
    #expect(baseline != LiftProgressCacheKey(
      range: .twelveWeeks,
      now: now,
      calendar: shiftedCalendar,
      sessions: [completed],
      exerciseNames: names
    ))

    var editedSet = workingSet
    editedSet.weight = 102.5
    var editedSession = completed
    editedSession.sets = [editedSet]
    #expect(baseline != LiftProgressCacheKey(
      range: .twelveWeeks,
      now: now,
      calendar: fixedCalendar,
      sessions: [editedSession],
      exerciseNames: names
    ))
    #expect(baseline != LiftProgressCacheKey(
      range: .twelveWeeks,
      now: now,
      calendar: fixedCalendar,
      sessions: [completed],
      exerciseNames: [exerciseA: "Strict Press"]
    ))
  }

  @MainActor
  @Test("Store reuses equal progress snapshots and recomputes for a new range")
  func storeProgressSnapshotMemoization() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiftProgressCacheTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let exercise = LiftExercise(
      id: exerciseA,
      name: "Press",
      muscleGroup: "Chest",
      equipment: "Barbell",
      instructions: "Test"
    )
    let completed = session(
      id: 1,
      startedAt: date(2026, 1, 12, 8),
      endedAt: date(2026, 1, 12, 10),
      sets: [set(id: 1, exerciseID: exerciseA, weight: 100, reps: 5, at: date(2026, 1, 12, 9))]
    )
    let envelope = LiftDataEnvelope(
      schemaVersion: 2,
      starterBankVersion: 1,
      userExercises: [exercise],
      routines: [],
      scheduledWorkouts: [],
      sessions: [completed],
      activeSession: nil,
      restTimerEndDate: nil,
      workoutRestOverrideSeconds: nil,
      completedExerciseIDs: [],
      activeExerciseIDsOverride: nil,
      activePlanOverrides: [:],
      activeSupersetGroups: [:],
      settings: LiftSettings()
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(envelope).write(
      to: directory.appendingPathComponent("lift-data.json"),
      options: .atomic
    )

    let store = LiftStore(
      dataURL: directory.appendingPathComponent("lift-data.json"),
      saveDebounceInterval: 0
    )
    await store.loadAndWait()
    let now = date(2026, 1, 14, 12)
    let first = store.progressSnapshot(for: .twelveWeeks, now: now, calendar: fixedCalendar)
    let second = store.progressSnapshot(for: .twelveWeeks, now: now, calendar: fixedCalendar)
    #expect(first == second)
    #expect(store.progressSnapshotComputationCount == 1)

    _ = store.progressSnapshot(for: .all, now: now, calendar: fixedCalendar)
    #expect(store.progressSnapshotComputationCount == 2)
  }

  @MainActor
  @Test("Repeated receipt reads reuse PR history and completed workouts invalidate it")
  func storeHistoricalPersonalRecordMemoization() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiftHistoricalPRCacheTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = LiftStore(dataURL: directory.appendingPathComponent("lift-data.json"), saveDebounceInterval: 0)
    await store.loadAndWait()
    let exercise = try #require(store.exercises.first)
    #expect(store.startRoutine(nil, now: date(2026, 1, 12, 8)))
    #expect(store.logSet(exercise: exercise, weight: 100, reps: 5, rpe: 8, isWarmup: false) != nil)
    #expect(store.finishActiveSession() != nil)

    let baseline = LiftProgressMath.historicalPersonalRecords(sessions: store.sessions)
    for _ in 0..<50 {
      #expect(store.historicalPersonalRecords() == baseline)
    }
    #expect(store.historicalPersonalRecordComputationCount == 1)

    // Live logging and other store notifications do not change completed PR history.
    #expect(store.startRoutine(nil, now: date(2026, 1, 13, 8)))
    let improvement = try #require(store.logSet(exercise: exercise, weight: 120, reps: 5, rpe: 8, isWarmup: false))
    store.setDefaultRestSeconds(120)
    #expect(store.historicalPersonalRecords() == baseline)
    #expect(store.historicalPersonalRecordComputationCount == 1)

    #expect(store.finishActiveSession() != nil)
    let updated = store.historicalPersonalRecords()
    #expect(updated == LiftProgressMath.historicalPersonalRecords(sessions: store.sessions))
    #expect(updated[improvement.set.id] != nil)
    #expect(store.historicalPersonalRecordComputationCount == 2)
    #expect(store.historicalPersonalRecords() == updated)
    #expect(store.historicalPersonalRecordComputationCount == 2)

    // Loading saved history also invalidates an empty ledger read before the load finished.
    let restored = LiftStore(dataURL: directory.appendingPathComponent("lift-data.json"), saveDebounceInterval: 0)
    #expect(restored.historicalPersonalRecords().recordsBySetID.isEmpty)
    await restored.loadAndWait()
    #expect(restored.historicalPersonalRecords() == updated)
    #expect(restored.historicalPersonalRecordComputationCount == 2)
  }

  @Test("Calendar ranges are aligned and never include future sessions")
  func alignedWindows() throws {
    let calendar = fixedCalendar
    let now = date(2026, 1, 14, 12)
    let past = session(
      id: 1,
      startedAt: date(2025, 12, 1),
      endedAt: date(2025, 12, 1, 1),
      sets: []
    )
    let future = session(
      id: 2,
      startedAt: date(2026, 2, 1),
      endedAt: date(2026, 2, 1, 1),
      sets: []
    )

    let four = LiftProgressMath.window(
      for: .fourWeeks,
      sessions: [past, future],
      now: now,
      calendar: calendar
    )
    let twelve = LiftProgressMath.window(
      for: .twelveWeeks,
      sessions: [past, future],
      now: now,
      calendar: calendar
    )
    let sixMonths = LiftProgressMath.window(
      for: .sixMonths,
      sessions: [past, future],
      now: now,
      calendar: calendar
    )
    let all = LiftProgressMath.window(
      for: .all,
      sessions: [past, future],
      now: now,
      calendar: calendar
    )

    #expect(four.weekStarts.count == 4)
    #expect(twelve.weekStarts.count == 12)
    #expect(calendar.component(.month, from: sixMonths.startInclusive) == 8)
    #expect(calendar.component(.day, from: sixMonths.startInclusive) == 1)
    #expect(all.startInclusive == calendar.dateInterval(of: .weekOfYear, for: past.startedAt)?.start)
    #expect(all.endInclusive == now)
    #expect(all.weekStarts.last == calendar.dateInterval(of: .weekOfYear, for: now)?.start)
  }

  @Test("Snapshot uses completed sessions, working-set semantics, and deterministic name ties")
  func snapshotSemantics() {
    let now = date(2026, 1, 14, 12)
    let warmup = set(id: 1, exerciseID: exerciseA, weight: 45, reps: 10, warmup: true, at: date(2026, 1, 12, 9))
    let workA = set(id: 2, exerciseID: exerciseA, weight: 100, reps: 5, at: date(2026, 1, 12, 9))
    let workB = set(id: 3, exerciseID: exerciseB, weight: 190, reps: 5, at: date(2026, 1, 13, 9))
    let completed = session(
      id: 1,
      startedAt: date(2026, 1, 12, 8),
      endedAt: date(2026, 1, 12, 10),
      sets: [warmup, workA, workB]
    )
    let active = session(
      id: 2,
      startedAt: date(2026, 1, 13, 8),
      endedAt: nil,
      sets: [workA]
    )

    let snapshot = LiftProgressMath.snapshot(
      sessions: [active, completed],
      range: .fourWeeks,
      now: now,
      calendar: fixedCalendar,
      exerciseNames: [exerciseA: "Zulu", exerciseB: "alpha"]
    )

    #expect(snapshot.weeklyVolume.count == 4)
    #expect(snapshot.metrics.workDone == warmup.volume + workA.volume + workB.volume)
    #expect(snapshot.metrics.workouts == 1)
    #expect(snapshot.metrics.workingSets == 2)
    #expect(snapshot.metrics.averageDuration == 7_200)
    #expect(snapshot.metrics.consistencyPercent == 25)
    #expect(snapshot.metrics.exerciseCount == 2)
    #expect(snapshot.topExercises.map(\.name) == ["alpha", "Zulu"])
  }

  @Test("Exercise modes separate warm-up volume from strength and reps")
  func exerciseModes() {
    let now = date(2026, 1, 14, 12)
    let warmup = set(id: 1, exerciseID: exerciseA, weight: 50, reps: 12, warmup: true, at: date(2026, 1, 12, 9))
    let work = set(id: 2, exerciseID: exerciseA, weight: 100, reps: 5, at: date(2026, 1, 12, 10))
    let futureSet = set(id: 3, exerciseID: exerciseA, weight: 200, reps: 20, at: date(2026, 1, 15))
    let completed = session(
      id: 1,
      startedAt: date(2026, 1, 12, 8),
      endedAt: date(2026, 1, 12, 11),
      sets: [warmup, work, futureSet]
    )

    let points = LiftProgressMath.exercisePoints(
      sessions: [completed],
      exerciseID: exerciseA,
      now: now,
      calendar: fixedCalendar
    )

    #expect(points.count == 1)
    #expect(points[0].volume == warmup.volume + work.volume)
    #expect(points[0].bestEstimatedOneRepMax == work.estimatedOneRepMax)
    #expect(points[0].bestReps == work.reps)
  }

  @Test("Recent sets retain exact parent and stable persisted order")
  func recentParentLinkage() {
    let now = date(2026, 1, 14, 12)
    let older = set(id: 1, exerciseID: exerciseA, weight: 100, reps: 5, at: date(2026, 1, 12, 11))
    let newerInArray = set(id: 2, exerciseID: exerciseA, weight: 105, reps: 5, at: date(2026, 1, 12, 10))
    let parent = session(
      id: 1,
      startedAt: date(2026, 1, 12, 8),
      endedAt: date(2026, 1, 12, 12),
      sets: [older, newerInArray]
    )

    let rows = LiftProgressMath.recentSets(
      sessions: [parent],
      exerciseID: exerciseA,
      now: now
    )

    #expect(rows.map(\.set.id) == [newerInArray.id, older.id])
    #expect(rows.allSatisfy { $0.session.id == parent.id })
  }

  @Test("Best set prefers loaded estimated strength then deterministic ties")
  func bestSetSelection() {
    let now = date(2026, 1, 14, 12)
    let bodyweight = set(id: 1, exerciseID: exerciseA, weight: 0, reps: 30, at: date(2026, 1, 11))
    let lighter = set(id: 2, exerciseID: exerciseA, weight: 100, reps: 10, at: date(2026, 1, 12))
    let heavier = set(id: 3, exerciseID: exerciseA, weight: 110, reps: 5, at: date(2026, 1, 13))
    let completed = session(
      id: 1,
      startedAt: date(2026, 1, 11),
      endedAt: date(2026, 1, 13, 1),
      sets: [bodyweight, lighter, heavier]
    )

    #expect(
      LiftProgressMath.bestSet(sessions: [completed], exerciseID: exerciseA, now: now)?.id
        == lighter.id
    )
  }

  @Test("Historical records use a strict prefix and never let warm-ups establish history")
  func strictPrefixRecords() {
    let warmup = set(id: 1, exerciseID: exerciseA, weight: 100, reps: 20, warmup: true, at: date(2026, 1, 1))
    let baseline = set(id: 2, exerciseID: exerciseA, weight: 100, reps: 5, at: date(2026, 1, 1))
    let strengthPR = set(id: 3, exerciseID: exerciseA, weight: 105, reps: 5, at: date(2026, 1, 1))
    let repPR = set(id: 4, exerciseID: exerciseA, weight: 105, reps: 6, at: date(2026, 1, 1))
    let completed = session(
      id: 1,
      startedAt: date(2026, 1, 1),
      endedAt: date(2026, 1, 1, 2),
      sets: [warmup, baseline, strengthPR, repPR]
    )

    let ledger = LiftProgressMath.historicalPersonalRecords(sessions: [completed])

    #expect(ledger[warmup.id] == nil)
    #expect(ledger[baseline.id] == nil)
    #expect(ledger[strengthPR.id]?.kind == .estimatedOneRepMax)
    #expect(ledger[repPR.id]?.kind == .estimatedOneRepMax)
  }

  @Test("Latest exercise PR survives later tied best sets")
  func latestExercisePersonalRecord() {
    let now = date(2026, 1, 14, 12)
    let baseline = set(id: 21, exerciseID: exerciseA, weight: 100, reps: 5, at: date(2026, 1, 12, 9))
    let recordSet = set(id: 22, exerciseID: exerciseA, weight: 110, reps: 5, at: date(2026, 1, 12, 10))
    let laterTie = set(id: 23, exerciseID: exerciseA, weight: 110, reps: 5, at: date(2026, 1, 12, 11))
    let completed = session(
      id: 21,
      startedAt: date(2026, 1, 12, 8),
      endedAt: date(2026, 1, 12, 12),
      sets: [baseline, recordSet, laterTie]
    )

    #expect(
      LiftProgressMath.latestPersonalRecord(
        sessions: [completed],
        exerciseID: exerciseA,
        now: now
      ) == LiftPersonalRecord(
        kind: .estimatedOneRepMax,
        value: recordSet.estimatedOneRepMax,
        previousBest: baseline.estimatedOneRepMax
      )
    )
  }

  @Test("Exercise progress snapshot scopes one shared PR ledger to the selected exercise")
  func exerciseProgressSnapshotScopesRecords() {
    let now = date(2026, 1, 14, 12)
    let baseline = set(id: 31, exerciseID: exerciseA, weight: 100, reps: 5, at: date(2026, 1, 12, 9))
    let recordSet = set(id: 32, exerciseID: exerciseA, weight: 110, reps: 5, at: date(2026, 1, 12, 10))
    let otherBaseline = set(id: 33, exerciseID: exerciseB, weight: 50, reps: 5, at: date(2026, 1, 12, 9))
    let otherRecord = set(id: 34, exerciseID: exerciseB, weight: 60, reps: 5, at: date(2026, 1, 12, 10))
    let completed = session(
      id: 31,
      startedAt: date(2026, 1, 12, 8),
      endedAt: date(2026, 1, 12, 12),
      sets: [baseline, otherBaseline, recordSet, otherRecord]
    )

    let snapshot = LiftProgressMath.exerciseProgressSnapshot(
      sessions: [completed],
      exerciseID: exerciseA,
      now: now,
      calendar: fixedCalendar
    )

    #expect(snapshot.recentSets.map(\.set.id) == [recordSet.id, baseline.id])
    #expect(snapshot.bestSet?.id == recordSet.id)
    #expect(snapshot.historicalPersonalRecords[recordSet.id]?.kind == .estimatedOneRepMax)
    #expect(snapshot.historicalPersonalRecords[otherRecord.id] == nil)
    #expect(snapshot.latestPersonalRecord == snapshot.historicalPersonalRecords[recordSet.id])
  }

  @Test("Bodyweight history is rep-only and loaded history can establish strength")
  func bodyweightRecordSemantics() {
    let bodyweightBaseline = set(id: 1, exerciseID: exerciseA, weight: 0, reps: 10, at: date(2026, 1, 1))
    let bodyweightPR = set(id: 2, exerciseID: exerciseA, weight: 0, reps: 12, at: date(2026, 1, 1))
    let loaded = set(id: 3, exerciseID: exerciseA, weight: 45, reps: 5, at: date(2026, 1, 1))
    let completed = session(
      id: 1,
      startedAt: date(2026, 1, 1),
      endedAt: date(2026, 1, 1, 2),
      sets: [bodyweightBaseline, bodyweightPR, loaded]
    )

    let ledger = LiftProgressMath.historicalPersonalRecords(sessions: [completed])

    #expect(ledger[bodyweightBaseline.id] == nil)
    #expect(ledger[bodyweightPR.id]?.kind == .reps)
    #expect(ledger[loaded.id]?.kind == .estimatedOneRepMax)
    #expect(ledger[loaded.id]?.previousBest == 0)
  }

  /// ORG-8: this used to assert an absolute 50 ms bound per run, which failed at random on a loaded,
  /// parallel Debug simulator run. It now checks that the work scales roughly linearly: 4x the sessions
  /// may cost at most 8x the time (a quadratic regression costs 16x), using the fastest of five runs.
  @Test("The 16000-set snapshot and ledger scale linearly with history size")
  func deterministicPerformanceBound() {
    let now = date(2026, 1, 14, 12)
    let exerciseIDs = (0..<40).map { uuid(10_000 + $0) }
    let names = Dictionary(uniqueKeysWithValues: exerciseIDs.enumerated().map {
      ($0.element, "Exercise \($0.offset)")
    })
    func makeFixture(sessionCount: Int) -> [LiftSession] {
      (0..<sessionCount).map { sessionIndex -> LiftSession in
        let started = now.addingTimeInterval(-Double(sessionCount - sessionIndex) * 126_000)
        var sets: [LiftSet] = []
        for exerciseOffset in 0..<8 {
          let exerciseID = exerciseIDs[(sessionIndex * 8 + exerciseOffset) % 40]
          for setOffset in 0..<4 {
            sets.append(set(
              id: 100_000 + sessionIndex * 32 + exerciseOffset * 4 + setOffset,
              exerciseID: exerciseID,
              weight: Double(45 + (sessionIndex + exerciseOffset + setOffset) % 50 * 5),
              reps: 5 + setOffset,
              warmup: setOffset == 0,
              at: started.addingTimeInterval(Double(exerciseOffset * 300 + setOffset * 60))
            ))
          }
        }
        return session(
          id: 200_000 + sessionIndex,
          startedAt: started,
          endedAt: started.addingTimeInterval(3_600),
          sets: sets
        )
      }
    }
    let small = makeFixture(sessionCount: 125)
    let fixture = makeFixture(sessionCount: 500)

    #expect(fixture.count == 500)
    #expect(fixture.reduce(0) { $0 + $1.sets.count } == 16_000)

    func fastestRun(_ sessions: [LiftSession]) -> (snapshot: Duration, ledger: Duration) {
      let clock = ContinuousClock()
      var snapshot = Duration.seconds(1_000)
      var ledger = Duration.seconds(1_000)
      for _ in 0..<5 {
        snapshot = min(snapshot, clock.measure {
          _ = LiftProgressMath.snapshot(
            sessions: sessions,
            range: .all,
            now: now,
            calendar: fixedCalendar,
            exerciseNames: names
          )
        })
        ledger = min(ledger, clock.measure {
          _ = LiftProgressMath.historicalPersonalRecords(sessions: sessions)
        })
      }
      return (snapshot, ledger)
    }
    _ = fastestRun(small)   // warm-up
    let base = fastestRun(small)
    let large = fastestRun(fixture)
    #expect(large.snapshot <= base.snapshot * 8 + .milliseconds(2))
    #expect(large.ledger <= base.ledger * 8 + .milliseconds(2))
  }

  private var fixedCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    calendar.minimumDaysInFirstWeek = 4
    return calendar
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
    fixedCalendar.date(from: DateComponents(
      timeZone: fixedCalendar.timeZone,
      year: year,
      month: month,
      day: day,
      hour: hour
    ))!
  }

  private func session(
    id: Int,
    startedAt: Date,
    endedAt: Date?,
    sets: [LiftSet]
  ) -> LiftSession {
    LiftSession(
      id: uuid(id),
      routineID: nil,
      title: "Session \(id)",
      startedAt: startedAt,
      endedAt: endedAt,
      sets: sets
    )
  }

  private func set(
    id: Int,
    exerciseID: UUID,
    weight: Double,
    reps: Int,
    warmup: Bool = false,
    at: Date
  ) -> LiftSet {
    LiftSet(
      id: uuid(id),
      exerciseID: exerciseID,
      setNumber: id,
      weight: weight,
      reps: reps,
      rpe: 8,
      isWarmup: warmup,
      completedAt: at,
      notes: ""
    )
  }

  private func uuid(_ value: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value))!
  }
}
