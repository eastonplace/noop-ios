import Foundation
import GRDB
import ReceiptLiftFeature
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import XCTest
@testable import NOOP

/// The app's side of Strength Strain: how a Lift set becomes a formula input, which body weight a lift is scored
/// with, which day it belongs to, and what the stored result looks like.
final class StrengthStrainIntegrationTests: XCTestCase {

    private typealias Fixtures = StrengthStrainFixtures

    private func set(_ exercise: String = "Barbell Squat", equipment: String? = "Barbell", muscle: String = "quadriceps",
                     secondary: [String] = ["glutes"], kg: Double = 100, reps: Int = 5, rpe: Double? = 8,
                     warmup: Bool = false) -> ReceiptLiftSet {
        ReceiptLiftSet(id: UUID().uuidString, exercise: exercise, muscleGroup: muscle, secondaryMuscles: secondary,
                       setIndex: 1, weightKg: kg, reps: reps, rpe: rpe, isWarmup: warmup,
                       completedAt: Date(timeIntervalSince1970: 1_800_000_000), note: nil, equipment: equipment)
    }

    private func workout(_ sets: [ReceiptLiftSet], start: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> ReceiptLiftWorkout {
        ReceiptLiftWorkout(id: UUID().uuidString, title: "Lift", startedAt: start,
                           endedAt: start.addingTimeInterval(3_000), sets: sets)
    }

    // MARK: Mapping

    func testSetMappingCarriesEveryField() {
        let input = StrengthStrainIntegration.input(for: set(warmup: true))
        XCTAssertEqual(input.exerciseName, "Barbell Squat")
        XCTAssertEqual(input.equipment, "Barbell")
        XCTAssertEqual(input.primaryMuscle, "quadriceps")
        XCTAssertEqual(input.secondaryMuscles, ["glutes"])
        XCTAssertEqual(input.reps, 5)
        XCTAssertEqual(input.weightKg, 100)
        XCTAssertEqual(input.rpe, 8)
        XCTAssertTrue(input.isWarmup)
    }

    func testEmptyMuscleGroupIsAnUnknownPrimaryAndAMissingRPEStaysMissing() {
        let input = StrengthStrainIntegration.input(for: set(equipment: nil, muscle: "", rpe: nil))
        XCTAssertNil(input.primaryMuscle)
        XCTAssertNil(input.equipment)
        XCTAssertNil(input.rpe)
    }

    func testLiveAndSavedPathsUseOneMapping() {
        let sets = [set(), set("Pull-Up", equipment: "Bodyweight", muscle: "lats", secondary: [], kg: 0, reps: 8)]
        XCTAssertEqual(StrengthStrainIntegration.inputs(for: sets),
                       StrengthStrainIntegration.inputs(for: workout(sets)))
        // The same sets give a bit-equal muscular load whether the card or the saved score computes it.
        let live = StrengthStrain.evaluate(sets: StrengthStrainIntegration.inputs(for: sets), bodyweightKg: 80)
        let saved = StrengthStrainIntegration.computed(
            for: workout(sets), frozen: LiftStrainFrozenBodyweight(kg: 80, isDefault: false), profileKg: nil)
        XCTAssertEqual(live.muscularLoad.bitPattern, saved.muscularLoad.bitPattern)
    }

    func testStoredRowsMapWithoutEquipment() {
        let row = LiftSetRow(
            id: "s", deviceId: "d", sessionId: "x", ord: 0, exercise: "Bench Press", primaryMuscle: .chest,
            secondaryMuscles: [.triceps, .frontDelts], setIndex: 1, weightKg: 80, reps: nil, rpe: nil, isWarmup: false,
            startTs: nil, endTs: nil, restSec: nil, note: nil)
        let input = StrengthStrainIntegration.inputs(for: [row])[0]
        XCTAssertNil(input.equipment)
        XCTAssertEqual(input.primaryMuscle, LiftMuscle.chest.rawValue)
        XCTAssertEqual(input.secondaryMuscles, [LiftMuscle.triceps.rawValue, LiftMuscle.frontDelts.rawValue])
        XCTAssertEqual(input.reps, 0)
    }

    // MARK: Body weight

    func testAFrozenWeightSurvivesAProfileChange() {
        let frozen = LiftStrainFrozenBodyweight(kg: 80, isDefault: false)
        XCTAssertEqual(StrengthStrainIntegration.bodyweight(frozen: frozen, profileKg: 95), frozen)
        let computed = StrengthStrainIntegration.computed(for: workout([set()]), frozen: frozen, profileKg: 95)
        XCTAssertEqual(computed.bodyweightKg, 80)
        XCTAssertFalse(computed.bodyweightIsDefault)
    }

    func testNoProfileWeightScoresAt75AndSaysSo() {
        let computed = StrengthStrainIntegration.computed(for: workout([set()]), frozen: nil, profileKg: nil)
        XCTAssertEqual(computed.bodyweightKg, 75)
        XCTAssertTrue(computed.bodyweightIsDefault)
        for invalid in [0.0, -5, .nan, .infinity] {
            XCTAssertEqual(StrengthStrainIntegration.bodyweight(frozen: nil, profileKg: invalid),
                           LiftStrainFrozenBodyweight(kg: 75, isDefault: true), "\(invalid)")
        }
    }

    func testAProfileWeightIsUsedAndClamped() {
        XCTAssertEqual(StrengthStrainIntegration.bodyweight(frozen: nil, profileKg: 82),
                       LiftStrainFrozenBodyweight(kg: 82, isDefault: false))
        XCTAssertEqual(StrengthStrainIntegration.bodyweight(frozen: nil, profileKg: 10).kg, StrengthStrain.minBodyweightKg)
    }

    /// A lift frozen at the 75 kg default is rescored with the weight the person sets later.
    func testADefaultFrozenLiftTakesTheProfileWeightOnceSet() {
        let frozenDefault = LiftStrainFrozenBodyweight(kg: 75, isDefault: true)
        XCTAssertEqual(StrengthStrainIntegration.bodyweight(frozen: frozenDefault, profileKg: 90),
                       LiftStrainFrozenBodyweight(kg: 90, isDefault: false))
        XCTAssertEqual(StrengthStrainIntegration.bodyweight(frozen: frozenDefault, profileKg: nil), frozenDefault)
    }

    // MARK: Day key

    func testTheDayKeyIsTheLogicalDayIncludingTheEarlyMorning() throws {
        let calendar = Calendar.current
        let base = calendar.startOfDay(for: Date())
        let earlyMorning = try XCTUnwrap(calendar.date(bySettingHour: 2, minute: 30, second: 0, of: base))
        let afternoon = try XCTUnwrap(calendar.date(bySettingHour: 15, minute: 0, second: 0, of: base))

        let early = StrengthStrainIntegration.computed(for: workout([set()], start: earlyMorning), frozen: nil, profileKg: nil)
        let late = StrengthStrainIntegration.computed(for: workout([set()], start: afternoon), frozen: nil, profileKg: nil)

        XCTAssertEqual(early.dayKey, Repository.logicalDayKey(earlyMorning))
        XCTAssertEqual(late.dayKey, Repository.logicalDayKey(afternoon))
        XCTAssertEqual(late.dayKey, Repository.localDayKey(afternoon))
        let previous = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: base))
        XCTAssertEqual(early.dayKey, Repository.localDayKey(previous), "02:30 belongs to the previous logical day")
        XCTAssertEqual(early.workoutStartTs, Int(earlyMorning.timeIntervalSince1970))
        XCTAssertEqual(early.workoutSport, "Strength Training")
    }

    func testTheSkippedJSONIsStableAndSorted() {
        let sets = [set(warmup: true), set("Plank", equipment: "Bodyweight", muscle: "abs", secondary: [], kg: 0),
                    set(warmup: true)]
        let computed = StrengthStrainIntegration.computed(for: workout(sets), frozen: nil, profileKg: 80)
        XCTAssertEqual(computed.skippedJSON, #"{"isometric":1,"warmup":2}"#)
        XCTAssertEqual(StrengthStrainIntegration.skippedJSON([:]), "{}")
    }

    // MARK: Apply through the store

    func testImportedLiftingWorkoutsNeverGetRows() async throws {
        let store = try await WhoopStore.inMemory()
        let start = Fixtures.noon(daysAgo: 3)
        let lifts = [Fixtures.Lift(start: start)]
        try await Fixtures.seed(store, lifts: lifts)
        // A workout imported from a lifting log: same sport, other source, an hour later.
        let importedStart = Int(start.addingTimeInterval(7_200).timeIntervalSince1970)
        try await store.upsertWorkouts([WorkoutRow(
            startTs: importedStart, endTs: importedStart + 3_000, sport: "Strength Training", source: "lifting",
            durationS: 3_000, energyKcal: nil, avgHr: nil, maxHr: nil, strain: 12, distanceM: nil, zonesJSON: nil,
            notes: nil, strainVersion: nil)], deviceId: Fixtures.owner)
        let before = try await Fixtures.workoutBits(store, start: importedStart)

        let (engine, _) = await Fixtures.makeEngine(store: store)
        await engine.runStrengthStrainBackfillIfNeeded()

        let rowCount = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftStrain") ?? -1
        }
        XCTAssertEqual(rowCount, 1, "only the logged lift gets a row")
        let after = try await Fixtures.workoutBits(store, start: importedStart)
        XCTAssertEqual(after, before, "an imported lifting workout keeps its bits")
    }

    func testALiftWithNoSetsLeavesTheStoredBitsAlone() async throws {
        let store = try await WhoopStore.inMemory()
        let start = Fixtures.noon(daysAgo: 2)
        let lift = Fixtures.Lift(start: start, sets: 0, warmups: 2)
        let workouts = try await Fixtures.seed(store, lifts: [lift], workoutStrain: 31.25, dayStrain: 44.5)
        let startTs = Int(try XCTUnwrap(workouts.first).startedAt.timeIntervalSince1970)
        let day = Repository.logicalDayKey(start)
        let workoutBefore = try await Fixtures.workoutBits(store, start: startTs)
        let dayBefore = try await Fixtures.dayBits(store, day: day)

        let computed = StrengthStrainIntegration.computed(
            for: try XCTUnwrap(workouts.first), frozen: nil, profileKg: nil)
        XCTAssertEqual(computed.countedSets, 0)
        XCTAssertEqual(computed.muscularLoad, 0)
        try await store.upsertLiftStrainComputed(deviceId: Fixtures.owner, rows: [computed], now: 100)
        _ = try await store.applyLiftStrain(
            canonicalComputedDeviceId: Fixtures.canonical, now: 200, combine: StrengthStrainIntegration.combine)

        let workoutAfter = try await Fixtures.workoutBits(store, start: startTs)
        let dayAfter = try await Fixtures.dayBits(store, day: day)
        XCTAssertEqual(workoutAfter, workoutBefore)
        XCTAssertEqual(dayAfter, dayBefore)
    }

    func testALiftWithSetsCombinesTheWorkoutAndItsDay() async throws {
        let store = try await WhoopStore.inMemory()
        let start = Fixtures.noon(daysAgo: 2)
        let workouts = try await Fixtures.seed(store, lifts: [Fixtures.Lift(start: start)], workoutStrain: 30, dayStrain: 40)
        let workout = try XCTUnwrap(workouts.first)
        let computed = StrengthStrainIntegration.computed(for: workout, frozen: nil, profileKg: 80)
        XCTAssertGreaterThan(computed.muscularLoad, 0)
        try await store.upsertLiftStrainComputed(deviceId: Fixtures.owner, rows: [computed], now: 100)

        _ = try await store.applyLiftStrain(
            canonicalComputedDeviceId: Fixtures.canonical, now: 200, combine: StrengthStrainIntegration.combine)

        let startTs = Int(workout.startedAt.timeIntervalSince1970)
        let expectedWorkout = StrengthStrain.combine(hrStored: 30, muscularLoad: computed.muscularLoad)
        let expectedDay = StrengthStrain.combine(hrStored: 40, muscularLoad: computed.muscularLoad)
        let workoutBits = try await Fixtures.workoutBits(store, start: startTs)
        let dayBits = try await Fixtures.dayBits(store, day: computed.dayKey)
        XCTAssertEqual(workoutBits, Fixtures.Bits(expectedWorkout, 2))
        XCTAssertEqual(dayBits, Fixtures.Bits(expectedDay, 2))
    }

    #if DEBUG
    /// BF-3: the demo seeder applies real rows, so "Upper body A" goes from 47.6 stored (10.0) to 72.127996 (15.1).
    func testDemoSeedGives72Point127996() async throws {
        let store = try await WhoopStore.inMemory()
        let noon = Fixtures.noon(daysAgo: 0)
        await AppleDemoWorkoutFixture.seed(into: store, now: noon)

        let rows = try await store.workouts(deviceId: AppleDemoSeeder.whoop, from: 0, to: Int.max / 2, limit: 100)
        // Today's session is the newest Strength Training row (the older lifts are 8 and 12 days back).
        let strength = try XCTUnwrap(rows.filter { $0.sport == "Strength Training" }.max(by: { $0.startTs < $1.startTs }))
        XCTAssertEqual(try XCTUnwrap(strength.strain), 72.127996, accuracy: 1e-6)
        XCTAssertEqual(strength.strainVersion, 2)
        XCTAssertEqual(StrainScorerV2.displayValue(fromStored: 72.127996), 15.1, accuracy: 0.05)

        // A re-seed rebuilds the week; the base rule lands on the same bits.
        await AppleDemoWorkoutFixture.seed(into: store, now: noon)
        let again = try await store.workouts(deviceId: AppleDemoSeeder.whoop, from: 0, to: Int.max / 2, limit: 100)
        let second = try XCTUnwrap(again.first(where: { $0.startTs == strength.startTs && $0.sport == strength.sport }))
        XCTAssertEqual(second.strain?.bitPattern, strength.strain?.bitPattern)
    }
    #endif
}
