import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Reviewed Lift progression")
@MainActor
struct LiftProgressionApplicationTests {
  private let now = Date(timeIntervalSince1970: 1_792_584_000)

  @Test func generatingAReviewDoesNotWriteOrChangeWorkoutData() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let before = try Data(contentsOf: fixture.dataURL)
    let routine = try #require(fixture.store.routines.first)

    let review = fixture.store.progressionReview(for: routine, now: now)
    await fixture.store.waitForScheduledWrites()

    #expect(review.hasTargets)
    #expect(review.rows.first?.decision.target?.weightPounds == 105)
    #expect(fixture.store.activeSession == nil)
    #expect(try Data(contentsOf: fixture.dataURL) == before)
  }

  @Test func applyingTargetsChangesOnlyTheNewActiveSessionSnapshotAndSurvivesRelaunch() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let store = fixture.store
    let original = try LiftWorkoutLogicTests.decodeEnvelope(at: fixture.dataURL)
    let routine = try #require(store.routines.first)
    let exerciseID = try #require(routine.exerciseIDs.first)
    let review = store.progressionReview(for: routine, now: now)

    #expect(store.startRoutine(routine, progression: review, now: now))
    store.flushPendingSave()
    await store.waitForPendingSave()
    let saved = try LiftWorkoutLogicTests.decodeEnvelope(at: fixture.dataURL)

    #expect(try LiftWorkoutLogicTests.encode(saved.routines) == LiftWorkoutLogicTests.encode(original.routines))
    #expect(try LiftWorkoutLogicTests.encode(saved.sessions) == LiftWorkoutLogicTests.encode(original.sessions))
    #expect(try LiftWorkoutLogicTests.encode(saved.scheduledWorkouts) == LiftWorkoutLogicTests.encode(original.scheduledWorkouts))
    #expect(saved.activeSession?.routineID == routine.id)
    #expect(saved.activeSession?.sets.isEmpty == true)
    #expect(saved.activePlanOverrides[exerciseID]?.targetWeightPounds == 105)
    #expect(saved.activePlanOverrides[exerciseID]?.reps == "5")
    #expect(saved.activePlanOverrides[exerciseID]?.sets == "3")
    #expect(saved.activePlanOverrides[exerciseID]?.notes == original.routines[0].exercisePlans?[0].notes)

    let reloaded = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0)
    await reloaded.loadAndWait()
    #expect(reloaded.suggestedWeight(for: exerciseID) == 105)
    #expect(reloaded.suggestedReps(for: exerciseID) == 5)
    #expect(reloaded.setProgress(for: exerciseID).target == 3)
  }

  @Test func startingAsPlannedDoesNotApplyAnUnacceptedReview() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let routine = try #require(fixture.store.routines.first)
    let id = try #require(routine.exerciseIDs.first)
    _ = fixture.store.progressionReview(for: routine, now: now)

    #expect(fixture.store.startRoutine(routine, now: now))
    #expect(fixture.store.activePlan(for: id)?.targetWeightPounds == nil)
    #expect(fixture.store.activePlan(for: id)?.reps == "5-8")
    #expect(fixture.store.suggestedWeight(for: id) == 100)
  }

  @Test func warmupsDoNotReplaceApprovedTargetsButActualWorkingSetsDo() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let store = fixture.store
    let routine = try #require(store.routines.first)
    let exercise = try #require(store.exercise(for: routine.exerciseIDs[0]))
    #expect(store.startRoutine(routine, progression: store.progressionReview(for: routine, now: now), now: now))

    store.logSet(exercise: exercise, weight: 45, reps: 12, rpe: 6, isWarmup: true)
    #expect(store.suggestedWeight(for: exercise.id) == 105)
    #expect(store.suggestedReps(for: exercise.id) == 5)

    store.logSet(exercise: exercise, weight: 110, reps: 6, rpe: 8, isWarmup: false)
    #expect(store.suggestedWeight(for: exercise.id) == 110)
    #expect(store.suggestedReps(for: exercise.id) == 6)
  }

  @Test func activeWorkoutsCannotBeReplacedByAReviewedOrOrdinaryStart() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let store = fixture.store
    let routine = try #require(store.routines.first)
    let review = store.progressionReview(for: routine, now: now)
    #expect(store.startRoutine(nil, now: now))
    let active = store.activeSession

    #expect(!store.startRoutine(routine, progression: review, now: now))
    #expect(!store.startRoutine(routine, now: now))
    #expect(store.activeSession == active)
  }

  @Test func routineEditsInvalidateTheReviewedTargetsWithoutStarting() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let store = fixture.store
    var routine = try #require(store.routines.first)
    let review = store.progressionReview(for: routine, now: now)
    routine.exercisePlans?[0].reps = "3-5"
    store.updateRoutine(routine)

    #expect(!store.startRoutine(routine, progression: review, now: now))
    #expect(store.activeSession == nil)
    #expect(store.routines.first?.exercisePlans?.first?.reps == "3-5")
  }

  @Test func aNewCompletedSourceInvalidatesAnEarlierReview() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let store = fixture.store
    let routine = try #require(store.routines.first)
    let review = store.progressionReview(for: routine, now: now)
    #expect(store.startRoutine(routine, now: now))
    _ = store.finishActiveSession()

    #expect(!store.startRoutine(routine, progression: review, now: now))
    #expect(store.activeSession == nil)
    #expect(store.sessions.count == 2)
  }

  @Test func unitChangesRequireARefreshedReview() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let store = fixture.store
    let routine = try #require(store.routines.first)
    let review = store.progressionReview(for: routine, now: now)
    store.setWeightUnit(.kilograms)

    #expect(!store.startRoutine(routine, progression: review, now: now))
    #expect(store.activeSession == nil)
    let refreshed = store.progressionReview(for: routine, now: now)
    #expect(refreshed.unit == .kilograms)
    #expect(store.startRoutine(routine, progression: refreshed, now: now))
  }

  @Test func reviewsCannotBeReusedByADifferentStoreInstance() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let routine = try #require(fixture.store.routines.first)
    let review = fixture.store.progressionReview(for: routine, now: now)
    let replacement = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0)
    await replacement.loadAndWait()

    #expect(!replacement.startRoutine(routine, progression: review, now: now))
    #expect(replacement.activeSession == nil)
  }

  @Test func discardedCoordinatorsCannotApplyTheirOwnOldReview() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let store = fixture.store
    let routine = try #require(store.routines.first)
    let review = store.progressionReview(for: routine, now: now)
    store.cancelDatabasePersistence()

    #expect(!store.startRoutine(routine, progression: review, now: now))
    #expect(store.activeSession == nil)
  }

  @Test func anotherHostWorkoutBlocksApplyingTargets() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    var canStart = true
    let store = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0, canStart: { canStart })
    await store.loadAndWait()
    let routine = try #require(store.routines.first)
    let review = store.progressionReview(for: routine, now: now)
    canStart = false

    #expect(!store.startRoutine(routine, progression: review, now: now))
    #expect(store.activeSession == nil)
  }

  @Test func expiredReviewsCannotApplyEvenIfStoredHistoryHasNotChanged() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let routine = try #require(fixture.store.routines.first)
    let review = fixture.store.progressionReview(for: routine, now: now)

    #expect(!fixture.store.startRoutine(routine, progression: review, now: now.addingTimeInterval(901)))
    #expect(fixture.store.activeSession == nil)
  }

  @Test func oneSessionTargetsDoNotLeakIntoTheNextUnreviewedStart() async throws {
    let fixture = try await fixture()
    defer { fixture.remove() }
    let store = fixture.store
    let routine = try #require(store.routines.first)
    let id = try #require(routine.exerciseIDs.first)
    #expect(store.startRoutine(routine, progression: store.progressionReview(for: routine, now: now), now: now))
    store.discardActiveSession()

    #expect(store.startRoutine(routine, now: now))
    #expect(store.activePlan(for: id)?.targetWeightPounds == nil)
    #expect(store.suggestedWeight(for: id) == 100)
  }

  @Test func legacyPlansDecodeAndEncodeWithoutANewNilField() throws {
    let plan = LiftRoutineExercisePlan(
      id: UUID(), exerciseID: UUID(), sets: "3", reps: "5-8", rest: "90 s", targetEffort: "RPE 8", notes: ""
    )
    let data = try JSONEncoder().encode(plan)
    #expect(!String(decoding: data, as: UTF8.self).contains("targetWeightPounds"))
    let decoded = try JSONDecoder().decode(LiftRoutineExercisePlan.self, from: data)
    #expect(decoded.targetWeightPounds == nil)
    #expect(decoded == plan)
  }

  private func fixture() async throws -> LiftWorkoutLogicTests.StoreFixture {
    let exercise = LiftWorkoutLogicTests.exercise("Progression Test Press")
    let plan = LiftRoutineExercisePlan(
      id: UUID(), exerciseID: exercise.id, sets: "3", reps: "5-8", rest: "90 s", targetEffort: "RPE 8", notes: "Keep control."
    )
    let routine = LiftRoutine(
      id: UUID(), name: "Progression Test", notes: "Keep the saved plan.", trainingMode: .strength,
      exerciseIDs: [exercise.id], exercisePlans: [plan]
    )
    let start = now.addingTimeInterval(-86_400)
    let session = LiftSession(
      id: UUID(), routineID: routine.id, title: routine.name, startedAt: start,
      endedAt: start.addingTimeInterval(3_600),
      sets: (1...3).map { index in
        LiftSet(
          id: UUID(), exerciseID: exercise.id, setNumber: index, weight: 100, reps: 8, rpe: 8,
          isWarmup: false, completedAt: start.addingTimeInterval(Double(index * 180)), notes: "Original", effortRated: true
        )
      }
    )
    return try await LiftWorkoutLogicTests.fixture(exercises: [exercise], routines: [routine], sessions: [session])
  }
}
