import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Receipt Lift history")
@MainActor
struct ReceiptLiftHistoryTests {
  private func makeCoordinator(_ harness: HistoryHarness) -> ReceiptLiftCoordinator {
    ReceiptLiftCoordinator(
      load: { await harness.load() },
      save: { data, workouts in await harness.save(data, workouts: workouts) })
  }

  private func decodeEnvelope(_ data: Data) throws -> LiftDataEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LiftDataEnvelope.self, from: data)
  }

  /// A fresh store, one finished session with sets on the given starter exercises.
  private func finishedSession(
    exerciseNames: [String]
  ) async throws -> (data: Data, delivered: [ReceiptLiftWorkout], store: LiftStore) {
    let harness = HistoryHarness()
    let coordinator = makeCoordinator(harness)
    await coordinator.load()
    await coordinator.store.waitForPendingSave()
    coordinator.store.startRoutine(nil)
    for name in exerciseNames {
      let exercise = try #require(coordinator.store.exercises.first { $0.name == name })
      #expect(coordinator.store.logSet(exercise: exercise, weight: 100, reps: 10, rpe: 8, isWarmup: false) != nil)
    }
    #expect(await coordinator.store.finishActiveSessionDurably() != nil)
    let snapshot = await harness.snapshot()
    return (try #require(snapshot.data), snapshot.workouts, coordinator.store)
  }

  @Test func theDecodeEqualsTheDatabaseMapping() async throws {
    let saved = try await finishedSession(exerciseNames: ["Calf Raise", "Hanging Knee Raise", "Leg Press"])

    let history = try ReceiptLiftHistory.completedWorkouts(fromStateData: saved.data)

    #expect(history.count == 1)
    // The save path delivers the in-memory workout (sub-second dates). The stored blob is iso8601, so the history
    // read matches it to the second; every other field is the same.
    let delivered = try #require(saved.delivered.first)
    let first = try #require(history.first)
    #expect(first.id == delivered.id)
    #expect(first.title == delivered.title)
    #expect(first.sets.map(\.id) == delivered.sets.map(\.id))
    #expect(first.sets.map(\.exercise) == delivered.sets.map(\.exercise))
    #expect(first.sets.map(\.muscleGroup) == delivered.sets.map(\.muscleGroup))
    #expect(first.sets.map(\.secondaryMuscles) == delivered.sets.map(\.secondaryMuscles))
    #expect(first.sets.map(\.equipment) == delivered.sets.map(\.equipment))
    #expect(first.sets.map(\.weightKg) == delivered.sets.map(\.weightKg))
    let mapped = ReceiptLiftDatabase.workouts(try decodeEnvelope(saved.data))
    #expect(history == mapped)
    #expect(history.first?.sets.map(\.exercise) == ["Calf Raise", "Hanging Knee Raise", "Leg Press"])
    #expect(history.first?.sets.map(\.setIndex) == [1, 1, 1])
  }

  @Test func equipmentIsTheExercisesOwnNotTheMediaAliases() async throws {
    let saved = try await finishedSession(exerciseNames: ["Calf Raise", "Hanging Knee Raise", "Leg Press"])
    let sets = try #require(ReceiptLiftHistory.completedWorkouts(fromStateData: saved.data).first?.sets)

    let equipment = Dictionary(uniqueKeysWithValues: sets.map { ($0.exercise, $0.equipment) })
    #expect(equipment["Calf Raise"] == "Machine")
    #expect(equipment["Hanging Knee Raise"] == "Bodyweight")
    #expect(equipment["Leg Press"] == "Machine")

    // The alias that supplies the image for "Calf Raise" is a body-weight catalog record. The set must not take it.
    let calf = try #require(saved.store.exercises.first { $0.name == "Calf Raise" })
    #expect(LiftExerciseCatalog.metadata(for: calf)?.equipment == "body weight")
    #expect(calf.equipment == "Machine")
    // Muscles still come from the catalog record, unchanged by this work.
    let calfSet = try #require(sets.first { $0.exercise == "Calf Raise" })
    #expect(calfSet.muscleGroup == (LiftExerciseCatalog.metadata(for: calf)?.target ?? calf.muscleGroup))
  }

  @Test func aCatalogExerciseCarriesItsCatalogEquipment() async throws {
    let harness = HistoryHarness()
    let coordinator = makeCoordinator(harness)
    await coordinator.load()
    await coordinator.store.waitForPendingSave()
    let bench = try #require(coordinator.store.exercises.first {
      LiftExerciseCatalog.normalizedName($0.name) == LiftExerciseCatalog.normalizedName("barbell bench press")
    })
    coordinator.store.startRoutine(nil)
    #expect(coordinator.store.logSet(exercise: bench, weight: 135, reps: 8, rpe: 8, isWarmup: false) != nil)
    #expect(await coordinator.store.finishActiveSessionDurably() != nil)

    let data = try #require(await harness.snapshot().data)
    let set = try #require(ReceiptLiftHistory.completedWorkouts(fromStateData: data).first?.sets.first)
    #expect(set.equipment == bench.equipment)
    #expect(set.equipment == LiftExerciseCatalog.metadata(for: bench)?.equipment)
  }

  @Test func aWrongSchemaThrows() async throws {
    let saved = try await finishedSession(exerciseNames: ["Calf Raise"])
    var envelope = try decodeEnvelope(saved.data)
    envelope.schemaVersion = LiftDataEnvelope.currentSchemaVersion + 1
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    do {
      _ = try ReceiptLiftHistory.completedWorkouts(fromStateData: try encoder.encode(envelope))
      Issue.record("an unsupported schema must throw")
    } catch LiftPersistenceError.unsupportedSchema(let version) {
      #expect(version == LiftDataEnvelope.currentSchemaVersion + 1)
    }
    #expect(throws: (any Error).self) {
      _ = try ReceiptLiftHistory.completedWorkouts(fromStateData: Data("not json".utf8))
    }
  }

  @Test func anEnvelopeWithoutFinishedSessionsHasNoHistory() async throws {
    let harness = HistoryHarness()
    let coordinator = makeCoordinator(harness)
    await coordinator.load()
    await coordinator.store.waitForPendingSave()
    let data = try #require(await harness.snapshot().data)
    #expect(try ReceiptLiftHistory.completedWorkouts(fromStateData: data).isEmpty)
  }

  @Test func theEquipmentFieldIsOptionalAndDefaultsToNil() throws {
    let set = ReceiptLiftSet(id: "s", exercise: "Pull-Up", muscleGroup: "lats", setIndex: 1, weightKg: 0, reps: 8,
                             rpe: nil, isWarmup: false, completedAt: Date(timeIntervalSince1970: 1_780_000_000),
                             note: nil)
    #expect(set.equipment == nil)
    #expect(set.secondaryMuscles.isEmpty)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let bytes = try encoder.encode(set)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("equipment"), "a nil equipment is not written")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(ReceiptLiftSet.self, from: bytes) == set)

    var withEquipment = set
    withEquipment.equipment = "Bodyweight"
    let roundTrip = try decoder.decode(ReceiptLiftSet.self, from: try encoder.encode(withEquipment))
    #expect(roundTrip == withEquipment)
    #expect(roundTrip != set)
  }
}

private actor HistoryHarness {
  private var data: Data?
  private var workouts: [ReceiptLiftWorkout] = []

  func load() -> Data? { data }

  func save(_ data: Data, workouts: [ReceiptLiftWorkout]) {
    self.data = data
    self.workouts = workouts
  }

  func snapshot() -> HistorySnapshot { HistorySnapshot(data: data, workouts: workouts) }
}

private struct HistorySnapshot: Sendable {
  var data: Data?
  var workouts: [ReceiptLiftWorkout]
}
