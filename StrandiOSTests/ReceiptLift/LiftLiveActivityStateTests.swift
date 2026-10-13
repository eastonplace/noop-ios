import Foundation
import Testing
import ReceiptLiftActivity
import StrandDesign
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

  @Test("The unit rides with the volume, so the figure is never a bare number")
  func theUnitRidesWithTheVolume() {
    let session = Self.session()
    let metric = LiftLiveActivityManager.contentState(
      session: session, progress: nil, currentMove: "Bench Press", restTimerEndDate: nil,
      weightUnit: .kilograms, now: Self.now)
    let imperial = LiftLiveActivityManager.contentState(
      session: session, progress: nil, currentMove: "Bench Press", restTimerEndDate: nil,
      weightUnit: .pounds, now: Self.now)
    #expect(metric.volumeUnit == "kg")
    #expect(imperial.volumeUnit == "lb")
  }

  @Test("The unit round-trips, and an activity started by an older build still decodes as a bare number")
  func theUnitIsAdditive() throws {
    let state = LiftLiveActivityManager.contentState(
      session: Self.session(), progress: nil, currentMove: "Bench Press", restTimerEndDate: nil,
      weightUnit: .kilograms, now: Self.now)
    let decoded = try JSONDecoder().decode(
      LiftLiveActivityAttributes.ContentState.self, from: JSONEncoder().encode(state))
    #expect(decoded == state)
    #expect(decoded.volumeUnit == "kg")

    let old = #"{"currentMove":"Bench Press","completedSets":3,"targetSets":9,"volume":3000,"updatedAt":700000000}"#
    let legacy = try JSONDecoder().decode(LiftLiveActivityAttributes.ContentState.self, from: Data(old.utf8))
    #expect(legacy.volumeUnit == nil)
    #expect(legacy.volume == 3_000)
    #expect(NOOPLiftFacts.unitSymbol(legacy.volumeUnit) == nil, "no unit is drawn for a payload that carries none")
  }

  @Test("The card writes the unit it was given in the person's language and ignores a code it does not know")
  func theFactsStripKnowsTheUnitCodes() {
    #expect(NOOPLiftFacts.unitSymbol("lb") != nil)
    #expect(NOOPLiftFacts.unitSymbol("kg") != nil)
    #expect(NOOPLiftFacts.unitSymbol("stone") == nil)
    #expect(NOOPLiftFacts.unitSymbol(nil) == nil)
    if Locale.current.language.languageCode?.identifier == "en" {
      #expect(NOOPLiftFacts.unitSymbol("lb") == "lb")
      #expect(NOOPLiftFacts.unitSymbol("kg") == "kg")
    }
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
