import XCTest
import WhoopStore
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
}
