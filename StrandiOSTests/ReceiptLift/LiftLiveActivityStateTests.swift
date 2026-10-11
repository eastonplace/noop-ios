import Foundation
import Testing
@testable import ReceiptLiftFeature

@Suite("Lift Live Activity state")
struct LiftLiveActivityStateTests {
  private static let now = Date(timeIntervalSince1970: 1_780_000_000)

  /// Three working sets of 100 kg × 10, stored in pounds like every Lift load.
  private static func session() -> LiftSession {
    let load = LiftWeightUnit.kilograms.toPounds(100)
    let sets = (1...3).map { index in
      LiftSet(
        id: UUID(), exerciseID: UUID(), setNumber: index, weight: load, reps: 10, rpe: 8,
        isWarmup: false, completedAt: now, notes: "")
    }
    return LiftSession(id: UUID(), routineID: nil, title: "Push", startedAt: now, endedAt: nil, sets: sets)
  }

  @Test("A metric person sees kilograms on the Lock Screen, matching the receipt")
  func volumeIsShownInKilograms() {
    let session = Self.session()
    let state = LiftLiveActivityManager.contentState(
      session: session, progress: nil, currentMove: "Bench Press", restTimerEndDate: nil,
      weightUnit: .kilograms, now: Self.now)
    #expect(abs(state.volume - 3_000) < 1e-6)
    #expect(LiftFormat(unit: .kilograms, locale: Locale(identifier: "en_US")).volume(pounds: session.totalVolume) == "3,000 kg")
  }

  @Test("An imperial person still sees the stored pound total")
  func volumeStaysInPounds() {
    let session = Self.session()
    let state = LiftLiveActivityManager.contentState(
      session: session, progress: nil, currentMove: "Bench Press", restTimerEndDate: nil,
      weightUnit: .pounds, now: Self.now)
    #expect(abs(state.volume - session.totalVolume) < 1e-9)
  }
}

@Suite("Lift unit handed over before load")
@MainActor
struct LiftCoordinatorUnitTests {
  @Test("The store has the person's unit before load() runs, so a restored session's first Live Activity sync is in it")
  func coordinatorHandsTheUnitToTheStoreAtCreation() {
    let metric = ReceiptLiftCoordinator(load: { nil }, save: { _, _ in }, weightUnit: .kilograms)
    #expect(metric.store.weightUnit == .kilograms)
    let imperial = ReceiptLiftCoordinator(load: { nil }, save: { _, _ in }, weightUnit: .pounds)
    #expect(imperial.store.weightUnit == .pounds)
    // Left out, it is pounds, Lift's stored unit.
    #expect(ReceiptLiftCoordinator(load: { nil }, save: { _, _ in }).store.weightUnit == .pounds)
  }
}
