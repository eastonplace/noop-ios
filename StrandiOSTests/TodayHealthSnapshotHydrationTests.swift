import XCTest
import NoopPhase34Core
import WhoopStore
import WhoopProtocol
@testable import NOOP

@MainActor
final class TodayHealthSnapshotHydrationTests: XCTestCase {
    func testHistoricalPublicationRefreshesRecalculatedPriorNightCarry() async throws {
        let result = try await rebuiltPriorNightCarry(recovery: 60, sleep: 570, sleepScore: 82)
        XCTAssertEqual(result.recovery?.value, 60)
        XCTAssertEqual(result.recovery?.metricDay, "2026-09-27")
        XCTAssertEqual(result.sleepDurationMinutes?.value, 570)
        XCTAssertEqual(result.sleepScore?.value, 82)
        XCTAssertNil(result.dailyMetric.recovery, "Yesterday's carry must not become today's score")
        XCTAssertNil(result.dailyMetric.totalSleepMin)
    }

    func testHistoricalPublicationRetractsRejectedPriorNightCarry() async throws {
        let result = try await rebuiltPriorNightCarry(recovery: nil, sleep: nil, sleepScore: nil)
        XCTAssertNil(result.recovery?.value, "A complete read must not resurrect rejected Recovery")
        XCTAssertNil(result.sleepDurationMinutes?.value)
        XCTAssertNil(result.sleepScore?.value)
    }

    func testRegularRefreshUpdatesAndRetractsRecalculatedPriorRecovery() async throws {
        let updated = try await rebuiltPriorNightCarry(
            recovery: 60, sleep: 570, sleepScore: 82, regularRefresh: true)
        XCTAssertEqual(updated.recovery?.value, 60)
        XCTAssertNil(updated.dailyMetric.recovery)
        let rejected = try await rebuiltPriorNightCarry(
            recovery: nil, sleep: nil, sleepScore: nil, regularRefresh: true)
        XCTAssertNil(rejected.recovery?.value)
    }

    private func rebuiltPriorNightCarry(
        recovery: Double?, sleep: Double?, sleepScore: Double?, regularRefresh: Bool = false
    ) async throws -> TodayHealthSnapshot {
        let store = try await WhoopStore.inMemory()
        let snapshotContext = try await context(for: store)
        let now = Date(timeIntervalSince1970: 1_790_604_000)
        let source = Repository.whoopSource + "-noop"
        try await store.upsertDailyMetrics([
            daily("2026-09-27", recovery: recovery, strain: nil, sleep: sleep),
            daily("2026-09-28", recovery: nil, strain: nil, sleep: nil)
        ], deviceId: source)
        if let sleepScore {
            try await store.upsertMetricSeries([
                MetricPoint(day: "2026-09-27", key: "sleep_performance", value: sleepScore)
            ], deviceId: source)
        }
        let template = TodayHealthSnapshot(
            scopeId: "dashboard:my-whoop|\(snapshotContext.identifier)", context: snapshotContext,
            deviceId: Repository.whoopSource, displayDay: "2026-09-28",
            logicalDay: "2026-09-28", localDay: "2026-09-28",
            generatedAt: Int(now.timeIntervalSince1970) - 300,
            authoritativeMetrics: [.recovery, .sleepDurationMinutes, .sleepScore],
            dailyMetric: daily("2026-09-28", recovery: nil, strain: nil, sleep: nil),
            metricStates: [
                .recovery: .value(TodayHealthMetricValue(value: 99, metricDay: "2026-09-27", sourceId: source,
                                                       algorithmVersion: "daily-recovery-v1")),
                .sleepDurationMinutes: .value(TodayHealthMetricValue(value: 600, metricDay: "2026-09-27", sourceId: source,
                                                                   algorithmVersion: "daily-sleep-duration-v1")),
                .sleepScore: .value(TodayHealthMetricValue(value: 90, metricDay: "2026-09-27", sourceId: source,
                                                        algorithmVersion: "sleep-performance-v1"))
            ])
        let read = try await store.canonicalHealthSurfaceSnapshot(
            sourceIds: [Repository.whoopSource, source, Repository.appleHealthSource],
            fromDay: "2026-09-27", throughDay: "2026-09-28",
            sleepFromTs: 1_790_478_000, sleepThroughTs: 1_790_647_200,
            metricKeys: ["sleep_performance"])
        if regularRefresh {
            let repository = Repository(deviceId: Repository.whoopSource)
            repository.setStoreForTesting(store)
            repository.setTodayHealthSnapshotTestNow(now)
            let initialized = await repository.refresh(days: 3)
            XCTAssertTrue(initialized)
            let current = try XCTUnwrap(repository.todayHealthSnapshot)
            repository.todayHealthSnapshot = TodayHealthSnapshot(
                scopeId: current.scopeId, context: current.context, deviceId: current.deviceId,
                displayDay: template.displayDay, logicalDay: template.logicalDay, localDay: template.localDay,
                generatedAt: template.generatedAt, rawFrontierTs: current.rawFrontierTs,
                generation: current.generation, authoritativeMetrics: template.authoritativeMetrics,
                dailyMetric: template.dailyMetric,
                metricStates: Dictionary(uniqueKeysWithValues: TodayHealthSnapshot.Metric.allCases.map {
                    ($0, template.state(for: $0))
                }))
            let refreshed = await repository.refresh(days: 3)
            XCTAssertTrue(refreshed)
            return try XCTUnwrap(repository.todayHealthSnapshot)
        }
        return try RepositoryPostAnalysisSnapshotBuilder.build(.init(
            template: template, ownerDeviceId: Repository.whoopSource, read: read,
            readWindows: [.init(fromDay: "2026-09-27", throughDay: "2026-09-28",
                                sleepFromTs: 1_790_478_000, sleepThroughTs: 1_790_647_200)],
            importedSourceIds: [Repository.whoopSource], computedSourceIds: [source],
            appleSourceId: Repository.appleHealthSource, sleepMode: .off,
            analysisGeneration: 42, rawFrontierTs: 1_790_604_000,
            recordedTimeZoneIdentifier: "America/New_York", now: now))
    }

    private func context(for store: WhoopStore) async throws -> TodayHealthSnapshotContext {
        TodayHealthSnapshotContext(
            databaseInstanceId: try await store.todayHealthSnapshotDatabaseInstanceId(),
            dashboardProfileId: "dashboard:\(Repository.whoopSource)",
            sourceLineage: "apple-health,my-whoop,my-whoop-noop,no-live-source",
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
        rawFrontierTs: Int? = nil,
        authoritative: Set<TodayHealthSnapshot.Metric> = [.recovery, .strain, .sleepScore, .sleepDurationMinutes]
    ) -> TodayHealthSnapshot {
        TodayHealthSnapshot(
            scopeId: "dashboard:\(Repository.whoopSource)|\(context.identifier)", context: context,
            deviceId: Repository.whoopSource, displayDay: day, logicalDay: day, localDay: localDay,
            generatedAt: generatedAt, rawFrontierTs: rawFrontierTs, authoritativeMetrics: authoritative,
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

    private func legacySleepSnapshot(day: String, generatedAt: Int) -> TodayHealthSnapshot {
        TodayHealthSnapshot(
            scopeId: "dashboard:\(Repository.whoopSource)", deviceId: Repository.whoopSource,
            displayDay: day, logicalDay: day, localDay: day, generatedAt: generatedAt,
            schemaVersion: 2, authoritativeMetrics: [.sleepScore],
            dailyMetric: daily(day, recovery: nil, strain: nil, sleep: nil),
            sleepScore: TodayHealthMetricValue(
                value: 91, metricDay: day, sourceId: "my-whoop-noop",
                algorithmVersion: "sleep-performance-v1")
        )
    }

    private func fixedNewYorkDate(hour: Int, minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 8, day: 3,
            hour: hour, minute: minute))!
    }

    func testHydrationPreservesLegacySleepWhenRefreshCreatesCurrentRowFirst() async throws {
        let store = try await WhoopStore.inMemory()
        let beforeRollover = fixedNewYorkDate(hour: 3, minute: 59)
        let day = Repository.logicalDayKey(beforeRollover)
        let legacy = legacySleepSnapshot(day: day, generatedAt: Int(beforeRollover.timeIntervalSince1970))
        let savedLegacy = try await store.saveTodayHealthSnapshot(legacy)
        XCTAssertTrue(savedLegacy)
        try await store.upsertDailyMetrics(
            [daily(day, recovery: 78, strain: nil, sleep: nil)], deviceId: Repository.whoopSource)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        repository.setTodayHealthSnapshotTestNow(beforeRollover)
        repository.todayHealthSnapshotSleepReadOverride = .failed

        let hydrationGate = AsyncTestGate()
        repository.todayHealthSnapshotHydrationReadHook = { await hydrationGate.wait() }
        let hydrationTask = Task { await repository.hydrateTodayHealthSnapshot() }
        await hydrationGate.waitUntilEntered()

        let didRefresh = await repository.refresh(days: 1)
        XCTAssertTrue(didRefresh)
        XCTAssertEqual(repository.todayHealthSnapshot?.sleepScore?.value, 91)

        repository.todayHealthSnapshotHydrationReadHook = nil
        await hydrationGate.open()
        await hydrationTask.value

        XCTAssertEqual(repository.todayHealthSnapshot?.displayDay, day)
        XCTAssertEqual(repository.todayHealthSnapshot?.sleepScore?.value, 91)
        let scopeId = try XCTUnwrap(repository.todayHealthSnapshot?.scopeId)
        let durable = try await store.todayHealthSnapshot(scopeId: scopeId)
        XCTAssertEqual(durable?.sleepScore?.value, 91)
    }

    func testAuthoritativeRefreshOwnsWriteAgainstThrottledLiveUpdate() async throws {
        let store = try await WhoopStore.inMemory()
        let fixedNow = fixedNewYorkDate(hour: 3, minute: 59)
        let day = Repository.logicalDayKey(fixedNow)
        try await store.upsertDailyMetrics(
            [daily(day, recovery: 78, strain: 64, sleep: nil)], deviceId: Repository.whoopSource)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        repository.setTodayHealthSnapshotTestNow(fixedNow)
        let sleepGate = AsyncTestGate()
        repository.todayHealthSnapshotSleepReadHook = { await sleepGate.wait() }

        let refreshTask = Task { await repository.refresh(days: 1) }
        await sleepGate.waitUntilEntered()
        repository.scheduleTodayHealthSnapshotWriteForTesting()
        repository.todayHealthSnapshotSleepReadHook = nil
        await sleepGate.open()

        let didRefresh = await refreshTask.value
        XCTAssertTrue(didRefresh)
        let scopeId = try XCTUnwrap(repository.todayHealthSnapshot?.scopeId)
        let durable = try await store.todayHealthSnapshot(scopeId: scopeId)
        XCTAssertNotNil(durable)

        // The live follow-up is test-owned and may be queued after the authoritative save. Cancel it so
        // this test leaves no delayed task behind.
        await repository.invalidateTodayHealthSnapshot()
    }

    func testVerifiedHistoricalCommitInvalidatesOlderTodayWriterOwnership() async throws {
        let store = try await WhoopStore.inMemory()
        let fixedNow = fixedNewYorkDate(hour: 3, minute: 59)
        let day = Repository.logicalDayKey(fixedNow)
        let localDay = Repository.localDayKey(fixedNow)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        repository.setTodayHealthSnapshotTestNow(fixedNow)
        let oldOwnership = repository.todayHealthSnapshotWriteOwnershipForTesting()
        XCTAssertTrue(repository.isCurrentTodayHealthSnapshotWriteForTesting(
            generation: oldOwnership.generation,
            refreshGeneration: oldOwnership.refreshGeneration,
            writeToken: oldOwnership.writeToken
        ))

        let snapshotContext = try await context(for: store)
        let verifiedCandidate = snapshot(
            context: snapshotContext,
            day: day,
            localDay: localDay,
            generatedAt: Int(fixedNow.timeIntervalSince1970) + 1,
            recovery: 91,
            strain: 64,
            sleepScore: 88,
            sleepDuration: 442,
            rawFrontierTs: Int(fixedNow.timeIntervalSince1970)
        )
        let civilDay = try CivilDay(key: day)
        let scope = try HistoricalAnalysisScope(
            databaseInstanceId: snapshotContext.databaseInstanceId,
            sourceId: Repository.whoopSource,
            deviceId: Repository.whoopSource,
            deviceLineageId: "test-lineage",
            cursorEpoch: 1,
            trimScope: "historical"
        )
        let work = try HistoricalAnalysisWork(
            scope: scope,
            firstReceiptGeneration: 1,
            lastReceiptGeneration: 1,
            affectedDays: [civilDay],
            recordedTimeZoneIdentifier: "America/New_York",
            createdAt: fixedNow
        )
        let analysis = try AnalysisMutationReceipt(
            throughReceiptGeneration: 1,
            analysisGeneration: 1,
            analyzedDays: [civilDay],
            rawFrontierTs: Int(fixedNow.timeIntervalSince1970),
            algorithmBundleVersion: snapshotContext.algorithmBundleVersion
        )

        let receipt = try await repository.verifyAndCommitHistoricalSnapshot(
            candidate: verifiedCandidate,
            work: work,
            analysis: analysis,
            store: store
        )
        XCTAssertEqual(receipt.projection.metrics[.recovery]?.value, 91)
        XCTAssertFalse(repository.isCurrentTodayHealthSnapshotWriteForTesting(
            generation: oldOwnership.generation,
            refreshGeneration: oldOwnership.refreshGeneration,
            writeToken: oldOwnership.writeToken
        ))

        let durable = try await store.todayHealthSnapshot(scopeId: verifiedCandidate.scopeId)
        XCTAssertEqual(durable?.recovery?.value, 91)
        XCTAssertEqual(durable?.generation, receipt.snapshotGeneration)
    }

    func testHistoricalSnapshotVerificationWaitsForHealthKitPublicationFence() async throws {
        let store = try await WhoopStore.inMemory()
        let fixedNow = fixedNewYorkDate(hour: 3, minute: 59)
        let day = Repository.logicalDayKey(fixedNow)
        let localDay = Repository.localDayKey(fixedNow)
        let snapshotContext = try await context(for: store)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        repository.setTodayHealthSnapshotTestNow(fixedNow)
        await repository.refreshHistoryExtent()
        XCTAssertEqual(
            repository.todayHealthSnapshotDatabaseIdentityForTesting(),
            snapshotContext.databaseInstanceId
        )
        let oldOwnership = repository.todayHealthSnapshotWriteOwnershipForTesting()

        let template = snapshot(
            context: snapshotContext,
            day: day,
            localDay: localDay,
            generatedAt: Int(fixedNow.timeIntervalSince1970),
            recovery: 78,
            strain: 64,
            sleepScore: 85,
            sleepDuration: 442,
            rawFrontierTs: Int(fixedNow.timeIntervalSince1970) - 60
        )
        let savedTemplate = try await store.saveTodayHealthSnapshot(template)
        XCTAssertTrue(savedTemplate)
        try await store.upsertDailyMetrics(
            [daily(day, recovery: 91, strain: 64, sleep: 442)],
            deviceId: Repository.whoopSource + "-noop"
        )

        let civilDay = try CivilDay(key: day)
        let work = try HistoricalAnalysisWork(
            scope: HistoricalAnalysisScope(
                databaseInstanceId: snapshotContext.databaseInstanceId,
                sourceId: Repository.whoopSource,
                deviceId: Repository.whoopSource,
                deviceLineageId: "test-lineage",
                cursorEpoch: 1,
                trimScope: "historical"
            ),
            firstReceiptGeneration: 1,
            lastReceiptGeneration: 1,
            affectedDays: [civilDay],
            recordedTimeZoneIdentifier: "America/New_York",
            createdAt: fixedNow
        )
        let analysis = try AnalysisMutationReceipt(
            throughReceiptGeneration: 1,
            analysisGeneration: 1,
            analyzedDays: [civilDay],
            rawFrontierTs: Int(fixedNow.timeIntervalSince1970),
            algorithmBundleVersion: snapshotContext.algorithmBundleVersion
        )
        let publicationBarrier = RepositoryPublicationBarrier()
        await publicationBarrier.acquireExclusive()
        var completed = false
        let commitTask = Task { @MainActor in
            defer { completed = true }
            return try await repository.buildAndCommitVerifiedHistoricalSnapshot(
                work: work,
                analysis: analysis,
                store: store,
                now: fixedNow,
                snapshotBuilder: RepositoryPostAnalysisSnapshotBuilder.self,
                publicationBarrier: publicationBarrier
            )
        }

        for _ in 0..<500 where !completed {
            try await Task.sleep(nanoseconds: 1_000_000)
        }

        XCTAssertFalse(completed,
                       "historical verification must wait while HealthKit owns coherent publication")
        XCTAssertTrue(repository.isCurrentTodayHealthSnapshotWriteForTesting(
            generation: oldOwnership.generation,
            refreshGeneration: oldOwnership.refreshGeneration,
            writeToken: oldOwnership.writeToken
        ), "waiting historical work must not supersede HealthKit's Repository refresh generation")

        publicationBarrier.releaseExclusive()
        let receipt = try await commitTask.value

        XCTAssertEqual(receipt.projection.metrics[.recovery]?.value, 91)
        XCTAssertFalse(repository.isCurrentTodayHealthSnapshotWriteForTesting(
            generation: oldOwnership.generation,
            refreshGeneration: oldOwnership.refreshGeneration,
            writeToken: oldOwnership.writeToken
        ))
    }

    func testRefreshFailsWhenSnapshotDatabaseIdentityCannotBeEstablished() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        repository.todayHealthSnapshotDatabaseIdentityUnavailableForTesting = true

        let didRefresh = await repository.refresh(days: 1)

        XCTAssertFalse(didRefresh)
        XCTAssertNil(repository.todayHealthSnapshot)
    }

    func testHydratesOneStoredSnapshotWithoutPublishingTheBroadCache() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let logicalDay = Repository.logicalDayKey(now)
        let localDay = Repository.localDayKey(now)
        let expected = snapshot(context: try await context(for: store), day: logicalDay, localDay: localDay,
                                generatedAt: Int(now.timeIntervalSince1970))
        let didSave = try await store.saveTodayHealthSnapshot(expected)
        XCTAssertTrue(didSave)
        let storedBefore = try await store.todayHealthSnapshot(scopeId: expected.scopeId)
        let durableBefore = try XCTUnwrap(storedBefore)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        await repository.hydrateTodayHealthSnapshot()

        XCTAssertEqual(repository.todayHealthSnapshot, durableBefore)
        let durableAfter = try await store.todayHealthSnapshot(scopeId: expected.scopeId)
        XCTAssertEqual(durableAfter, durableBefore)
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
        let didRefresh = await repository.refresh(days: 1)

        XCTAssertTrue(didRefresh)
        XCTAssertNil(repository.todayHealthSnapshot?.recovery)
        XCTAssertNil(repository.todayHealthSnapshot?.sleepScore)
        let durable = try await store.todayHealthSnapshot(scopeId: repository.todayHealthSnapshot?.scopeId ?? "")
        XCTAssertNil(durable?.recovery)
        XCTAssertNil(durable?.sleepScore)
    }

    func testFailedSleepReadPreservesPersistedScoreAndDurability() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let day = Repository.logicalDayKey(now)
        let persisted = snapshot(
            context: try await context(for: store), day: day,
            localDay: Repository.localDayKey(now), generatedAt: Int(now.timeIntervalSince1970),
            recovery: nil, strain: nil, sleepScore: 91, sleepDuration: nil,
            authoritative: [.sleepScore]
        )
        _ = try await store.saveTodayHealthSnapshot(persisted)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        await repository.hydrateTodayHealthSnapshot()
        repository.todayHealthSnapshotSleepReadOverride = .failed

        let didRefresh = await repository.refresh(days: 1)

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(repository.todayHealthSnapshot?.displayDay, day)
        XCTAssertEqual(repository.todayHealthSnapshot?.sleepScore?.value, 91)
        XCTAssertTrue(repository.todayHealthSnapshot?.isAuthoritative(.sleepScore) == true)
        let durable = try await store.todayHealthSnapshot(scopeId: persisted.scopeId)
        XCTAssertEqual(durable?.displayDay, day)
        XCTAssertEqual(durable?.sleepScore?.value, 91)
        XCTAssertTrue(durable?.isAuthoritative(.sleepScore) == true)
    }

    func testFailedSleepReadWithoutHydrationPreservesDurableScore() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let day = Repository.logicalDayKey(now)
        let persisted = snapshot(
            context: try await context(for: store), day: day,
            localDay: Repository.localDayKey(now), generatedAt: Int(now.timeIntervalSince1970),
            recovery: nil, strain: nil, sleepScore: 92, sleepDuration: nil,
            authoritative: [.sleepScore]
        )
        _ = try await store.saveTodayHealthSnapshot(persisted)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        repository.todayHealthSnapshotSleepReadOverride = .failed

        let didRefresh = await repository.refresh(days: 1)

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(repository.todayHealthSnapshot?.displayDay, day)
        XCTAssertEqual(repository.todayHealthSnapshot?.sleepScore?.value, 92)
        XCTAssertTrue(repository.todayHealthSnapshot?.isAuthoritative(.sleepScore) == true)
        let durable = try await store.todayHealthSnapshot(scopeId: persisted.scopeId)
        XCTAssertEqual(durable?.displayDay, day)
        XCTAssertEqual(durable?.sleepScore?.value, 92)
        XCTAssertTrue(durable?.isAuthoritative(.sleepScore) == true)
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

        let didRefresh = await repository.refresh(days: 1)
        XCTAssertTrue(didRefresh)

        XCTAssertEqual(repository.todayHealthSnapshot?.displayDay, day)
        XCTAssertEqual(repository.todayHealthSnapshot?.sleepScore?.value, 86)
        XCTAssertEqual(repository.todayHealthSnapshot?.sleepScore?.metricDay, day)
        XCTAssertNil(repository.todayHealthSnapshot?.recovery)
        XCTAssertNil(repository.todayHealthSnapshot?.strain)
        let scopeId = repository.todayHealthSnapshot?.scopeId ?? ""
        let durable = try await store.todayHealthSnapshot(scopeId: scopeId)
        XCTAssertEqual(durable?.displayDay, day)
        XCTAssertEqual(durable?.sleepScore?.value, 86)
    }

    func testRefreshReturnsFalseWhenDurableSnapshotWriteIsRejected() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date()
        let day = Repository.logicalDayKey(now)
        let persisted = snapshot(
            context: try await context(for: store), day: day,
            localDay: Repository.localDayKey(now), generatedAt: Int(now.timeIntervalSince1970),
            sleepScore: 55, rawFrontierTs: 100
        )
        let seeded = try await store.saveTodayHealthSnapshot(persisted)
        XCTAssertTrue(seeded)
        try await store.upsertMetricSeries(
            [MetricPoint(day: day, key: "sleep_performance", value: 86)],
            deviceId: Repository.whoopSource
        )
        try await store.insert(
            Streams(hr: [HRSample(ts: 100, bpm: 60)]), deviceId: Repository.whoopSource)

        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)

        let didRefresh = await repository.refresh(days: 1)

        XCTAssertTrue(didRefresh)
        XCTAssertNil(repository.todayHealthSnapshot)
        let durable = try await store.todayHealthSnapshot(scopeId: persisted.scopeId)
        XCTAssertEqual(durable?.sleepScore?.value, 55)
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

        let didRefresh = await repository.refresh(days: 1)

        XCTAssertTrue(didRefresh)
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

        let didRefresh = await repository.refresh(days: 1)
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
        _ = await repository.refresh(days: 1) // completes a write against the old database generation

        try await repository.quiesceStoreForRestore()
        let restoredStore = try await WhoopStore.inMemory()
        repository.setStoreForTesting(restoredStore)
        try await repository.reopenStoreAfterRestore()

        let restoredContext = try await context(for: restoredStore)
        let restoredScope = "dashboard:\(Repository.whoopSource)|\(restoredContext.identifier)"
        let restoredSnapshot = try await restoredStore.todayHealthSnapshot(scopeId: restoredScope)
        XCTAssertEqual(repository.todayHealthSnapshot?.context, restoredContext)
        XCTAssertEqual(restoredSnapshot?.context, restoredContext)
        XCTAssertNotEqual(repository.todayHealthSnapshot?.context, oldContext)
        XCTAssertNil(repository.todayHealthSnapshot?.recovery)
        XCTAssertNil(repository.todayHealthSnapshot?.strain)
        XCTAssertNil(repository.todayHealthSnapshot?.sleepScore)
        XCTAssertNil(repository.todayHealthSnapshot?.sleepDurationMinutes)
        XCTAssertNil(restoredSnapshot?.recovery)
        XCTAssertNil(restoredSnapshot?.strain)
        XCTAssertNil(restoredSnapshot?.sleepScore)
        XCTAssertNil(restoredSnapshot?.sleepDurationMinutes)
        let oldScope = "dashboard:\(Repository.whoopSource)|\(oldContext.identifier)"
        let staleSnapshot = try await restoredStore.todayHealthSnapshot(scopeId: oldScope)
        XCTAssertNil(staleSnapshot)
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

private actor AsyncTestGate {
    private var entered = false
    private var released = false
    private var enteredContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        enteredContinuation?.resume()
        enteredContinuation = nil
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredContinuation = continuation
        }
    }

    func open() {
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
