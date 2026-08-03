import XCTest
import WhoopStore
import WhoopProtocol
@testable import NOOP

@MainActor
final class TodayHealthSnapshotHydrationTests: XCTestCase {
    private func daily(_ day: String) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 442, efficiency: 0.91, deepMin: 90, remMin: 108,
                    lightMin: 244, disturbances: 3, restingHr: 52, avgHrv: 63,
                    recovery: 78, strain: nil, exerciseCount: 1)
    }

    func testHydratesOneStoredSnapshotWithoutPublishingTheBroadCache() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let logicalDay = Repository.logicalDayKey(now)
        let localDay = Repository.localDayKey(now)
        let row = daily(logicalDay)
        let snapshot = TodayHealthSnapshot(
            scopeId: "dashboard:\(Repository.whoopSource)", deviceId: Repository.whoopSource,
            displayDay: logicalDay, logicalDay: logicalDay, localDay: localDay,
            generatedAt: Int(now.timeIntervalSince1970), dailyMetric: row,
            recovery: TodayHealthMetricValue(value: 78, sourceId: "my-whoop-noop",
                                              algorithmVersion: "recovery-v1"),
            strain: TodayHealthMetricValue(value: 64, sourceId: "my-whoop-noop",
                                            algorithmVersion: "strain-v2", strainVersion: 2),
            sleepScore: TodayHealthMetricValue(value: 85, sourceId: "my-whoop-noop",
                                                algorithmVersion: "sleep-performance-v2"),
            sleepDurationMinutes: TodayHealthMetricValue(value: 442, sourceId: "my-whoop-noop",
                                                          algorithmVersion: "sleep-duration-v1")
        )
        _ = try await store.saveTodayHealthSnapshot(snapshot)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        await repository.hydrateTodayHealthSnapshot()

        XCTAssertEqual(repository.todayHealthSnapshot, snapshot)
        XCTAssertEqual(repository.canonicalStrain(for: logicalDay)?.storedValue, 64)
        XCTAssertFalse(repository.loaded)
        XCTAssertTrue(repository.days.isEmpty)
        XCTAssertEqual(repository.refreshSeq, 0)
    }

    func testLegacySnapshotRepairsStrainFromExactDayComputedV2Row() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let logicalDay = Repository.logicalDayKey(now)
        let localDay = Repository.localDayKey(now)
        let stale = TodayHealthSnapshot(
            scopeId: "dashboard:\(Repository.whoopSource)", deviceId: Repository.whoopSource,
            displayDay: logicalDay, logicalDay: logicalDay, localDay: localDay,
            generatedAt: Int(now.timeIntervalSince1970) - 1, rawFrontierTs: 1_000,
            schemaVersion: 1, dailyMetric: daily(logicalDay),
            recovery: TodayHealthMetricValue(value: 78, sourceId: "my-whoop-noop",
                                              algorithmVersion: "recovery-v1"),
            strain: TodayHealthMetricValue(value: 0, sourceId: "my-whoop-noop",
                                            rawFrontierTs: 1_000, algorithmVersion: "strain-v2",
                                            strainVersion: 2),
            sleepScore: TodayHealthMetricValue(value: 85, sourceId: "my-whoop-noop",
                                                algorithmVersion: "sleep-performance-v2"),
            sleepDurationMinutes: TodayHealthMetricValue(value: 442, sourceId: "my-whoop-noop",
                                                          algorithmVersion: "sleep-duration-v1")
        )
        _ = try await store.saveTodayHealthSnapshot(stale)
        try await store.upsertDailyMetrics([
            daily(logicalDay).replacing(strain: .some(64), strainVersion: .some(2))
        ], deviceId: Repository.whoopSource + "-noop")

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        await repository.hydrateTodayHealthSnapshot()

        XCTAssertEqual(repository.todayHealthSnapshot?.strain?.value, 64)
        XCTAssertEqual(repository.todayHealthSnapshot?.dailyMetric.strain, 64)
        XCTAssertEqual(repository.todayHealthSnapshot?.schemaVersion, TodayHealthSnapshot.currentSchemaVersion)
        let saved = try await store.todayHealthSnapshot(scopeId: "dashboard:\(Repository.whoopSource)")
        XCTAssertEqual(saved?.strain?.value, 64)
        XCTAssertEqual(saved?.schemaVersion, TodayHealthSnapshot.currentSchemaVersion)
    }

    func testLoadedCanonicalStrainOverridesAnOlderFirstPaintSnapshot() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let logicalDay = Repository.logicalDayKey(now)
        let localDay = Repository.localDayKey(now)
        let snapshot = TodayHealthSnapshot(
            scopeId: "dashboard:\(Repository.whoopSource)", deviceId: Repository.whoopSource,
            displayDay: logicalDay, logicalDay: logicalDay, localDay: localDay,
            generatedAt: Int(now.timeIntervalSince1970), dailyMetric: daily(logicalDay),
            recovery: TodayHealthMetricValue(value: 78, sourceId: "my-whoop-noop",
                                              algorithmVersion: "recovery-v1"),
            strain: TodayHealthMetricValue(value: 0, sourceId: "my-whoop-noop",
                                            rawFrontierTs: 1_000, algorithmVersion: "strain-v2",
                                            strainVersion: 2),
            sleepScore: TodayHealthMetricValue(value: 85, sourceId: "my-whoop-noop",
                                                algorithmVersion: "sleep-performance-v2"),
            sleepDurationMinutes: TodayHealthMetricValue(value: 442, sourceId: "my-whoop-noop",
                                                          algorithmVersion: "sleep-duration-v1")
        )
        _ = try await store.saveTodayHealthSnapshot(snapshot)
        try await store.upsertDailyMetrics([
            daily(logicalDay).replacing(strain: .some(64), strainVersion: .some(2))
        ], deviceId: Repository.whoopSource + "-noop")

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        await repository.hydrateTodayHealthSnapshot()
        XCTAssertEqual(repository.canonicalStrain(for: logicalDay)?.storedValue, 0)

        let refreshed = await repository.refresh(days: 120)
        XCTAssertTrue(refreshed)
        XCTAssertTrue(repository.loaded)
        XCTAssertEqual(repository.todayHealthSnapshot?.strain?.value, 0,
                       "The stale snapshot remains protected until its producer has a newer raw frontier.")
        XCTAssertEqual(repository.canonicalStrain(for: logicalDay)?.storedValue, 64)
    }

    func testColdLaunchLiveStrainCannotReplaceSnapshotBeforeInitialCacheLoads() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let logicalDay = Repository.logicalDayKey(now)
        let localDay = Repository.localDayKey(now)
        let snapshot = TodayHealthSnapshot(
            scopeId: "dashboard:\(Repository.whoopSource)", deviceId: Repository.whoopSource,
            displayDay: logicalDay, logicalDay: logicalDay, localDay: localDay,
            generatedAt: Int(now.timeIntervalSince1970), dailyMetric: daily(logicalDay),
            recovery: TodayHealthMetricValue(value: 78, sourceId: "my-whoop-noop",
                                              algorithmVersion: "recovery-v1"),
            strain: TodayHealthMetricValue(value: 64, sourceId: "my-whoop-noop",
                                            algorithmVersion: "strain-v2", strainVersion: 2),
            sleepScore: TodayHealthMetricValue(value: 85, sourceId: "my-whoop-noop",
                                                algorithmVersion: "sleep-performance-v2"),
            sleepDurationMinutes: TodayHealthMetricValue(value: 442, sourceId: "my-whoop-noop",
                                                          algorithmVersion: "sleep-duration-v1")
        )
        _ = try await store.saveTodayHealthSnapshot(snapshot)
        let nowTs = Int(now.timeIntervalSince1970)
        try await store.insert(
            Streams(hr: (0..<21).map { HRSample(ts: nowTs - (20 - $0) * 30, bpm: 90) }),
            deviceId: Repository.whoopSource
        )

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        await repository.hydrateTodayHealthSnapshot()
        await repository.refreshLiveDayStrain(maxHR: 184, now: now)

        XCTAssertFalse(repository.loaded)
        XCTAssertNil(repository.liveDayStrain)
        XCTAssertEqual(repository.todayHealthSnapshot?.strain?.value, 64)
        XCTAssertEqual(repository.canonicalStrain(for: logicalDay)?.storedValue, 64)
    }
}
