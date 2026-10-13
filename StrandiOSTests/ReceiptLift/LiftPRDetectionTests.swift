import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Lift personal-record detection")
@MainActor
struct LiftPRDetectionTests {
  @Test("The first working set establishes a baseline without becoming a PR")
  func noBaseline() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = await loadedStore(for: fixture)
    store.startRoutine(nil)

    let outcome = try #require(store.logSet(
      exercise: fixture.exercise,
      weight: 100,
      reps: 8,
      rpe: 8,
      isWarmup: false
    ))
    store.flushPendingSave()

    #expect(outcome.set == store.activeSession?.sets.last)
    #expect(outcome.personalRecord == nil)
  }

  @Test("Ties are not personal records")
  func tieIsNotARecord() async throws {
    let prior = makeSet(weight: 100, reps: 8)
    let fixture = try makeFixture(sessions: [makeSession(sets: [prior])])
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = await loadedStore(for: fixture)
    let candidate = makeSet(exerciseID: fixture.exercise.id, weight: 100, reps: 8)

    #expect(store.personalRecord(for: candidate, exerciseID: fixture.exercise.id) == nil)
  }

  @Test("Warm-ups neither establish nor earn records")
  func warmupsAreExcluded() async throws {
    let warmupHistory = makeSet(weight: 100, reps: 8, isWarmup: true)
    let fixture = try makeFixture(sessions: [makeSession(sets: [warmupHistory])])
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = await loadedStore(for: fixture)
    let workingCandidate = makeSet(exerciseID: fixture.exercise.id, weight: 105, reps: 8)
    let warmupCandidate = makeSet(
      exerciseID: fixture.exercise.id,
      weight: 200,
      reps: 12,
      isWarmup: true
    )

    #expect(store.personalRecord(for: workingCandidate, exerciseID: fixture.exercise.id) == nil)
    #expect(store.personalRecord(for: warmupCandidate, exerciseID: fixture.exercise.id) == nil)
  }

  @Test("A later active-session set can PR over an earlier set")
  func sameSessionSequencing() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = await loadedStore(for: fixture)
    store.startRoutine(nil)

    let first = try #require(store.logSet(
      exercise: fixture.exercise,
      weight: 100,
      reps: 8,
      rpe: 8,
      isWarmup: false
    ))
    let second = try #require(store.logSet(
      exercise: fixture.exercise,
      weight: 105,
      reps: 8,
      rpe: 8,
      isWarmup: false
    ))
    store.flushPendingSave()

    #expect(first.personalRecord == nil)
    #expect(second.personalRecord == LiftPersonalRecord(
      kind: .estimatedOneRepMax,
      value: second.set.estimatedOneRepMax,
      previousBest: first.set.estimatedOneRepMax
    ))
  }

  @Test("A rep PR compares against equal-or-heavier historical sets")
  func repRecordAtComparableWeight() async throws {
    let prior = makeSet(weight: 120, reps: 8)
    let fixture = try makeFixture(sessions: [makeSession(sets: [prior])])
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = await loadedStore(for: fixture)
    let candidate = makeSet(exerciseID: fixture.exercise.id, weight: 100, reps: 12)

    #expect(store.personalRecord(for: candidate, exerciseID: fixture.exercise.id) == LiftPersonalRecord(
      kind: .reps,
      value: 12,
      previousBest: 8
    ))
  }

  @Test("Bodyweight sets are eligible for rep PRs only")
  func bodyweightRepRecord() async throws {
    let prior = makeSet(weight: 0, reps: 8)
    let fixture = try makeFixture(sessions: [makeSession(sets: [prior])])
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = await loadedStore(for: fixture)
    let candidate = makeSet(exerciseID: fixture.exercise.id, weight: 0, reps: 10)

    #expect(store.personalRecord(for: candidate, exerciseID: fixture.exercise.id) == LiftPersonalRecord(
      kind: .reps,
      value: 10,
      previousBest: 8
    ))
  }

  @Test("Estimated 1RM wins when both record paths could apply")
  func estimatedOneRepMaxWins() async throws {
    let prior = makeSet(weight: 105, reps: 8)
    let fixture = try makeFixture(sessions: [makeSession(sets: [prior])])
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = await loadedStore(for: fixture)
    let candidate = makeSet(exerciseID: fixture.exercise.id, weight: 105, reps: 9)

    #expect(store.personalRecord(for: candidate, exerciseID: fixture.exercise.id) == LiftPersonalRecord(
      kind: .estimatedOneRepMax,
      value: candidate.estimatedOneRepMax,
      previousBest: prior.estimatedOneRepMax
    ))
  }

  /// ORG-8: this used to assert an absolute 100 ms bound, which failed at random on a loaded, parallel
  /// Debug simulator run. It now checks that a lookup scales roughly linearly with history size: a
  /// 4x longer history may cost at most 8x (a quadratic regression costs 16x), fastest of five runs.
  @Test("A PR lookup scales linearly with history size")
  func fiveHundredSessionCostBound() async throws {
    func history(_ count: Int) -> [LiftSession] {
      (0..<count).map { offset in
        makeSession(
          startedAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(offset)),
          sets: [makeSet(weight: 100 + Double(offset % 5) * 5, reps: 5 + offset % 5)]
        )
      }
    }
    func fastestLookup(sessions: [LiftSession]) async throws -> Duration {
      let fixture = try makeFixture(sessions: sessions)
      defer { try? FileManager.default.removeItem(at: fixture.directory) }
      let store = await loadedStore(for: fixture)
      let candidate = makeSet(exerciseID: fixture.exercise.id, weight: 200, reps: 12)
      _ = store.personalRecord(for: candidate, exerciseID: fixture.exercise.id)
      var fastest = Duration.seconds(1_000)
      for _ in 0..<5 {
        fastest = min(fastest, ContinuousClock().measure {
          for _ in 0..<20 {
            _ = store.personalRecord(for: candidate, exerciseID: fixture.exercise.id)
          }
        })
      }
      return fastest
    }

    let base = try await fastestLookup(sessions: history(125))
    let large = try await fastestLookup(sessions: history(500))
    #expect(large <= base * 8 + .milliseconds(2))
  }

  @Test("The feature flag defaults on without entering the persistence envelope")
  func featureFlagDefaultsOn() {
    #expect(LiftStore.prDetectionEnabled)
  }

  @Test("Logging without an active session preserves the existing no-op behavior")
  func noActiveSessionRemainsANoOp() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = await loadedStore(for: fixture)

    #expect(store.logSet(
      exercise: fixture.exercise,
      weight: 100,
      reps: 8,
      rpe: 8,
      isWarmup: false
    ) == nil)
  }

  private func loadedStore(for fixture: PRFixture) async -> LiftStore {
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 10)
    await store.loadAndWait()
    return store
  }

  private func makeFixture(sessions: [LiftSession] = []) throws -> PRFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiftPRDetectionTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let dataURL = directory.appendingPathComponent("lift-data.json")
    let exercise = LiftExercise(
      id: testExerciseID,
      name: "PR Test Press",
      muscleGroup: "Chest",
      equipment: "Barbell",
      instructions: "Test fixture"
    )
    let envelope = LiftDataEnvelope(
      schemaVersion: 2,
      starterBankVersion: 1,
      userExercises: [exercise],
      routines: [],
      scheduledWorkouts: [],
      sessions: sessions.map { session in
        var session = session
        session.sets = session.sets.map { set in
          var set = set
          set.exerciseID = exercise.id
          return set
        }
        return session
      },
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
    encoder.outputFormatting = [.sortedKeys]
    try encoder.encode(envelope).write(to: dataURL, options: .atomic)
    return PRFixture(directory: directory, dataURL: dataURL, exercise: exercise)
  }

  private func makeSession(
    startedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    sets: [LiftSet]
  ) -> LiftSession {
    LiftSession(
      id: UUID(),
      routineID: nil,
      title: "Completed fixture",
      startedAt: startedAt,
      endedAt: startedAt.addingTimeInterval(60),
      sets: sets
    )
  }

  private func makeSet(
    exerciseID: UUID? = nil,
    weight: Double,
    reps: Int,
    isWarmup: Bool = false
  ) -> LiftSet {
    LiftSet(
      id: UUID(),
      exerciseID: exerciseID ?? testExerciseID,
      setNumber: 1,
      weight: weight,
      reps: reps,
      rpe: 8,
      isWarmup: isWarmup,
      completedAt: Date(timeIntervalSince1970: 1_700_000_030),
      notes: ""
    )
  }

  private var testExerciseID: UUID {
    UUID(uuidString: "00800000-0000-0000-0000-000000000009")!
  }
}

private struct PRFixture {
  let directory: URL
  let dataURL: URL
  let exercise: LiftExercise
}
