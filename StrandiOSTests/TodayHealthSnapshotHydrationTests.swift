import XCTest
import WhoopStore
import WhoopProtocol
@testable import NOOP

@MainActor
final class TodayHealthSnapshotHydrationTests: XCTestCase {
    private func context(for store: WhoopStore) async throws -> TodayHealthSnapshotContext {
        TodayHealthSnapshotContext(
            databaseInstanceId: try await store.todayHealthSnapshotDatabaseInstanceId(),
            dashboardProfileId: "dashboard:\(Repository.whoopSource)",
            sourceLineage: "apple-health,my-whoop,my-whoop-noop",
            algorithmBundleVersion: "today-health-v3|strain-v2|sleep-performance-v2"
        )
    }

    private func daily(_ day: String, recovery: Double? = 78, strain: Double? = 64,
                       sleep: Double? = 442) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: sleep, efficiency: 0.91, deepMin: 90, remMin: 108,
                    lightMin: 244, disturbances: 3, restingHr: 52, avgHrv: 63,
                    recovery: recovery, strain: strain, exerciseCount: 1,
                    strainVersion: strain.map { _ in 2 })
    }

    private func snapshot(
        context: TodayHealthSnapshotContext,
        day: String,
        localDay: String,
        generatedAt: Int,
        recovery: Double? = 78,
        strain: Double? = 64,
        sleepScore: Double? = 85,
        sleepDuration: Double? = 442,
        authoritative: Set<TodayHealthSnapshot.Metric> = [.recovery, .strain, .sleepScore, .sleepDurationMinutes]
    ) -> TodayHealthSnapshot {
        TodayHealthSnapshot(
            scopeId: "dashboard:\(Repository.whoopSource)|\(context.identifier)", context: context,
            deviceId: Repository.whoopSource, displayDay: day, logicalDay: day, localDay: localDay,
            generatedAt: generatedAt, authoritativeMetrics: authoritative,
            dailyMetric: daily(day, recovery: recovery, strain: strain, sleep: sleepDuration),
            recovery: recovery.map {
                TodayHealthMetricValue(value: $0, metricDay: day, sourceId: "my-whoop-noop",
                                        algorithmVersion: "daily-recovery-v1")
            },
            strain: strain.map {
                TodayHealthMetricValue(value: $0, metricDay: day, sourceId: "my-whoop-noop",
                                        algorithmVersion: "strain-v2-daily", strainVersion: 2)
            },
            sleepScore: sleepScore.map {
                TodayHealthMetricValue(value: $0, metricDay: day, sourceId: "my-whoop-noop",
                                        algorithmVersion: "sleep-performance-v1")
            },
            sleepDurationMinutes: sleepDuration.map {
                TodayHealthMetricValue(value: $0, metricDay: day, sourceId: "my-whoop-noop",
                                        algorithmVersion: "daily-sleep-duration-v1")
            }
        )
    }

    func testHydratesOneStoredSnapshotWithoutPublishingTheBroadCache() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let logicalDay = Repository.logicalDayKey(now)
        let localDay = Repository.localDayKey(now)
        let expected = snapshot(context: try await context(for: store), day: logicalDay, localDay: localDay,
                                generatedAt: Int(now.timeIntervalSince1970))
        _ = try await store.saveTodayHealthSnapshot(expected)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        await repository.hydrateTodayHealthSnapshot()

        XCTAssertEqual(repository.todayHealthSnapshot, expected)
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
            generatedAt: Int(now.timeIntervalSince1970) - 1, schemaVersion: 2,
            dailyMetric: daily(logicalDay, recovery: 78, strain: 0),
            recovery: TodayHealthMetricValue(value: 78, sourceId: "my-whoop-noop", algorithmVersion: "recovery-v1"),
            strain: TodayHealthMetricValue(value: 0, sourceId: "my-whoop-noop", algorithmVersion: "strain-v2",
                                            strainVersion: 2),
            sleepScore: TodayHealthMetricValue(value: 85, sourceId: "my-whoop-noop", algorithmVersion: "sleep-performance-v1"),
            sleepDurationMinutes: TodayHealthMetricValue(value: 442, sourceId: "my-whoop-noop",
                                                          algorithmVersion: "sleep-duration-v1")
        )
        _ = try await store.saveTodayHealthSnapshot(stale)
        try await store.upsertDailyMetrics([
            daily(logicalDay, recovery: 78, strain: 64)
        ], deviceId: Repository.whoopSource + "-noop")

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        await repository.hydrateTodayHealthSnapshot()

        XCTAssertEqual(repository.todayHealthSnapshot?.strain?.value, 64)
        XCTAssertEqual(repository.todayHealthSnapshot?.dailyMetric.strain, 64)
        XCTAssertEqual(repository.todayHealthSnapshot?.schemaVersion, TodayHealthSnapshot.currentSchemaVersion)
        let saved = try await store.todayHealthSnapshot(scopeId: repository.todayHealthSnapshot?.scopeId ?? "")
        let legacy = try await store.todayHealthSnapshot(scopeId: stale.scopeId)
        XCTAssertEqual(saved?.strain?.value, 64)
        XCTAssertNil(legacy)
    }

    func testAuthoritativeEmptyRefreshCannotResurrectInvalidatedSnapshot() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let day = Repository.logicalDayKey(now)
        let expected = snapshot(context: try await context(for: store), day: day,
                                localDay: Repository.localDayKey(now), generatedAt: Int(now.timeIntervalSince1970))
        _ = try await store.saveTodayHealthSnapshot(expected)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        await repository.hydrateTodayHealthSnapshot()
        await repository.invalidateTodayHealthSnapshot()
        let didRefresh = await repository.refresh(days: 4_000)

        XCTAssertTrue(didRefresh)
        XCTAssertNil(repository.todayHealthSnapshot?.recovery)
        XCTAssertNil(repository.todayHealthSnapshot?.sleepScore)
        for _ in 0..<20 { await Task.yield() }
        let durable = try await store.todayHealthSnapshot(scopeId: repository.todayHealthSnapshot?.scopeId ?? "")
        XCTAssertNil(durable?.recovery)
    }

    func testScalarOnlySleepScoreCreatesDurableFirstPaintSnapshot() async throws {
        let store = try await WhoopStore.inMemory()
        let day = Repository.logicalDayKey(Date())
        try await store.upsertMetricSeries(
            [MetricPoint(day: day, key: "sleep_performance", value: 86)],
            deviceId: Repository.whoopSource
        )
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)

        let didRefresh = await repository.refresh(days: 4_000)
        XCTAssertTrue(didRefresh)
        for _ in 0..<100 {
            if repository.todayHealthSnapshot?.sleepScore?.value == 86 { break }
            await Task.yield()
        }

        XCTAssertEqual(repository.todayHealthSnapshot?.sleepScore?.value, 86)
        XCTAssertNil(repository.todayHealthSnapshot?.recovery)
        XCTAssertNil(repository.todayHealthSnapshot?.strain)
        let scopeId = repository.todayHealthSnapshot?.scopeId ?? ""
        var durable: TodayHealthSnapshot?
        for _ in 0..<100 {
            durable = try await store.todayHealthSnapshot(scopeId: scopeId)
            if durable?.sleepScore?.value == 86 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(durable?.sleepScore?.value, 86)
    }

    func testScalarSleepScoreKeepsTheWinningSourceProvenance() async throws {
        let store = try await WhoopStore.inMemory()
        let day = Repository.logicalDayKey(Date())
        try await store.upsertMetricSeries(
            [MetricPoint(day: day, key: "sleep_performance", value: 86)],
            deviceId: "active-strap"
        )
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        XCTAssertTrue(repository.adoptActiveDeviceId("active-strap"))

        _ = await repository.refresh(days: 4_000)
        for _ in 0..<100 {
            if repository.todayHealthSnapshot?.sleepScore?.sourceId == "active-strap" { break }
            await Task.yield()
        }

        XCTAssertEqual(repository.todayHealthSnapshot?.sleepScore?.sourceId, "active-strap")
    }

    func testDailyPillarSourcesKeepTheWinningActiveStrapProvenance() async throws {
        let store = try await WhoopStore.inMemory()
        let day = Repository.logicalDayKey(Date())
        try await store.upsertDailyMetrics([
            daily(day, recovery: 79, strain: nil, sleep: 451)
        ], deviceId: "active-strap")
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        XCTAssertTrue(repository.adoptActiveDeviceId("active-strap"))

        let didRefresh = await repository.refresh(days: 4_000)
        XCTAssertTrue(didRefresh)

        XCTAssertEqual(repository.todayHealthSnapshot?.recovery?.sourceId, "active-strap")
        XCTAssertEqual(repository.todayHealthSnapshot?.sleepDurationMinutes?.sourceId, "active-strap")
    }

    func testIncompatibleSourceContextIsRejectedBeforeFirstPaint() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let expectedContext = try await context(for: store)
        let incompatibleContext = TodayHealthSnapshotContext(
            databaseInstanceId: expectedContext.databaseInstanceId,
            dashboardProfileId: expectedContext.dashboardProfileId,
            sourceLineage: "apple-health,other-strap",
            algorithmBundleVersion: expectedContext.algorithmBundleVersion
        )
        let scope = "dashboard:\(Repository.whoopSource)|\(expectedContext.identifier)"
        let snapshot = TodayHealthSnapshot(
            scopeId: scope, context: incompatibleContext, deviceId: Repository.whoopSource,
            displayDay: Repository.logicalDayKey(now), logicalDay: Repository.logicalDayKey(now),
            localDay: Repository.localDayKey(now), generatedAt: Int(now.timeIntervalSince1970),
            dailyMetric: daily(Repository.logicalDayKey(now)),
            recovery: TodayHealthMetricValue(value: 78, metricDay: Repository.logicalDayKey(now),
                                              sourceId: "my-whoop-noop", algorithmVersion: "daily-recovery-v1"),
            strain: TodayHealthMetricValue(value: 64, metricDay: Repository.logicalDayKey(now),
                                            sourceId: "my-whoop-noop", algorithmVersion: "strain-v2-daily",
                                            strainVersion: 2),
            sleepScore: TodayHealthMetricValue(value: 85, metricDay: Repository.logicalDayKey(now),
                                                sourceId: "my-whoop-noop", algorithmVersion: "sleep-performance-v1"),
            sleepDurationMinutes: TodayHealthMetricValue(value: 442, metricDay: Repository.logicalDayKey(now),
                                                          sourceId: "my-whoop-noop",
                                                          algorithmVersion: "daily-sleep-duration-v1")
        )
        _ = try await store.saveTodayHealthSnapshot(snapshot)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        await repository.hydrateTodayHealthSnapshot()

        let persisted = try await store.todayHealthSnapshot(scopeId: scope)
        XCTAssertNil(repository.todayHealthSnapshot)
        XCTAssertNil(persisted)
    }

    func testStoreReplacementCannotBlendOrRepersistPreRestoreSnapshot() async throws {
        let oldStore = try await WhoopStore.inMemory()
        let now = Date()
        let day = Repository.logicalDayKey(now)
        let oldContext = try await context(for: oldStore)
        _ = try await oldStore.saveTodayHealthSnapshot(
            snapshot(context: oldContext, day: day, localDay: Repository.localDayKey(now),
                     generatedAt: Int(now.timeIntervalSince1970))
        )
        try await oldStore.upsertDailyMetrics([daily(day)], deviceId: Repository.whoopSource + "-noop")

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(oldStore)
        await repository.hydrateTodayHealthSnapshot()
        XCTAssertEqual(repository.todayHealthSnapshot?.context, oldContext)
        _ = await repository.refresh(days: 4_000) // queues a writer from the old database generation

        try await repository.quiesceStoreForRestore()
        let restoredStore = try await WhoopStore.inMemory()
        repository.setStoreForTesting(restoredStore)
        await repository.hydrateTodayHealthSnapshot()
        for _ in 0..<20 { await Task.yield() }

        let restoredContext = try await context(for: restoredStore)
        let restoredScope = "dashboard:\(Repository.whoopSource)|\(restoredContext.identifier)"
        let restoredSnapshot = try await restoredStore.todayHealthSnapshot(scopeId: restoredScope)
        XCTAssertNil(repository.todayHealthSnapshot)
        XCTAssertNil(restoredSnapshot)
    }

    func testLogicalDayUsesCivilTimeAtSpringForwardBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeRollover = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 3, day: 8, hour: 3, minute: 59))!
        let atRollover = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 3, day: 8, hour: 4, minute: 0))!

        XCTAssertEqual(Repository.logicalDayKey(beforeRollover, calendar: calendar), "2026-03-07")
        XCTAssertEqual(Repository.logicalDayKey(atRollover, calendar: calendar), "2026-03-08")
    }

    func testLogicalDayUsesCivilTimeAtFallBackBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeRollover = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 11, day: 1, hour: 3, minute: 59))!
        let atRollover = calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 11, day: 1, hour: 4, minute: 0))!

        XCTAssertEqual(Repository.logicalDayKey(beforeRollover, calendar: calendar), "2026-10-31")
        XCTAssertEqual(Repository.logicalDayKey(atRollover, calendar: calendar), "2026-11-01")
    }

    func testLocalDayKeyUsesTheCurrentCalendarZoneAfterTravel() {
        let instant = Date(timeIntervalSince1970: 1_774_915_200) // 2026-03-31 00:00:00 UTC
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        XCTAssertEqual(Repository.localDayKey(instant, calendar: newYork), "2026-03-30")
        XCTAssertEqual(Repository.localDayKey(instant, calendar: tokyo), "2026-03-31")
    }
}
