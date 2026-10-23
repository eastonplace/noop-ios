import Foundation
import Testing
#if canImport(ReceiptLiftFeature)
@testable import ReceiptLiftFeature
#else
@testable import LiftProgressionHarness
#endif

@Suite("Lift next-session progression")
struct LiftProgressionEngineTests {
  private let now = Date(timeIntervalSince1970: 1_792_584_000)

  @Test func completedTopOfRangeAtRatedEffortAddsOneBarbellStep() {
    let decision = recommend()
    #expect(decision.reason == .addWeight)
    #expect(decision.target == LiftProgressionTarget(weightPounds: 105, reps: 5, sets: 3))
    #expect(decision.evidence?.workingSets == 3)
    #expect(decision.evidence?.highestRPE == 8)
  }

  @Test func addsOneRepOnlyAfterEverySetMeetsTheCurrentRepTarget() {
    let decision = recommend(sets: [workSet(reps: 7), workSet(reps: 6), workSet(reps: 8)])
    #expect(decision.reason == .addReps)
    #expect(decision.target == LiftProgressionTarget(weightPounds: 100, reps: 7, sets: 3))
  }

  @Test func highRatedEffortReducesLoadAndReturnsToTheBottomOfTheRange() {
    let decision = recommend(sets: workSets(rpe: 9.5))
    #expect(decision.reason == .reduceWeight)
    #expect(decision.target == LiftProgressionTarget(weightPounds: 95, reps: 5, sets: 3))
  }

  @Test func missedMinimumRepsDoNotQualifyForProgression() {
    let decision = recommend(sets: [workSet(reps: 8), workSet(reps: 6), workSet(reps: 4)])
    #expect(decision.reason == .reduceWeight)
    #expect(decision.target?.weightPounds == 95)
    #expect(decision.target?.reps == 5)
  }

  @Test func moderatelyHighEffortRepeatsCompletedWork() {
    let decision = recommend(sets: workSets(rpe: 8.5))
    #expect(decision.reason == .repeatWork)
    #expect(decision.target == LiftProgressionTarget(weightPounds: 100, reps: 8, sets: 3))
  }

  @Test func incompleteWorkingSetCountNeverBorrowsCompletionFromWarmups() {
    let decision = recommend(sets: [workSet(isWarmup: true), workSet(), workSet()])
    #expect(decision.reason == .incompleteSets)
    #expect(decision.target == nil)
  }

  @Test(arguments: [false, nil] as [Bool?])
  func explicitlyRatedEffortIsRequiredForEveryWorkingSet(rated: Bool?) {
    var sets = workSets()
    sets[1].effortRated = rated
    let decision = recommend(sets: sets)
    #expect(decision.reason == .missingEffort)
    #expect(decision.target == nil)
  }

  @Test func warmupsNeverAffectLoadRepsOrEffortEvidence() {
    let decision = recommend(sets: [workSet(weight: 300, reps: 1, rpe: 10, isWarmup: true)] + workSets())
    #expect(decision.reason == .addWeight)
    #expect(decision.target?.weightPounds == 105)
    #expect(decision.evidence?.workingSets == 3)
  }

  @Test func warmupOnlySessionsDoNotBecomeWorkingHistory() {
    let decision = recommend(sets: [workSet(isWarmup: true)])
    #expect(decision.reason == .noWorkingSets)
    #expect(decision.target == nil)
  }

  @Test func historyOlderThanSixWeeksRequiresAFreshBaseline() {
    let decision = recommend(history: [session(daysAgo: 43)])
    #expect(decision.reason == .staleHistory)
    #expect(decision.target == nil)
  }

  @Test func unfinishedAndFutureSessionsCannotDriveASuggestion() {
    var active = session(daysAgo: 0)
    active.endedAt = nil
    let decision = recommend(history: [active, session(daysAgo: -1)])
    #expect(decision.reason == .noHistory)
    #expect(decision.target == nil)
  }

  @Test func aNewerIncompleteSessionPreventsUsingAnOlderSuccessfulOne() {
    let decision = recommend(history: [session(daysAgo: 7), session(daysAgo: 1, sets: [workSet()])])
    #expect(decision.reason == .incompleteSets)
    #expect(decision.target == nil)
  }

  @Test func aNewerSessionWithNoExerciseSetsDoesNotReuseOlderPerformance() {
    let decision = recommend(history: [session(daysAgo: 7), session(daysAgo: 1, sets: [])])
    #expect(decision.reason == .noWorkingSets)
    #expect(decision.target == nil)
  }

  @Test func kilogramBarbellTargetsUseRealPlateStepsAndStayStoredInPounds() {
    let decision = recommend(sets: workSets(weight: pounds(100)), unit: .kilograms)
    #expect(decision.reason == .addWeight)
    #expect(abs((decision.target?.weightPounds ?? 0) - pounds(102.5)) < 0.000_001)
  }

  @Test func kilogramDumbbellsUseTheirOwnStep() {
    let decision = recommend(sets: workSets(weight: pounds(50)), equipment: .dumbbell, unit: .kilograms)
    #expect(decision.reason == .addWeight)
    #expect(abs((decision.target?.weightPounds ?? 0) - pounds(52)) < 0.000_001)
  }

  @Test func convertingUnitsNeverProducesAnOffGridLoadIncrease() {
    let decision = recommend(sets: workSets(weight: 135), unit: .kilograms)
    #expect(decision.reason == .addWeight)
    #expect(abs((decision.target?.weightPounds ?? 0) - pounds(62.5)) < 0.000_001)
  }

  @Test func bodyweightProgressionUsesRepsWithoutInventingAddedLoad() {
    let decision = recommend(sets: workSets(weight: 0, reps: 6), equipment: .bodyweight)
    #expect(decision.reason == .addReps)
    #expect(decision.target == LiftProgressionTarget(weightPounds: 0, reps: 7, sets: 3))
  }

  @Test(arguments: [0.0, 25.0])
  func bodyweightAtTheRepCeilingKeepsTheLoggedLoad(weight: Double) {
    let decision = recommend(sets: workSets(weight: weight), equipment: .bodyweight)
    #expect(decision.reason == .bodyweightCeiling)
    #expect(decision.target?.weightPounds == weight)
    #expect(decision.target?.reps == 8)
  }

  @Test func reducingBodyweightRepsDoesNotGoBelowAFixedPrescription() {
    let decision = recommend(sets: workSets(weight: 0, reps: 10, rpe: 10), plannedReps: "8", equipment: .bodyweight)
    #expect(decision.reason == .repeatWork)
    #expect(decision.target?.reps == 8)
  }

  @Test func difficultBodyweightWorkCanReduceRepsWithinThePlannedRange() {
    let decision = recommend(sets: workSets(weight: 0, reps: 8, rpe: 10), equipment: .bodyweight)
    #expect(decision.reason == .reduceReps)
    #expect(decision.target == LiftProgressionTarget(weightPounds: 0, reps: 7, sets: 3))
  }

  @Test func unknownEquipmentDoesNotAssumeAStackOrPlateIncrement() {
    let decision = recommend(equipment: .unknown)
    #expect(decision.reason == .unknownLoadStep)
    #expect(decision.target?.weightPounds == 100)
  }

  @Test func oneEquipmentStepCannotIncreaseLoadByMoreThanTenPercent() {
    let decision = recommend(sets: workSets(weight: 20), equipment: .dumbbell)
    #expect(decision.reason == .loadStepTooLarge)
    #expect(decision.target?.weightPounds == 20)
  }

  @Test func easyCompletedWorkCanAddOneSetWithinTheSavedSetRange() {
    let decision = recommend(sets: workSets(count: 2, rpe: 7), plannedSets: "2-3")
    #expect(decision.reason == .addSet)
    #expect(decision.target == LiftProgressionTarget(weightPounds: 100, reps: 8, sets: 3))
  }

  @Test func addingASetRequiresMoreEffortHeadroomThanAddingARep() {
    let decision = recommend(sets: workSets(count: 2), plannedSets: "2-3")
    #expect(decision.reason == .repeatWork)
    #expect(decision.target?.sets == 2)
    #expect(decision.target?.weightPounds == 100)
  }

  @Test func reachingTheSetRangeCeilingAllowsLoadProgression() {
    let decision = recommend(plannedSets: "2-3")
    #expect(decision.reason == .addWeight)
    #expect(decision.target?.sets == 3)
  }

  @Test(arguments: ["30-45 s/side", "10-15/side or 30-45 s", "AMRAP", "0", "8-5", "999999999999999999999999"])
  func timedAmbiguousOrMalformedPrescriptionsStayUnchanged(reps: String) {
    let decision = recommend(plannedReps: reps)
    #expect(decision.reason == .unsupportedPrescription)
    #expect(decision.target == nil)
  }

  @Test func perLegRepSemanticsSurviveAnAppliedTarget() {
    let decision = recommend(sets: workSets(reps: 10), plannedReps: "8–12/leg")
    #expect(decision.reason == .addReps)
    #expect(decision.target?.repsText == "11/leg")
  }

  @Test(arguments: ["2 RIR", "1-2 RIR", "RPE 8", "8"])
  func supportedEffortPrescriptionsUseTheExplicitRatings(effort: String) {
    #expect(recommend(targetEffort: effort).reason == .addWeight)
  }

  @Test func aLowerPlannedEffortCeilingDoesNotProgressHarderSets() {
    #expect(recommend(sets: workSets(rpe: 7.5), targetEffort: "RPE 7").reason == .repeatWork)
  }

  @Test func technicalEffortTextDoesNotPretendToBeAnRPEPrescription() {
    let decision = recommend(targetEffort: "Technical")
    #expect(decision.reason == .unsupportedPrescription)
    #expect(decision.target == nil)
  }

  @Test(arguments: [Double.nan, .infinity, -1, 20_000])
  func invalidLoadsNeverCreateTargets(weight: Double) {
    let decision = recommend(sets: workSets(weight: weight))
    #expect(decision.reason == .invalidHistory)
    #expect(decision.target == nil)
  }

  @Test(arguments: [Double.nan, .infinity, 0, 11])
  func invalidRatedEffortNeverCreatesTargets(rpe: Double) {
    #expect(recommend(sets: workSets(rpe: rpe)).reason == .invalidHistory)
  }

  @Test(arguments: [0, -1, Int.max])
  func invalidRepCountsNeverCreateTargets(reps: Int) {
    let decision = recommend(sets: workSets(reps: reps))
    #expect(decision.reason == .invalidHistory)
    #expect(decision.target == nil)
  }

  @Test func duplicateSetIdentitiesCannotInflateCompletedVolume() {
    let set = workSet()
    let decision = recommend(sets: [set, set, set])
    #expect(decision.reason == .invalidHistory)
    #expect(decision.target == nil)
  }

  @Test func mixedWorkingLoadsAreNotCollapsedIntoASingleHeavierTarget() {
    let decision = recommend(sets: [workSet(weight: 100), workSet(weight: 95), workSet(weight: 90)])
    #expect(decision.reason == .mixedLoads)
    #expect(decision.target == nil)
  }

  @Test func setsOutsideTheCompletedSessionWindowAreInvalidEvidence() {
    var recent = session(daysAgo: 1)
    recent.sets[0].completedAt = now.addingTimeInterval(60)
    #expect(recommend(history: [recent]).reason == .invalidHistory)
  }

  @Test func historyOrderNeverChangesTheLatestCompletedSource() {
    let old = session(daysAgo: 7, sets: workSets(weight: 90))
    let latest = session(daysAgo: 1)
    #expect(recommend(history: [old, latest]) == recommend(history: [latest, old]))
    #expect(recommend(history: [old, latest]).sourceSessionID == latest.id)
  }

  private func recommend(
    sets: [LiftProgressionWorkSet]? = nil,
    history: [LiftProgressionSession]? = nil,
    plannedSets: String = "3",
    plannedReps: String = "5-8",
    targetEffort: String = "RPE 8",
    equipment: LiftProgressionEquipment = .barbell,
    unit: LiftProgressionUnit = .pounds
  ) -> LiftProgressionDecision {
    LiftProgressionEngine.recommendation(
      plan: LiftProgressionPlan(sets: plannedSets, reps: plannedReps, targetEffort: targetEffort),
      equipment: equipment,
      unit: unit,
      history: history ?? [session(daysAgo: 1, sets: sets)],
      now: now
    )
  }

  private func workSet(
    weight: Double = 100,
    reps: Int = 8,
    rpe: Double = 8,
    isWarmup: Bool = false
  ) -> LiftProgressionWorkSet {
    LiftProgressionWorkSet(
      id: UUID(), weightPounds: weight, reps: reps, rpe: rpe,
      effortRated: true, isWarmup: isWarmup, completedAt: now.addingTimeInterval(-86_100)
    )
  }

  private func workSets(count: Int = 3, weight: Double = 100, reps: Int = 8, rpe: Double = 8) -> [LiftProgressionWorkSet] {
    (0..<count).map { _ in workSet(weight: weight, reps: reps, rpe: rpe) }
  }

  private func session(daysAgo: Int, sets: [LiftProgressionWorkSet]? = nil) -> LiftProgressionSession {
    let start = now.addingTimeInterval(-Double(daysAgo) * 86_400)
    return LiftProgressionSession(
      id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(3_600),
      sets: (sets ?? workSets()).map { set in
        var adjusted = set
        adjusted.completedAt = start.addingTimeInterval(300)
        return adjusted
      }
    )
  }

  private func pounds(_ kilograms: Double) -> Double { kilograms / 0.45359237 }
}
