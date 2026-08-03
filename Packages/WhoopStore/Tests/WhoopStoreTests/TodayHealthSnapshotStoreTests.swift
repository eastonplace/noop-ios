import XCTest
@testable import WhoopStore

final class TodayHealthSnapshotStoreTests: XCTestCase {
    private func daily(_ day: String, recovery: Double = 73, sleep: Double = 447) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: 0.91, deepMin: 92, remMin: 107,
                    lightMin: 248, disturbances: 4, restingHr: 51, avgHrv: 62,
                    recovery: recovery, strain: nil, exerciseCount: 1)
    }

    private func snapshot(scope: String = "dashboard:my-whoop", deviceId: String = "my-whoop",
                          day: String = "2026-08-03", generatedAt: Int = 1_754_208_000,
                          rawFrontierTs: Int? = 1_754_207_800, recovery: Double = 73,
                          strain: Double = 61, sleepScore: Double = 84) -> TodayHealthSnapshot {
        let metric = daily(day, recovery: recovery)
        return TodayHealthSnapshot(
            scopeId: scope, deviceId: deviceId, displayDay: day, logicalDay: day, localDay: day,
            generatedAt: generatedAt, rawFrontierTs: rawFrontierTs, dailyMetric: metric,
            recovery: TodayHealthMetricValue(value: recovery, sourceId: "my-whoop-noop",
                                              observedAt: generatedAt, rawFrontierTs: rawFrontierTs,
                                              algorithmVersion: "recovery-v1"),
            strain: TodayHealthMetricValue(value: strain, sourceId: "my-whoop-noop",
                                            observedAt: generatedAt, rawFrontierTs: rawFrontierTs,
                                            algorithmVersion: "strain-v2", strainVersion: 2),
            sleepScore: TodayHealthMetricValue(value: sleepScore, sourceId: "my-whoop-noop",
                                                observedAt: generatedAt, rawFrontierTs: rawFrontierTs,
                                                algorithmVersion: "sleep-performance-v2"),
            sleepDurationMinutes: TodayHealthMetricValue(value: metric.totalSleepMin ?? 0,
                                                          sourceId: "my-whoop-noop",
                                                          observedAt: generatedAt,
                                                          rawFrontierTs: rawFrontierTs,
                                                          algorithmVersion: "sleep-duration-v1")
        )
    }

    func testRoundTripsSingleScopedSnapshotWithMetricProvenance() async throws {
        let store = try await WhoopStore.inMemory()
        let expected = snapshot()

        let didSave = try await store.saveTodayHealthSnapshot(expected)
        let persisted = try await store.todayHealthSnapshot(scopeId: expected.scopeId)
        let loaded = try XCTUnwrap(persisted)

        XCTAssertTrue(didSave)
        XCTAssertEqual(loaded, expected)
        XCTAssertEqual(loaded.metric(.strain)?.value, 61)
        XCTAssertEqual(loaded.metric(.strain)?.strainVersion, 2)
        XCTAssertEqual(loaded.metric(.sleepScore)?.algorithmVersion, "sleep-performance-v2")
        let other = try await store.todayHealthSnapshot(scopeId: "dashboard:other-device")
        XCTAssertNil(other)
    }

    func testOlderOrLowerFrontierSnapshotCannotReplaceNewerEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let current = snapshot(generatedAt: 200, rawFrontierTs: 50, recovery: 82, strain: 76)
        let older = snapshot(generatedAt: 199, rawFrontierTs: 99, recovery: 20, strain: 8)
        let sameTimeLowerFrontier = snapshot(generatedAt: 200, rawFrontierTs: 49, recovery: 21, strain: 9)

        let savedCurrent = try await store.saveTodayHealthSnapshot(current)
        let savedOlder = try await store.saveTodayHealthSnapshot(older)
        let savedSameTimeLowerFrontier = try await store.saveTodayHealthSnapshot(sameTimeLowerFrontier)

        XCTAssertTrue(savedCurrent)
        XCTAssertFalse(savedOlder)
        XCTAssertFalse(savedSameTimeLowerFrontier)
        let persisted = try await store.todayHealthSnapshot(scopeId: current.scopeId)
        let loaded = try XCTUnwrap(persisted)
        XCTAssertEqual(loaded, current)
    }

    func testDeleteAllDataRemovesTheDeviceScopedSnapshot() async throws {
        let store = try await WhoopStore.inMemory()
        let expected = snapshot()
        let didSave = try await store.saveTodayHealthSnapshot(expected)
        XCTAssertTrue(didSave)

        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.deleteAllData(deviceId: expected.deviceId)

        let loaded = try await store.todayHealthSnapshot(scopeId: expected.scopeId)
        XCTAssertNil(loaded)
    }

    func testRejectsInvalidMetricEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let invalid = TodayHealthSnapshot(
            scopeId: "dashboard:my-whoop", deviceId: "my-whoop", displayDay: "2026-08-03",
            logicalDay: "2026-08-03", localDay: "2026-08-03", generatedAt: 1,
            dailyMetric: daily("2026-08-03"),
            recovery: TodayHealthMetricValue(value: 73, sourceId: "")
        )

        do {
            _ = try await store.saveTodayHealthSnapshot(invalid)
            XCTFail("invalid snapshot should be rejected")
        } catch {
            XCTAssertEqual(error as? TodayHealthSnapshotStoreError, .invalidSnapshot)
        }
    }
}
