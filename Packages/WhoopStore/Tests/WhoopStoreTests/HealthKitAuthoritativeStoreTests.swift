import XCTest
@testable import WhoopStore

final class HealthKitAuthoritativeStoreTests: XCTestCase {
    func testObjectIndexRetainsHistoricalWindowUnionAcrossCorrections() async throws {
        let store = try await WhoopStore.inMemory()
        let original = HealthKitObjectIdentity(
            sampleType: "HKQuantityTypeIdentifierHeartRate",
            objectUUID: "sample-1",
            startTs: 1_700_000_000,
            endTs: 1_700_000_060
        )
        try await store.upsertHealthKitObjectIdentities([original], deviceId: "apple-health")
        let indexedOriginal = try await store.healthKitObjectIdentities(
            sampleType: original.sampleType,
            objectUUIDs: [original.objectUUID],
            deviceId: "apple-health"
        )
        XCTAssertEqual(indexedOriginal, [original])

        let corrected = HealthKitObjectIdentity(
            sampleType: original.sampleType,
            objectUUID: original.objectUUID,
            startTs: 1_700_086_400,
            endTs: 1_700_086_460
        )
        try await store.upsertHealthKitObjectIdentities([corrected], deviceId: "apple-health")
        let indexedCorrected = try await store.healthKitObjectIdentities(
            sampleType: original.sampleType,
            objectUUIDs: [original.objectUUID],
            deviceId: "apple-health"
        )
        XCTAssertEqual(indexedCorrected, [HealthKitObjectIdentity(
            sampleType: original.sampleType,
            objectUUID: original.objectUUID,
            startTs: original.startTs,
            endTs: corrected.endTs
        )])
    }

    func testObjectIndexChunksMassDeletionLookupsAndPreservesDuplicateRequests() async throws {
        let store = try await WhoopStore.inMemory()
        let sampleType = "HKQuantityTypeIdentifierHeartRate"
        let identities = (0..<1_205).map { index in
            HealthKitObjectIdentity(
                sampleType: sampleType,
                objectUUID: "sample-\(index)",
                startTs: 1_700_000_000 + index,
                endTs: 1_700_000_001 + index
            )
        }
        try await store.upsertHealthKitObjectIdentities(identities, deviceId: "apple-health")
        let requested = identities.map(\.objectUUID) + [identities[0].objectUUID, "unknown"]

        let loaded = try await store.healthKitObjectIdentities(
            sampleType: sampleType,
            objectUUIDs: requested,
            deviceId: "apple-health"
        )

        XCTAssertEqual(loaded.count, identities.count + 1)
        XCTAssertEqual(loaded.first, identities[0])
        XCTAssertEqual(loaded[identities.count], identities[0])
    }

    func testEarliestAppleHealthTimestampIncludesHyphenatedWorkoutSource() async throws {
        let store = try await WhoopStore.inMemory()
        let start = 1_700_000_000
        _ = try await store.upsertWorkouts([WorkoutRow(
            startTs: start,
            endTs: start + 3_600,
            sport: "Running",
            source: "apple-health",
            durationS: 3_600,
            energyKcal: 400,
            avgHr: 140,
            maxHr: 168,
            strain: nil,
            distanceM: 8_000,
            zonesJSON: nil,
            notes: nil
        )], deviceId: "apple-health")

        let earliest = try await store.earliestAppleHealthTimestamp(deviceId: "apple-health")
        XCTAssertEqual(earliest, start)
    }

    func testEmptyAuthoritativeWindowRetractsAppleRowsAndWorkouts() async throws {
        let store = try await WhoopStore.inMemory()
        let day = "2026-07-20"
        let workout = WorkoutRow(
            startTs: 1_753_000_000, endTs: 1_753_003_600, sport: "Running", source: "apple-health",
            durationS: 3_600, energyKcal: 400, avgHr: 140, maxHr: 168, strain: nil, distanceM: 8_000,
            zonesJSON: nil, notes: nil
        )
        let daily = DailyMetric(
            day: day, totalSleepMin: 440, efficiency: nil, deepMin: 80, remMin: 90, lightMin: 270,
            disturbances: nil, restingHr: 52, avgHrv: 62, recovery: nil, strain: nil, exerciseCount: nil
        )
        try await store.replaceAppleHealthRange(
            appleDaily: [AppleDaily(day: day, steps: 8_000, activeKcal: 400, basalKcal: nil, vo2max: nil,
                                    avgHr: 140, maxHr: 168, walkingHr: nil, weightKg: nil)],
            dailyMetrics: [daily], metricPoints: [MetricPoint(day: day, key: "steps", value: 8_000)],
            workouts: [workout], deviceId: "apple-health", fromDay: day, toDay: day,
            fromTimestamp: workout.startTs, toTimestamp: workout.endTs, workoutSource: "apple-health"
        )

        try await store.replaceAppleHealthRange(
            appleDaily: [], dailyMetrics: [], metricPoints: [], workouts: [], deviceId: "apple-health",
            fromDay: day, toDay: day, fromTimestamp: workout.startTs, toTimestamp: workout.endTs,
            workoutSource: "apple-health"
        )
        let appleRows = try await store.appleDaily(deviceId: "apple-health", from: day, to: day)
        let dailyRows = try await store.dailyMetrics(deviceId: "apple-health", from: day, to: day)
        let points = try await store.metricSeries(deviceId: "apple-health", key: "steps", from: day, to: day)
        let workouts = try await store.workouts(
            deviceId: "apple-health", from: workout.startTs, to: workout.endTs, limit: 10
        )
        XCTAssertTrue(appleRows.isEmpty)
        XCTAssertTrue(dailyRows.isEmpty)
        XCTAssertTrue(points.isEmpty)
        XCTAssertTrue(workouts.isEmpty)
    }
}
