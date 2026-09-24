import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Schedule, routines, and contextual library")
@MainActor
struct LiftScheduleTests {
  @Test func routineCRUDRoundTripsThroughPersistenceEnvelopeAndReload() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let originalPlan = Self.plan(fixture.exercises[0].id, sets: "3")
    let replacementPlan = Self.plan(fixture.exercises[1].id, sets: "5")

    let created = fixture.store.createRoutine(
      name: "Persistent Draft", notes: "First pass", trainingMode: .hypertrophy,
      plans: [originalPlan]
    )
    var updated = created
    updated.name = "Persistent Final"
    updated.notes = "Updated notes"
    updated.trainingMode = .strength
    updated.exerciseIDs = [replacementPlan.exerciseID]
    updated.exercisePlans = [replacementPlan]
    fixture.store.updateRoutine(updated)
    fixture.store.flushPendingSave()

    let persistedAfterUpdate = try Self.decodeEnvelope(at: fixture.dataURL)
    let reloadedAfterUpdate = await fixture.reloadedStore()
    let envelopeRoutine = try #require(
      persistedAfterUpdate.routines.first { $0.id == created.id }
    )
    let reloadedRoutine = try #require(
      reloadedAfterUpdate.routines.first { $0.id == created.id }
    )

    #expect(envelopeRoutine == reloadedRoutine)
    #expect(reloadedRoutine.name == "Persistent Final")
    #expect(reloadedRoutine.notes == "Updated notes")
    #expect(reloadedRoutine.trainingMode == .strength)
    #expect(reloadedRoutine.exerciseIDs == [replacementPlan.exerciseID])
    #expect(reloadedRoutine.exercisePlans == [replacementPlan])

    reloadedAfterUpdate.deleteRoutine(id: created.id)
    reloadedAfterUpdate.flushPendingSave()

    let persistedAfterDelete = try Self.decodeEnvelope(at: fixture.dataURL)
    let reloadedAfterDelete = await fixture.reloadedStore()
    #expect(!persistedAfterDelete.routines.contains { $0.id == created.id })
    #expect(!reloadedAfterDelete.routines.contains { $0.id == created.id })
  }

  @Test func routineWritesCanonicalizeAndDuplicateFreshPlanIDs() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let first = fixture.exercises[0]
    let second = fixture.exercises[1]
    let firstPlan = Self.plan(first.id, sets: "4")
    let duplicateFirst = Self.plan(first.id, sets: "9")
    let secondPlan = Self.plan(second.id, sets: "3")

    let routine = fixture.store.createRoutine(
      name: "  Test Order  ", notes: "Keep", trainingMode: .strength,
      plans: [firstPlan, duplicateFirst, secondPlan]
    )
    let copy = try #require(fixture.store.duplicateRoutine(id: routine.id))

    #expect(routine.name == "Test Order")
    #expect(routine.exerciseIDs == [first.id, second.id])
    #expect(routine.exercisePlans == [firstPlan, secondPlan])
    #expect(copy.id != routine.id)
    #expect(copy.name == "Test Order Copy")
    #expect(copy.exerciseIDs == routine.exerciseIDs)
    #expect(copy.exercisePlans?.map(\.id) != routine.exercisePlans?.map(\.id))
  }

  @Test func routineMoveAndUpdateKeepPlansAndIDsInLockstep() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let plans = fixture.exercises.prefix(3).map { Self.plan($0.id) }
    let routine = fixture.store.createRoutine(
      name: "Move", notes: "", trainingMode: .hypertrophy, plans: plans
    )

    fixture.store.moveRoutinePlan(routineID: routine.id, from: IndexSet(integer: 0), to: 3)
    let moved = try #require(fixture.store.routines.first { $0.id == routine.id })

    #expect(moved.exercisePlans?.map(\.exerciseID) == [plans[1].exerciseID, plans[2].exerciseID, plans[0].exerciseID])
    #expect(moved.exerciseIDs == moved.exercisePlans?.map(\.exerciseID))
  }

  @Test func deletingRoutineTreatsTodayAsUpcomingAndKeepsPastOrCompletedHistory() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
    let now = Date(timeIntervalSince1970: 1_735_732_800) // 2025-01-01 12:00 UTC
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let routine = fixture.store.createRoutine(name: "Delete", notes: "", trainingMode: .hypertrophy)
    let past = fixture.store.scheduleWorkout(
      routineID: routine.id, at: now.addingTimeInterval(-86_400), note: "past"
    )
    let earlierToday = fixture.store.scheduleWorkout(
      routineID: routine.id, at: now.addingTimeInterval(-4 * 3_600), note: "today earlier"
    )
    let laterToday = fixture.store.scheduleWorkout(
      routineID: routine.id, at: now.addingTimeInterval(4 * 3_600), note: "today later"
    )
    let tomorrow = fixture.store.scheduleWorkout(
      routineID: routine.id, at: now.addingTimeInterval(86_400), note: "tomorrow"
    )
    var completed = fixture.store.scheduleWorkout(
      routineID: routine.id, at: now.addingTimeInterval(2 * 86_400), note: "done"
    )
    completed.completedSessionID = UUID()
    fixture.store.updateScheduledWorkout(completed)

    fixture.store.deleteRoutine(id: routine.id, now: now, calendar: calendar)

    #expect(fixture.store.scheduledWorkouts.contains { $0.id == past.id })
    #expect(fixture.store.scheduledWorkouts.contains { $0.id == completed.id })
    #expect(!fixture.store.scheduledWorkouts.contains { $0.id == earlierToday.id })
    #expect(!fixture.store.scheduledWorkouts.contains { $0.id == laterToday.id })
    #expect(!fixture.store.scheduledWorkouts.contains { $0.id == tomorrow.id })
  }

  @Test func scheduleProjectionsUseCalendarBoundsAndStableOrdering() async throws {
    let calendar = Calendar(identifier: .gregorian)
    let now = Date(timeIntervalSince1970: 1_735_732_800)
    let routineID = UUID()
    let old = ScheduledWorkout(id: UUID(), routineID: routineID, plannedAt: now.addingTimeInterval(-7 * 86_400), note: "old", completedSessionID: UUID())
    let recent = ScheduledWorkout(id: UUID(), routineID: routineID, plannedAt: now.addingTimeInterval(-5 * 86_400), note: "recent", completedSessionID: UUID())
    let today = ScheduledWorkout(id: UUID(), routineID: routineID, plannedAt: now, note: "today", completedSessionID: nil)
    let future = ScheduledWorkout(id: UUID(), routineID: routineID, plannedAt: now.addingTimeInterval(86_400), note: "future", completedSessionID: nil)
    let completedFuture = ScheduledWorkout(id: UUID(), routineID: routineID, plannedAt: now.addingTimeInterval(2 * 86_400), note: "completed future", completedSessionID: UUID())

    let upcoming = LiftStore.upcomingWorkouts(
      in: [completedFuture, future, old, today, recent], now: now, calendar: calendar
    )
    #expect(upcoming.map(\.id) == [today.id, future.id])
    #expect(!upcoming.contains { $0.id == completedFuture.id })
    #expect(LiftStore.recentCompletedWorkouts(in: [old, recent, today], now: now, calendar: calendar).map(\.id) == [recent.id])
  }

  @Test func editingRoutineDuringActiveSessionDoesNotMutateWorkoutSnapshot() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let firstPlan = Self.plan(fixture.exercises[0].id, sets: "3")
    let secondPlan = Self.plan(fixture.exercises[1].id, sets: "4")
    let replacementPlan = Self.plan(fixture.exercises[2].id, sets: "5")
    let routine = fixture.store.createRoutine(
      name: "Snapshot", notes: "Before", trainingMode: .hypertrophy,
      plans: [firstPlan, secondPlan]
    )

    fixture.store.startRoutine(routine)
    let exerciseIDsAtStart = try #require(fixture.store.activeExerciseIDsOverride)
    let plansAtStart = fixture.store.activePlanOverrides
    var edited = routine
    edited.notes = "After"
    edited.exerciseIDs = [replacementPlan.exerciseID]
    edited.exercisePlans = [replacementPlan]
    fixture.store.updateRoutine(edited)

    #expect(fixture.store.activeExerciseIDsOverride == exerciseIDsAtStart)
    #expect(fixture.store.activeExerciseIDsOverride == [firstPlan.exerciseID, secondPlan.exerciseID])
    #expect(fixture.store.activePlanOverrides == plansAtStart)
    #expect(fixture.store.activePlanOverrides[firstPlan.exerciseID] == firstPlan)
    #expect(fixture.store.activePlanOverrides[secondPlan.exerciseID] == secondPlan)
    #expect(fixture.store.activeExercises.map(\.id) == exerciseIDsAtStart)
  }

  @Test func finishLinksExactlyEarliestSameDaySchedule() async throws {
    let fixture = try await Fixture.make()
    defer { fixture.remove() }
    let routine = fixture.store.createRoutine(name: "Link", notes: "", trainingMode: .strength)
    let later = fixture.store.scheduleWorkout(routineID: routine.id, at: Date().addingTimeInterval(60), note: "later")
    let earlier = fixture.store.scheduleWorkout(routineID: routine.id, at: Date(), note: "earlier")

    fixture.store.startRoutine(routine)
    let session = try #require(fixture.store.finishActiveSession())

    #expect(fixture.store.scheduledWorkouts.first { $0.id == earlier.id }?.completedSessionID == session.id)
    #expect(fixture.store.scheduledWorkouts.first { $0.id == later.id }?.completedSessionID == nil)
  }

  @Test func earliestResolvableUpcomingRoutineWinsSuggestion() {
    let first = LiftRoutine(id: UUID(), name: "First", notes: "", trainingMode: .strength, exerciseIDs: [], exercisePlans: [])
    let planned = LiftRoutine(id: UUID(), name: "Planned", notes: "", trainingMode: .strength, exerciseIDs: [], exercisePlans: [])
    let future = ScheduledWorkout(id: UUID(), routineID: planned.id, plannedAt: Date().addingTimeInterval(172_800), note: "", completedSessionID: nil)

    #expect(LiftStore.suggestedRoutine(routines: [first, planned], scheduledWorkouts: [future], sessions: [], on: Date())?.id == planned.id)
  }

  @Test func searchNormalizesAllFieldsPreservesOrderAndCaps() async throws {
    let ordered = (0..<75).map { index in
      LiftExercise(
        id: UUID(), name: index == 0 ? "Développé Press" : "Move \(index)",
        muscleGroup: index == 1 ? "Posterior Delts" : "Chest",
        equipment: index == 2 ? "Câble" : "Machine", instructions: ""
      )
    }

    #expect(LiftExerciseSearch.filter(exercises: ordered, query: "developpe").map(\.id) == [ordered[0].id])
    #expect(LiftExerciseSearch.filter(exercises: ordered, query: "posterior").map(\.id) == [ordered[1].id])
    #expect(LiftExerciseSearch.filter(exercises: ordered, query: "cable").map(\.id) == [ordered[2].id])
    #expect(LiftExerciseSearch.filter(exercises: ordered, query: "").map(\.id) == Array(ordered.prefix(60)).map(\.id))
    #expect(LiftExerciseSearch.filter(exercises: ordered, query: "", limit: 0).isEmpty)
    let debounced = try await LiftExerciseSearch.debouncedFilter(exercises: ordered, query: "move 7", delay: .zero)
    #expect(debounced.first?.id == ordered[7].id)
  }

  private static func plan(_ exerciseID: UUID, sets: String = "3") -> LiftRoutineExercisePlan {
    LiftRoutineExercisePlan(
      id: UUID(), exerciseID: exerciseID, sets: sets, reps: "8-12", rest: "90 s",
      targetEffort: "2 RIR", notes: ""
    )
  }

  private static func decodeEnvelope(at dataURL: URL) throws -> LiftDataEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LiftDataEnvelope.self, from: Data(contentsOf: dataURL))
  }

  private struct Fixture {
    let directory: URL
    let dataURL: URL
    let store: LiftStore
    let exercises: [LiftExercise]

    @MainActor
    static func make() async throws -> Fixture {
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LiftScheduleTests-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let dataURL = directory.appendingPathComponent("lift-data.json")
      let exercises = Array(LiftExerciseCatalog.catalogExercises().prefix(3))
      let envelope = LiftDataEnvelope(
        schemaVersion: 2, starterBankVersion: 1, userExercises: [], routines: [],
        scheduledWorkouts: [], sessions: [], activeSession: nil, restTimerEndDate: nil,
        workoutRestOverrideSeconds: nil, completedExerciseIDs: [], activeExerciseIDsOverride: nil,
        activePlanOverrides: [:], activeSupersetGroups: [:], settings: LiftSettings()
      )
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      encoder.outputFormatting = [.sortedKeys]
      try encoder.encode(envelope).write(to: dataURL, options: [.atomic])
      let store = LiftStore(dataURL: dataURL, saveDebounceInterval: 0)
      await store.loadAndWait()
      return Fixture(directory: directory, dataURL: dataURL, store: store, exercises: exercises)
    }

    func remove() {
      try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func reloadedStore() async -> LiftStore {
      let reloaded = LiftStore(dataURL: dataURL, saveDebounceInterval: 0)
      await reloaded.loadAndWait()
      return reloaded
    }
  }
}
