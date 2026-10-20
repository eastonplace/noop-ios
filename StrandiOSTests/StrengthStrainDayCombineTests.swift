import Foundation
import StrandAnalytics
import WhoopProtocol
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
            try combiner.dayCombine("2026-07-17", stored, 10).bitPattern,
            StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: 10, components: parts).bitPattern)
        XCTAssertEqual(combiner.missedDays, [])

        let (_, secondaryRepo) = Fixtures.makeEngine(store: store, primary: false)
        XCTAssertNil(secondaryRepo.liftStrainDayPartsLoader, "a transient engine never installs a loader")
    }

    func testUnavailableBackfillKeepsPendingWorkForALaterLoadedSettle() async throws {
        let parts = floorDominated()
        let base = try XCTUnwrap(parts.score)
        let lift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 3), kg: 100, sets: 12)
        let (store, computed, _) = try await pendingStore(dayStored: base, lift: lift)
        let (engine, repo) = Fixtures.makeEngine(store: store)
        let day = Repository.logicalDayKey(lift.start)
        repo.loaded = false

        await engine.runStrengthStrainBackfillIfNeeded()

        let deferred = try await Fixtures.dayBits(store, day: day)
        XCTAssertEqual(deferred, Fixtures.Bits(base, 2), "unavailable parts must not commit the inversion")
        let deferredRow = try await Fixtures.liftRow(store, id: lift.id)
        XCTAssertEqual(deferredRow?.state, .pending, "the next normal settle must still see dirty work")
        let job = try await store.liftStrainJob(jobKey: "strength-strain-backfill-v\(StrengthStrain.version):\(Fixtures.owner)")
        XCTAssertEqual(job?.state, .running)
        XCTAssertNil(job?.cursorDay, "unavailable parts must not advance the durable backfill cursor")
        XCTAssertFalse(engine.strengthBackfillDone)

        repo.loaded = true
        engine.liftStrainDayPartsForTesting = { _ in parts }
        _ = await engine.settleLiftStrain()

        let actual = try await Fixtures.dayBits(store, day: day)
        let expected = StrengthStrainIntegration.dayCombine(
            hrStored: base, muscularLoad: computed.muscularLoad, components: parts)
        XCTAssertNotEqual(expected.bitPattern, inversion(base, computed.muscularLoad).bitPattern)
        XCTAssertEqual(actual, Fixtures.Bits(expected, 2), "the later loaded settle must persist the parts-aware result")
    }

    func testEngineReloadsPartsWhenRawChangesBeforeRepositoryRefresh() async throws {
        let store = try await WhoopStore.inMemory()
        try Fixtures.register(store, ids: [Fixtures.owner])
        let (engine, repo) = Fixtures.makeEngine(store: store)
        repo.loaded = true
        let date = Fixtures.noon(daysAgo: 3)
        let day = Repository.logicalDayKey(date)
        let start = Calendar.current.startOfDay(for: date)
        let ts = Int(date.timeIntervalSince1970)
        let profile = ProfileStore()
        let floor = StrainScorerV2.stepFloor(20_000)
        let base = StrainScorerV2.storedValue(fromDisplay: floor)
        let basis = Fixtures.dailyMetric(day, strain: base, steps: 20_000)
        try await store.upsertDailyMetrics([basis], deviceId: Fixtures.canonical)
        var streams = Streams()
        streams.hr = stride(from: ts, to: ts + 600, by: 10).map { HRSample(ts: $0, bpm: 70) }
        _ = try await store.insert(streams, deviceId: Fixtures.owner)
        let first = StrengthStrainDayCombiner()
        await engine.loadLiftStrainDayParts([day], into: first)
        let firstValue = try first.dayCombine(day, base, 20)

        // New raw HR raises cardio, while the step floor and every stored daily input stay the same.
        streams.hr = stride(from: ts + 600, to: ts + 1_200, by: 10).map { HRSample(ts: $0, bpm: 130) }
        _ = try await store.insert(streams, deviceId: Fixtures.owner)
        // In-pass settle runs before the repository refresh, so its published sequence has not moved.
        let request = StrainDayRequest(
            dayKey: day, logicalStart: start, isToday: false, maxHR: profile.hrMaxForBatchScoring,
            restingHR: 52, steps: 20_000, stepTicksPerStep: profile.stepTicksPerStep,
            sleepMinutes: 420, heroTenths: nil, refreshSeq: repo.refreshSeq)
        let freshResult = await StrainDayLoader.load(request, repo: repo, useCache: false)
        let fresh = try XCTUnwrap(freshResult?.analysis.components)
        XCTAssertEqual(fresh.score?.bitPattern, base.bitPattern, "the stored score remains floor dominated")
        let expected = StrengthStrainIntegration.dayCombine(hrStored: base, muscularLoad: 20, components: fresh)
        XCTAssertNotEqual(firstValue.bitPattern, expected.bitPattern, "new cardio must change the combined lift score")
        let second = StrengthStrainDayCombiner()
        await engine.loadLiftStrainDayParts([day], into: second)
        XCTAssertEqual(try second.dayCombine(day, base, 20).bitPattern, expected.bitPattern,
                       "new raw readings must be used before the repository publishes a refresh")
    }

    func testNewlyDiscoveredUnavailableDayRollsBackAndRetriesWhenLoaded() async throws {
        let parts = floorDominated()
        let base = try XCTUnwrap(parts.score)
        let firstLift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 4), kg: 100, sets: 12)
        let newLift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 3), kg: 100, sets: 12)
        let (store, firstComputed, _) = try await pendingStore(dayStored: base, lift: firstLift)
        let newWorkout = try XCTUnwrap(Fixtures.workouts([newLift]).first)
        let newComputed = StrengthStrainIntegration.computed(for: newWorkout, frozen: nil, profileKg: 80)
        let firstDay = Repository.logicalDayKey(firstLift.start)
        let newDay = Repository.logicalDayKey(newLift.start)
        let (engine, repo) = Fixtures.makeEngine(store: store)
        var injected = false
        var injectionError: Error?
        engine.liftStrainDayPartsForTesting = { day in
            if day == firstDay, !injected {
                injected = true
                do {
                    // This writer lands after preflight listed A, before the apply transaction chooses A and B.
                    _ = try await Fixtures.seed(store, lifts: [firstLift, newLift], workoutStrain: 30, dayStrain: base)
                    try await store.upsertLiftStrainComputed(deviceId: Fixtures.owner, rows: [newComputed], now: 11)
                } catch { injectionError = error }
                repo.loaded = false
                engine.liftStrainDayPartsForTesting = nil
            }
            return parts
        }

        let deferred = await engine.settleLiftStrain()

        XCTAssertTrue(injected)
        XCTAssertNil(injectionError)
        XCTAssertNil(deferred, "the transaction must defer when it discovers an unprepared day")
        for (day, lift) in [(firstDay, firstLift), (newDay, newLift)] {
            let value = try await Fixtures.dayBits(store, day: day)
            let row = try await Fixtures.liftRow(store, id: lift.id)
            XCTAssertEqual(value, Fixtures.Bits(base, 2), "the entire transaction rolls back, including known A")
            XCTAssertEqual(row?.state, .pending, "unavailable B must remain durable dirty work")
        }

        repo.loaded = true
        engine.liftStrainDayPartsForTesting = { _ in parts }
        _ = await engine.settleLiftStrain()

        for (day, computed) in [(firstDay, firstComputed), (newDay, newComputed)] {
            let actual = try await Fixtures.dayBits(store, day: day)
            let expected = StrengthStrainIntegration.dayCombine(
                hrStored: base, muscularLoad: computed.muscularLoad, components: parts)
            XCTAssertEqual(actual, Fixtures.Bits(expected, 2), "a normal loaded settle must correct both days")
        }
    }

    func testNewlyDiscoveredReadyDayRetriesOnlyTheRolledBackSettle() async throws {
        let parts = floorDominated()
        let base = try XCTUnwrap(parts.score)
        let firstLift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 4), kg: 100, sets: 12)
        let newLift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 3), kg: 100, sets: 12)
        let (store, firstComputed, _) = try await pendingStore(dayStored: base, lift: firstLift)
        let newWorkout = try XCTUnwrap(Fixtures.workouts([newLift]).first)
        let newComputed = StrengthStrainIntegration.computed(for: newWorkout, frozen: nil, profileKg: 80)
        let firstDay = Repository.logicalDayKey(firstLift.start)
        let newDay = Repository.logicalDayKey(newLift.start)
        let (engine, _) = Fixtures.makeEngine(store: store)
        var injected = false
        var injectionError: Error?
        var loadedDays: [String] = []
        engine.liftStrainDayPartsForTesting = { day in
            loadedDays.append(day)
            if day == firstDay, !injected {
                injected = true
                do {
                    _ = try await Fixtures.seed(store, lifts: [firstLift, newLift], workoutStrain: 30, dayStrain: base)
                    try await store.upsertLiftStrainComputed(deviceId: Fixtures.owner, rows: [newComputed], now: 11)
                } catch { injectionError = error }
            }
            return parts
        }

        let result = await engine.settleLiftStrain()

        XCTAssertNil(injectionError)
        XCTAssertEqual(Array(loadedDays.prefix(2)), [firstDay, newDay])
        XCTAssertEqual(result?.rowsVisited, 2, "rolled-back work must not be counted as applied")
        XCTAssertEqual(result?.workoutWrites, 2)
        XCTAssertEqual(result?.dayWrites, 2, "B must never commit a fallback before its parts-aware write")
        for (day, computed) in [(firstDay, firstComputed), (newDay, newComputed)] {
            let actual = try await Fixtures.dayBits(store, day: day)
            let expected = StrengthStrainIntegration.dayCombine(
                hrStored: base, muscularLoad: computed.muscularLoad, components: parts)
            XCTAssertEqual(actual, Fixtures.Bits(expected, 2))
        }
    }

    func testRepositoryRekeyPreservesLiftAssociationWithAnUnrelatedDirtyDay() async throws {
        try await assertRepositoryRekeyWithUnrelatedDay(injectDuringPartsLoad: false)
    }

    func testRepositoryRekeyRetriesTheOriginalMoveWhenANewDirtyDayIsDiscovered() async throws {
        try await assertRepositoryRekeyWithUnrelatedDay(injectDuringPartsLoad: true)
    }

    private func assertRepositoryRekeyWithUnrelatedDay(injectDuringPartsLoad: Bool) async throws {
        let parts = floorDominated()
        let base = try XCTUnwrap(parts.score)
        let movingLift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 4), kg: 100, sets: 12)
        let unrelatedLift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 3), kg: 100, sets: 12)
        let store = try await WhoopStore.inMemory()
        try Fixtures.register(store, ids: [Fixtures.owner])
        let workouts = try await Fixtures.seed(
            store, lifts: [movingLift, unrelatedLift], workoutStrain: 30, dayStrain: base)
        let movingWorkout = try XCTUnwrap(workouts.first { $0.id == movingLift.id.uuidString })
        let unrelatedWorkout = try XCTUnwrap(workouts.first { $0.id == unrelatedLift.id.uuidString })
        let moving = StrengthStrainIntegration.computed(for: movingWorkout, frozen: nil, profileKg: 80)
        let unrelated = StrengthStrainIntegration.computed(for: unrelatedWorkout, frozen: nil, profileKg: 80)
        try await store.upsertLiftStrainComputed(deviceId: Fixtures.owner, rows: [moving], now: 10)
        _ = try await store.applyLiftStrain(
            canonicalComputedDeviceId: Fixtures.canonical, now: 11, combine: StrengthStrainIntegration.combine,
            dayCombine: { _, hr, load in
                StrengthStrainIntegration.dayCombine(hrStored: hr, muscularLoad: load, components: parts)
            })
        if !injectDuringPartsLoad {
            try await store.upsertLiftStrainComputed(deviceId: Fixtures.owner, rows: [unrelated], now: 12)
        }
        let oldStart = Int(movingLift.start.timeIntervalSince1970)
        let rows = try await store.workouts(deviceId: Fixtures.owner, from: oldStart, to: oldStart, limit: 10)
        let old = try XCTUnwrap(rows.first { $0.sport == Fixtures.sport })
        let newStart = Int(Fixtures.noon(daysAgo: 2).timeIntervalSince1970)
        let edited = old.replacing(startTs: newStart, endTs: newStart + 3_000)
        let newDay = Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(newStart)))
        try await store.upsertDailyMetrics([Fixtures.dailyMetric(newDay, strain: base)], deviceId: Fixtures.canonical)
        let (engine, repo) = Fixtures.makeEngine(store: store)
        var injected = false
        var injectionError: Error?
        var loadedDays: [String] = []
        engine.liftStrainDayPartsForTesting = { day in
            loadedDays.append(day)
            if injectDuringPartsLoad, !injected {
                injected = true
                do {
                    try await store.upsertLiftStrainComputed(deviceId: Fixtures.owner, rows: [unrelated], now: 12)
                } catch { injectionError = error }
            }
            return parts
        }

        await repo.saveManualWorkout(edited, replacing: old)
        withExtendedLifetime(engine) {}

        XCTAssertNil(injectionError)
        XCTAssertTrue(loadedDays.contains(Repository.logicalDayKey(unrelatedLift.start)),
                      "the unrelated day must be prepared before the successful rekey")
        let moved = try await Fixtures.liftRow(store, id: movingLift.id)
        XCTAssertEqual(moved?.workoutStartTs, newStart, "the association must move in the same rekey transaction")
        XCTAssertEqual(moved?.dayKey, newDay)
        XCTAssertEqual(moved?.state, .applied)
        XCTAssertEqual(moved?.hrOnlyStrain?.bitPattern, Double(30).bitPattern,
                       "the old combined workout must be normalized to heart-rate-only before recombining")
        let newValue = try await Fixtures.workoutBits(store, start: newStart)
        XCTAssertEqual(newValue, Fixtures.Bits(StrengthStrain.combine(hrStored: 30, muscularLoad: moving.muscularLoad), 2))
        let oldDay = Repository.logicalDayKey(movingLift.start)
        let oldDayValue = try await Fixtures.dayBits(store, day: oldDay)
        XCTAssertEqual(oldDayValue, Fixtures.Bits(base, 2), "the moved lift leaves the old day heart-rate-only")
        let newDayValue = try await Fixtures.dayBits(store, day: newDay)
        XCTAssertEqual(newDayValue, Fixtures.Bits(StrengthStrainIntegration.dayCombine(
            hrStored: base, muscularLoad: moving.muscularLoad, components: parts), 2))
        let unrelatedDay = Repository.logicalDayKey(unrelatedLift.start)
        let unrelatedValue = try await Fixtures.dayBits(store, day: unrelatedDay)
        XCTAssertEqual(unrelatedValue, Fixtures.Bits(StrengthStrainIntegration.dayCombine(
            hrStored: base, muscularLoad: unrelated.muscularLoad, components: parts), 2))
    }

    func testRepositoryRekeyDefersWithoutChangingTheWorkoutWhenPartsAreUnavailable() async throws {
        let parts = floorDominated()
        let base = try XCTUnwrap(parts.score)
        let lift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 4), kg: 100, sets: 12)
        let (store, _, oldStart) = try await pendingStore(dayStored: base, lift: lift)
        _ = try await store.applyLiftStrain(
            canonicalComputedDeviceId: Fixtures.canonical, now: 11, combine: StrengthStrainIntegration.combine,
            dayCombine: { _, hr, load in
                StrengthStrainIntegration.dayCombine(hrStored: hr, muscularLoad: load, components: parts)
            })
        let rows = try await store.workouts(deviceId: Fixtures.owner, from: oldStart, to: oldStart, limit: 10)
        let old = try XCTUnwrap(rows.first { $0.sport == Fixtures.sport })
        let newStart = Int(Fixtures.noon(daysAgo: 2).timeIntervalSince1970)
        let edited = old.replacing(startTs: newStart, endTs: newStart + 3_000)
        let newDay = Repository.logicalDayKey(Date(timeIntervalSince1970: TimeInterval(newStart)))
        try await store.upsertDailyMetrics([Fixtures.dailyMetric(newDay, strain: base)], deviceId: Fixtures.canonical)
        let before = try await Fixtures.strainDump(store)
        let beforeLift = try await Fixtures.liftRow(store, id: lift.id)
        let (engine, repo) = Fixtures.makeEngine(store: store)
        repo.loaded = false

        await repo.saveManualWorkout(edited, replacing: old)

        let after = try await Fixtures.strainDump(store)
        let afterLift = try await Fixtures.liftRow(store, id: lift.id)
        XCTAssertEqual(after, before, "temporary unavailability must not run the delete/upsert fallback")
        XCTAssertEqual(afterLift, beforeLift, "the workout, target and association must stay atomic")
        let newValue = try await Fixtures.workoutBits(store, start: newStart)
        XCTAssertNil(newValue)
        withExtendedLifetime(engine) {}
    }

    // MARK: The combiner

    func testCombinerRecordsADayItWasNeverAskedToLoadAndForgetsItOnceLoaded() async throws {
        let combiner = StrengthStrainDayCombiner()
        let parts = floorDominated()
        let stored = parts.score ?? 0
        await combiner.load(["2026-07-17"]) { _ in .found(parts) }

        let known = try combiner.dayCombine("2026-07-17", stored, 10)
        XCTAssertEqual(known.bitPattern,
                       StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: 10, components: parts).bitPattern)
        XCTAssertEqual(combiner.missedDays, [])

        XCTAssertThrowsError(try combiner.dayCombine("2026-07-18", stored, 10)) { error in
            XCTAssertTrue(error is StrengthStrainDayCombiner.UnpreparedDay)
        }
        XCTAssertEqual(combiner.missedDays, ["2026-07-18"])

        await combiner.load(["2026-07-18"]) { _ in .found(parts) }
        XCTAssertEqual(combiner.missedDays, [])
        XCTAssertEqual(try combiner.dayCombine("2026-07-18", stored, 10).bitPattern, known.bitPattern)
    }

    func testCombinerTreatsNilPartsAsAFinalAnswer() async throws {
        let combiner = StrengthStrainDayCombiner()
        var asked = 0
        await combiner.load(["2026-07-17"]) { _ in asked += 1; return .none }
        await combiner.load(["2026-07-17"]) { _ in asked += 1; return .none }
        XCTAssertEqual(asked, 1)
        _ = try combiner.dayCombine("2026-07-17", 40, 10)
        XCTAssertEqual(combiner.missedDays, [], "a day with no parts is not retried")
    }

    func testCombinerRetriesADayWhoseLookupWasUnavailable() async throws {
        let combiner = StrengthStrainDayCombiner()
        let parts = floorDominated()
        let stored = parts.score ?? 0
        var asked = 0
        await combiner.load(["2026-07-17"]) { _ in asked += 1; return .unavailable }
        XCTAssertThrowsError(try combiner.dayCombine("2026-07-17", stored, 10))
        XCTAssertEqual(combiner.missedDays, ["2026-07-17"], "an unavailable lookup leaves the day missed")

        await combiner.load(["2026-07-17"]) { _ in asked += 1; return .found(parts) }
        XCTAssertEqual(asked, 2, "and it is looked for again")
        XCTAssertEqual(combiner.missedDays, [])
        XCTAssertEqual(
            try combiner.dayCombine("2026-07-17", stored, 10).bitPattern,
            StrengthStrainIntegration.dayCombine(hrStored: stored, muscularLoad: 10, components: parts).bitPattern,
            "the retry settles by the parts, not the inversion")
    }

    func testEngineDoesNotCacheAnUnavailablePartsLoad() async throws {
        let store = try await WhoopStore.inMemory()
        let (engine, repo) = Fixtures.makeEngine(store: store)
        let day = "2026-07-17"

        // The repository has not loaded: the day is missed, not settled as "no parts".
        repo.loaded = false
        let early = StrengthStrainDayCombiner()
        await engine.loadLiftStrainDayParts([day], into: early)
        XCTAssertThrowsError(try early.dayCombine(day, 40, 10))
        XCTAssertEqual(early.missedDays, [day])

        // A cancelled task is the same.
        repo.loaded = true
        let cancelled = StrengthStrainDayCombiner()
        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            await engine.loadLiftStrainDayParts([day], into: cancelled)
        }
        task.cancel()
        await task.value
        XCTAssertThrowsError(try cancelled.dayCombine(day, 40, 10))
        XCTAssertEqual(cancelled.missedDays, [day])

        // Neither left a cached answer behind: the next look, loaded and not cancelled, gives a definite one.
        let later = StrengthStrainDayCombiner()
        await engine.loadLiftStrainDayParts([day], into: later)
        _ = try later.dayCombine(day, 40, 10)
        XCTAssertEqual(later.missedDays, [], "the day has no computed row: a final answer this time")
    }
}
