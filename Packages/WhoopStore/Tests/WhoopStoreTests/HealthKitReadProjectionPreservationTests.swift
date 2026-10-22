import XCTest
@testable import WhoopStore

final class HealthKitReadProjectionPreservationTests: XCTestCase {
    private let day = "2026-10-20"
    private let start = 1_792_454_400

    private func daily(_ day: String, rhr: Int? = 52, hrv: Double? = 65) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 480, efficiency: nil, deepMin: 90, remMin: 90,
                    lightMin: 300, disturbances: nil, restingHr: rhr, avgHrv: hrv,
                    recovery: nil, strain: nil, exerciseCount: nil)
    }

    private func replace(_ store: WhoopStore, rows: [DailyMetric] = [],
                         points: [MetricPoint] = [], evidence: [HealthKitProjectionDeletion] = []) async throws {
        try await store.replaceAppleHealthRange(
            appleDaily: [], dailyMetrics: rows, metricPoints: points, workouts: [],
            deviceId: "apple-health", fromDay: day, toDay: "2026-10-21",
            fromTimestamp: start, toTimestamp: start + 2 * 86_400,
            preserveUnprovenEmptyReads: true, projectionDeletions: evidence)
    }

    func testEmptyHiddenReadsPreservePriorRowsAndSurviveReopenAndRetry() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-read-preservation-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try await WhoopStore(path: path)
        _ = try await store.upsertDailyMetrics([daily(day)], deviceId: "apple-health")
        _ = try await store.upsertMetricSeries([MetricPoint(day: day, key: "hrv", value: 65)], deviceId: "apple-health")
        try await replace(store)
        try await store.close()
        let reopened = try await WhoopStore(path: path)
        try await replace(reopened)
        let rows = try await reopened.dailyMetrics(deviceId: "apple-health", from: day, to: day)
        let points = try await reopened.metricSeries(deviceId: "apple-health", key: "hrv", from: day, to: day)
        XCTAssertEqual(rows.first?.avgHrv, 65)
        XCTAssertEqual(rows.first?.totalSleepMin, 480)
        XCTAssertEqual(points.first?.value, 65)
        try await reopened.close()
    }

    func testPartialReadsUpdatePresentTypeWithoutErasingHiddenType() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertDailyMetrics([daily(day)], deviceId: "apple-health")
        try await replace(store, rows: [DailyMetric(day: day, totalSleepMin: nil, efficiency: nil,
            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil, restingHr: 49, avgHrv: nil,
            recovery: nil, strain: nil, exerciseCount: nil)])
        let rows = try await store.dailyMetrics(deviceId: "apple-health", from: day, to: day)
        XCTAssertEqual(rows.first?.restingHr, 49)
        XCTAssertEqual(rows.first?.avgHrv, 65)
        XCTAssertEqual(rows.first?.totalSleepMin, 480)
    }

    func testAnchoredDeletionClearsOnlyItsTypeAndDaysAndPreservesOtherOwner() async throws {
        let store = try await WhoopStore.inMemory()
        for owner in ["apple-health", "whoop"] {
            _ = try await store.upsertDailyMetrics([daily(day), daily("2026-10-21")], deviceId: owner)
            _ = try await store.upsertMetricSeries([MetricPoint(day: day, key: "hrv", value: 65),
                MetricPoint(day: day, key: "resting_hr", value: 52)], deviceId: owner)
        }
        let evidence = HealthKitProjectionDeletion(sampleType: "HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
            fromDay: day, toDay: day, fromTimestamp: start, toTimestamp: start + 86_399)
        try await replace(store, evidence: [evidence])
        try await replace(store, evidence: [evidence])
        let rows = try await store.dailyMetrics(deviceId: "apple-health", from: day, to: "2026-10-21")
        XCTAssertNil(rows.first?.avgHrv)
        XCTAssertEqual(rows.first?.restingHr, 52)
        XCTAssertEqual(rows.last?.avgHrv, 65)
        let hrv = try await store.metricSeries(deviceId: "apple-health", key: "hrv", from: day, to: day)
        XCTAssertTrue(hrv.isEmpty)
        let whoop = try await store.dailyMetrics(deviceId: "whoop", from: day, to: day)
        XCTAssertEqual(whoop.first?.avgHrv, 65)
    }

    func testHiddenActivityAndWorkoutsRemainUntilExactWorkoutDeletionEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertAppleDaily([AppleDaily(day: day, steps: 8000,
            activeKcal: 400, basalKcal: nil, vo2max: nil, avgHr: nil, maxHr: nil,
            walkingHr: nil, weightKg: 80)], deviceId: "apple-health")
        func workout(_ timestamp: Int, source: String = "apple-health") -> WorkoutRow {
            WorkoutRow(startTs: timestamp, endTs: timestamp + 3600, sport: "Running", source: source,
                durationS: 3600, energyKcal: 400, avgHr: 140, maxHr: 160, strain: nil,
                distanceM: 5000, zonesJSON: nil, notes: nil)
        }
        _ = try await store.upsertWorkouts([workout(start + 3600), workout(start + 86_400),
            workout(start + 10_800, source: "manual")], deviceId: "apple-health")
        try await replace(store)
        let activity = try await store.appleDaily(deviceId: "apple-health", from: day, to: day)
        XCTAssertEqual(activity.first?.steps, 8000)
        XCTAssertEqual(activity.first?.weightKg, 80)
        let before = try await store.workouts(deviceId: "apple-health", from: start,
                                              to: start + 2 * 86_400, limit: 10)
        XCTAssertEqual(before.count, 3)
        try await store.upsertHealthKitObjectIdentities([
            .init(sampleType: "HKWorkoutTypeIdentifier", objectUUID: "deleted-workout",
                  startTs: start + 3600, endTs: start + 7200)
        ], deviceId: "apple-health")
        try await replace(store, evidence: [HealthKitProjectionDeletion(
            sampleType: "HKWorkoutTypeIdentifier", fromDay: day, toDay: day,
            fromTimestamp: start + 3600, toTimestamp: start + 7200)])
        let after = try await store.workouts(deviceId: "apple-health", from: start,
                                             to: start + 2 * 86_400, limit: 10)
        XCTAssertEqual(after.count, 2)
        XCTAssertTrue(after.contains { $0.source == "manual" })
        XCTAssertTrue(after.contains { $0.startTs == start + 86_400 })
    }

    func testOverlappingWorkoutSurvivesHiddenReadTombstoneRetryAndReopen() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-workout-overlap-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try await WhoopStore(path: path)
        let first = start + 10 * 3600, second = first + 1800
        func workout(_ timestamp: Int) -> WorkoutRow {
            WorkoutRow(startTs: timestamp, endTs: timestamp + 3600, sport: "Running", source: "apple-health",
                durationS: 3600, energyKcal: 400, avgHr: 140, maxHr: 160, strain: nil,
                distanceM: 5000, zonesJSON: nil, notes: nil)
        }
        _ = try await store.upsertWorkouts([workout(first), workout(second)], deviceId: "apple-health")
        try await store.upsertHealthKitObjectIdentities([
            .init(sampleType: "HKWorkoutTypeIdentifier", objectUUID: "deleted-a", startTs: first, endTs: first + 3600),
            .init(sampleType: "HKWorkoutTypeIdentifier", objectUUID: "surviving-b", startTs: second, endTs: second + 3600)
        ], deviceId: "apple-health")
        let tombstone = HealthKitProjectionDeletion(sampleType: "HKWorkoutTypeIdentifier",
            fromDay: day, toDay: day, fromTimestamp: first, toTimestamp: first + 3600)
        try await replace(store, evidence: [tombstone])
        let after = try await store.workouts(deviceId: "apple-health", from: start,
                                             to: start + 2 * 86_400, limit: 10)
        XCTAssertEqual(after.map(\.startTs), [second])
        try await store.close()
        let reopened = try await WhoopStore(path: path)
        try await replace(reopened, evidence: [tombstone])
        let replayed = try await reopened.workouts(deviceId: "apple-health", from: start,
                                                  to: start + 2 * 86_400, limit: 10)
        XCTAssertEqual(replayed.map(\.startTs), [second])
        try await reopened.close()
    }

    func testUnindexedOrAmbiguousWorkoutStartCannotAuthorizeClearing() async throws {
        for indexedObjects in [0, 2] {
            let store = try await WhoopStore.inMemory()
            let timestamp = start + 10 * 3600
            _ = try await store.upsertWorkouts([WorkoutRow(startTs: timestamp, endTs: timestamp + 3600,
                sport: "Running", source: "apple-health", durationS: 3600, energyKcal: nil,
                avgHr: nil, maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)],
                deviceId: "apple-health")
            try await store.upsertHealthKitObjectIdentities((0..<indexedObjects).map {
                .init(sampleType: "HKWorkoutTypeIdentifier", objectUUID: "ambiguous-\($0)",
                      startTs: timestamp, endTs: timestamp + 3600)
            }, deviceId: "apple-health")
            let evidence = HealthKitProjectionDeletion(sampleType: "HKWorkoutTypeIdentifier",
                fromDay: day, toDay: day, fromTimestamp: timestamp, toTimestamp: timestamp + 3600)
            try await replace(store, evidence: [evidence])
            let rows = try await store.workouts(deviceId: "apple-health", from: start,
                                                to: start + 2 * 86_400, limit: 10)
            XCTAssertEqual(rows.count, 1, "Indexed objects: \(indexedObjects)")
        }
    }

    func testAmbiguousSleepTombstonePreservesAdjacentBankedNightsOnHiddenReadReplay() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-sleep-tombstone-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let store = try await WhoopStore(path: path)
        let days = [day, "2026-10-21", "2026-10-22"]
        _ = try await store.upsertDailyMetrics(days.map { daily($0) }, deviceId: "apple-health")
        _ = try await store.upsertMetricSeries(days.map { MetricPoint(day: $0, key: "asleep_min", value: 480) },
                                               deviceId: "apple-health")
        // Compatibility with a queued broad range: stage timestamps do not prove an episode's
        // reduced wake-day contribution, nor anything about the adjacent banked nights.
        let evidence = HealthKitProjectionDeletion(sampleType: "HKCategoryTypeIdentifierSleepAnalysis",
            fromDay: "2026-10-19", toDay: "2026-10-22",
            fromTimestamp: start + 22 * 3600, toTimestamp: start + 30 * 3600)
        func hiddenRead(_ target: WhoopStore) async throws {
            try await target.replaceAppleHealthRange(appleDaily: [], dailyMetrics: [], metricPoints: [],
                workouts: [], deviceId: "apple-health", fromDay: day, toDay: "2026-10-22",
                fromTimestamp: start, toTimestamp: start + 3 * 86_400,
                preserveUnprovenEmptyReads: true, projectionDeletions: [evidence])
        }
        try await hiddenRead(store)
        try await store.close()
        let reopened = try await WhoopStore(path: path)
        try await hiddenRead(reopened)
        let rows = try await reopened.dailyMetrics(deviceId: "apple-health", from: day, to: "2026-10-22")
        XCTAssertEqual(rows.map(\.totalSleepMin), [480, 480, 480])
        let points = try await reopened.metricSeries(deviceId: "apple-health", key: "asleep_min",
                                                     from: day, to: "2026-10-22")
        XCTAssertEqual(points.map(\.value), [480, 480, 480])
        try await reopened.close()
    }
}
