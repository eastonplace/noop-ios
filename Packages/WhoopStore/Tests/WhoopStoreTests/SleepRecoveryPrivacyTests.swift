import XCTest
@testable import WhoopStore

final class SleepRecoveryPrivacyTests: XCTestCase {
    func testDeleteAllDataRemovesRecoveryRowsWithoutTriggerResurrection() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "my-whoop-noop"
        let session = CachedSleepSession(
            startTs: 1_000,
            endTs: 5_000,
            efficiency: 0.88,
            restingHr: 50,
            avgHrv: 64,
            stagesJSON: "[{\"start\":1000,\"end\":5000,\"stage\":\"light\"}]",
            userEdited: true)
        let audit = SleepRecoveryAuditRecord(
            id: "privacy",
            source: "manual_window",
            requestedStartTs: 1_000,
            requestedEndTs: 5_000,
            outcome: "complete",
            confidence: 0.8,
            reason: "bounded_reanalysis",
            resultStartTs: 1_000,
            resultEndTs: 5_000,
            stagesAvailable: true,
            restingHr: 50,
            avgHrv: 64,
            algorithmVersion: "sleep-window-recovery-v1",
            createdAt: 10_000,
            updatedAt: 10_000)
        let daily = DailyMetric(
            day: "2026-07-26",
            totalSleepMin: 420,
            efficiency: 0.88,
            deepMin: 70,
            remMin: 90,
            lightMin: 260,
            disturbances: 3,
            restingHr: 50,
            avgHrv: 64,
            recovery: 77,
            strain: 20,
            exerciseCount: 1,
            steps: 8_000,
            strainVersion: 2)
        let override = SleepRecoveryDailyOverride(
            day: daily.day,
            sessionStartTs: session.startTs,
            totalSleepMin: daily.totalSleepMin,
            efficiency: daily.efficiency,
            deepMin: daily.deepMin,
            remMin: daily.remMin,
            lightMin: daily.lightMin,
            disturbances: daily.disturbances,
            restingHr: daily.restingHr,
            avgHrv: daily.avgHrv,
            recovery: daily.recovery,
            restScore: 88,
            updatedAt: 10_000)

        _ = try await store.replaceWithManualSleepRecovery(
            session,
            deviceId: device,
            audit: audit,
            dailyOverride: override,
            daily: daily)

        try DeviceRegistryStore(dbQueue: store.registryWriter).deleteAllData(deviceId: device)

        XCTAssertTrue(try await store.sleepSessions(deviceId: device, from: 0, to: 10_000, limit: 10).isEmpty)
        XCTAssertTrue(try await store.dailyMetrics(deviceId: device, from: "0000-01-01", to: "9999-12-31").isEmpty)
        XCTAssertTrue(try await store.metricSeries(
            deviceId: device, key: "sleep_performance",
            from: "0000-01-01", to: "9999-12-31").isEmpty)
        XCTAssertTrue(try await store.sleepRecoveryAttempts(deviceId: device).isEmpty)
        XCTAssertTrue(try await store.sleepRecoveryDailyOverrides(deviceId: device).isEmpty)
    }
}
