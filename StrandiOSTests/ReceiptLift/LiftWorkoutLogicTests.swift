import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Workout workspace logic")
@MainActor
struct LiftWorkoutLogicTests {
  @Test func activeProgressIgnoresSavedHistoryAndWarmups() async throws {
    let exercise = Self.exercise("Session Press")
    let plan = Self.plan(exercise.id, sets: "3", rest: "90 s")
    let saved = LiftSession(
      id: UUID(), routineID: nil, title: "Saved", startedAt: .distantPast,
      endedAt: .distantPast,
      sets: [
        Self.set(exercise.id, number: 1),
        Self.set(exercise.id, number: 2)
      ]
    )
    let active = LiftSession(
      id: UUID(), routineID: nil, title: "Active", startedAt: Date(), endedAt: nil,
      sets: [Self.set(exercise.id, number: 1, isWarmup: true)]
    )
    let fixture = try await Self.fixture(
      exercises: [exercise],
      sessions: [saved],
      activeSession: active,
      activeIDs: [exercise.id],
      activePlans: [exercise.id: plan]
    )
    defer { fixture.remove() }

    let progress = fixture.store.setProgress(for: exercise.id)

    #expect(progress.completed == 0)
    #expect(progress.target == 3)
  }

  @Test func routineStartSnapshotsOrderPlansAndMissingPlansAcrossRelaunch() async throws {
    let first = Self.exercise("First")
    let second = Self.exercise("Second")
    let startingPlan = Self.plan(first.id, sets: "3", rest: "90 s")
    let routine = LiftRoutine(
      id: UUID(), name: "Snapshot", notes: "", trainingMode: .hypertrophy,
      exerciseIDs: [first.id, second.id], exercisePlans: [startingPlan]
    )
    let fixture = try await Self.fixture(exercises: [first, second], routines: [routine])
    defer { fixture.remove() }

    fixture.store.startRoutine(routine)
    fixture.store.flushPendingSave()
    var envelope = try Self.decodeEnvelope(at: fixture.dataURL)
    let editedFirst = Self.plan(first.id, sets: "8", rest: "15 s")
    let laterSecond = Self.plan(second.id, sets: "5", rest: "180 s")
    envelope.routines[0].exerciseIDs = [second.id, first.id]
    envelope.routines[0].exercisePlans = [editedFirst, laterSecond]
    try Self.encode(envelope).write(to: fixture.dataURL, options: [.atomic])

    let reloaded = LiftStore(dataURL: fixture.dataURL, saveDebounceInterval: 0)
    await reloaded.loadAndWait()

    #expect(reloaded.activeExerciseIDsOverride == [first.id, second.id])
    #expect(reloaded.activeExercises.map(\.id) == [first.id, second.id])
    #expect(reloaded.activePlan(for: first.id) == startingPlan)
    #expect(reloaded.activePlan(for: second.id) == nil)
  }

  @Test func openLiftUsesAnExplicitEmptyQueue() async throws {
    let exercise = Self.exercise("Catalog Move")
    let fixture = try await Self.fixture(exercises: [exercise])
    defer { fixture.remove() }

    fixture.store.startRoutine(nil)

    #expect(fixture.store.activeSession?.title == "Open Lift")
    #expect(fixture.store.activeExerciseIDsOverride == [])
    #expect(fixture.store.activeExercises.isEmpty)
  }

  @Test func addingActiveExercisesIsUniqueAndKeepsInsertionOrder() async throws {
    let first = Self.exercise("First")
    let second = Self.exercise("Second")
    let fixture = try await Self.fixture(exercises: [first, second])
    defer { fixture.remove() }
    fixture.store.startRoutine(nil)

    fixture.store.addActiveExercise(first.id)
    fixture.store.addActiveExercise(first.id)
    fixture.store.addActiveExercise(second.id)

    #expect(fixture.store.activeExerciseIDsOverride == [first.id, second.id])
    #expect(fixture.store.activeExercises.map(\.id) == [first.id, second.id])
  }

  @Test func estimatedMinutesReturnsZeroForEmptyOrAllInvalidPlans() {
    let exerciseID = UUID()
    let invalidPlans = [
      Self.plan(exerciseID, sets: "0", rest: "90 s"),
      Self.plan(exerciseID, sets: "none", rest: "as needed")
    ]

    #expect(LiftStore.estimatedMinutes(plans: [], defaultRestSeconds: 90) == 0)
    #expect(LiftStore.estimatedMinutes(plans: invalidPlans, defaultRestSeconds: 90) == 0)
  }

  @Test func estimatedMinutesAppliesMinimumAndNearestFiveRounding() {
    let exerciseID = UUID()
    let short = [Self.plan(exerciseID, sets: "1", rest: "0 s")]
    let exactTen = [Self.plan(exerciseID, sets: "4", rest: "105 s")]
    let halfStep = [Self.plan(exerciseID, sets: "5", rest: "105 s")]

    #expect(LiftStore.estimatedMinutes(plans: short, defaultRestSeconds: 90) == 5)
    #expect(LiftStore.estimatedMinutes(plans: exactTen, defaultRestSeconds: 90) == 10)
    #expect(LiftStore.estimatedMinutes(plans: halfStep, defaultRestSeconds: 90) == 15)
  }

  @Test func estimatedMinutesUsesExistingPlanParsersAndDefaultRestDeterministically() {
    let firstID = UUID()
    let secondID = UUID()
    let parsed = Self.plan(firstID, sets: "3–4 sets", rest: "1.5 min")
    let fallback = Self.plan(secondID, sets: "2 sets", rest: "as needed")
    let plans = [parsed, fallback]

    let forward = LiftStore.estimatedMinutes(plans: plans, defaultRestSeconds: 75)
    let reversed = LiftStore.estimatedMinutes(plans: Array(plans.reversed()), defaultRestSeconds: 75)

    #expect(forward == 15)
    #expect(reversed == forward)
  }

  @Test func routineEstimateUsesPlansAndStoreDefaultRest() async throws {
    let exercise = Self.exercise("Estimate")
    let plan = Self.plan(exercise.id, sets: "4", rest: "as needed")
    let routine = LiftRoutine(
      id: UUID(), name: "Estimate", notes: "", trainingMode: .hypertrophy,
      exerciseIDs: [exercise.id], exercisePlans: [plan]
    )
    let fixture = try await Self.fixture(
      exercises: [exercise], routines: [routine],
      settings: LiftSettings(defaultRestSeconds: 105)
    )
    defer { fixture.remove() }

    #expect(fixture.store.estimatedMinutes(for: routine) == 10)
  }

  @Test func logSetWithoutSessionReturnsNilAndMutatesNothing() async throws {
    let exercise = Self.exercise("No Session")
    let fixture = try await Self.fixture(exercises: [exercise])
    defer { fixture.remove() }
    let beforeData = try Data(contentsOf: fixture.dataURL)
    let beforeStatus = fixture.store.status
    let beforeSessions = fixture.store.sessions
    let beforeRestEnd = fixture.store.restTimerEndDate

    let outcome = fixture.store.logSet(
      exercise: exercise, weight: 100, reps: 8, rpe: 8, isWarmup: false
    )
    await fixture.store.waitForScheduledWrites()

    #expect(outcome == nil)
    #expect(fixture.store.activeSession == nil)
    #expect(fixture.store.sessions == beforeSessions)
    #expect(fixture.store.restTimerEndDate == beforeRestEnd)
    #expect(fixture.store.status == beforeStatus)
    #expect(try Data(contentsOf: fixture.dataURL) == beforeData)
  }

  @Test func successfulLogReturnsTheExactAppendedSetAndPreservesOutcomeFields() async throws {
    let exercise = Self.exercise("Outcome")
    let active = LiftSession(
      id: UUID(), routineID: nil, title: "Active", startedAt: Date(), endedAt: nil, sets: []
    )
    let fixture = try await Self.fixture(
      exercises: [exercise], activeSession: active, activeIDs: [exercise.id]
    )
    defer { fixture.remove() }

    let outcome = fixture.store.logSet(
      exercise: exercise, weight: 135, reps: 5, rpe: 9, isWarmup: false, restSeconds: 0
    )
    let appended = fixture.store.activeSession?.sets.last

    #expect(outcome?.set == appended)
    #expect(outcome?.set.exerciseID == exercise.id)
    #expect(outcome?.set.weight == 135)
    #expect(outcome?.set.reps == 5)
    #expect(outcome?.personalRecord == nil)
    #expect(fixture.store.activeSession?.sets.count == 1)
  }

  @Test func loggingDuringActiveRestRestartsCountdownForTheNewSet() async throws {
    let exercise = Self.exercise("Rest Continuity")
    let active = LiftSession(
      id: UUID(), routineID: nil, title: "Active", startedAt: Date(), endedAt: nil, sets: []
    )
    let fixture = try await Self.fixture(
      exercises: [exercise],
      activeSession: active,
      restTimerEndDate: Date().addingTimeInterval(120),
      activeIDs: [exercise.id]
    )
    defer { fixture.remove() }
    let existingEndDate = try #require(fixture.store.restTimerEndDate)
    let loggedAt = Date()

    let outcome = fixture.store.logSet(
      exercise: exercise,
      weight: 100,
      reps: 8,
      rpe: 8,
      isWarmup: false,
      restSeconds: 300
    )

    #expect(outcome != nil)
    let restartedEndDate = try #require(fixture.store.restTimerEndDate)
    #expect(restartedEndDate > existingEndDate)
    #expect(restartedEndDate.timeIntervalSince(loggedAt) >= 299)
    #expect(restartedEndDate.timeIntervalSince(loggedAt) <= 301)
  }

  @Test func nextUnfinishedUsesActiveOrderAndWrapsOnce() async throws {
    let first = Self.exercise("First")
    let second = Self.exercise("Second")
    let third = Self.exercise("Third")
    let active = LiftSession(
      id: UUID(), routineID: nil, title: "Active", startedAt: Date(), endedAt: nil, sets: []
    )
    let fixture = try await Self.fixture(
      exercises: [first, second, third], activeSession: active,
      completedExerciseIDs: [second.id, third.id],
      activeIDs: [first.id, second.id, third.id]
    )
    defer { fixture.remove() }

    #expect(fixture.store.nextUnfinishedExerciseID(after: nil) == first.id)
    #expect(fixture.store.nextUnfinishedExerciseID(after: third.id) == first.id)
  }

  @Test func nextUnfinishedSkipsExplicitDoneAndTargetCompleteExercises() async throws {
    let first = Self.exercise("First")
    let complete = Self.exercise("Complete")
    let done = Self.exercise("Done")
    let next = Self.exercise("Next")
    let active = LiftSession(
      id: UUID(), routineID: nil, title: "Active", startedAt: Date(), endedAt: nil,
      sets: [Self.set(complete.id, number: 1)]
    )
    let plans = [first, complete, done, next].reduce(into: [UUID: LiftRoutineExercisePlan]()) {
      $0[$1.id] = Self.plan($1.id, sets: "1", rest: "90 s")
    }
    let fixture = try await Self.fixture(
      exercises: [first, complete, done, next], activeSession: active,
      completedExerciseIDs: [done.id],
      activeIDs: [first.id, complete.id, done.id, next.id], activePlans: plans
    )
    defer { fixture.remove() }

    #expect(fixture.store.nextUnfinishedExerciseID(after: first.id) == next.id)
  }

  @Test func warmupsDoNotCompleteTargetsAndEmptyQueuesReturnNil() async throws {
    let first = Self.exercise("First")
    let warmup = Self.exercise("Warmup")
    let active = LiftSession(
      id: UUID(), routineID: nil, title: "Active", startedAt: Date(), endedAt: nil,
      sets: [Self.set(warmup.id, number: 1, isWarmup: true)]
    )
    let fixture = try await Self.fixture(
      exercises: [first, warmup], activeSession: active,
      activeIDs: [first.id, warmup.id],
      activePlans: [warmup.id: Self.plan(warmup.id, sets: "1", rest: "90 s")]
    )
    defer { fixture.remove() }

    #expect(fixture.store.nextUnfinishedExerciseID(after: first.id) == warmup.id)

    let empty = try await Self.fixture(
      exercises: [first],
      activeSession: LiftSession(
        id: UUID(), routineID: nil, title: "Open Lift", startedAt: Date(), endedAt: nil, sets: []
      ),
      activeIDs: []
    )
    defer { empty.remove() }
    #expect(empty.store.nextUnfinishedExerciseID(after: nil) == nil)
  }

  @Test func workoutStampFormatsLoadedAndBodyweightSetsWithoutPRClaims() {
    let loaded = Self.exercise("Loaded", equipment: "Barbell")
    let bodyweight = Self.exercise("Pull-Up", equipment: "Bodyweight")

    #expect(
      liftWorkoutStampText(set: Self.set(loaded.id, number: 1, weight: 60), exercise: loaded)
        == "60 LB × 8 ADDED TO RECEIPT"
    )
    #expect(
      liftWorkoutStampText(set: Self.set(bodyweight.id, number: 1, weight: 0), exercise: bodyweight)
        == "BW × 8 ADDED TO RECEIPT"
    )
  }

  @Test func nextSetRestKeepsOverridePlanDefaultPrecedence() async throws {
    let exercise = Self.exercise("Rest")
    let active = LiftSession(
      id: UUID(), routineID: nil, title: "Active", startedAt: Date(), endedAt: nil, sets: []
    )
    let fixture = try await Self.fixture(
      exercises: [exercise], activeSession: active, activeIDs: [exercise.id],
      activePlans: [exercise.id: Self.plan(exercise.id, sets: "3", rest: "2 min")],
      settings: LiftSettings(defaultRestSeconds: 95)
    )
    defer { fixture.remove() }

    #expect(fixture.store.restSecondsForNextSet(for: exercise.id) == 120)
    fixture.store.setWorkoutRestOverride(seconds: 45)
    #expect(fixture.store.restSecondsForNextSet(for: exercise.id) == 45)
    fixture.store.setWorkoutRestOverride(seconds: nil)

    let noPlan = Self.exercise("No Plan")
    #expect(fixture.store.restSecondsForNextSet(for: noPlan.id) == 95)
  }

  @Test func queueRowProjectionEqualityCoversAllSixFields() {
    let exercise = Self.exercise("Machine Chest Press")
    let alternateExercise = Self.exercise("Pull-Up", equipment: "Bodyweight")
    let row = LiftWorkoutQueueRowState(
      id: exercise.id,
      ordinal: 2,
      exercise: exercise,
      progressLabel: "1/3",
      isDone: false,
      supersetLabel: "Superset 1"
    )

    #expect(
      Mirror(reflecting: row).children.compactMap(\.label)
        == ["id", "ordinal", "exercise", "progressLabel", "isDone", "supersetLabel"]
    )
    #expect(
      row == LiftWorkoutQueueRowState(
        id: row.id, ordinal: row.ordinal, exercise: row.exercise,
        progressLabel: row.progressLabel, isDone: row.isDone,
        supersetLabel: row.supersetLabel
      )
    )
    #expect(
      row != LiftWorkoutQueueRowState(
        id: UUID(), ordinal: row.ordinal, exercise: row.exercise,
        progressLabel: row.progressLabel, isDone: row.isDone,
        supersetLabel: row.supersetLabel
      )
    )
    #expect(
      row != LiftWorkoutQueueRowState(
        id: row.id, ordinal: 3, exercise: row.exercise,
        progressLabel: row.progressLabel, isDone: row.isDone,
        supersetLabel: row.supersetLabel
      )
    )
    #expect(
      row != LiftWorkoutQueueRowState(
        id: row.id, ordinal: row.ordinal, exercise: alternateExercise,
        progressLabel: row.progressLabel, isDone: row.isDone,
        supersetLabel: row.supersetLabel
      )
    )
    #expect(
      row != LiftWorkoutQueueRowState(
        id: row.id, ordinal: row.ordinal, exercise: row.exercise,
        progressLabel: "2/3", isDone: row.isDone,
        supersetLabel: row.supersetLabel
      )
    )
    #expect(
      row != LiftWorkoutQueueRowState(
        id: row.id, ordinal: row.ordinal, exercise: row.exercise,
        progressLabel: row.progressLabel, isDone: true,
        supersetLabel: row.supersetLabel
      )
    )
    #expect(
      row != LiftWorkoutQueueRowState(
        id: row.id, ordinal: row.ordinal, exercise: row.exercise,
        progressLabel: row.progressLabel, isDone: row.isDone,
        supersetLabel: nil
      )
    )
  }

  @Test func queueAccessibilityTextDistinguishesUpNextAndPrinted() {
    let exercise = Self.exercise("Pull-Up", equipment: "Bodyweight")
    let row = LiftWorkoutQueueRowState(
      id: exercise.id,
      ordinal: 2,
      exercise: exercise,
      progressLabel: "1/3",
      isDone: false,
      supersetLabel: "Superset 1"
    )

    #expect(
      liftWorkoutQueueAccessibilityLabel(row: row, isPrinted: false)
        == "Exercise 2, Pull-Up, 1 of 3 sets, up next, Superset 1"
    )
    #expect(
      liftWorkoutQueueAccessibilityLabel(row: row, isPrinted: true)
        == "Exercise 2, Pull-Up, 1 of 3 sets, printed, Superset 1"
    )
  }

  @Test func composerAccessibilitySummaryFormatsLoadedAndBodyweightSets() {
    let loaded = Self.exercise("Loaded")
    let bodyweight = Self.exercise("Pull-Up", equipment: "Bodyweight")

    #expect(
      liftWorkoutComposerAccessibilitySummary(
        weight: 60,
        reps: 8,
        progress: LiftSetProgress(completed: 1, target: 3),
        exercise: loaded
      ) == "60 pounds, 8 reps, set 2 of 3"
    )
    #expect(
      liftWorkoutComposerAccessibilitySummary(
        weight: 0,
        reps: 8,
        progress: LiftSetProgress(completed: 1, target: nil),
        exercise: bodyweight
      ) == "Bodyweight, 8 reps, set 2"
    )
  }

  @Test func miniRestSnapshotClampsAtZeroAndRoundsVisibleSecondsUp() {
    let now = Date(timeIntervalSinceReferenceDate: 1_000)
    let endDate = now.addingTimeInterval(90)

    #expect(
      LiftMiniRestSnapshot(endDate: endDate, now: now)
        == LiftMiniRestSnapshot(endDate: endDate, remainingSeconds: 90)
    )
    #expect(
      LiftMiniRestSnapshot(endDate: endDate, now: now.addingTimeInterval(89.01))
        == LiftMiniRestSnapshot(endDate: endDate, remainingSeconds: 1)
    )
    #expect(
      LiftMiniRestSnapshot(endDate: endDate, now: endDate)
        == LiftMiniRestSnapshot(endDate: endDate, remainingSeconds: 0)
    )
    #expect(
      LiftMiniRestSnapshot(endDate: endDate, now: endDate.addingTimeInterval(5))
        == LiftMiniRestSnapshot(endDate: endDate, remainingSeconds: 0)
    )
    #expect(
      LiftMiniRestSnapshot(endDate: nil, now: now)
        == LiftMiniRestSnapshot(endDate: nil, remainingSeconds: 0)
    )
  }

  @Test func miniRestCompletionGateEmitsOnlyForOnePositiveToZeroTransitionPerEndDate() {
    let firstEndDate = Date(timeIntervalSinceReferenceDate: 2_000)
    let secondEndDate = firstEndDate.addingTimeInterval(90)

    #expect(
      liftMiniRestShouldEmitCompletion(
        endDate: firstEndDate,
        previousRemainingSeconds: 1,
        remainingSeconds: 0,
        emittedEndDate: nil
      )
    )
    #expect(
      !liftMiniRestShouldEmitCompletion(
        endDate: firstEndDate,
        previousRemainingSeconds: 0,
        remainingSeconds: 0,
        emittedEndDate: nil
      )
    )
    #expect(
      !liftMiniRestShouldEmitCompletion(
        endDate: nil,
        previousRemainingSeconds: 1,
        remainingSeconds: 0,
        emittedEndDate: nil
      )
    )
    #expect(
      !liftMiniRestShouldEmitCompletion(
        endDate: firstEndDate,
        previousRemainingSeconds: 1,
        remainingSeconds: 0,
        emittedEndDate: firstEndDate
      )
    )
    #expect(
      liftMiniRestShouldEmitCompletion(
        endDate: secondEndDate,
        previousRemainingSeconds: 1,
        remainingSeconds: 0,
        emittedEndDate: firstEndDate
      )
    )
  }
}

private extension LiftWorkoutLogicTests {
  struct StoreFixture {
    let directory: URL
    let dataURL: URL
    let store: LiftStore

    func remove() {
      try? FileManager.default.removeItem(at: directory)
    }
  }

  static func fixture(
    exercises: [LiftExercise],
    routines: [LiftRoutine] = [],
    sessions: [LiftSession] = [],
    activeSession: LiftSession? = nil,
    restTimerEndDate: Date? = nil,
    workoutRestOverrideSeconds: TimeInterval? = nil,
    completedExerciseIDs: Set<UUID> = [],
    activeIDs: [UUID]? = nil,
    activePlans: [UUID: LiftRoutineExercisePlan] = [:],
    settings: LiftSettings = LiftSettings()
  ) async throws -> StoreFixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("LiftWorkoutLogicTests-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let dataURL = directory.appendingPathComponent("lift-data.json")
    let envelope = LiftDataEnvelope(
      schemaVersion: LiftDataEnvelope.currentSchemaVersion,
      starterBankVersion: LiftDataEnvelope.currentStarterBankVersion,
      userExercises: exercises,
      routines: routines,
      scheduledWorkouts: [],
      sessions: sessions,
      activeSession: activeSession,
      restTimerEndDate: restTimerEndDate,
      workoutRestOverrideSeconds: workoutRestOverrideSeconds,
      completedExerciseIDs: completedExerciseIDs,
      activeExerciseIDsOverride: activeIDs,
      activePlanOverrides: activePlans,
      activeSupersetGroups: [:],
      settings: settings
    )
    try encode(envelope).write(to: dataURL, options: [.atomic])
    let store = LiftStore(dataURL: dataURL, saveDebounceInterval: 0)
    await store.loadAndWait()
    return StoreFixture(directory: directory, dataURL: dataURL, store: store)
  }

  static func exercise(_ name: String, equipment: String = "Barbell") -> LiftExercise {
    LiftExercise(
      id: UUID(), name: name, muscleGroup: "Test", equipment: equipment,
      instructions: "Test"
    )
  }

  static func plan(
    _ exerciseID: UUID,
    sets: String,
    rest: String,
    reps: String = "8"
  ) -> LiftRoutineExercisePlan {
    LiftRoutineExercisePlan(
      id: UUID(), exerciseID: exerciseID, sets: sets, reps: reps, rest: rest,
      targetEffort: "RPE 8", notes: ""
    )
  }

  static func set(
    _ exerciseID: UUID,
    number: Int,
    weight: Double = 100,
    reps: Int = 8,
    isWarmup: Bool = false
  ) -> LiftSet {
    LiftSet(
      id: UUID(), exerciseID: exerciseID, setNumber: number, weight: weight, reps: reps,
      rpe: 8, isWarmup: isWarmup, completedAt: Date(), notes: ""
    )
  }

  static func encode<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }

  static func decodeEnvelope(at url: URL) throws -> LiftDataEnvelope {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(LiftDataEnvelope.self, from: Data(contentsOf: url))
  }
}
