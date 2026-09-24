import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Receipt Lift database integration")
@MainActor
struct ReceiptLiftDatabaseTests {
  private static let expectedPresetExercises: [String: [String]] = [
    "Upper A": [
      "Machine Chest Press", "Pull-Up", "Incline Dumbbell Press", "Chest-Supported Row",
      "Cable Fly or Pec Deck", "Rope Pushdown", "Cable Curl", "Hanging Knee Raise"
    ],
    "Lower A": [
      "Leg Press", "Romanian Deadlift", "Seated Leg Curl", "Walking Lunge",
      "Leg Extension", "Calf Raise", "Side Plank"
    ],
    "Pull + Posture": [
      "T-Bar Row", "Lat Pulldown", "Machine Row or Cable Row", "Straight-Arm Pulldown",
      "Rear-Delt Fly", "Face Pull", "Incline Dumbbell Curl", "Hammer Curl", "Dead Hang"
    ],
    "Push + Delts": [
      "Machine Shoulder Press", "Smith Incline Press", "Cable Fly or Pec Deck",
      "Cable Lateral Raise", "Rear-Delt Fly", "Overhead Cable Extension",
      "Straight-Bar Pushdown", "Ab Machine or Cable Crunch", "Pallof Press or Plank"
    ],
    "Lower B": [
      "Hack Squat", "Hip Thrust", "Lying Leg Curl", "Bulgarian Split Squat",
      "Calf Raise", "Back Extension", "Russian Twist or Hanging Knee Raise"
    ]
  ]

  @Test func freshDatabaseLoadPersistsEveryReferencePreset() async throws {
    let adapter = ReceiptLiftDatabaseAdapterHarness()
    let coordinator = makeCoordinator(adapter: adapter)

    await coordinator.load()
    await coordinator.store.waitForPendingSave()

    let snapshot = await adapter.snapshot()
    let savedData = try #require(snapshot.data)
    let envelope = try decodeEnvelope(savedData)
    let expectedNames = Set(Self.expectedPresetExercises.keys)

    #expect(coordinator.store.routines.count == expectedNames.count)
    #expect(Set(coordinator.store.routines.map(\.name)) == expectedNames)
    #expect(coordinator.store.routines.flatMap { $0.exercisePlans ?? [] }.count == 40)
    #expect(planNames(coordinator.store.routines, exercises: coordinator.store.exercises) == Self.expectedPresetExercises)
    #expect(coordinator.store.routines.allSatisfy { routine in
      routine.exerciseIDs == (routine.exercisePlans ?? []).map(\.exerciseID)
        && (routine.exercisePlans ?? []).allSatisfy { !$0.sets.isEmpty && !$0.reps.isEmpty }
    })

    #expect(envelope.userExercises.count == 37)
    #expect(Set(envelope.routines.map(\.name)) == expectedNames)
    #expect(planNames(envelope.routines, exercises: coordinator.store.exercises) == Self.expectedPresetExercises)
    #expect(snapshot.saveAttempts == 1)
    #expect(snapshot.successfulSaves == 1)
    #expect(snapshot.workouts.isEmpty)
  }

  @Test func failedFreshSaveCanRetryTheCompletePresetEnvelope() async throws {
    let adapter = ReceiptLiftDatabaseAdapterHarness(failuresRemaining: 1)
    let coordinator = makeCoordinator(adapter: adapter)

    await coordinator.load()
    await coordinator.store.waitForPendingSave()

    let failedSnapshot = await adapter.snapshot()
    #expect(coordinator.saveError != nil)
    #expect(failedSnapshot.saveAttempts == 1)
    #expect(failedSnapshot.successfulSaves == 0)
    #expect(failedSnapshot.data == nil)
    #expect(Set(coordinator.store.routines.map(\.name)) == Set(Self.expectedPresetExercises.keys))

    coordinator.store.flushPendingSave()
    await coordinator.store.waitForPendingSave()

    let retriedSnapshot = await adapter.snapshot()
    let savedData = try #require(retriedSnapshot.data)
    let envelope = try decodeEnvelope(savedData)
    #expect(coordinator.saveError == nil)
    #expect(retriedSnapshot.saveAttempts == 2)
    #expect(retriedSnapshot.successfulSaves == 1)
    #expect(planNames(envelope.routines, exercises: coordinator.store.exercises) == Self.expectedPresetExercises)
  }

  @Test func discardInvalidatesTheSourceBeforeFurtherDatabaseSaves() async throws {
    let adapter = ReceiptLiftDatabaseAdapterHarness()
    let coordinator = makeCoordinator(adapter: adapter)

    await coordinator.load()
    await coordinator.store.waitForPendingSave()
    let beforeDiscard = await adapter.snapshot()
    #expect(beforeDiscard.successfulSaves == 1)

    coordinator.discard()
    coordinator.store.setDefaultRestSeconds(120)
    coordinator.store.flushPendingSave()
    await coordinator.store.waitForPendingSave()

    let afterDiscard = await adapter.snapshot()
    #expect(afterDiscard.saveAttempts == beforeDiscard.saveAttempts)
    #expect(afterDiscard.data == beforeDiscard.data)
    #expect(coordinator.store.activeSession == nil)
  }

  @Test func completedBenchSetUsesCatalogTargetAndSecondaryMuscles() async throws {
    let adapter = ReceiptLiftDatabaseAdapterHarness()
    let coordinator = makeCoordinator(adapter: adapter)
    await coordinator.load()
    await coordinator.store.waitForPendingSave()

    let bench = try #require(coordinator.store.exercises.first {
      LiftExerciseCatalog.normalizedName($0.name) == LiftExerciseCatalog.normalizedName("barbell bench press")
    })
    let catalogRecord = try #require(LiftExerciseCatalog.metadata(for: bench))
    coordinator.store.startRoutine(nil)
    #expect(coordinator.store.logSet(exercise: bench, weight: 135, reps: 8, rpe: 8, isWarmup: false) != nil)

    let finishedSession = await coordinator.store.finishActiveSessionDurably()
    let snapshot = await adapter.snapshot()
    let receiptSet = try #require(snapshot.workouts.first?.sets.first)

    #expect(finishedSession != nil)
    #expect(receiptSet.exercise == bench.name)
    #expect(receiptSet.muscleGroup == catalogRecord.target)
    #expect(receiptSet.muscleGroup == "pectorals")
    #expect(receiptSet.secondaryMuscles == (catalogRecord.secondaryMuscles ?? []))
    #expect(receiptSet.secondaryMuscles == ["triceps", "shoulders"])
  }

  @Test func invalidationDuringSuspendedDatabaseLoadRejectsLateResult() async throws {
    let loadGate = ReceiptLiftLoadGate()
    let database = ReceiptLiftDatabase(
      load: { try await loadGate.load() },
      save: { _, _ in }
    )
    let loadTask = Task { try await database.load() }

    await loadGate.waitUntilLoadStarts()
    await database.invalidate()
    await loadGate.resumeLoad()

    await #expect(throws: CancellationError.self) {
      _ = try await loadTask.value
    }
  }

  private func makeCoordinator(adapter: ReceiptLiftDatabaseAdapterHarness) -> ReceiptLiftCoordinator {
    ReceiptLiftCoordinator(
      load: { await adapter.load() },
      save: { data, workouts in try await adapter.save(data, workouts: workouts) }
    )
  }

  private func planNames(_ routines: [LiftRoutine], exercises: [LiftExercise]) -> [String: [String]] {
    let namesByID = Dictionary(exercises.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    return routines.reduce(into: [String: [String]]()) { result, routine in
      result[routine.name] = (routine.exercisePlans ?? []).compactMap { namesByID[$0.exerciseID] }
    }
  }

  private func decodeEnvelope(_ data: Data) throws -> LiftDataEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LiftDataEnvelope.self, from: data)
  }
}

private actor ReceiptLiftDatabaseAdapterHarness {
  private var data: Data?
  private var workouts: [ReceiptLiftWorkout] = []
  private var failuresRemaining: Int
  private var saveAttempts = 0
  private var successfulSaves = 0

  init(failuresRemaining: Int = 0) {
    self.failuresRemaining = failuresRemaining
  }

  func load() -> Data? { data }

  func save(_ data: Data, workouts: [ReceiptLiftWorkout]) throws {
    saveAttempts += 1
    guard failuresRemaining == 0 else {
      failuresRemaining -= 1
      throw ReceiptLiftDatabaseAdapterError.injectedFailure
    }
    self.data = data
    self.workouts = workouts
    successfulSaves += 1
  }

  func snapshot() -> ReceiptLiftDatabaseAdapterSnapshot {
    ReceiptLiftDatabaseAdapterSnapshot(
      data: data,
      workouts: workouts,
      saveAttempts: saveAttempts,
      successfulSaves: successfulSaves
    )
  }
}

private struct ReceiptLiftDatabaseAdapterSnapshot: Sendable {
  var data: Data?
  var workouts: [ReceiptLiftWorkout]
  var saveAttempts: Int
  var successfulSaves: Int
}

private enum ReceiptLiftDatabaseAdapterError: Error {
  case injectedFailure
}

private actor ReceiptLiftLoadGate {
  private var loadContinuation: CheckedContinuation<Data?, Error>?
  private var startedContinuation: CheckedContinuation<Void, Never>?

  func load() async throws -> Data? {
    try await withCheckedThrowingContinuation { continuation in
      loadContinuation = continuation
      startedContinuation?.resume()
      startedContinuation = nil
    }
  }

  func waitUntilLoadStarts() async {
    guard loadContinuation == nil else { return }
    await withCheckedContinuation { continuation in
      startedContinuation = continuation
    }
  }

  func resumeLoad() {
    let continuation = loadContinuation
    loadContinuation = nil
    continuation?.resume(returning: nil)
  }
}
