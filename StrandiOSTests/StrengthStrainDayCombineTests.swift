import Foundation
import StrandAnalytics
import WhoopStore
import XCTest
@testable import NOOP

/// A7: one day combine for the stored value and the shown value. On a floor-dominated day the stored day Strain, the
/// live day Strain and the day detail's combined score are the same number: `max(floors, combine(cardio, M))`, not
/// `combine(floor, M)`. The stored-score inversion is used only when the day's parts are missing.
@MainActor
final class StrengthStrainDayCombineTests: XCTestCase {

    private typealias Fixtures = StrengthStrainFixtures

    /// A day whose step floor (display 8) sets the score while cardio is only 5: the example from the review.
    private func floorDominated() -> StrainScorerV2.DayStrainComponents {
        StrainScorerV2.DayStrainComponents(
            cardio: 5, steps: 8, energy: nil, score: StrainScorerV2.storedValue(fromDisplay: 8), dominant: .steps)
    }

    private func inversion(_ stored: Double, _ load: Double) -> Double {
        StrengthStrain.combine(hrStored: stored, muscularLoad: load)
    }

    // MARK: The combine

    func testFloorDominatedDayIsMaxOfFloorAndCombinedCardioNotTheInversion() throws {
        let parts = floorDominated()
        let stored = try XCTUnwrap(parts.score)
        let load = 10.0
        let expected = max(stored, StrengthStrain.combine(
            hrStored: StrainScorerV2.storedValue(fromDisplay: 5), muscularLoad: load))
        let combined = StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: load, components: parts)
        XCTAssertEqual(combined.bitPattern, expected.bitPattern)
        let wrong = inversion(stored, load)
        XCTAssertGreaterThan(
            StrainScorerV2.displayValue(fromStored: wrong) - StrainScorerV2.displayValue(fromStored: combined), 1.0,
            "the inversion over-credits a floor-dominated day by more than a point")
    }

    func testWithoutPartsTheInversionIsTheDocumentedFallback() throws {
        let stored = StrainScorerV2.storedValue(fromDisplay: 8)
        XCTAssertEqual(
            StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: 10, components: nil).bitPattern,
            inversion(stored, 10).bitPattern)
        // Parts that are not this score (the readings changed, or another day's parts) are not used.
        let other = StrainScorerV2.DayStrainComponents(
            cardio: 12, steps: 3, energy: nil, score: StrainScorerV2.storedValue(fromDisplay: 12), dominant: .cardio)
        XCTAssertEqual(
            StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: 10, components: other).bitPattern,
            inversion(stored, 10).bitPattern)
        // An unscored day's parts have no score to anchor on.
        XCTAssertEqual(
            StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: 10, components: .unscored).bitPattern,
            inversion(stored, 10).bitPattern)
    }

    func testNoLoadLeavesTheScoreBitForBit() throws {
        let parts = floorDominated()
        let stored = try XCTUnwrap(parts.score)
        for load in [0.0, -3, .nan] {
            XCTAssertEqual(
                StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: load, components: parts).bitPattern,
                stored.bitPattern)
        }
    }

    func testPartsRebuiltWithinARoundingAnchorOnTheStoredBits() throws {
        // The parts rebuilt from the readings can differ from the stored score by a rounding; the result is built on
        // the stored bits so it never drifts from a settle that used the exact parts.
        let exact = floorDominated()
        let stored = try XCTUnwrap(exact.score)
        let nudged = StrainScorerV2.DayStrainComponents(
            cardio: exact.cardio, steps: exact.steps, energy: exact.energy,
            score: stored.nextUp, dominant: exact.dominant)
        XCTAssertEqual(
            StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: 10, components: nudged).bitPattern,
            StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: 10, components: exact).bitPattern)
    }

    // MARK: Stored == live == shown

    private func pendingStore(dayStored: Double, lift: Fixtures.Lift) async throws -> (WhoopStore, LiftStrainComputed, Int) {
        let store = try await WhoopStore.inMemory()
        try Fixtures.register(store, ids: [Fixtures.owner])
        let workouts = try await Fixtures.seed(store, lifts: [lift], workoutStrain: 30, dayStrain: dayStored)
        let workout = try XCTUnwrap(workouts.first)
        let computed = StrengthStrainIntegration.computed(for: workout, frozen: nil, profileKg: 80)
        try await store.upsertLiftStrainComputed(deviceId: Fixtures.owner, rows: [computed], now: 10)
        return (store, computed, Int(workout.startedAt.timeIntervalSince1970))
    }

    func testStoredLiveAndDetailAgreeOnAFloorDominatedLiftDay() async throws {
        let parts = floorDominated()
        let base = try XCTUnwrap(parts.score)
        let lift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 1), kg: 100, sets: 12)
        let (store, computed, _) = try await pendingStore(dayStored: base, lift: lift)
        let (engine, _) = Fixtures.makeEngine(store: store)
        let dayKey = Repository.logicalDayKey(lift.start)
        engine.liftStrainDayPartsForTesting = { day in day == dayKey ? parts : nil }

        _ = await engine.settleLiftStrain()

        let load = StrengthStrain.dayMuscularLoad([computed.muscularLoad])
        XCTAssertGreaterThan(load, 0)
        let stored = try await Fixtures.dayBits(store, day: dayKey)
        let live = Repository.liveDayStrainWithLifts(
            heartRateStored: base, components: parts, liftLoads: [computed.muscularLoad])
        let storedValue = try XCTUnwrap(stored?.value)
        XCTAssertEqual(stored?.version, 2)
        XCTAssertGreaterThan(storedValue, base, "the sets lift the cardio part above the step floor")
        XCTAssertEqual(storedValue.bitPattern, live.bitPattern, "the stored day and the live day are the same number")
        XCTAssertNotEqual(storedValue.bitPattern, inversion(base, load).bitPattern,
                          "and not the inversion, which over-credits a floor-dominated day")

        // The day detail: its hero is the stored value, so the parts agree with it and the Lifting row is the add.
        let hero = StrainScorerV2.displayValue(fromStored: storedValue)
        let shown = try XCTUnwrap(StrainScoreParts.make(parts, hero: hero, liftLoad: load))
        XCTAssertTrue(shown.agreesWithHero)
        let add = try XCTUnwrap(shown.rows.first(where: { $0.kind == .lifting })?.value)
        XCTAssertEqual(add, hero - StrainScorerV2.displayValue(fromStored: base), accuracy: 1e-9)

        // A second settle writes nothing.
        let before = try await Fixtures.strainDump(store)
        _ = await engine.settleLiftStrain()
        let after = try await Fixtures.strainDump(store)
        XCTAssertEqual(after, before)
    }

    func testSettleFallsBackToTheInversionWhenTheDayHasNoParts() async throws {
        let base = StrainScorerV2.storedValue(fromDisplay: 8)
        let lift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 1))
        let (store, computed, _) = try await pendingStore(dayStored: base, lift: lift)
        let (engine, _) = Fixtures.makeEngine(store: store)
        engine.liftStrainDayPartsForTesting = { _ in nil }

        _ = await engine.settleLiftStrain()

        let stored = try await Fixtures.dayBits(store, day: Repository.logicalDayKey(lift.start))
        XCTAssertEqual(stored, Fixtures.Bits(inversion(base, computed.muscularLoad), 2))
    }

    func testBackfillSettlesFloorDominatedDaysWithTheirParts() async throws {
        let parts = floorDominated()
        let base = try XCTUnwrap(parts.score)
        let lift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 3), kg: 100, sets: 12)
        let store = try await WhoopStore.inMemory()
        try Fixtures.register(store, ids: [Fixtures.owner])
        let workouts = try await Fixtures.seed(store, lifts: [lift], workoutStrain: 30, dayStrain: base)
        XCTAssertEqual(workouts.count, 1)
        let (engine, _) = Fixtures.makeEngine(store: store)
        let dayKey = Repository.logicalDayKey(lift.start)
        engine.liftStrainDayPartsForTesting = { day in day == dayKey ? parts : nil }

        await engine.runStrengthStrainBackfillIfNeeded()

        // The backfill computes the lift itself (the body weight it freezes is the profile's), so the load comes from
        // the row it stored.
        let row = try await Fixtures.liftRow(store, id: lift.id)
        let load = try XCTUnwrap(row?.muscularLoad)
        let stored = try await Fixtures.dayBits(store, day: dayKey)
        let expected = StrengthStrainIntegration.dayCombine(hrStored: base, muscularLoad: load, components: parts)
        XCTAssertEqual(stored, Fixtures.Bits(expected, 2))
        XCTAssertNotEqual(expected.bitPattern, inversion(base, load).bitPattern)
    }

    func testThePrimaryEngineHandsTheRepositoryItsPartsLoaderForTheRekeySettle() async throws {
        let store = try await WhoopStore.inMemory()
        let (engine, repo) = Fixtures.makeEngine(store: store)
        let parts = floorDominated()
        engine.liftStrainDayPartsForTesting = { _ in parts }
        let loader = try XCTUnwrap(repo.liftStrainDayPartsLoader)
        let combiner = StrengthStrainDayCombiner()
        await loader(["2026-07-17"], combiner)
        let stored = try XCTUnwrap(parts.score)
        XCTAssertEqual(
            combiner.dayCombine("2026-07-17", stored, 10).bitPattern,
            StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: 10, components: parts).bitPattern)
        XCTAssertEqual(combiner.missedDays, [])

        let (_, secondaryRepo) = Fixtures.makeEngine(store: store, primary: false)
        XCTAssertNil(secondaryRepo.liftStrainDayPartsLoader, "a transient engine never installs a loader")
    }

    // MARK: The combiner

    func testCombinerRecordsADayItWasNeverAskedToLoadAndForgetsItOnceLoaded() async {
        let combiner = StrengthStrainDayCombiner()
        let parts = floorDominated()
        let stored = parts.score ?? 0
        await combiner.load(["2026-07-17"]) { _ in parts }

        let known = combiner.dayCombine("2026-07-17", stored, 10)
        XCTAssertEqual(known.bitPattern,
                       StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: 10, components: parts).bitPattern)
        XCTAssertEqual(combiner.missedDays, [])

        let unknown = combiner.dayCombine("2026-07-18", stored, 10)
        XCTAssertEqual(unknown.bitPattern, inversion(stored, 10).bitPattern, "no parts: the inversion")
        XCTAssertEqual(combiner.missedDays, ["2026-07-18"])

        await combiner.load(["2026-07-18"]) { _ in parts }
        XCTAssertEqual(combiner.missedDays, [])
        XCTAssertEqual(combiner.dayCombine("2026-07-18", stored, 10).bitPattern, known.bitPattern)
    }

    func testCombinerTreatsNilPartsAsAFinalAnswer() async {
        let combiner = StrengthStrainDayCombiner()
        var asked = 0
        await combiner.load(["2026-07-17"]) { _ in asked += 1; return nil }
        await combiner.load(["2026-07-17"]) { _ in asked += 1; return nil }
        XCTAssertEqual(asked, 1)
        _ = combiner.dayCombine("2026-07-17", 40, 10)
        XCTAssertEqual(combiner.missedDays, [], "a day with no parts is not retried")
    }
}
