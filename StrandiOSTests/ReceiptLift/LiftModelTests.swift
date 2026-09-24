import Foundation
import Testing
@testable import ReceiptLiftFeature

struct LiftModelTests {
  @Test func warmupsContributeToLiftedVolumeButNotWorkingSetCount() {
    let exerciseID = UUID()
    let warmup = makeSet(exerciseID: exerciseID, weight: 100, reps: 7, isWarmup: true)
    let working = makeSet(exerciseID: exerciseID, weight: 100, reps: 7, isWarmup: false)
    let session = LiftSession(
      id: UUID(),
      routineID: nil,
      title: "Lower A",
      startedAt: Date(),
      endedAt: Date(),
      sets: [warmup, working]
    )

    #expect(warmup.volume == 700)
    #expect(session.totalVolume == 1_400)
    #expect(session.workingSets.count == 1)
  }

  @Test func estimatedMaxIgnoresWarmupOnlySession() {
    let warmup = makeSet(weight: 315, reps: 1, isWarmup: true)
    let working = makeSet(weight: 135, reps: 8, isWarmup: false)
    let session = LiftSession(
      id: UUID(),
      routineID: nil,
      title: "Open Lift",
      startedAt: Date(),
      endedAt: Date(),
      sets: [warmup, working]
    )

    #expect(session.bestEstimatedOneRepMax == working.estimatedOneRepMax)
  }

  @Test func invalidPersistedLoadDoesNotCreateNegativeMetrics() {
    let negativeWeight = makeSet(weight: -50, reps: 8, isWarmup: false)
    let negativeReps = makeSet(weight: 50, reps: -8, isWarmup: false)

    #expect(negativeWeight.volume == 0)
    #expect(negativeWeight.estimatedOneRepMax == 0)
    #expect(negativeReps.volume == 0)
    #expect(negativeReps.estimatedOneRepMax == 0)
  }

  @Test func nonFinitePersistedLoadDoesNotPoisonMetrics() {
    let invalidSets = [
      makeSet(weight: .nan, reps: 8, isWarmup: false),
      makeSet(weight: .infinity, reps: 8, isWarmup: false),
      makeSet(weight: -.infinity, reps: 8, isWarmup: false),
      makeSet(weight: .greatestFiniteMagnitude, reps: Int.max, isWarmup: false)
    ]

    for set in invalidSets {
      #expect(set.volume == 0)
      #expect(set.volume.isFinite)
      #expect(set.estimatedOneRepMax == 0)
      #expect(set.estimatedOneRepMax.isFinite)
    }

    let session = LiftSession(
      id: UUID(), routineID: nil, title: "Recovered", startedAt: Date(), endedAt: Date(),
      sets: invalidSets
    )
    #expect(session.totalVolume == 0)
    #expect(session.totalVolume.isFinite)
    #expect(session.bestEstimatedOneRepMax == 0)
  }

  @Test func v2EnvelopeDefaultsFieldsAddedAfterTheInitialSchema() throws {
    let data = Data(
      """
      {
        "schemaVersion": 2,
        "userExercises": [],
        "routines": [],
        "sessions": [],
        "defaultRestSeconds": 135
      }
      """.utf8
    )

    let envelope = try JSONDecoder().decode(LiftDataEnvelope.self, from: data)

    #expect(envelope.schemaVersion == 2)
    #expect(envelope.starterBankVersion == 0)
    #expect(envelope.scheduledWorkouts.isEmpty)
    #expect(envelope.activeSession == nil)
    #expect(envelope.restTimerEndDate == nil)
    #expect(envelope.completedExerciseIDs.isEmpty)
    #expect(envelope.activeExerciseIDsOverride == nil)
    #expect(envelope.activePlanOverrides.isEmpty)
    #expect(envelope.activeSupersetGroups.isEmpty)
    #expect(envelope.settings.defaultRestSeconds == 135)
    #expect(envelope.settings.hapticsEnabled)
    #expect(envelope.settings.exportPaperStyle == .white)
  }

  @Test func routineRestParserHandlesRangesAndMinutes() {
    #expect(LiftStore.restSeconds(from: "75-90 s") == 90)
    #expect(LiftStore.restSeconds(from: "2-3 min") == 180)
    #expect(LiftStore.restSeconds(from: "as needed") == nil)
  }

  @Test func exerciseSearchCacheTracksSearchableFieldEdits() {
    let id = UUID()
    var exercise = LiftExercise(
      id: id,
      name: "Incline Press",
      muscleGroup: "Chest",
      equipment: "Dumbbells",
      instructions: "Test"
    )

    #expect(LiftExerciseSearch.filter(exercises: [exercise], query: "chest") == [exercise])
    #expect(LiftExerciseSearch.filter(exercises: [exercise], query: "incline") == [exercise])

    exercise.name = "Supported Row"
    exercise.muscleGroup = "Back"
    #expect(LiftExerciseSearch.filter(exercises: [exercise], query: "incline").isEmpty)
    #expect(LiftExerciseSearch.filter(exercises: [exercise], query: "back") == [exercise])
  }

  @Test func catalogNormalizationIsStableAcrossPunctuationAndCase() {
    #expect(LiftExerciseCatalog.normalizedName("Chest-Supported ROW") == "chest supported row")
    #expect(LiftExerciseCatalog.catalogExercises() == LiftExerciseCatalog.catalogExercises())
  }

  @Test func liveActivityStateClampsVisibleProgress() {
    let state = LiftLiveActivityAttributes.ContentState(
      currentMove: "Leg Press",
      completedSets: 9,
      targetSets: 8,
      volume: 6_780,
      restTimerEndDate: nil,
      updatedAt: Date()
    )

    #expect(state.setProgressLabel == "8/8")
    #expect(state.isResting == false)
    #expect(state.restStaleDate == nil)
  }

  @Test func liveActivityRestStateExpiresAtItsEndDate() {
    let updatedAt = Date(timeIntervalSinceReferenceDate: 10_000)
    let endDate = updatedAt.addingTimeInterval(90)
    let active = LiftLiveActivityAttributes.ContentState(
      currentMove: "Leg Press",
      completedSets: 2,
      targetSets: 8,
      volume: 2_400,
      restTimerEndDate: endDate,
      updatedAt: updatedAt
    )
    let expired = LiftLiveActivityAttributes.ContentState(
      currentMove: "Leg Press",
      completedSets: 2,
      targetSets: 8,
      volume: 2_400,
      restTimerEndDate: updatedAt,
      updatedAt: updatedAt
    )

    #expect(active.isResting)
    #expect(active.restStaleDate == endDate)
    #expect(!expired.isResting)
    #expect(expired.restStaleDate == nil)
  }

  @Test func miniRestPresentationDropsAlreadyExpiredTimers() {
    let now = Date(timeIntervalSinceReferenceDate: 20_000)

    #expect(!liftMiniRestShouldDiscardExpired(endDate: nil, now: now))
    #expect(!liftMiniRestShouldDiscardExpired(endDate: now.addingTimeInterval(1), now: now))
    #expect(liftMiniRestShouldDiscardExpired(endDate: now, now: now))
    #expect(liftMiniRestShouldDiscardExpired(endDate: now.addingTimeInterval(-1), now: now))
  }

  @Test func exerciseProgressSnapshotExcludesFutureDatedSetsFromEveryOutput() {
    let now = Date(timeIntervalSinceReferenceDate: 30_000)
    let exerciseID = UUID()
    let baseline = makeSet(
      exerciseID: exerciseID,
      weight: 100,
      reps: 5,
      isWarmup: false,
      completedAt: now.addingTimeInterval(-600)
    )
    let future = makeSet(
      exerciseID: exerciseID,
      weight: 500,
      reps: 20,
      isWarmup: false,
      completedAt: now.addingTimeInterval(3_600)
    )
    let session = LiftSession(
      id: UUID(),
      routineID: nil,
      title: "Recovered History",
      startedAt: now.addingTimeInterval(-1_800),
      endedAt: now.addingTimeInterval(-300),
      sets: [baseline, future]
    )

    let snapshot = LiftProgressMath.exerciseProgressSnapshot(
      sessions: [session],
      exerciseID: exerciseID,
      now: now,
      calendar: Calendar(identifier: .gregorian)
    )

    #expect(snapshot.recentSets.map(\.set.id) == [baseline.id])
    #expect(snapshot.bestSet?.id == baseline.id)
    #expect(snapshot.points.count == 1)
    #expect(snapshot.points.first?.volume == baseline.volume)
    #expect(snapshot.historicalPersonalRecords[future.id] == nil)
    #expect(snapshot.latestPersonalRecord == nil)
  }

  private func makeSet(
    id: UUID = UUID(),
    exerciseID: UUID = UUID(),
    weight: Double,
    reps: Int,
    isWarmup: Bool,
    completedAt: Date = Date()
  ) -> LiftSet {
    LiftSet(
      id: id,
      exerciseID: exerciseID,
      setNumber: 1,
      weight: weight,
      reps: reps,
      rpe: 8,
      isWarmup: isWarmup,
      completedAt: completedAt,
      notes: ""
    )
  }
}
