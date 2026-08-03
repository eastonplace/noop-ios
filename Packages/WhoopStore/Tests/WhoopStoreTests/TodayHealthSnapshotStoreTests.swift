import XCTest
@testable import WhoopStore

final class TodayHealthSnapshotStoreTests: XCTestCase {
    private func context(for store: WhoopStore) async throws -> TodayHealthSnapshotContext {
        TodayHealthSnapshotContext(
            databaseInstanceId: try await store.todayHealthSnapshotDatabaseInstanceId(),
            dashboardProfileId: "dashboard:my-whoop",
            sourceLineage: "my-whoop,my-whoop-noop",
            algorithmBundleVersion: "today-health-v3|strain-v2|sleep-performance-v2"
        )
    }

    private func daily(_ day: String, recovery: Double = 73, strain: Double = 61,
                       sleep: Double = 447) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: 0.91, deepMin: 92, remMin: 107,
                    lightMin: 248, disturbances: 4, restingHr: 51, avgHrv: 62,
                    recovery: recovery, strain: strain, exerciseCount: 1, strainVersion: 2)
    }

    private func snapshot(
        context: TodayHealthSnapshotContext,
        day: String = "2026-08-03",
        generatedAt: Int = 1_754_208_000,
        rawFrontierTs: Int? = 1_754_207_800,
        recovery: Double = 73,
        strain: Double = 61,
        sleepScore: Double = 84
    ) -> TodayHealthSnapshot {
        let metric = daily(day, recovery: recovery, strain: strain)
        return TodayHealthSnapshot(
            scopeId: "dashboard:my-whoop|\(context.identifier)", context: context, deviceId: "my-whoop",
            displayDay: day, logicalDay: day, localDay: day, generatedAt: generatedAt,
            rawFrontierTs: rawFrontierTs,
            authoritativeMetrics: [.recovery, .strain, .sleepScore, .sleepDurationMinutes],
            dailyMetric: metric,
            recovery: TodayHealthMetricValue(value: recovery, metricDay: day, sourceId: "my-whoop-noop",
                                              observedAt: generatedAt, rawFrontierTs: rawFrontierTs,
                                              algorithmVersion: "daily-recovery-v1"),
            strain: TodayHealthMetricValue(value: strain, metricDay: day, sourceId: "my-whoop-noop",
                                            observedAt: generatedAt, rawFrontierTs: rawFrontierTs,
                                            algorithmVersion: "strain-v2-daily", strainVersion: 2),
            sleepScore: TodayHealthMetricValue(value: sleepScore, metricDay: day, sourceId: "my-whoop-noop",
                                                observedAt: generatedAt, rawFrontierTs: rawFrontierTs,
                                                algorithmVersion: "sleep-performance-v1"),
            sleepDurationMinutes: TodayHealthMetricValue(value: metric.totalSleepMin ?? 0, metricDay: day,
                                                          sourceId: "my-whoop-noop", observedAt: generatedAt,
                                                          rawFrontierTs: rawFrontierTs,
                                                          algorithmVersion: "daily-sleep-duration-v1")
        )
    }

    func testRoundTripsSingleContextScopedSnapshotWithMetricProvenance() async throws {
        let store = try await WhoopStore.inMemory()
        let expected = snapshot(context: try await context(for: store))

        let didSave = try await store.saveTodayHealthSnapshot(expected)
        let persisted = try await store.todayHealthSnapshot(scopeId: expected.scopeId)
        let loaded = try XCTUnwrap(persisted)

        XCTAssertTrue(didSave)
        XCTAssertEqual(loaded.scopeId, expected.scopeId)
        XCTAssertEqual(loaded.generatedAt, expected.generatedAt)
        XCTAssertEqual(loaded.generation, 1)
        XCTAssertEqual(loaded.recovery?.value, expected.recovery?.value)
        XCTAssertEqual(loaded.recovery?.generation, 1)
        XCTAssertEqual(loaded.strain?.value, expected.strain?.value)
        XCTAssertEqual(loaded.strain?.generation, 1)
        XCTAssertEqual(loaded.sleepScore?.value, expected.sleepScore?.value)
        XCTAssertEqual(loaded.sleepDurationMinutes?.value, expected.sleepDurationMinutes?.value)
        XCTAssertEqual(loaded.metric(.strain)?.strainVersion, 2)
        XCTAssertEqual(loaded.context, expected.context)
    }

    func testNewerRawEvidenceWinsWhenWallClockMovesBackward() async throws {
        let store = try await WhoopStore.inMemory()
        let context = try await context(for: store)
        let current = snapshot(context: context, generatedAt: 200, rawFrontierTs: 50, recovery: 82, strain: 76)
        let stale = snapshot(context: context, generatedAt: 199, rawFrontierTs: 49, recovery: 20, strain: 8)
        let newerEvidence = snapshot(context: context, generatedAt: 1, rawFrontierTs: 51, recovery: 21, strain: 9)

        let savedCurrent = try await store.saveTodayHealthSnapshot(current)
        let savedStale = try await store.saveTodayHealthSnapshot(stale)
        let savedNewerEvidence = try await store.saveTodayHealthSnapshot(newerEvidence)
        let persisted = try await store.todayHealthSnapshot(scopeId: current.scopeId)
        XCTAssertTrue(savedCurrent)
        XCTAssertFalse(savedStale)
        XCTAssertTrue(savedNewerEvidence)
        XCTAssertEqual(persisted?.generatedAt, 1)
        XCTAssertEqual(persisted?.recovery?.value, 21)
        XCTAssertEqual(persisted?.recovery?.generation, 2)
        XCTAssertEqual(persisted?.generation, 2)
    }

    func testEqualRawFrontierUsesDatabaseGenerationInsteadOfGeneratedAt() async throws {
        let store = try await WhoopStore.inMemory()
        let context = try await context(for: store)
        let first = snapshot(context: context, generatedAt: 200, rawFrontierTs: 50, recovery: 82, strain: 76)
        let second = snapshot(context: context, generatedAt: 1, rawFrontierTs: 50, recovery: 21, strain: 9)

        let savedFirst = try await store.saveTodayHealthSnapshot(first)
        let savedSecond = try await store.saveTodayHealthSnapshot(second)
        XCTAssertTrue(savedFirst)
        XCTAssertTrue(savedSecond)

        let persisted = try await store.todayHealthSnapshot(scopeId: first.scopeId)
        XCTAssertEqual(persisted?.generatedAt, 1)
        XCTAssertEqual(persisted?.recovery?.value, 21)
        XCTAssertEqual(persisted?.generation, 2)
        XCTAssertEqual(persisted?.recovery?.generation, 2)
    }

    func testRoundTripsUnavailableAndUnknownMetricStatesWithEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let context = try await context(for: store)
        let day = "2026-08-03"
        let unavailable = TodayHealthUnavailableEvidence(
            metricDay: day, sourceId: "my-whoop-noop", reason: .absent, observedAt: 100,
            rawFrontierTs: 90, algorithmVersion: "daily-recovery-v1", generation: 0
        )
        let dailyMetric = DailyMetric(
            day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil,
            lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil,
            strain: nil, exerciseCount: nil, strainVersion: nil
        )
        let expected = TodayHealthSnapshot(
            scopeId: "dashboard:my-whoop|\(context.identifier)", context: context, deviceId: "my-whoop",
            displayDay: day, logicalDay: day, localDay: day, generatedAt: 100, rawFrontierTs: 90,
            authoritativeMetrics: [.recovery], dailyMetric: dailyMetric,
            metricStates: [
                .recovery: .unavailable(unavailable),
                .strain: .unknown,
                .sleepScore: .unknown,
                .sleepDurationMinutes: .unknown
            ]
        )

        let didSave = try await store.saveTodayHealthSnapshot(expected)
        let persisted = try await store.todayHealthSnapshot(scopeId: expected.scopeId)
        let loaded = try XCTUnwrap(persisted)
        XCTAssertTrue(didSave)

        guard case let .unavailable(evidence) = loaded.recoveryState else {
            return XCTFail("Expected unavailable recovery state")
        }
        XCTAssertEqual(evidence.reason, .absent)
        XCTAssertEqual(evidence.metricDay, day)
        XCTAssertEqual(evidence.generation, 1)
        guard case .unknown = loaded.strainState else {
            return XCTFail("Expected unknown strain state")
        }
        XCTAssertNil(loaded.recovery)
        XCTAssertTrue(loaded.authoritativeMetrics.contains(.recovery))
    }

    func testDeleteAllDataRemovesEveryContextScopedSnapshotForDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let expected = snapshot(context: try await context(for: store))
        let didSave = try await store.saveTodayHealthSnapshot(expected)
        XCTAssertTrue(didSave)

        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.deleteAllData(deviceId: expected.deviceId)

        let loaded = try await store.todayHealthSnapshot(scopeId: expected.scopeId)
        XCTAssertNil(loaded)
    }

    func testRejectsInvalidMetricEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let context = try await context(for: store)
        let invalid = TodayHealthSnapshot(
            scopeId: "dashboard:my-whoop|\(context.identifier)", context: context, deviceId: "my-whoop",
            displayDay: "2026-08-03", logicalDay: "2026-08-03", localDay: "2026-08-03", generatedAt: 1,
            dailyMetric: daily("2026-08-03"),
            recovery: TodayHealthMetricValue(value: 101, metricDay: "2026-08-03", sourceId: "my-whoop",
                                              algorithmVersion: "daily-recovery-v1")
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await store.saveTodayHealthSnapshot(invalid)
        }, handler: { error in
            XCTAssertEqual(error as? TodayHealthSnapshotStoreError, .invalidSnapshot)
        })
    }

    func testRejectsFutureSchemaSnapshot() async throws {
        let store = try await WhoopStore.inMemory()
        let context = try await context(for: store)
        let current = snapshot(context: context)
        let future = TodayHealthSnapshot(
            scopeId: current.scopeId, context: context, deviceId: current.deviceId,
            displayDay: current.displayDay, logicalDay: current.logicalDay, localDay: current.localDay,
            generatedAt: current.generatedAt, schemaVersion: TodayHealthSnapshot.currentSchemaVersion + 1,
            dailyMetric: current.dailyMetric, recovery: current.recovery, strain: current.strain,
            sleepScore: current.sleepScore, sleepDurationMinutes: current.sleepDurationMinutes
        )

        await XCTAssertThrowsErrorAsync({
            _ = try await store.saveTodayHealthSnapshot(future)
        }, handler: { error in
            XCTAssertEqual(error as? TodayHealthSnapshotStoreError, .invalidSnapshot)
        })
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    handler: (Error) -> Void
) async {
    do {
        try await expression()
        XCTFail("Expected error")
    } catch {
        handler(error)
    }
}
