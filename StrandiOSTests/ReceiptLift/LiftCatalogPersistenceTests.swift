import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Lift catalog persistence")
@MainActor
struct LiftCatalogPersistenceTests {
  @Test func v2FileContainsNoCatalogExercises() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await store.loadAndWait()

    let envelope = try decodeEnvelope(from: fixture.dataURL)
    #expect(Set(envelope.userExercises.map(\.id)).isDisjoint(with: LiftExerciseCatalog.catalogExerciseIDs))
  }

  @Test func runtimeUnionResolvesStableCatalogIDs() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let catalogExercise = try #require(LiftExerciseCatalog.catalogExercises().first)
    let plan = LiftRoutineExercisePlan(
      id: UUID(), exerciseID: catalogExercise.id, sets: "3", reps: "8", rest: "90 s",
      targetEffort: "2 RIR", notes: "Catalog reference"
    )
    let routine = LiftRoutine(
      id: UUID(), name: "Catalog Routine", notes: "", trainingMode: .hypertrophy,
      exerciseIDs: [catalogExercise.id], exercisePlans: [plan]
    )
    try encode(makeEnvelope(userExercises: [], routines: [routine])).write(to: fixture.dataURL)

    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await store.loadAndWait()

    #expect(store.exercises.contains { $0.id == catalogExercise.id })
    #expect(store.displayExercises.contains { $0.id == catalogExercise.id })
  }

  @Test func persistedExerciseWinsNormalizedNameCollision() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let catalogExercise = try #require(LiftExerciseCatalog.catalogExercises().first)
    let custom = LiftExercise(
      id: UUID(), name: catalogExercise.name.uppercased(), muscleGroup: "Custom",
      equipment: "Custom", instructions: "Persisted wins"
    )
    try encode(makeEnvelope(userExercises: [custom], routines: [])).write(to: fixture.dataURL)

    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await store.loadAndWait()
    let matches = store.exercises.filter {
      LiftExerciseCatalog.normalizedName($0.name) == LiftExerciseCatalog.normalizedName(custom.name)
    }

    #expect(matches.count == 1)
    #expect(matches.first?.id == custom.id)
  }

  @Test func newCustomExercisePersistsWithoutCatalogRows() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await store.loadAndWait()

    store.addExercise(name: "My Cable Press", muscleGroup: "Chest", equipment: "Cable", instructions: "Custom")
    await store.waitForPendingSave()

    let envelope = try decodeEnvelope(from: fixture.dataURL)
    #expect(envelope.userExercises.contains { $0.name == "My Cable Press" })
    #expect(Set(envelope.userExercises.map(\.id)).isDisjoint(with: LiftExerciseCatalog.catalogExerciseIDs))
  }

  private func makeFixture() throws -> CatalogFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiftCatalogPersistenceTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return CatalogFixture(directory: directory, dataURL: directory.appendingPathComponent("lift-data.json"))
  }

  private func makeEnvelope(userExercises: [LiftExercise], routines: [LiftRoutine]) -> LiftDataEnvelope {
    LiftDataEnvelope(
      schemaVersion: 2, starterBankVersion: 1, userExercises: userExercises, routines: routines,
      scheduledWorkouts: [], sessions: [], activeSession: nil, restTimerEndDate: nil,
      workoutRestOverrideSeconds: nil, completedExerciseIDs: [], activeExerciseIDsOverride: nil,
      activePlanOverrides: [:], activeSupersetGroups: [:], settings: LiftSettings()
    )
  }

  private func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private func decodeEnvelope(from url: URL) throws -> LiftDataEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LiftDataEnvelope.self, from: Data(contentsOf: url))
  }
}

private struct CatalogFixture {
  var directory: URL
  var dataURL: URL
}
