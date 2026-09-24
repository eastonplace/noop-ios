import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Lift persistence v2")
@MainActor
struct LiftPersistenceTests {
  @Test func migratesLegacyFileToV2() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let legacy = makeLegacyData(catalogExercise: fixture.catalogExercise, customExercise: fixture.customExercise)
    let legacyBytes = try encode(legacy)
    try legacyBytes.write(to: fixture.dataURL, options: [.atomic])

    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await store.loadAndWait()

    #expect(store.sessions == legacy.sessions)
    #expect(store.activeSession == legacy.activeSession)
    #expect(store.restTimerEndDate == legacy.restTimerEndDate)
    #expect(store.workoutRestOverrideSeconds == legacy.workoutRestOverrideSeconds)
    #expect(store.completedExerciseIDs == legacy.completedExerciseIDs)
    #expect(store.activeExerciseIDsOverride == legacy.activeExerciseIDsOverride)
    #expect(store.activePlanOverrides == legacy.activePlanOverrides)
    #expect(store.activeSupersetGroups == legacy.activeSupersetGroups)
    #expect(store.settings.defaultRestSeconds == legacy.defaultRestSeconds)
    #expect(store.scheduledWorkouts.isEmpty)

    let migrated = try decodeEnvelope(from: fixture.dataURL)
    #expect(migrated.schemaVersion == 2)
    #expect(migrated.starterBankVersion == 1)
    #expect(migrated.sessions == legacy.sessions)
    #expect(migrated.activeSession == legacy.activeSession)
  }

  @Test func legacyMigrationDropsCatalogRowsButKeepsUserExercises() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let legacy = makeLegacyData(catalogExercise: fixture.catalogExercise, customExercise: fixture.customExercise)
    try encode(legacy).write(to: fixture.dataURL, options: [.atomic])

    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await store.loadAndWait()

    let migrated = try decodeEnvelope(from: fixture.dataURL)
    #expect(!migrated.userExercises.contains { $0.id == fixture.catalogExercise.id })
    #expect(migrated.userExercises.contains { $0.id == fixture.customExercise.id })
    #expect(store.exercises.contains { $0.id == fixture.catalogExercise.id })
    #expect(store.exercises.contains { $0.id == fixture.customExercise.id })
  }

  @Test func v2RoundTripPreservesActiveSessionAndSupersets() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let activeSession = makeActiveSession(exerciseID: fixture.customExercise.id)
    let plan = LiftRoutineExercisePlan(
      id: UUID(),
      exerciseID: fixture.customExercise.id,
      sets: "3",
      reps: "8-10",
      rest: "90 s",
      targetEffort: "2 RIR",
      notes: "Persist me"
    )
    let envelope = makeEnvelope(
      userExercises: [fixture.customExercise],
      activeSession: activeSession,
      completedExerciseIDs: [fixture.customExercise.id],
      activeExerciseIDsOverride: [fixture.customExercise.id],
      activePlanOverrides: [fixture.customExercise.id: plan],
      activeSupersetGroups: [fixture.customExercise.id: 2]
    )
    try encode(envelope).write(to: fixture.dataURL, options: [.atomic])

    let firstStore = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await firstStore.loadAndWait()
    firstStore.flushPendingSave()

    let secondStore = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await secondStore.loadAndWait()

    #expect(secondStore.activeSession == activeSession)
    #expect(secondStore.completedExerciseIDs == [fixture.customExercise.id])
    #expect(secondStore.activeExerciseIDsOverride == [fixture.customExercise.id])
    #expect(secondStore.activePlanOverrides == [fixture.customExercise.id: plan])
    #expect(secondStore.activeSupersetGroups == [fixture.customExercise.id: 2])
  }

  @Test func backupFileWrittenOnceOnMigration() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let legacy = makeLegacyData(catalogExercise: fixture.catalogExercise, customExercise: fixture.customExercise)
    let legacyBytes = try encode(legacy)
    try legacyBytes.write(to: fixture.dataURL, options: [.atomic])

    let firstStore = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await firstStore.loadAndWait()

    let backupURL = fixture.directory.appendingPathComponent("lift-data.v1.backup.json")
    let firstBackup = try Data(contentsOf: backupURL)
    #expect(firstBackup == legacyBytes)

    firstStore.setDefaultRestSeconds(120)
    firstStore.flushPendingSave()
    let secondStore = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await secondStore.loadAndWait()

    #expect(try Data(contentsOf: backupURL) == firstBackup)
  }

  @Test func invalidFileIsPreserved() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let invalid = Data("not valid lift data".utf8)
    try invalid.write(to: fixture.dataURL, options: [.atomic])

    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await store.loadAndWait()

    #expect(try Data(contentsOf: fixture.dataURL) == invalid)
    #expect(store.routines.isEmpty)
    #expect(store.status.contains("Load failed"))
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("lift-data.v1.backup.json").path))
  }

  @Test func newerSchemaIsNotOverwritten() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var envelope = makeEnvelope(userExercises: [fixture.customExercise])
    envelope.schemaVersion = 999
    let futureBytes = try encode(envelope)
    try futureBytes.write(to: fixture.dataURL, options: [.atomic])

    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await store.loadAndWait()

    #expect(try Data(contentsOf: fixture.dataURL) == futureBytes)
    #expect(store.routines.isEmpty)
    #expect(store.status.contains("Unsupported schema"))
  }

  @Test func editedStarterRoutineSurvivesReload() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let seedStore = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await seedStore.loadAndWait()
    var envelope = try decodeEnvelope(from: fixture.dataURL)
    let index = try #require(envelope.routines.firstIndex { $0.name == "Upper A" })
    let originalID = envelope.routines[index].id
    envelope.routines[index].notes = "My protected edit"
    try encode(envelope).write(to: fixture.dataURL, options: [.atomic])

    let reloaded = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await reloaded.loadAndWait()

    let upperA = try #require(reloaded.routines.first { $0.name == "Upper A" })
    #expect(upperA.id == originalID)
    #expect(upperA.notes == "My protected edit")
  }

  @Test func deletedStarterRoutineStaysDeleted() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let seedStore = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await seedStore.loadAndWait()
    var envelope = try decodeEnvelope(from: fixture.dataURL)
    envelope.routines.removeAll { $0.name == "Lower B" }
    try encode(envelope).write(to: fixture.dataURL, options: [.atomic])

    let reloaded = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await reloaded.loadAndWait()

    #expect(!reloaded.routines.contains { $0.name == "Lower B" })
  }

  @Test func freshInstallSeedsFiveRoutinesAnd37Exercises() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)

    await store.loadAndWait()

    let envelope = try decodeEnvelope(from: fixture.dataURL)
    #expect(envelope.routines.count == 5)
    #expect(envelope.userExercises.count == 37)
    #expect(envelope.sessions.isEmpty)
    #expect(envelope.scheduledWorkouts.isEmpty)
  }

  @Test func restoreStarterRoutineAddsNonCollidingCopy() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await store.loadAndWait()
    let original = try #require(store.routines.first { $0.name == "Upper A" })

    store.restoreStarterRoutine(named: "Upper A")
    store.flushPendingSave()

    #expect(store.routines.contains { $0.id == original.id && $0.name == "Upper A" })
    #expect(store.routines.contains { $0.id != original.id && $0.name == "Upper A (Starter)" })
    #expect(Set(store.routines.map(\.name)).count == store.routines.count)
  }

  @Test func legacyStarterNamesCleanOnlyDuringMigration() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    var legacy = makeLegacyData(catalogExercise: fixture.catalogExercise, customExercise: fixture.customExercise)
    legacy.routines.append(
      LiftRoutine(
        id: UUID(),
        name: "Push Day",
        notes: "Legacy starter",
        trainingMode: .hypertrophy,
        exerciseIDs: [],
        exercisePlans: []
      )
    )
    try encode(legacy).write(to: fixture.dataURL, options: [.atomic])

    let migratedStore = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await migratedStore.loadAndWait()
    #expect(!migratedStore.routines.contains { $0.name == "Push Day" })

    var envelope = try decodeEnvelope(from: fixture.dataURL)
    envelope.routines.append(
      LiftRoutine(
        id: UUID(),
        name: "Push Day",
        notes: "User-owned v2 routine",
        trainingMode: .hypertrophy,
        exerciseIDs: [],
        exercisePlans: []
      )
    )
    try encode(envelope).write(to: fixture.dataURL, options: [.atomic])

    let v2Store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0.01)
    await v2Store.loadAndWait()
    #expect(v2Store.routines.contains { $0.name == "Push Day" && $0.notes == "User-owned v2 routine" })
  }

  private func makeFixture() throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiftPersistenceTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let catalogExercise = try #require(LiftExerciseCatalog.catalogExercises().first)
    return Fixture(
      directory: directory,
      dataURL: directory.appendingPathComponent("lift-data.json"),
      catalogExercise: catalogExercise,
      customExercise: LiftExercise(
        id: UUID(),
        name: "Custom Test Press",
        muscleGroup: "Chest",
        equipment: "Machine",
        instructions: "Test instructions"
      )
    )
  }

  private func makeLegacyData(
    catalogExercise: LiftExercise,
    customExercise: LiftExercise
  ) -> LiftLegacyData {
    let activeSession = makeActiveSession(exerciseID: customExercise.id)
    let completedSession = LiftSession(
      id: UUID(),
      routineID: nil,
      title: "Completed Test",
      startedAt: Date(timeIntervalSince1970: 1_720_000_000),
      endedAt: Date(timeIntervalSince1970: 1_720_003_600),
      sets: [makeSet(exerciseID: customExercise.id)]
    )
    let plan = LiftRoutineExercisePlan(
      id: UUID(),
      exerciseID: customExercise.id,
      sets: "3",
      reps: "8",
      rest: "90 s",
      targetEffort: "2 RIR",
      notes: "Legacy plan"
    )
    return LiftLegacyData(
      exercises: [catalogExercise, customExercise],
      routines: [
        LiftRoutine(
          id: UUID(),
          name: "My Routine",
          notes: "Keep this",
          trainingMode: .hypertrophy,
          exerciseIDs: [customExercise.id],
          exercisePlans: [plan]
        )
      ],
      sessions: [completedSession],
      activeSession: activeSession,
      restTimerEndDate: Date(timeIntervalSince1970: 1_720_004_000),
      workoutRestOverrideSeconds: 135,
      completedExerciseIDs: [customExercise.id],
      activeExerciseIDsOverride: [customExercise.id],
      activePlanOverrides: [customExercise.id: plan],
      activeSupersetGroups: [customExercise.id: 1],
      defaultRestSeconds: 105
    )
  }

  private func makeEnvelope(
    userExercises: [LiftExercise],
    activeSession: LiftSession? = nil,
    completedExerciseIDs: Set<UUID> = [],
    activeExerciseIDsOverride: [UUID]? = nil,
    activePlanOverrides: [UUID: LiftRoutineExercisePlan] = [:],
    activeSupersetGroups: [UUID: Int] = [:]
  ) -> LiftDataEnvelope {
    LiftDataEnvelope(
      schemaVersion: 2,
      starterBankVersion: 1,
      userExercises: userExercises,
      routines: [],
      scheduledWorkouts: [],
      sessions: [],
      activeSession: activeSession,
      restTimerEndDate: nil,
      workoutRestOverrideSeconds: nil,
      completedExerciseIDs: completedExerciseIDs,
      activeExerciseIDsOverride: activeExerciseIDsOverride,
      activePlanOverrides: activePlanOverrides,
      activeSupersetGroups: activeSupersetGroups,
      settings: LiftSettings()
    )
  }

  private func makeActiveSession(exerciseID: UUID) -> LiftSession {
    LiftSession(
      id: UUID(),
      routineID: nil,
      title: "Active Test",
      startedAt: Date(timeIntervalSince1970: 1_720_010_000),
      endedAt: nil,
      sets: [makeSet(exerciseID: exerciseID)]
    )
  }

  private func makeSet(exerciseID: UUID) -> LiftSet {
    LiftSet(
      id: UUID(),
      exerciseID: exerciseID,
      setNumber: 1,
      weight: 100,
      reps: 8,
      rpe: 8,
      isWarmup: false,
      completedAt: Date(timeIntervalSince1970: 1_720_010_100),
      notes: ""
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

private struct Fixture {
  var directory: URL
  var dataURL: URL
  var catalogExercise: LiftExercise
  var customExercise: LiftExercise
}
