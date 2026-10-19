import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Post-session summary logic")
struct LiftSessionSummaryLogicTests {
  private let enUS = Locale(identifier: "en_US")
  private let start = Date(timeIntervalSince1970: 1_780_000_000)

  private func set(_ exerciseID: UUID, rpe: Double, rated: Bool?, warmup: Bool = false, weight: Double = 100, reps: Int = 8) -> LiftSet {
    LiftSet(
      id: UUID(), exerciseID: exerciseID, setNumber: 1, weight: weight, reps: reps, rpe: rpe, isWarmup: warmup,
      completedAt: start, notes: "", effortRated: rated)
  }

  private func session(_ sets: [LiftSet]) -> LiftSession {
    LiftSession(id: UUID(), routineID: nil, title: "Push day", startedAt: start, endedAt: start.addingTimeInterval(3_000), sets: sets)
  }

  private func snapshot(_ state: LiftStrainSummaryState) -> LiftStrainSnapshot {
    LiftStrainSnapshot(
      state: state, heartRateDisplay: 6.4, combinedDisplay: 11.6, workingSets: 18, warmupSets: 3, countedSets: 18,
      bodyweightIsDefault: false)
  }

  // MARK: Effort

  @Test func onlyRatedWorkingSetsCount() {
    let id = UUID()
    let lift = session([
      set(id, rpe: 8, rated: true), set(id, rpe: 9, rated: true), set(id, rpe: 8, rated: nil),
      set(id, rpe: 8, rated: false), set(id, rpe: 6, rated: true, warmup: true),
    ])
    let efforts = LiftSessionSummaryLogic.ratedWorkingEfforts(lift)
    #expect(efforts == [8, 9])
    #expect(LiftSessionSummaryLogic.averageEffort(efforts) == 8.5)
    let range = LiftSessionSummaryLogic.rpeRange(efforts)
    #expect(range?.low == 8 && range?.high == 9)
  }

  @Test func nothingRatedMeansNoEffortAtAll() {
    let id = UUID()
    let lift = session([set(id, rpe: 8, rated: nil), set(id, rpe: 8, rated: false)])
    let efforts = LiftSessionSummaryLogic.ratedWorkingEfforts(lift)
    #expect(efforts.isEmpty)
    #expect(LiftSessionSummaryLogic.averageEffort(efforts) == nil)
    #expect(LiftSessionSummaryLogic.rpeRange(efforts) == nil)
  }

  // MARK: Lede

  @Test func ledeWithARange() {
    let text = LiftSessionSummaryLogic.lede(
      heartRate: 6.4, combined: 11.6, workingSets: 18, rpeRange: (8, 9), locale: enUS)
    #expect(text.contains("**6.4**"))
    #expect(text.contains("**11.6**"))
    #expect(text.contains("RPE 8–9"))
    #expect(text.contains("18 working sets"))
  }

  @Test func ledeWithOneEffort() {
    let text = LiftSessionSummaryLogic.lede(
      heartRate: 6.4, combined: 11.6, workingSets: 18, rpeRange: (8, 8), locale: enUS)
    #expect(text.contains("at RPE 8 "))
    #expect(!text.contains("8–8"))
  }

  @Test func ledeWithoutRatedSetsDropsTheRPEClause() {
    let text = LiftSessionSummaryLogic.lede(
      heartRate: 6.4, combined: 11.6, workingSets: 18, rpeRange: nil, locale: enUS)
    #expect(!text.contains("RPE"))
    #expect(text.contains("bring it to"))
  }

  @Test func defaultBodyweightNoteNamesTheWeight() {
    #expect(LiftSessionSummaryLogic.defaultBodyweightNote().contains("75"))
  }

  // MARK: Strain state

  @Test func missingSnapshotScoresThenGivesUp() {
    #expect(LiftSummaryStrainState.resolve(snapshot: nil, elapsed: 1, timeout: 20) == .scoring)
    #expect(LiftSummaryStrainState.resolve(snapshot: nil, elapsed: 20, timeout: 20) == .unavailable)
  }

  @Test func pendingScoresThenWaits() {
    let pending = snapshot(.pending)
    #expect(LiftSummaryStrainState.resolve(snapshot: pending, elapsed: 5, timeout: 20) == .scoring)
    #expect(LiftSummaryStrainState.resolve(snapshot: pending, elapsed: 21, timeout: 20) == .waiting)
  }

  @Test func scoredNotScoredAndNoSetsResolveAtOnce() {
    let scored = snapshot(.scored)
    #expect(LiftSummaryStrainState.resolve(snapshot: scored, elapsed: 0, timeout: 20) == .scored(scored))
    #expect(LiftSummaryStrainState.resolve(snapshot: snapshot(.notScored), elapsed: 0, timeout: 20) == .notScoredYet)
    #expect(LiftSummaryStrainState.resolve(snapshot: snapshot(.noSets), elapsed: 0, timeout: 20) == .noSets(heartRateDisplay: 6.4))
  }

  @Test func waitingAndNotScoredSwapToScoredWhenHeartDataArrives() {
    let waiting = LiftSummaryStrainState.resolve(snapshot: snapshot(.pending), elapsed: 30, timeout: 20)
    #expect(waiting == .waiting)
    let later = LiftSummaryStrainState.resolve(snapshot: snapshot(.scored), elapsed: 31, timeout: 20)
    #expect(later == .scored(snapshot(.scored)))
    let notScored = LiftSummaryStrainState.resolve(snapshot: snapshot(.notScored), elapsed: 1, timeout: 20)
    #expect(notScored == .notScoredYet)
    #expect(LiftSummaryStrainState.resolve(snapshot: snapshot(.scored), elapsed: 2, timeout: 20) == .scored(snapshot(.scored)))
  }

  @Test func defaultTimeoutIsTwentySeconds() {
    #expect(LiftSummaryStrainState.defaultTimeout == 20)
  }

  // MARK: What you lifted

  @Test func bestSetPerExerciseWithRecordsAndReps() {
    let bench = LiftExercise(id: UUID(), name: "Bench press", muscleGroup: "chest", equipment: "barbell", instructions: "")
    let pushUp = LiftExercise(id: UUID(), name: "push-up", muscleGroup: "chest", equipment: "body weight", instructions: "")
    let light = set(bench.id, rpe: 8, rated: true, weight: 135, reps: 8)
    let heavy = set(bench.id, rpe: 9, rated: true, weight: 185, reps: 8)
    let warmup = set(bench.id, rpe: 6, rated: true, warmup: true, weight: 95, reps: 10)
    let pushUps = [set(pushUp.id, rpe: 8, rated: true, weight: 0, reps: 15), set(pushUp.id, rpe: 9, rated: true, weight: 0, reps: 20)]
    let lifts = LiftSummaryLifts.make(
      session: session([warmup, light, heavy] + pushUps),
      exercises: [bench.id: bench, pushUp.id: pushUp], recordSetIDs: [heavy.id])
    #expect(lifts.count == 2)
    #expect(lifts[0].best.id == heavy.id)
    #expect(lifts[0].workingSets == 2)
    #expect(lifts[0].isPersonalRecord)
    #expect(!lifts[0].showsReps)
    #expect(lifts[1].best.reps == 20)
    #expect(lifts[1].showsReps)
    #expect(!lifts[1].isPersonalRecord)
  }
}
