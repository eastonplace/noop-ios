import XCTest
import GRDB
import NoopPhase34Core
@testable import WhoopStore

private func makeV50Projection(
    contextId: String = "context-v50",
    deviceId: String = "my-whoop",
    generation: Int64 = 1,
    day: String = "2026-08-08",
    recovery: Double = 73
) throws -> VerifiedHealthProjection {
    let civilDay = try CivilDay(key: day)
    let metric = try VerifiedHealthMetric(
        kind: .recovery,
        value: recovery,
        metricDay: civilDay,
        sourceId: deviceId + "-noop",
        algorithmVersion: "v50-test",
        generation: generation,
        freshness: .fresh
    )
    return try VerifiedHealthProjection(
        contextId: contextId,
        deviceId: deviceId,
        generation: generation,
        logicalDay: civilDay,
        metrics: [.recovery: metric]
    )
}

private func makeV50WidgetCore(
    projection: VerifiedHealthProjection,
    steps: Int = 8_000
) throws -> VerifiedWidgetCorePayload {
    try VerifiedWidgetCorePayload(
        contextId: projection.contextId,
        projectionGeneration: projection.generation,
        logicalDay: projection.logicalDay,
        restingHR: 51,
        sleepMinutes: 440,
        steps: steps,
        calories: 2_100,
        recoveryDelta: 2,
        enrichmentSourceIds: [projection.deviceId, projection.deviceId + "-noop"]
    )
}

private func makeV50Receipt(
    projection: VerifiedHealthProjection,
    analysisGeneration: Int64 = 1,
    recordedTimeZoneIdentifier: String = "UTC"
) throws -> SnapshotCommitReceipt {
    try SnapshotCommitReceipt(
        throughReceiptGeneration: analysisGeneration,
        analysisGeneration: analysisGeneration,
        snapshotGeneration: projection.generation,
        analyzedDays: [projection.logicalDay],
        recordedTimeZoneIdentifier: recordedTimeZoneIdentifier,
        projection: projection
    )
}

private func temporaryV50DatabasePath() -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("whoop-v50-\(UUID().uuidString).sqlite")
        .path
}

private func makeV50TodaySnapshot(
    context: TodayHealthSnapshotContext,
    projection: VerifiedHealthProjection,
    recovery: Double = 73,
    generatedAt: Int = 1_800_000_000
) -> TodayHealthSnapshot {
    let day = projection.logicalDay.key
    let daily = DailyMetric(
        day: day,
        totalSleepMin: 440,
        efficiency: 0.9,
        deepMin: 90,
        remMin: 100,
        lightMin: 250,
        disturbances: 4,
        restingHr: 51,
        avgHrv: 62,
        recovery: recovery,
        strain: 61,
        exerciseCount: 1,
        steps: 8_000,
        activeKcalEst: 600,
        strainVersion: 2
    )
    return TodayHealthSnapshot(
        scopeId: "dashboard|\(context.identifier)",
        context: context,
        deviceId: projection.deviceId,
        displayDay: day,
        logicalDay: day,
        localDay: day,
        generatedAt: generatedAt,
        rawFrontierTs: 1_799_999_900,
        generation: projection.generation,
        authoritativeMetrics: [],
        dailyMetric: daily
    )
}

private func removeV50Database(at path: String) {
    for suffix in ["", "-wal", "-shm"] {
        try? FileManager.default.removeItem(atPath: path + suffix)
    }
}

final class PR29V50PersistenceTests: XCTestCase {
    func testRecordedV50CadenceWithoutLeaseColumnsIsRepairedByV51() async throws {
        let path = temporaryV50DatabasePath()
        defer { removeV50Database(at: path) }
        let queue = try DatabaseQueue(path: path)
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: PR29V50Migrations.identifier)
        try await queue.write { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: [PR29V50Migrations.identifier]
                ),
                1
            )
            try db.execute(sql: "DROP TABLE durableMaintenanceCadence")
            try db.execute(sql: """
                CREATE TABLE durableMaintenanceCadence (
                    key TEXT PRIMARY KEY NOT NULL,
                    lastRunAt INTEGER NOT NULL,
                    CHECK (length(key) > 0)
                )
                """)
            try db.execute(
                sql: """
                    INSERT INTO durableMaintenanceCadence (key, lastRunAt)
                    VALUES (?, 100)
                    """,
                arguments: [DurablePruningCadence.key]
            )
        }
        try queue.close()

        let store = try await WhoopStore(path: path)
        let repairedLastRunAt = try await store.maintenanceLastRunAt(
            key: DurablePruningCadence.key
        )
        XCTAssertEqual(repairedLastRunAt, Date(timeIntervalSince1970: 100))
        let leaseValue = try await store.claimMaintenanceLease(
            key: DurablePruningCadence.key,
            owner: "v51-repair-test",
            now: Date(timeIntervalSince1970: 200),
            minimumInterval: 50,
            leaseDuration: 15
        )
        let lease = try XCTUnwrap(leaseValue)
        let released = try await store.releaseMaintenanceLease(lease)
        XCTAssertTrue(released)
        try await store.close()

        let probe = try DatabaseQueue(path: path)
        try await probe.read { db in
            let columns = Set(
                try db.columns(in: "durableMaintenanceCadence").map(\.name)
            )
            XCTAssertTrue(columns.isSuperset(of: [
                "key", "lastRunAt", "leaseOwner", "leaseExpiresAt",
            ]))
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: [PR29V51Migrations.identifier]
                ),
                1
            )
        }
    }

    func testV51CleanupRowsGainNullableAuthorizationDeferralInV52() async throws {
        let path = temporaryV50DatabasePath()
        defer { removeV50Database(at: path) }
        let queue = try DatabaseQueue(path: path)
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: PR29V51Migrations.identifier)
        let cleanupWorkId = UUID()
        let transitionId = UUID()
        let contributorsJSON = try JSONEncoder().encode(Set(["source-a"]))
        let emptySourcesJSON = try JSONEncoder().encode(Set<String>())
        try await queue.write { db in
            XCTAssertFalse(
                Set(try db.columns(in: "sourcePrivacyCleanupWork").map(\.name))
                    .contains("authorizationBlockedAt")
            )
            try db.execute(sql: """
                INSERT INTO sourceTransitionJournal (
                    transitionId, version, mutationKind, sourceDeviceId,
                    targetDeviceId, previousActiveDeviceId,
                    previousSinkContextId, previousSinkEpoch,
                    contributorIdsJSON, transitionScope, cleanupWorkId,
                    historicalEpoch, externalEpoch, sinkEpoch, stage,
                    commitJSON, lastErrorCode, createdAt, updatedAt
                ) VALUES (?, 2, 'deleteData', 'source-a', NULL, 'source-a',
                          'old-context', 1, ?, 'activeProjection', ?,
                          1, 1, 1, 'complete', NULL, NULL, 100, 100)
                """, arguments: [
                    transitionId.uuidString,
                    contributorsJSON,
                    cleanupWorkId.uuidString,
                ])
            for category in SourcePrivacyCleanupCategory.allCases {
                try db.execute(sql: """
                    INSERT INTO sourcePrivacyCleanupWork (
                        cleanupWorkId, transitionId, sourceDeviceId, category,
                        remainingImportedIdsJSON, remainingComputedIdsJSON,
                        firstDay, throughDay, recordedTimeZoneIdentifier,
                        state, attemptCount, nextAttemptAt, leaseOwner,
                        leaseExpiresAt, lastErrorCode, createdAt, updatedAt
                    ) VALUES (?, ?, 'source-a', ?, ?, ?, '2026-08-08',
                              '2026-08-08', 'UTC', 'pending', 0, NULL,
                              NULL, NULL, NULL, 100, 100)
                    """, arguments: [
                        cleanupWorkId.uuidString,
                        transitionId.uuidString,
                        category.rawValue,
                        emptySourcesJSON,
                        emptySourcesJSON,
                    ])
            }
        }
        try migrator.migrate(queue)
        let columns = try await queue.read { db in
            Set(try db.columns(in: "sourcePrivacyCleanupWork").map(\.name))
        }
        XCTAssertTrue(columns.contains("authorizationBlockedAt"))
        try queue.close()

        let store = try await WhoopStore(path: path)
        let groupValue = try await store.sourcePrivacyCleanupGroup(
            cleanupWorkId: cleanupWorkId
        )
        let group = try XCTUnwrap(groupValue)
        XCTAssertEqual(group.work.count, 4)
        XCTAssertTrue(group.work.allSatisfy { $0.authorizationBlockedAt == nil })
        try await store.close()

        let probe = try DatabaseQueue(path: path)
        try await probe.read { db in
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: [PR29V52Migrations.identifier]
                ),
                1
            )
        }
    }

    func testV48TransitionMigratesToV50AndDecodesAsLegacyRecord() async throws {
        let path = temporaryV50DatabasePath()
        defer { removeV50Database(at: path) }
        let queue = try DatabaseQueue(path: path)
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v48-pr28-final-hardening")
        let transitionId = UUID()
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO sourceTransitionJournal (
                    transitionId, mutationKind, sourceDeviceId, targetDeviceId,
                    historicalEpoch, externalEpoch, sinkEpoch, stage,
                    commitJSON, lastErrorCode, createdAt, updatedAt
                ) VALUES (?, 'archive', 'source-a', 'source-b', 2, 3, 4,
                          'prepared', NULL, NULL, 100, 100)
                """, arguments: [transitionId.uuidString])
        }
        try migrator.migrate(queue)
        let migratedColumns = try await queue.read { db in
            Set(try db.columns(in: "sourceTransitionJournal").map(\.name))
        }
        let cadenceColumns = try await queue.read { db in
            Set(try db.columns(in: "durableMaintenanceCadence").map(\.name))
        }
        XCTAssertTrue(migratedColumns.isSuperset(of: [
            "version", "previousActiveDeviceId", "previousSinkContextId",
            "previousSinkEpoch", "contributorIdsJSON", "transitionScope",
            "cleanupWorkId",
        ]))
        XCTAssertTrue(cadenceColumns.isSuperset(of: ["leaseOwner", "leaseExpiresAt"]))
        try queue.close()

        let store = try await WhoopStore(path: path)
        let recoveredRecord = try await store.latestSourceTransitionRecovery()
        let recovered = try XCTUnwrap(recoveredRecord)
        XCTAssertEqual(recovered.id, transitionId)
        XCTAssertEqual(recovered.version, 1)
        XCTAssertEqual(recovered.sourceDeviceId, "source-a")
        XCTAssertEqual(recovered.previousActiveDeviceId, "source-a")
        XCTAssertEqual(recovered.contributorIds, ["source-a"])
        XCTAssertEqual(recovered.transitionScope, .activeProjection)
        XCTAssertNil(recovered.cleanupWorkId)
        XCTAssertEqual(recovered.historicalEpoch, 2)
        XCTAssertEqual(recovered.externalEpoch, 3)
        XCTAssertEqual(recovered.sinkEpoch, 4)
        XCTAssertEqual(recovered.stage, .prepared)
        try await store.close()
    }

    func testV49CheckpointMigratesAsWidgetEvidenceOnly() async throws {
        let path = temporaryV50DatabasePath()
        defer { removeV50Database(at: path) }
        let projection = try makeV50Projection()
        let core = try makeV50WidgetCore(projection: projection)
        let queue = try DatabaseQueue(path: path)
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: "v49-pr28-immutable-artifacts-and-checkpoints")
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO latestStateDeliveryCheckpoint (
                    contextId, deviceId, snapshotGeneration,
                    presentationJSON, widgetCoreJSON, logicalDay, deliveredAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    projection.contextId,
                    projection.deviceId,
                    projection.generation,
                    try JSONEncoder().encode(projection.presentationIdentity),
                    try JSONEncoder().encode(core),
                    projection.logicalDay.key,
                    100,
                ])
        }
        try migrator.migrate(queue)
        try queue.close()

        let store = try await WhoopStore(path: path)
        let widgetCheckpoint = try await store.latestStateDeliveryCheckpoint(
            contextId: projection.contextId,
            destination: .widget
        )
        let widget = try XCTUnwrap(widgetCheckpoint)
        XCTAssertEqual(widget.destination, .widget)
        XCTAssertEqual(widget.presentationIdentity, projection.presentationIdentity)
        XCTAssertEqual(widget.widgetCore, core)
        let liveCheckpoint = try await store.latestStateDeliveryCheckpoint(
            contextId: projection.contextId,
            destination: .liveActivity
        )
        XCTAssertNil(liveCheckpoint)
        try await store.close()
    }

    func testDestinationCheckpointsAreIndependentAndEqualGenerationConflictsFailClosed() async throws {
        let store = try await WhoopStore.inMemory()
        let projection = try makeV50Projection()
        let core = try makeV50WidgetCore(projection: projection)
        let firstDelivery = Date(timeIntervalSince1970: 100)
        let replayDelivery = Date(timeIntervalSince1970: 200)

        try await store.recordLatestStateDeliveryCheckpoint(
            projection: projection,
            widgetCore: core,
            destination: .widget,
            deliveredAt: firstDelivery
        )
        try await store.recordLatestStateDeliveryCheckpoint(
            projection: projection,
            widgetCore: core,
            destination: .liveActivity,
            deliveredAt: firstDelivery
        )
        try await store.recordLatestStateDeliveryCheckpoint(
            projection: projection,
            widgetCore: core,
            destination: .widget,
            deliveredAt: replayDelivery
        )

        let widgetCheckpoint = try await store.latestStateDeliveryCheckpoint(
            contextId: projection.contextId,
            destination: .widget
        )
        let liveCheckpoint = try await store.latestStateDeliveryCheckpoint(
            contextId: projection.contextId,
            destination: .liveActivity
        )
        let widget = try XCTUnwrap(widgetCheckpoint)
        let live = try XCTUnwrap(liveCheckpoint)
        XCTAssertEqual(widget.deliveredAt, replayDelivery)
        XCTAssertEqual(live.deliveredAt, firstDelivery)
        XCTAssertNotEqual(widget.identity, live.identity)

        let changedCore = try makeV50WidgetCore(projection: projection, steps: 8_001)
        do {
            try await store.recordLatestStateDeliveryCheckpoint(
                projection: projection,
                widgetCore: changedCore,
                destination: .widget,
                deliveredAt: replayDelivery
            )
            XCTFail("equal-generation Widget payload conflict was accepted")
        } catch LatestStateDeliveryCheckpointStoreError.conflictingGeneration {
            // Expected.
        }

        let changedProjection = try makeV50Projection(recovery: 74)
        do {
            try await store.recordLatestStateDeliveryCheckpoint(
                projection: changedProjection,
                widgetCore: core,
                destination: .liveActivity,
                deliveredAt: replayDelivery
            )
            XCTFail("equal-generation Live Activity payload conflict was accepted")
        } catch LatestStateDeliveryCheckpointStoreError.conflictingGeneration {
            // Expected.
        }
    }

    func testDurableMigrationProgressIsMonotonicAndCompletionIsTerminal() async throws {
        let store = try await WhoopStore.inMemory()
        let initial = try await store.durableMigrationProgress(key: "effort-rescore")
        XCTAssertNil(initial)
        let pending = try await store.saveDurableMigrationProgress(
            key: "effort-rescore",
            nextOffset: 30,
            now: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(pending.state, .pending)
        XCTAssertEqual(pending.nextOffset, 30)

        do {
            _ = try await store.saveDurableMigrationProgress(
                key: "effort-rescore",
                nextOffset: 29
            )
            XCTFail("durable migration offset moved backward")
        } catch DurableMigrationProgressStoreError.invalidProgress {
            // Expected.
        }

        let complete = try await store.markDurableMigrationComplete(
            key: "effort-rescore",
            nextOffset: 60,
            now: Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(complete.state, .complete)
        let loaded = try await store.durableMigrationProgress(key: "effort-rescore")
        XCTAssertEqual(loaded, complete)
        do {
            _ = try await store.saveDurableMigrationProgress(
                key: "effort-rescore",
                nextOffset: 90
            )
            XCTFail("completed durable migration returned to pending")
        } catch DurableMigrationProgressStoreError.invalidProgress {
            // Expected.
        }
    }

    func testMaintenanceCadenceClaimIsAtomicAndExpiredLeaseCanBeReclaimed() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date(timeIntervalSince1970: 100)
        async let first = store.claimMaintenanceLease(
            key: "prune-race",
            owner: "owner-a",
            now: now,
            minimumInterval: 100,
            leaseDuration: 15
        )
        async let second = store.claimMaintenanceLease(
            key: "prune-race",
            owner: "owner-b",
            now: now,
            minimumInterval: 100,
            leaseDuration: 15
        )
        let (firstResult, secondResult) = try await (first, second)
        let winners = [firstResult, secondResult].compactMap { $0 }
        XCTAssertEqual(winners.count, 1)

        let held = try await store.claimMaintenanceLease(
            key: "prune-race",
            owner: "owner-c",
            now: now.addingTimeInterval(14),
            minimumInterval: 100,
            leaseDuration: 15
        )
        XCTAssertNil(held)

        let reclaimedValue = try await store.claimMaintenanceLease(
            key: "prune-race",
            owner: "owner-c",
            now: now.addingTimeInterval(15),
            minimumInterval: 100,
            leaseDuration: 15
        )
        let reclaimed = try XCTUnwrap(reclaimedValue)
        try await store.completeMaintenanceLease(
            reclaimed,
            at: now.addingTimeInterval(20)
        )
        let lastRunAt = try await store.maintenanceLastRunAt(key: "prune-race")
        XCTAssertEqual(lastRunAt, now.addingTimeInterval(20))
        let notDue = try await store.claimMaintenanceLease(
            key: "prune-race",
            owner: "owner-d",
            now: now.addingTimeInterval(21),
            minimumInterval: 100,
            leaseDuration: 15
        )
        XCTAssertNil(notDue)
    }

    func testReleasedMaintenanceLeaseDoesNotAdvanceCadence() async throws {
        let store = try await WhoopStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000)
        let firstValue = try await store.claimMaintenanceLease(
            key: "prune-release",
            owner: "owner-a",
            now: now,
            minimumInterval: 100,
            leaseDuration: 60
        )
        let first = try XCTUnwrap(firstValue)
        let released = try await store.releaseMaintenanceLease(first)
        XCTAssertTrue(released)
        let secondValue = try await store.claimMaintenanceLease(
            key: "prune-release",
            owner: "owner-b",
            now: now,
            minimumInterval: 100,
            leaseDuration: 60
        )
        XCTAssertNotNil(secondValue)
    }

    func testDeleteCapturesBoundedCleanupEnvelopeAndCategoryCursorsAtomically() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let deleted = "my-whoop"
        let remaining = "remaining-source"
        let contributorIds: Set<String> = [
            deleted, deleted + "-noop", remaining, remaining + "-noop",
        ]
        try await writer.write { db in
            for (deviceId, day) in [
                (deleted, "2026-01-02"),
                (deleted + "-noop", "2026-02-03"),
                (remaining, "2025-12-31"),
                (remaining + "-noop", "2026-04-05"),
            ] {
                try db.execute(
                    sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, 'stress', 1)",
                    arguments: [deviceId, day]
                )
            }
        }
        let remainingProjection = try makeV50Projection(
            contextId: "remaining-context",
            deviceId: remaining,
            day: "2026-04-05"
        )
        let remainingReceipt = try makeV50Receipt(
            projection: remainingProjection,
            recordedTimeZoneIdentifier: "America/New_York"
        )
        _ = try await store.enqueueExternalPublications(
            snapshot: remainingReceipt,
            destinations: [.widget],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let cleanupWorkId = UUID()
        let planned = SourceTransitionRecoveryRecord(
            mutationKind: "deleteData",
            sourceDeviceId: deleted,
            targetDeviceId: nil,
            previousActiveDeviceId: deleted,
            previousSinkContextId: "deleted-context",
            previousSinkEpoch: 1,
            contributorIds: contributorIds,
            transitionScope: .activeProjection,
            cleanupWorkId: cleanupWorkId
        )
        let commitTime = Date(timeIntervalSince1970: 1_800_000_010)
        try await store.persistSourceTransitionRecovery(planned, now: commitTime)
        var prepared = planned
        prepared.historicalEpoch = 2
        prepared.externalEpoch = 2
        prepared.sinkEpoch = 2
        prepared.stage = .prepared
        try await store.persistSourceTransitionRecovery(prepared, now: commitTime)
        _ = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: deleted, consumerId: "privacy-test"),
            recovery: prepared,
            now: commitTime
        )

        let groupValue = try await store.sourcePrivacyCleanupGroup(
            cleanupWorkId: cleanupWorkId
        )
        let group = try XCTUnwrap(groupValue)
        XCTAssertEqual(group.work.count, 4)
        XCTAssertFalse(group.isTerminal)
        XCTAssertTrue(group.work.allSatisfy {
            $0.remainingImportedIds == [remaining]
                && $0.remainingComputedIds == [remaining + "-noop"]
                && $0.firstDay == "2025-12-31"
                && $0.throughDay == "2026-04-05"
                && $0.recordedTimeZoneIdentifier == "America/New_York"
                && $0.state == .pending
        })

        let firstLeaseValue = try await store.leaseNextSourcePrivacyCleanupWork(
            owner: "cleanup-worker",
            now: commitTime.addingTimeInterval(1),
            cleanupWorkId: cleanupWorkId
        )
        let firstLease = try XCTUnwrap(firstLeaseValue)
        do {
            _ = try await store.persistSourcePrivacyCleanupCursors(
                firstLease,
                owner: "cleanup-worker",
                scanCursor: Data([1]),
                cleanupCursor: nil,
                batchDayCount: 31,
                batchObjectCount: 1,
                hasMore: true,
                now: commitTime.addingTimeInterval(2)
            )
            XCTFail("unbounded cleanup batch was accepted")
        } catch SourcePrivacyCleanupStoreError.invalidWork {
            // Expected.
        }
        let retry = try await store.failSourcePrivacyCleanupWork(
            firstLease,
            owner: "cleanup-worker",
            code: "healthkit_unavailable",
            retryable: true,
            now: commitTime.addingTimeInterval(2)
        )
        XCTAssertEqual(retry.state, .retryable)
        XCTAssertEqual(retry.attemptCount, 1)

        var workerNow = commitTime.addingTimeInterval(40)
        while let leased = try await store.leaseNextSourcePrivacyCleanupWork(
            owner: "cleanup-worker",
            now: workerNow,
            cleanupWorkId: cleanupWorkId
        ) {
            _ = try await store.persistSourcePrivacyCleanupCursors(
                leased,
                owner: "cleanup-worker",
                scanCursor: leased.scanCursor,
                cleanupCursor: leased.cleanupCursor,
                batchDayCount: 30,
                batchObjectCount: 5_000,
                hasMore: false,
                now: workerNow.addingTimeInterval(1)
            )
            workerNow = workerNow.addingTimeInterval(2)
        }
        let completedValue = try await store.sourcePrivacyCleanupGroup(
            cleanupWorkId: cleanupWorkId
        )
        let completed = try XCTUnwrap(completedValue)
        XCTAssertTrue(completed.isTerminal)
        XCTAssertTrue(completed.completedSuccessfully)
        let pendingCount = try await store.pendingSourcePrivacyCleanupCount()
        XCTAssertEqual(pendingCount, 0)
    }

    func testWatermarkOnlyEvidenceDefinesCleanupBoundsBeforeLifecycleDeletion() async throws {
        let store = try await WhoopStore.inMemory()
        let deleted = "my-whoop"
        let first = try CivilDay(key: "2024-02-03")
        let through = try CivilDay(key: "2026-08-07")
        let commitTime = Date(timeIntervalSince1970: 1_800_010_000)
        try await store.recordHealthKitMutationDeliveryBatched(
            contextId: "watermark-first",
            deviceId: deleted,
            days: [first],
            analysisGeneration: 1,
            now: commitTime
        )
        try await store.recordHealthKitMutationDeliveryBatched(
            contextId: "watermark-through",
            deviceId: deleted,
            days: [through],
            analysisGeneration: 2,
            now: commitTime
        )

        let cleanupWorkId = UUID()
        let planned = SourceTransitionRecoveryRecord(
            mutationKind: "deleteData",
            sourceDeviceId: deleted,
            targetDeviceId: nil,
            previousActiveDeviceId: deleted,
            previousSinkContextId: "watermark-context",
            previousSinkEpoch: 1,
            contributorIds: [deleted, deleted + "-noop"],
            transitionScope: .activeProjection,
            cleanupWorkId: cleanupWorkId
        )
        try await store.persistSourceTransitionRecovery(planned, now: commitTime)
        var prepared = planned
        prepared.historicalEpoch = 1
        prepared.externalEpoch = 1
        prepared.sinkEpoch = 1
        prepared.stage = .prepared
        try await store.persistSourceTransitionRecovery(prepared, now: commitTime)
        _ = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: deleted, consumerId: "watermark-only-test"),
            recovery: prepared,
            now: commitTime
        )

        let groupValue = try await store.sourcePrivacyCleanupGroup(
            cleanupWorkId: cleanupWorkId
        )
        let group = try XCTUnwrap(groupValue)
        XCTAssertEqual(group.work.count, 4)
        XCTAssertTrue(group.work.allSatisfy {
            $0.firstDay == first.key
                && $0.throughDay == through.key
                && $0.state == .pending
        })
        let remainingWatermarks = try await store.healthKitMutationWatermarkDays(
            deviceId: deleted
        )
        XCTAssertTrue(remainingWatermarks.isEmpty)
    }

    func testDurableArtifactRepairCursorAdvancesPastTwentyFiveIrreparableRows() async throws {
        let path = temporaryV50DatabasePath()
        defer { removeV50Database(at: path) }
        var store = try await WhoopStore(path: path)
        var lateContext: TodayHealthSnapshotContext?
        var lateProjection: VerifiedHealthProjection?
        var lateReceipt: SnapshotCommitReceipt?

        for index in 0..<26 {
            let context = TodayHealthSnapshotContext(
                databaseInstanceId: "database-repair-\(index)",
                dashboardProfileId: "dashboard-repair-\(index)",
                sourceLineage: "my-whoop,my-whoop-noop",
                algorithmBundleVersion: "v51-test"
            )
            let projection = try makeV50Projection(
                contextId: context.identifier,
                generation: 1
            )
            let receipt = try makeV50Receipt(projection: projection)
            _ = try await store.recordVerifiedSnapshotCommit(
                receipt,
                now: Date(timeIntervalSince1970: TimeInterval(100 + index))
            )
            if index == 25 {
                lateContext = context
                lateProjection = projection
                lateReceipt = receipt
            }
        }
        let repairableContext = try XCTUnwrap(lateContext)
        let repairableProjection = try XCTUnwrap(lateProjection)
        let repairableReceipt = try XCTUnwrap(lateReceipt)
        let repairableSnapshot = makeV50TodaySnapshot(
            context: repairableContext,
            projection: repairableProjection
        )
        let savedRepairableSnapshot = try await store.saveTodayHealthSnapshot(
            repairableSnapshot
        )
        XCTAssertTrue(savedRepairableSnapshot)

        let firstPage = try await store.incompleteVerifiedArtifactRepairPage(
            limit: 25
        )
        XCTAssertEqual(firstPage.repairs.count, 25)
        XCTAssertFalse(firstPage.reachedEnd)
        XCTAssertFalse(firstPage.repairs.contains {
            $0.contextId == repairableProjection.contextId
        })
        let firstCursor = try XCTUnwrap(firstPage.nextCursor)
        do {
            try await store.saveIncompleteVerifiedArtifactRepairScanCursor(
                firstCursor,
                reachedEnd: true,
                now: Date(timeIntervalSince1970: 199)
            )
            XCTFail("artifact scan wrapped before reaching its last row")
        } catch VerifiedSnapshotCommitStoreError.invalidRepairCursor {
            // Expected.
        }
        try await store.saveIncompleteVerifiedArtifactRepairScanCursor(
            firstCursor,
            reachedEnd: false,
            now: Date(timeIntervalSince1970: 200)
        )
        try await store.close()

        // The next grant resumes after relaunch instead of rereading the oldest
        // 25 rows forever.
        store = try await WhoopStore(path: path)
        let restoredCursorValue = try await store
            .incompleteVerifiedArtifactRepairScanCursor()
        let restoredCursor = try XCTUnwrap(restoredCursorValue)
        XCTAssertEqual(restoredCursor, firstCursor)
        let secondPage = try await store.incompleteVerifiedArtifactRepairPage(
            after: restoredCursor,
            limit: 25
        )
        XCTAssertTrue(secondPage.reachedEnd)
        XCTAssertEqual(secondPage.repairs.map(\.contextId), [
            repairableProjection.contextId,
        ])

        let artifacts = try await store.verifiedExternalProjectionArtifacts(
            contextId: repairableProjection.contextId,
            generation: repairableProjection.generation
        )
        XCTAssertEqual(artifacts.projection, repairableProjection)
        XCTAssertNil(artifacts.widgetCore)
        let storedSnapshotValue = try await store.todayHealthSnapshot(
            scopeId: "dashboard|\(repairableContext.identifier)"
        )
        let storedSnapshot = try XCTUnwrap(storedSnapshotValue)
        let widgetCore = try makeV50WidgetCore(projection: repairableProjection)
        _ = try await store.repairVerifiedArtifacts(
            receipt: repairableReceipt,
            snapshot: storedSnapshot,
            widgetCore: widgetCore,
            now: Date(timeIntervalSince1970: 201)
        )
        try await store.saveIncompleteVerifiedArtifactRepairScanCursor(
            secondPage.nextCursor,
            reachedEnd: secondPage.reachedEnd,
            now: Date(timeIntervalSince1970: 202)
        )
        let clearedCursor = try await store
            .incompleteVerifiedArtifactRepairScanCursor()
        XCTAssertNil(clearedCursor)
        let strictBundleValue = try await store.verifiedExternalProjectionBundle(
            contextId: repairableProjection.contextId,
            generation: repairableProjection.generation
        )
        let strictBundle = try XCTUnwrap(strictBundleValue)
        XCTAssertEqual(strictBundle.widgetCore, widgetCore)

        let wrappedPage = try await store.incompleteVerifiedArtifactRepairPage(
            limit: 25
        )
        XCTAssertEqual(wrappedPage.repairs.count, 25)
        XCTAssertFalse(wrappedPage.repairs.contains {
            $0.contextId == repairableProjection.contextId
        })
        try await store.close()
    }

    func testIncompleteVerifiedArtifactsRepairFillsOnlyMissingPayloads() async throws {
        let store = try await WhoopStore.inMemory()
        let context = TodayHealthSnapshotContext(
            databaseInstanceId: "database-v50",
            dashboardProfileId: "dashboard-v50",
            sourceLineage: "my-whoop,my-whoop-noop",
            algorithmBundleVersion: "v50-test"
        )
        let projection = try makeV50Projection(contextId: context.identifier)
        let receipt = try makeV50Receipt(projection: projection)
        let core = try makeV50WidgetCore(projection: projection)
        let snapshot = makeV50TodaySnapshot(context: context, projection: projection)

        _ = try await store.recordVerifiedSnapshotCommit(
            receipt,
            now: Date(timeIntervalSince1970: 100)
        )
        let incomplete = try await store.incompleteVerifiedArtifactRepairs()
        XCTAssertEqual(incomplete.count, 1)
        XCTAssertTrue(incomplete[0].missingSnapshot)
        XCTAssertTrue(incomplete[0].missingWidgetCore)

        _ = try await store.repairVerifiedArtifacts(
            receipt: receipt,
            snapshot: snapshot,
            widgetCore: core,
            now: Date(timeIntervalSince1970: 101)
        )
        let remainingRepairs = try await store.incompleteVerifiedArtifactRepairs()
        XCTAssertTrue(remainingRepairs.isEmpty)
        let repairedSnapshot = try await store.verifiedTodaySnapshot(
            contextId: projection.contextId,
            analysisGeneration: receipt.analysisGeneration
        )
        XCTAssertEqual(repairedSnapshot, snapshot)
        let repairedBundle = try await store.verifiedExternalProjectionBundle(
            contextId: projection.contextId,
            generation: projection.generation
        )
        XCTAssertEqual(repairedBundle?.widgetCore, core)

        _ = try await store.ensureVerifiedArtifacts(
            receipt: receipt,
            snapshot: snapshot,
            widgetCore: core,
            now: Date(timeIntervalSince1970: 102)
        )

        let conflictingSnapshot = makeV50TodaySnapshot(
            context: context,
            projection: projection,
            recovery: 74,
            generatedAt: 1_800_000_001
        )
        do {
            _ = try await store.repairVerifiedArtifacts(
                receipt: receipt,
                snapshot: conflictingSnapshot,
                widgetCore: core
            )
            XCTFail("verified snapshot artifact was overwritten")
        } catch VerifiedSnapshotCommitStoreError.conflictingReplay {
            // Expected.
        }
        let conflictingCore = try makeV50WidgetCore(
            projection: projection,
            steps: 8_001
        )
        do {
            _ = try await store.repairVerifiedArtifacts(
                receipt: receipt,
                snapshot: snapshot,
                widgetCore: conflictingCore
            )
            XCTFail("verified Widget artifact was overwritten")
        } catch VerifiedSnapshotCommitStoreError.conflictingReplay {
            // Expected.
        }
    }

    func testArtifactRepairRollsBackWhenPublicationAdmissionConflicts() async throws {
        let store = try await WhoopStore.inMemory()
        let context = TodayHealthSnapshotContext(
            databaseInstanceId: "database-v50-atomic",
            dashboardProfileId: "dashboard-v50-atomic",
            sourceLineage: "source-a,source-a-noop",
            algorithmBundleVersion: "v50-test"
        )
        let projection = try makeV50Projection(
            contextId: context.identifier,
            deviceId: "source-a"
        )
        let receipt = try makeV50Receipt(projection: projection)
        let snapshot = makeV50TodaySnapshot(context: context, projection: projection)
        let core = try makeV50WidgetCore(projection: projection)
        _ = try await store.recordVerifiedSnapshotCommit(
            receipt,
            now: Date(timeIntervalSince1970: 100)
        )

        // A corrupted cross-device checkpoint forces destination planning to fail after artifact repair
        // starts. The enclosing SQLite transaction must make both artifacts invisible again.
        let conflictingProjection = try makeV50Projection(
            contextId: context.identifier,
            deviceId: "source-b"
        )
        let conflictingCore = try makeV50WidgetCore(projection: conflictingProjection)
        try await store.recordLatestStateDeliveryCheckpoint(
            projection: conflictingProjection,
            widgetCore: conflictingCore,
            destination: .widget,
            deliveredAt: Date(timeIntervalSince1970: 101)
        )
        do {
            _ = try await store.repairVerifiedArtifactsAndEnqueueExternalPublications(
                receipt: receipt,
                snapshot: snapshot,
                widgetCore: core,
                now: Date(timeIntervalSince1970: 102)
            )
            XCTFail("artifact repair committed without publication admission")
        } catch ExternalPublicationStoreError.invalidCheckpoint {
            // Expected.
        }

        let rolledBackSnapshot = try await store.verifiedTodaySnapshot(
            contextId: projection.contextId,
            analysisGeneration: receipt.analysisGeneration
        )
        XCTAssertNil(rolledBackSnapshot)
        let rolledBackArtifacts = try await store.verifiedExternalProjectionArtifacts(
            contextId: projection.contextId,
            generation: projection.generation
        )
        XCTAssertNil(rolledBackArtifacts.widgetCore)
        let stillIncomplete = try await store.incompleteVerifiedArtifactRepairs()
        XCTAssertEqual(stillIncomplete.count, 1)
        XCTAssertTrue(stillIncomplete[0].missingSnapshot)
        XCTAssertTrue(stillIncomplete[0].missingWidgetCore)

        let clearedConflict = try await store.clearLatestStateDeliveryCheckpoint(
            contextId: projection.contextId,
            destination: .widget
        )
        XCTAssertTrue(clearedConflict)
        let destinations = try await store
            .repairVerifiedArtifactsAndEnqueueExternalPublications(
                receipt: receipt,
                snapshot: snapshot,
                widgetCore: core,
                now: Date(timeIntervalSince1970: 103)
            )
        XCTAssertEqual(destinations, [.widget, .liveActivity])
        let repairedSnapshot = try await store.verifiedTodaySnapshot(
            contextId: projection.contextId,
            analysisGeneration: receipt.analysisGeneration
        )
        XCTAssertEqual(repairedSnapshot, snapshot)
        let repairedBundle = try await store.verifiedExternalProjectionBundle(
            contextId: projection.contextId,
            generation: projection.generation
        )
        XCTAssertEqual(repairedBundle?.widgetCore, core)
        XCTAssertEqual(repairedBundle?.widgetCore.recoveryDelta, 2)
        let widgetItem = try await store.leaseNextExternalPublication(
            owner: "widget-worker",
            now: Date(timeIntervalSince1970: 104),
            preferredDestination: .widget
        )
        XCTAssertNotNil(widgetItem)
        let liveItem = try await store.leaseNextExternalPublication(
            owner: "live-worker",
            now: Date(timeIntervalSince1970: 104),
            preferredDestination: .liveActivity
        )
        XCTAssertNotNil(liveItem)
    }
}
