import XCTest
@testable import WhoopStore

final class StrainV2StoreTests: XCTestCase {
    private func day(_ key: String, strain: Double, version: Int? = nil) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
                    lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil,
                    recovery: nil, strain: strain, exerciseCount: nil,
                    strainVersion: version)
    }

    private func workout(strain: Double, version: Int? = nil) -> WorkoutRow {
        WorkoutRow(startTs: 1_000, endTs: 2_000, sport: "run", source: "detected",
                   durationS: 1_000, energyKcal: nil, avgHr: 150, maxHr: 180,
                   strain: strain, distanceM: nil, zonesJSON: nil, notes: nil,
                   strainVersion: version)
    }

    func testProvenanceRoundTripsAndImportedDefaultsNil() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([day("2026-07-16", strain: 12)], deviceId: "my-whoop")
        try await store.upsertWorkouts([workout(strain: 9)], deviceId: "my-whoop")
        try await store.upsertDailyMetrics([day("2026-07-17", strain: 70, version: 2)],
                                           deviceId: "my-whoop-noop")
        try await store.upsertWorkouts([workout(strain: 13, version: 2)],
                                       deviceId: "my-whoop-noop")

        let importedDays = try await store.dailyMetrics(
            deviceId: "my-whoop", from: "2026-07-16", to: "2026-07-16")
        let importedWorkouts = try await store.workouts(
            deviceId: "my-whoop", from: 0, to: 3_000, limit: 10)
        let importedDay = try XCTUnwrap(importedDays.first)
        let importedWorkout = try XCTUnwrap(importedWorkouts.first)
        XCTAssertNil(importedDay.strainVersion)
        XCTAssertNil(importedWorkout.strainVersion)

        let computedDays = try await store.dailyMetrics(
            deviceId: "my-whoop-noop", from: "2026-07-17", to: "2026-07-17")
        let computedWorkouts = try await store.workouts(
            deviceId: "my-whoop-noop", from: 0, to: 3_000, limit: 10)
        let computedDay = try XCTUnwrap(computedDays.first)
        let computedWorkout = try XCTUnwrap(computedWorkouts.first)
        XCTAssertEqual(computedDay.strainVersion, 2)
        XCTAssertEqual(computedWorkout.strainVersion, 2)
    }

    func testShadowUpsertIsIdempotentAndDoesNotChangeCanonical() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([day("2026-07-17", strain: 42)],
                                           deviceId: "my-whoop-noop")
        let inserted = try await store.upsertStrainV2Shadow([
            DailyStrainV2Update(day: "2026-07-17", strain: 61)
        ], deviceId: "my-whoop-noop")
        let updated = try await store.upsertStrainV2Shadow([
            DailyStrainV2Update(day: "2026-07-17", strain: 63)
        ], deviceId: "my-whoop-noop")
        let unchanged = try await store.upsertStrainV2Shadow([
            DailyStrainV2Update(day: "2026-07-17", strain: 63)
        ], deviceId: "my-whoop-noop")

        XCTAssertEqual(inserted, 1)
        XCTAssertEqual(updated, 1)
        XCTAssertEqual(unchanged, 0)
        let canonicalDays = try await store.dailyMetrics(
            deviceId: "my-whoop-noop", from: "2026-07-17", to: "2026-07-17")
        let canonical = try XCTUnwrap(canonicalDays.first)
        XCTAssertEqual(canonical.strain, 42)
        XCTAssertNil(canonical.strainVersion)
    }

    func testCutoverIsAtomicIdempotentAndRemovesOnlyPromotedShadow() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([day("2026-07-17", strain: 42)],
                                           deviceId: "my-whoop-noop")
        try await store.upsertWorkouts([workout(strain: 8)], deviceId: "my-whoop-noop")
        try await store.upsertStrainV2Shadow([
            DailyStrainV2Update(day: "2026-07-17", strain: 63),
            DailyStrainV2Update(day: "2026-07-18", strain: 55),
        ], deviceId: "my-whoop-noop")

        let daily = [DailyStrainV2Update(day: "2026-07-17", strain: 63)]
        let workouts = [WorkoutStrainV2Update(startTs: 1_000, sport: "run", strain: 14)]
        let first = try await store.cutoverStrainV2(deviceId: "my-whoop-noop",
                                                    daily: daily, workouts: workouts)
        let second = try await store.cutoverStrainV2(deviceId: "my-whoop-noop",
                                                     daily: daily, workouts: workouts)

        let promotedDays = try await store.dailyMetrics(
            deviceId: "my-whoop-noop", from: "2026-07-17", to: "2026-07-17")
        let promotedWorkouts = try await store.workouts(
            deviceId: "my-whoop-noop", from: 0, to: 3_000, limit: 10)
        let promotedDay = try XCTUnwrap(promotedDays.first)
        let promotedWorkout = try XCTUnwrap(promotedWorkouts.first)
        XCTAssertEqual(promotedDay.strain, 63)
        XCTAssertEqual(promotedDay.strainVersion, 2)
        XCTAssertEqual(promotedWorkout.strain, 14)
        XCTAssertEqual(promotedWorkout.strainVersion, 2)

        XCTAssertEqual(first.shadowRowsRemoved, 1)
        XCTAssertEqual(second.shadowRowsRemoved, 0)
        let remaining = try await store.cutoverStrainV2(
            deviceId: "my-whoop-noop",
            daily: [DailyStrainV2Update(day: "2026-07-18", strain: 55)], workouts: [])
        XCTAssertEqual(remaining.dailyRows, 0)
        XCTAssertEqual(remaining.shadowRowsRemoved, 1)
    }

    func testLegacyRecomputeCannotUndoPromotedV2Rows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([day("2026-07-17", strain: 42)],
                                           deviceId: "my-whoop-noop")
        try await store.upsertWorkouts([workout(strain: 8)], deviceId: "my-whoop-noop")
        _ = try await store.cutoverStrainV2(
            deviceId: "my-whoop-noop",
            daily: [DailyStrainV2Update(day: "2026-07-17", strain: 63)],
            workouts: [WorkoutStrainV2Update(startTs: 1_000, sport: "run", strain: 14)])

        // A still-running V1 analytics pass carries no provenance. It may refresh every other
        // field, but it must not silently roll a promoted score back to V1.
        try await store.upsertDailyMetrics([day("2026-07-17", strain: 10)],
                                           deviceId: "my-whoop-noop")
        try await store.upsertWorkouts([workout(strain: 9)], deviceId: "my-whoop-noop")

        let persistedDays = try await store.dailyMetrics(
            deviceId: "my-whoop-noop", from: "2026-07-17", to: "2026-07-17")
        let persistedWorkouts = try await store.workouts(
            deviceId: "my-whoop-noop", from: 0, to: 3_000, limit: 10)
        let persistedDay = try XCTUnwrap(persistedDays.first)
        let persistedWorkout = try XCTUnwrap(persistedWorkouts.first)
        XCTAssertEqual(persistedDay.strain, 63)
        XCTAssertEqual(persistedDay.strainVersion, 2)
        XCTAssertEqual(persistedWorkout.strain, 14)
        XCTAssertEqual(persistedWorkout.strainVersion, 2)
    }

    func testCutoverRejectsImportedSourceAndPreservesRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDailyMetrics([day("2026-07-17", strain: 12)], deviceId: "my-whoop")

        do {
            _ = try await store.cutoverStrainV2(
                deviceId: "my-whoop",
                daily: [DailyStrainV2Update(day: "2026-07-17", strain: 99)], workouts: [])
            XCTFail("imported source cutover should fail")
        } catch {
            XCTAssertEqual(error as? StrainV2StoreError, .computedSourceRequired)
        }

        let importedDays = try await store.dailyMetrics(
            deviceId: "my-whoop", from: "2026-07-17", to: "2026-07-17")
        let imported = try XCTUnwrap(importedDays.first)
        XCTAssertEqual(imported.strain, 12)
        XCTAssertNil(imported.strainVersion)
    }
}
