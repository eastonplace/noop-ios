import Foundation
import Testing
@testable import ReceiptLiftFeature

/// Strength Strain never writes routines, the schedule, the starter bank version or the schema version. These tests
/// load a stored envelope, save it unchanged, then log and finish a session, and compare the protected fields as
/// bytes (`JSONEncoder`, `.sortedKeys`, `.iso8601`, the same configuration the save path uses).
@Suite("Lift routines round trip")
@MainActor
struct LiftRoutinesRoundTripTests {
  private static let benchID = UUID(uuidString: "0A000000-0000-4000-8000-000000000001")!
  private static let rowID = UUID(uuidString: "0A000000-0000-4000-8000-000000000002")!
  private static let routineAID = UUID(uuidString: "0B000000-0000-4000-8000-000000000001")!
  private static let routineBID = UUID(uuidString: "0B000000-0000-4000-8000-000000000002")!
  private static let oldSessionID = UUID(uuidString: "0C000000-0000-4000-8000-000000000001")!
  private static let base = Date(timeIntervalSince1970: 1_780_000_000)

  /// A schema-2 envelope: 2 routines, 3 scheduled workouts, one finished session that was linked to one of them.
  private static func fixture() -> LiftDataEnvelope {
    let bench = LiftExercise(id: benchID, name: "Fixture Bench Press", muscleGroup: "pectorals",
                             equipment: "Barbell", instructions: "Press it.")
    let row = LiftExercise(id: rowID, name: "Fixture Row", muscleGroup: "lats",
                           equipment: "Cable", instructions: "Pull it.")
    let planA = LiftRoutineExercisePlan(id: UUID(uuidString: "0D000000-0000-4000-8000-000000000001")!,
                                        exerciseID: benchID, sets: "3", reps: "5-8", rest: "120 s",
                                        targetEffort: "1-2 RIR", notes: "Heavy top set.")
    let planB = LiftRoutineExercisePlan(id: UUID(uuidString: "0D000000-0000-4000-8000-000000000002")!,
                                        exerciseID: rowID, sets: "4", reps: "8-12", rest: "90 s",
                                        targetEffort: "0-2 RIR", notes: "")
    let routineA = LiftRoutine(id: routineAID, name: "Fixture Push", notes: "Chest and triceps.",
                               trainingMode: .strength, exerciseIDs: [benchID], exercisePlans: [planA])
    let routineB = LiftRoutine(id: routineBID, name: "Fixture Pull", notes: "",
                               trainingMode: .hypertrophy, exerciseIDs: [rowID], exercisePlans: [planB])
    let oldSet = { (n: Int, weight: Double, reps: Int, rpe: Double) in
      LiftSet(id: UUID(uuidString: "0E000000-0000-4000-8000-00000000000\(n)")!, exerciseID: benchID, setNumber: n,
              weight: weight, reps: reps, rpe: rpe, isWarmup: n == 1,
              completedAt: base.addingTimeInterval(TimeInterval(-86_400 + n * 180)), notes: n == 2 ? "felt strong" : "")
    }
    let oldSession = LiftSession(id: oldSessionID, routineID: routineAID, title: "Fixture Push",
                                 startedAt: base.addingTimeInterval(-86_400),
                                 endedAt: base.addingTimeInterval(-86_400 + 3_000),
                                 sets: [oldSet(1, 95, 10, 5), oldSet(2, 185, 5, 8), oldSet(3, 185, 5, 8.5)])
    let scheduled = [
      ScheduledWorkout(id: UUID(uuidString: "0F000000-0000-4000-8000-000000000001")!, routineID: routineAID,
                       plannedAt: base.addingTimeInterval(-86_400), note: "", completedSessionID: oldSessionID),
      ScheduledWorkout(id: UUID(uuidString: "0F000000-0000-4000-8000-000000000002")!, routineID: routineBID,
                       plannedAt: base.addingTimeInterval(2 * 86_400), note: "Back day", completedSessionID: nil),
      ScheduledWorkout(id: UUID(uuidString: "0F000000-0000-4000-8000-000000000003")!, routineID: routineAID,
                       plannedAt: base.addingTimeInterval(4 * 86_400), note: "", completedSessionID: nil),
    ]
    return LiftDataEnvelope(
      schemaVersion: LiftDataEnvelope.currentSchemaVersion,
      starterBankVersion: LiftDataEnvelope.currentStarterBankVersion,
      userExercises: [bench, row], routines: [routineA, routineB], scheduledWorkouts: scheduled,
      sessions: [oldSession], activeSession: nil, restTimerEndDate: nil, workoutRestOverrideSeconds: nil,
      completedExerciseIDs: [], activeExerciseIDsOverride: nil, activePlanOverrides: [:],
      activeSupersetGroups: [:], settings: LiftSettings())
  }

  private static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  private static func decode(_ data: Data) throws -> LiftDataEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LiftDataEnvelope.self, from: data)
  }

  private func makeCoordinator(_ harness: RoundTripHarness) -> ReceiptLiftCoordinator {
    ReceiptLiftCoordinator(
      load: { await harness.load() },
      save: { data, workouts in await harness.save(data, workouts: workouts) })
  }

  @Test func theFixtureIsASchemaTwoEnvelopeWithTheExpectedShape() throws {
    let envelope = Self.fixture()
    let decoded = try Self.decode(Self.encode(envelope))
    #expect(decoded == envelope)
    #expect(decoded.schemaVersion == 2)
    #expect(decoded.starterBankVersion == 1)
    #expect(decoded.routines.count == 2)
    #expect(decoded.scheduledWorkouts.count == 3)
  }

  @Test func loadingAndSavingUnchangedKeepsEveryProtectedByte() async throws {
    let fixture = Self.fixture()
    let fixtureBytes = try Self.encode(fixture)
    let harness = RoundTripHarness(initial: fixtureBytes)
    let coordinator = makeCoordinator(harness)

    await coordinator.load()
    await coordinator.store.waitForPendingSave()
    let afterLoad = await harness.snapshot()
    #expect(afterLoad.saves == 0, "a stored schema-2 envelope at the current starter bank is not rewritten on load")

    coordinator.store.flushPendingSave()
    await coordinator.store.waitForPendingSave()

    let snapshot = await harness.snapshot()
    #expect(snapshot.saves == 1)
    let savedBytes = try #require(snapshot.data)
    let saved = try Self.decode(savedBytes)
    #expect(try Self.encode(saved.routines) == Self.encode(fixture.routines))
    #expect(try Self.encode(saved.scheduledWorkouts) == Self.encode(fixture.scheduledWorkouts))
    #expect(saved.schemaVersion == 2)
    #expect(saved.starterBankVersion == 1)
    #expect(savedBytes == fixtureBytes, "an unchanged save re-encodes to the same bytes")
    #expect(snapshot.workouts.isEmpty, "the new equipment field must not make every stored workout look changed")
  }

  @Test func loggingAndFinishingASessionLeavesRoutinesAndScheduleByteIdentical() async throws {
    let fixture = Self.fixture()
    let harness = RoundTripHarness(initial: try Self.encode(fixture))
    let coordinator = makeCoordinator(harness)
    await coordinator.load()
    await coordinator.store.waitForPendingSave()
    let bench = try #require(coordinator.store.exercises.first { $0.id == Self.benchID })
    let row = try #require(coordinator.store.exercises.first { $0.id == Self.rowID })

    // One open session, with an RPE that is left at the composer's default and one that is changed on purpose.
    coordinator.store.startRoutine(nil)
    #expect(coordinator.store.logSet(exercise: bench, weight: 135, reps: 8, rpe: 8, isWarmup: false) != nil)
    #expect(coordinator.store.logSet(exercise: row, weight: 110, reps: 10, rpe: 7.5, isWarmup: false) != nil)
    let finished = await coordinator.store.finishActiveSessionDurably()
    #expect(finished != nil)

    let snapshot = await harness.snapshot()
    let savedBytes = try #require(snapshot.data)
    let saved = try Self.decode(savedBytes)

    #expect(try Self.encode(saved.routines) == Self.encode(fixture.routines))
    #expect(try Self.encode(saved.scheduledWorkouts) == Self.encode(fixture.scheduledWorkouts))
    #expect(saved.schemaVersion == 2)
    #expect(saved.starterBankVersion == 1)
    #expect(saved.sessions.count == 2)
    #expect(snapshot.workouts.count == 1, "only the new session is delivered")
    #expect(snapshot.workouts.first?.sets.count == 2)
  }

  @Test func startingTheSelectedSavedRoutinePersistsItsIdentityAndPlanWithoutChangingRoutinesOrSchedule() async throws {
    let fixture = Self.fixture()
    let harness = RoundTripHarness(initial: try Self.encode(fixture))
    let coordinator = makeCoordinator(harness)
    await coordinator.load()
    let selected = try #require(coordinator.store.routines.first { $0.id == Self.routineBID })

    coordinator.store.startRoutine(selected)
    coordinator.store.flushPendingSave()
    await coordinator.store.waitForPendingSave()

    let snapshot = await harness.snapshot()
    let saved = try Self.decode(#require(snapshot.data))
    #expect(saved.activeSession?.routineID == Self.routineBID)
    #expect(saved.activeSession?.title == "Fixture Pull")
    #expect(saved.activeSession?.sets.isEmpty == true)
    #expect(saved.sessions == fixture.sessions, "Starting does not complete or replace history")
    #expect(saved.activeExerciseIDsOverride == [Self.rowID])
    #expect(saved.activePlanOverrides[Self.rowID]?.sets == "4")
    #expect(saved.activePlanOverrides[Self.rowID]?.reps == "8-12")
    #expect(saved.activePlanOverrides[Self.benchID] == nil)
    #expect(try Self.encode(saved.routines) == Self.encode(fixture.routines))
    #expect(try Self.encode(saved.scheduledWorkouts) == Self.encode(fixture.scheduledWorkouts))

    let reloaded = makeCoordinator(harness)
    await reloaded.load()
    #expect(reloaded.store.activeSession?.id == saved.activeSession?.id)
    #expect(reloaded.store.activeSession?.routineID == Self.routineBID)
    #expect(reloaded.store.activeExercises.map(\.id) == [Self.rowID])
    #expect(reloaded.store.activePlan(for: Self.rowID)?.sets == "4")
  }

  @Test func aPreExistingSessionsSetsEncodeByteIdentically() async throws {
    let fixture = Self.fixture()
    let originalSets = try Self.encode(fixture.sessions[0].sets)
    let harness = RoundTripHarness(initial: try Self.encode(fixture))
    let coordinator = makeCoordinator(harness)
    await coordinator.load()
    await coordinator.store.waitForPendingSave()
    let bench = try #require(coordinator.store.exercises.first { $0.id == Self.benchID })

    coordinator.store.startRoutine(nil)
    #expect(coordinator.store.logSet(exercise: bench, weight: 100, reps: 5, rpe: 6, isWarmup: false) != nil)
    _ = await coordinator.store.finishActiveSessionDurably()

    let snapshot = await harness.snapshot()
    let savedBytes = try #require(snapshot.data)
    let saved = try Self.decode(savedBytes)
    let old = try #require(saved.sessions.first { $0.id == Self.oldSessionID })
    #expect(try Self.encode(old.sets) == originalSets)
    #expect(!String(decoding: savedBytes, as: UTF8.self).contains("effortRated"),
            "no new key appears in any stored set")
    #expect(!String(decoding: originalSets, as: UTF8.self).contains("effortRated"))
  }

  @Test func theStarterBankTemplatesAndVersionsAreUnchanged() {
    #expect(LiftDataEnvelope.currentSchemaVersion == 2)
    #expect(LiftDataEnvelope.currentStarterBankVersion == 1)
    let bank = LiftRoutineBank.make()
    #expect(bank.routineTemplates.map(\.name) == ["Upper A", "Lower A", "Pull + Posture", "Push + Delts", "Lower B"])
    #expect(bank.routineTemplates.map { $0.plans.count } == [8, 7, 9, 9, 7])
  }
}

private actor RoundTripHarness {
  private var data: Data?
  private var workouts: [ReceiptLiftWorkout] = []
  private var saves = 0

  init(initial: Data?) { data = initial }

  func load() -> Data? { data }

  func save(_ data: Data, workouts: [ReceiptLiftWorkout]) {
    self.data = data
    self.workouts = workouts
    saves += 1
  }

  func snapshot() -> RoundTripSnapshot { RoundTripSnapshot(data: data, workouts: workouts, saves: saves) }
}

private struct RoundTripSnapshot: Sendable {
  var data: Data?
  var workouts: [ReceiptLiftWorkout]
  var saves: Int
}
