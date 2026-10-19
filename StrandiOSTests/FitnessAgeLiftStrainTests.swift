import Foundation
import StrandAnalytics
import WhoopProtocol
import WhoopStore
import XCTest
@testable import NOOP

/// DS-R2-3: Fitness Age and VO2max read heart-rate Strain only. A lift day whose stored Strain Strength Strain has
/// raised past the active-day line still feeds them the value its heart rate produced, in both the analysis pass
/// and `recomputeFitnessAgeOnly`, because both read the same overlay.
@MainActor
final class FitnessAgeLiftStrainTests: XCTestCase {

    private typealias Fixtures = StrengthStrainFixtures

    private func rows(_ days: [DailyMetric]) -> [MetricPoint] {
        IntelligenceEngine.fitnessAgeRows(
            gateDays: days.sorted { $0.day < $1.day }.suffix(7).map { $0 }, age: 35, sex: "male", waistCm: 80,
            heightCm: 180, weightKg: 80, computedId: Fixtures.canonical, satKey: "2026-10-17")
    }

    func testPassAndRecomputeAgreeOnALiftDay() async throws {
        let store = try await WhoopStore.inMemory()
        try Fixtures.register(store, ids: [Fixtures.owner])
        let dayKeys = (1...8).map { Repository.localDayKey(Fixtures.noon(daysAgo: $0)) }
        try await store.upsertDailyMetrics(dayKeys.enumerated().map { index, day in
            Fixtures.dailyMetric(day, strain: 25, restingHr: 50 + index % 3)
        }, deviceId: Fixtures.canonical)
        let lift = Fixtures.Lift(start: Fixtures.noon(daysAgo: 2), kg: 100, sets: 6)
        let workouts = try await Fixtures.seed(store, lifts: [lift], workoutStrain: 30, dayStrain: nil)
        let liftDay = Repository.logicalDayKey(try XCTUnwrap(workouts.first).startedAt)
        XCTAssertTrue(dayKeys.contains(liftDay))

        let (engine, _) = Fixtures.makeEngine(store: store)
        let from = dayKeys.min() ?? "", to = dayKeys.max() ?? ""
        let beforeDays = try await store.dailyMetrics(deviceId: Fixtures.canonical, from: from, to: to)
        let before = rows(beforeDays)
        XCTAssertFalse(before.isEmpty, "the fixture must be Fitness-Age ready or the test proves nothing")

        await engine.runStrengthStrainBackfillIfNeeded()
        let afterDays = try await store.dailyMetrics(deviceId: Fixtures.canonical, from: from, to: to)
        let lifted = try XCTUnwrap(afterDays.first { $0.day == liftDay }?.strain)
        XCTAssertGreaterThan(lifted, 30, "the backfill must push the lift day across the active-day line")
        XCTAssertNotEqual(rows(afterDays), before, "unguarded, the lift would change Fitness Age")

        // The overlay the pass and the recompute both read gives back the heart-rate value.
        let overlaid = await engine.liftStrainHROnlyForFitnessAge(afterDays, fromDay: from, toDay: to)
        XCTAssertEqual(overlaid.first { $0.day == liftDay }?.strain?.bitPattern, Double(25).bitPattern)
        XCTAssertEqual(rows(overlaid), before)

        // A day the person's heart rate rescored since is no longer the lift's value: it is left alone.
        try await store.upsertDailyMetrics(
            [Fixtures.dailyMetric(liftDay, strain: 61.5, restingHr: 50)], deviceId: Fixtures.canonical)
        let rescored = try await store.dailyMetrics(deviceId: Fixtures.canonical, from: from, to: to)
        let kept = await engine.liftStrainHROnlyForFitnessAge(rescored, fromDay: from, toDay: to)
        XCTAssertEqual(kept.first { $0.day == liftDay }?.strain?.bitPattern, Double(61.5).bitPattern)
    }
}
