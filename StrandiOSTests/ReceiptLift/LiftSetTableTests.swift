import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Live set table")
struct LiftSetTableTests {
  private let exerciseID = UUID()
  private let start = Date(timeIntervalSince1970: 1_780_000_000)

  private func set(_ number: Int, weight: Double = 185, reps: Int = 8, warmup: Bool = false) -> LiftSet {
    LiftSet(
      id: UUID(), exerciseID: exerciseID, setNumber: number, weight: weight, reps: reps, rpe: 8, isWarmup: warmup,
      completedAt: start.addingTimeInterval(Double(number) * 100), notes: "")
  }

  @Test func warmupsAreWAndWorkingSetsAreNumbered() {
    let rows = LiftSetTable.rows(
      logged: [set(1, warmup: true), set(2), set(3)], previousSession: [], target: 4, draftIsWarmup: false)
    #expect(rows.map(\.label) == ["W", "1", "2", "3", "4"])
    #expect(rows[3].kind == .draft)
    #expect(rows[4].kind == .planned)
  }

  @Test func previousLinesUpBySetNumber() {
    let previous = [set(1, weight: 95, warmup: true), set(2, weight: 175), set(3, weight: 180)]
    let rows = LiftSetTable.rows(logged: [set(1, warmup: true), set(2)], previousSession: previous, target: 3, draftIsWarmup: false)
    #expect(rows[0].previous?.weight == 95)
    #expect(rows[1].previous?.weight == 175)
    #expect(rows[2].previous?.weight == 180)
  }

  @Test func theDraftIsTheLastRowWhenNothingIsPlannedAfterIt() {
    let rows = LiftSetTable.rows(logged: [set(1), set(2), set(3)], previousSession: [], target: 3, draftIsWarmup: false)
    #expect(rows.last?.kind == .draft)
    #expect(rows.count == 4)
  }

  @Test func aWarmupDraftHasNoPlannedRows() {
    let rows = LiftSetTable.rows(logged: [], previousSession: [], target: 4, draftIsWarmup: true)
    #expect(rows.map(\.label) == ["W"])
  }

  @Test func bestEstimateAndNewBest() {
    let sets = [set(1, weight: 185, reps: 8), set(2, weight: 200, reps: 5, warmup: true)]
    let best = LiftSetTable.bestEstimate(logged: sets, previousBest: 200)
    #expect(best?.value == 185 * (1 + 8.0 / 30))
    #expect(best?.isNewBest == true)
    #expect(LiftSetTable.bestEstimate(logged: sets, previousBest: 300)?.isNewBest == false)
    #expect(LiftSetTable.bestEstimate(logged: [set(1, warmup: true)], previousBest: 0) == nil)
  }

  @Test func previousSessionIsTheLatestFinishedOneWithTheExercise() {
    let older = LiftSession(id: UUID(), routineID: nil, title: "Old", startedAt: start, endedAt: start.addingTimeInterval(60), sets: [set(1, weight: 100)])
    let newer = LiftSession(id: UUID(), routineID: nil, title: "New", startedAt: start.addingTimeInterval(1_000), endedAt: start.addingTimeInterval(1_060), sets: [set(1, weight: 150)])
    let active = LiftSession(id: UUID(), routineID: nil, title: "Active", startedAt: start.addingTimeInterval(2_000), endedAt: nil, sets: [set(1, weight: 999)])
    let sets = LiftPreviousSets.lastSession(for: exerciseID, in: [older, newer, active])
    #expect(sets.map(\.weight) == [150])
  }

  @Test func subtitleNamesEquipmentAndMuscles() {
    let exercise = LiftExercise(id: UUID(), name: "Custom", muscleGroup: "Chest", equipment: "barbell", instructions: "")
    #expect(LiftExerciseSubtitle.make(exercise).hasPrefix("Barbell"))
    let bodyweight = LiftExercise(id: UUID(), name: "Custom", muscleGroup: "Chest", equipment: "body weight", instructions: "")
    #expect(LiftExerciseSubtitle.make(bodyweight).hasPrefix("Bodyweight"))
  }
}
