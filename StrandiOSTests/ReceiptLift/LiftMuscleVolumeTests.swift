import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Sets per muscle")
struct LiftMuscleVolumeTests {
  private let start = Date(timeIntervalSince1970: 1_780_000_000)
  private var interval: DateInterval { DateInterval(start: start, duration: 7 * 86_400) }

  private func set(_ exerciseID: UUID, warmup: Bool = false) -> LiftSet {
    LiftSet(
      id: UUID(), exerciseID: exerciseID, setNumber: 1, weight: 100, reps: 8, rpe: 8, isWarmup: warmup,
      completedAt: start.addingTimeInterval(3_600), notes: "")
  }

  private func session(_ sets: [LiftSet], finished: Bool = true) -> LiftSession {
    LiftSession(
      id: UUID(), routineID: nil, title: "Test", startedAt: start.addingTimeInterval(3_000),
      endedAt: finished ? start.addingTimeInterval(6_000) : nil, sets: sets)
  }

  private func sets(_ volume: LiftMuscleVolume, _ group: LiftMuscleGroup) -> Double {
    volume.rows.first { $0.group == group }?.sets ?? -1
  }

  @Test func directCountsOneAndAssistingHalf() {
    let press = UUID()
    let volume = LiftMuscleVolume.make(
      sessions: [session([set(press), set(press)])], in: interval
    ) { _ in ("pectorals", ["triceps", "delts"]) }
    #expect(sets(volume, .chest) == 2)
    #expect(sets(volume, .triceps) == 1)
    #expect(sets(volume, .shoulders) == 1)
  }

  @Test func warmupsEarnNothing() {
    let press = UUID()
    let volume = LiftMuscleVolume.make(
      sessions: [session([set(press, warmup: true)])], in: interval
    ) { _ in ("pectorals", []) }
    #expect(sets(volume, .chest) == 0)
  }

  @Test func deltsAreShoulders() {
    #expect(LiftMuscleGroup.group(forToken: "delts") == .shoulders)
    #expect(LiftMuscleGroup.group(forToken: "Deltoids") == .shoulders)
  }

  @Test func sessionsOutsideTheWeekAndUnfinishedOnesAreIgnored() {
    let press = UUID()
    let before = LiftSession(
      id: UUID(), routineID: nil, title: "Old", startedAt: start.addingTimeInterval(-86_400),
      endedAt: start.addingTimeInterval(-80_000), sets: [set(press)])
    let volume = LiftMuscleVolume.make(
      sessions: [before, session([set(press)], finished: false)], in: interval
    ) { _ in ("pectorals", []) }
    #expect(sets(volume, .chest) == 0)
  }

  @Test func theBandEdgesAreInside() {
    #expect(LiftMuscleVolume.Row(group: .chest, sets: 10).isInsideBand)
    #expect(LiftMuscleVolume.Row(group: .chest, sets: 20).isInsideBand)
    #expect(!LiftMuscleVolume.Row(group: .chest, sets: 9.5).isInsideBand)
    #expect(!LiftMuscleVolume.Row(group: .chest, sets: 20.5).isInsideBand)
  }

  @Test func topMusclesFollowPlannedSets() {
    let a = UUID(), b = UUID(), c = UUID()
    let tokens: [UUID: String] = [a: "pectorals", b: "delts", c: "triceps"]
    let top = LiftMuscleVolume.topMuscles(
      plans: [(a, 4), (b, 3), (c, 3)], limit: 2) { (tokens[$0], []) }
    #expect(top == [.chest, .shoulders])
  }
}
