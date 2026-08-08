import XCTest
import GRDB
import NoopPhase34Core
@testable import WhoopStore

private final class SQLTraceCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class PR28RootFixMigrationTests: XCTestCase {
    func testRootFixMigrationPersistsDurableStateColumns() async throws {
        let store = try await WhoopStore.inMemory()

        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 48)
        let workColumns = Set(try await store.columnNamesForTest(table: "historicalAnalysisWork"))
        let snapshotColumns = Set(try await store.columnNamesForTest(table: "verifiedSnapshotCommit"))
        let outboxColumns = Set(try await store.columnNamesForTest(table: "externalPublicationOutbox"))
        XCTAssertTrue(
            workColumns.isSuperset(of: ["resumePhase", "recordedTimeZoneIdentifier"])
        )
        XCTAssertTrue(
            snapshotColumns.isSuperset(of: ["recordedTimeZoneIdentifier", "healthKitPayloadJSON"])
        )
        XCTAssertTrue(
            outboxColumns.isSuperset(of: ["recordedTimeZoneIdentifier", "destinationPayloadJSON"])
        )
    }

    func testV43RowsMigrateBlockedStatesResumePhaseAndRecordedZone() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v43-phase34-schema-validation")

        let affectedDays = Data("[\"2026-01-02\"]".utf8)
        let workKind = Data("{\"kind\":\"exactDays\"}".utf8)
        let pendingDestinations = Data("[]".utf8)
        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO historicalAnalysisWork (
                    workId, databaseInstanceId, sourceId, deviceId, lineage, cursorEpoch, trimScope,
                    firstReceiptGeneration, lastReceiptGeneration, minimumTs, maximumTs, affectedDaysJSON,
                    recordedTimeZoneIdentifier, workKindKey, workKindJSON, priority, state, attemptCount,
                    nextAttemptAt, leaseOwner, leaseExpiresAt, analyzedThroughReceiptGeneration,
                    analysisGeneration, snapshotGeneration, pendingDestinationsJSON, lastErrorCode,
                    createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "work-legacy", "db-legacy", "source", "device", "lineage", 0, "trim", 1, 1,
                    100, 200, affectedDays, "America/New_York", "exactDays", workKind, 4,
                    "repositoryPublished", 0, nil, "lease-owner", 200, 1, 3, 2, pendingDestinations,
                    nil, 100, 100,
                ])

            try db.execute(sql: """
                INSERT INTO analysisMutationJournal (
                    generation, workId, databaseInstanceId, sourceId, deviceId, lineage, cursorEpoch,
                    trimScope, throughReceiptGeneration, analyzedDaysJSON, rawFrontierTs,
                    algorithmBundleVersion, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    3, "work-legacy", "db-legacy", "source", "device", "lineage", 0, "trim", 1,
                    affectedDays, 200, "test", 100,
                ])

            try db.execute(sql: """
                INSERT INTO verifiedHealthProjection
                    (contextId, deviceId, snapshotGeneration, projectionJSON, createdAt)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: ["ctx", "device", 2, Data("{}".utf8), 100])

            try db.execute(sql: """
                INSERT INTO verifiedSnapshotCommit (
                    contextId, deviceId, analysisGeneration, throughReceiptGeneration,
                    snapshotGeneration, changedDaysJSON, createdAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: ["ctx", "device", 3, 1, 2, affectedDays, 100])

            try db.execute(sql: """
                INSERT INTO externalPublicationOutbox (
                    idempotencyKey, contextId, deviceId, snapshotGeneration, analysisGeneration,
                    changedDaysJSON, destination, state, attemptCount, nextAttemptAt, leaseOwner,
                    leaseExpiresAt, lastErrorCode, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    "hk-old", "ctx", "device", 2, 3, affectedDays, "healthKit", "inFlight", 0,
                    nil, "lease-owner", 200, nil, 100, 100,
                ])
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let work = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT state, resumePhase, leaseOwner FROM historicalAnalysisWork WHERE workId = ?",
                arguments: ["work-legacy"]
            ))
            XCTAssertEqual(work["state"] as String?, "repositoryPublished")
            XCTAssertEqual(work["resumePhase"] as String?, "outboxCommit")
            XCTAssertEqual(work["leaseOwner"] as String?, "lease-owner")

            let snapshot = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT recordedTimeZoneIdentifier FROM verifiedSnapshotCommit WHERE contextId = ?",
                arguments: ["ctx"]
            ))
            XCTAssertEqual(snapshot["recordedTimeZoneIdentifier"] as String?, "America/New_York")

            let outbox = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT state, recordedTimeZoneIdentifier, destinationPayloadJSON, leaseOwner, lastErrorCode FROM externalPublicationOutbox WHERE idempotencyKey = ?",
                arguments: ["hk-old"]
            ))
            XCTAssertEqual(outbox["state"] as String?, "blocked")
            XCTAssertEqual(outbox["recordedTimeZoneIdentifier"] as String?, "America/New_York")
            XCTAssertNil(outbox["destinationPayloadJSON"] as Data?)
            XCTAssertNil(outbox["leaseOwner"] as String?)
            XCTAssertEqual(outbox["lastErrorCode"] as String?, "legacy_healthkit_payload_requires_repair")
        }
    }

    func testV46ToV47BackfillsMaximumSucceededWatermarkAndCreatesValidatedLedgers() throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v46-pr28-followup-delivery-ordering")
        let changedDays = try JSONEncoder().encode(Set([try CivilDay(key: "2026-08-01")]))

        try dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO verifiedHealthProjection
                    (contextId, deviceId, snapshotGeneration, projectionJSON, createdAt)
                VALUES ('context', 'device', 1, '{}', 100)
                """)

            func insert(_ key: String, generation: Int64, state: String, updatedAt: Int) throws {
                try db.execute(sql: """
                    INSERT INTO externalPublicationOutbox (
                        idempotencyKey, contextId, deviceId, snapshotGeneration, analysisGeneration,
                        changedDaysJSON, recordedTimeZoneIdentifier, destination, state, attemptCount,
                        nextAttemptAt, leaseOwner, leaseExpiresAt, lastErrorCode, createdAt, updatedAt
                    ) VALUES (?, ?, ?, ?, ?, ?, 'UTC', ?, ?, 0, NULL, NULL, NULL, NULL, ?, ?)
                    """, arguments: [
                        key, "context", "device", 1, generation, changedDays,
                        "healthKit", state, 100, updatedAt
                    ])
            }
            try insert("hk-succeeded-5", generation: 5, state: "succeeded", updatedAt: 100)
            try insert("hk-succeeded-8", generation: 8, state: "succeeded", updatedAt: 200)
            try insert("hk-retryable-99", generation: 99, state: "retryable", updatedAt: 300)
            try insert("hk-quarantined-100", generation: 100, state: "quarantined", updatedAt: 400)

            try db.execute(sql: """
                INSERT INTO externalPublicationOutbox (
                    idempotencyKey, contextId, deviceId, snapshotGeneration, analysisGeneration,
                    changedDaysJSON, recordedTimeZoneIdentifier, destination, state, attemptCount,
                    nextAttemptAt, leaseOwner, leaseExpiresAt, lastErrorCode, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, 'UTC', 'healthKit', 'succeeded', 0,
                          NULL, NULL, NULL, NULL, ?, ?)
                """, arguments: [
                    "hk-malformed-succeeded", "context", "device", 1, 77,
                    Data("not-json".utf8), 500, 500
                ])
        }

        try migrator.migrate(dbQueue)

        try dbQueue.read { db in
            let generation = try Int64.fetchOne(db, sql: """
                SELECT analysisGeneration FROM healthKitMutationWatermark
                WHERE contextId = 'context' AND day = '2026-08-01'
                """)
            XCTAssertEqual(generation, 8)

            let malformed = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT state, lastErrorCode, leaseOwner, leaseExpiresAt
                    FROM externalPublicationOutbox
                    WHERE idempotencyKey = 'hk-malformed-succeeded'
                    """
            ))
            XCTAssertEqual(malformed["state"] as String?, "quarantined")
            XCTAssertEqual(
                malformed["lastErrorCode"] as String?,
                "v48_malformed_succeeded_healthkit_evidence"
            )
            XCTAssertNil(malformed["leaseOwner"] as String?)
            XCTAssertNil(malformed["leaseExpiresAt"] as Int?)

            let tables = Set(try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name IN ('healthKitSleepDayLedger', 'healthKitSleepKeyLedger')
                """))
            XCTAssertEqual(tables, ["healthKitSleepDayLedger", "healthKitSleepKeyLedger"])

            let indexes = Set(try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'index' AND name IN (
                    'idx_healthKitMutationWatermark_device_day',
                    'idx_healthKitSleepDayLedger_device_day',
                    'idx_healthKitSleepKeyLedger_device_day'
                )
                """))
            XCTAssertEqual(indexes, [
                "idx_healthKitMutationWatermark_device_day",
                "idx_healthKitSleepDayLedger_device_day",
                "idx_healthKitSleepKeyLedger_device_day"
            ])
            XCTAssertEqual(
                try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").count,
                0
            )
        }
    }

    func testSixtyFourDayWatermarkDeliveryUsesOneEligibilitySelectAndOneUpsert() async throws {
        let store = try await WhoopStore.inMemory()
        let days = try consecutiveDays(count: 64)
        let writer = await store.dbWriter
        let trace = SQLTraceCollector()
        try await writer.read { db in
            db.trace(options: .statement) { event in
                if case let .statement(statement) = event {
                    trace.append(statement.sql)
                }
            }
        }

        _ = try await store.eligibleHealthKitMutationDaysBatched(
            contextId: "context",
            deviceId: "device",
            days: days,
            analysisGeneration: 8)
        try await store.recordHealthKitMutationDeliveryBatched(
            contextId: "context",
            deviceId: "device",
            days: days,
            analysisGeneration: 8,
            now: Date(timeIntervalSince1970: 1_800_000_000))

        try await writer.read { db in db.trace(options: []) }
        let statements = trace.snapshot()
        let normalized = statements.map { $0.replacingOccurrences(of: "\n", with: " ") }
        let eligibilityReads = normalized.filter {
            $0.range(of: "FROM healthKitMutationWatermark", options: .caseInsensitive) != nil
        }
        let watermarkWrites = normalized.filter {
            $0.range(of: "INSERT INTO healthKitMutationWatermark", options: .caseInsensitive) != nil
        }
        XCTAssertEqual(eligibilityReads.count, 1, normalized.joined(separator: "\n"))
        XCTAssertEqual(watermarkWrites.count, 1, normalized.joined(separator: "\n"))
    }

    func testIdentitySafeWatermarkReplayRejectsDifferentSourceWithoutRewritingOwner() async throws {
        let store = try await WhoopStore.inMemory()
        let day = try CivilDay(key: "2026-08-03")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        try await store.recordHealthKitMutationDeliveryIdentitySafe(
            contextId: "context",
            deviceId: "source-A",
            days: [day],
            analysisGeneration: 7,
            now: now)
        try await store.recordHealthKitMutationDeliveryIdentitySafe(
            contextId: "context",
            deviceId: "source-A",
            days: [day],
            analysisGeneration: 7,
            now: now.addingTimeInterval(1))

        do {
            try await store.recordHealthKitMutationDeliveryIdentitySafe(
                contextId: "context",
                deviceId: "source-B",
                days: [day],
                analysisGeneration: 8,
                now: now.addingTimeInterval(2))
            XCTFail("different source rewrote the exact HealthKit watermark owner")
        } catch let error as HealthKitWatermarkConflict {
            XCTAssertEqual(
                error,
                .deviceIdentityChanged(
                    contextId: "context",
                    day: day,
                    existing: "source-A",
                    incoming: "source-B"))
        }

        let writer = await store.dbWriter
        let ownerAndGeneration: (String, Int64)? = try await writer.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT deviceId, analysisGeneration
                FROM healthKitMutationWatermark
                WHERE contextId = ? AND day = ?
                """, arguments: ["context", day.key]) else { return nil }
            return (row["deviceId"], row["analysisGeneration"])
        }
        XCTAssertEqual(ownerAndGeneration?.0, "source-A")
        XCTAssertEqual(ownerAndGeneration?.1, 7)
    }

    func testPrivacyFootprintReadsDeletionOnlyHealthKitEvidenceBySource() async throws {
        let store = try await WhoopStore.inMemory()
        let day = try CivilDay(key: "2026-08-04")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sleepEntry = HealthKitSleepLedgerEntry(
            wakeDay: day,
            stableStartTimestamp: 1_800_000_100,
            externalUUID: "noop:source-A:sleep:1800000100")

        try await store.recordHealthKitMutationDeliveryIdentitySafe(
            contextId: "context-A",
            deviceId: "source-A",
            days: [day],
            analysisGeneration: 4,
            now: now)
        try await store.replaceHealthKitSleepLedger(
            contextId: "context-A",
            deviceId: "source-A",
            days: [day],
            entries: [sleepEntry],
            analysisGeneration: 4,
            now: now)

        let deliveredDays = try await store.healthKitMutationWatermarkDays(deviceId: "source-A")
        let sleepEntries = try await store.healthKitSleepLedgerEntries(deviceId: "source-A")
        let unrelatedDays = try await store.healthKitMutationWatermarkDays(deviceId: "source-B")
        XCTAssertEqual(deliveredDays, [day])
        XCTAssertEqual(sleepEntries, [sleepEntry])
        XCTAssertTrue(unrelatedDays.isEmpty)
    }

    func testSleepLedgerRetainsZeroSessionCoverageAndStableKeysForDeletionReplay() async throws {
        let store = try await WhoopStore.inMemory()
        let day = try CivilDay(key: "2026-08-01")
        let entry = HealthKitSleepLedgerEntry(
            wakeDay: day,
            stableStartTimestamp: 1_785_542_400,
            externalUUID: "sleep-key")
        try await store.replaceHealthKitSleepLedger(
            contextId: "context",
            deviceId: "device",
            days: [day],
            entries: [entry],
            analysisGeneration: 4,
            now: Date(timeIntervalSince1970: 1_800_000_000))

        let populated = try await store.healthKitSleepLedger(
            contextId: "context", deviceId: "device", days: [day])
        XCTAssertEqual(populated.coveredDays, [day])
        XCTAssertEqual(populated.entries, [entry])

        try await store.replaceHealthKitSleepLedger(
            contextId: "context",
            deviceId: "device",
            days: [day],
            entries: [],
            analysisGeneration: 5,
            now: Date(timeIntervalSince1970: 1_800_000_001))
        let deletionOnly = try await store.healthKitSleepLedger(
            contextId: "context", deviceId: "device", days: [day])
        XCTAssertEqual(deletionOnly.coveredDays, [day])
        XCTAssertTrue(deletionOnly.entries.isEmpty)
    }

    func testOrdinarySelectionAtoBKeepsOldSourcePairedAndHistoricalWork() async throws {
        let registryDatabase = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(registryDatabase)
        let registry = DeviceRegistryStore(dbQueue: registryDatabase)
        try registry.add(PairedDevice(
            id: "device-b",
            brand: "Polar",
            model: "H10",
            sourceKind: .liveBLE,
            capabilities: [.hr, .hrv],
            status: .paired,
            addedAt: 1,
            lastSeenAt: 1))
        try registry.setActive("device-b")
        XCTAssertEqual(try registry.activeDeviceId(), "device-b")
        XCTAssertEqual(try registry.all().first { $0.id == "my-whoop" }?.status, .paired)

        // This is the durable outbox half of an ordinary A -> B selection. Only latest-state
        // rows are superseded; old-source HealthKit work and its watermark remain admissible.
        let store = try await WhoopStore.inMemory()
        let day = try CivilDay(key: "2026-08-02")
        let metric = try VerifiedHealthMetric(
            kind: .recovery,
            value: 82,
            metricDay: day,
            sourceId: "source-a",
            algorithmVersion: "r3-test",
            generation: 1,
            freshness: .fresh)
        let projection = try VerifiedHealthProjection(
            contextId: "context-a",
            deviceId: "device-a",
            generation: 1,
            logicalDay: day,
            metrics: [.recovery: metric])
        let payload = try HistoricalHealthKitMutationPayload(
            contextId: "context-a",
            deviceId: "device-a",
            analysisGeneration: 1,
            recordedTimeZoneIdentifier: "UTC",
            changedDays: [day],
            dailyMutations: [],
            sleepMutations: [])
        let receipt = try SnapshotCommitReceipt(
            throughReceiptGeneration: 1,
            analysisGeneration: 1,
            snapshotGeneration: 1,
            analyzedDays: [day],
            recordedTimeZoneIdentifier: "UTC",
            healthKitPayload: payload,
            projection: projection)

        _ = try await store.enqueueExternalPublications(
            snapshot: receipt,
            destinations: [.widget, .healthKit],
            now: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.recordHealthKitMutationDeliveryBatched(
            contextId: "context-a",
            deviceId: "device-a",
            days: [day],
            analysisGeneration: 1,
            now: Date(timeIntervalSince1970: 1_800_000_001))

        _ = try await store.retireLatestStatePublications(contextId: "context-a")

        let writer = await store.dbWriter
        try await writer.read { db in
            let states = try Dictionary(uniqueKeysWithValues: Row.fetchAll(db, sql: """
                SELECT destination, state
                FROM externalPublicationOutbox
                WHERE contextId = 'context-a'
                """).map { row in
                (try XCTUnwrap(row["destination"] as String?), try XCTUnwrap(row["state"] as String?))
            })
            XCTAssertEqual(states["widget"], "superseded")
            XCTAssertEqual(states["healthKit"], "pending")

            let watermark = try Int64.fetchOne(db, sql: """
                SELECT analysisGeneration
                FROM healthKitMutationWatermark
                WHERE contextId = 'context-a' AND deviceId = 'device-a' AND day = '2026-08-02'
                """)
            XCTAssertEqual(watermark, 1)
        }

        try await store.deleteExternalPublicationState(deviceId: "device-a")
        try await writer.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM externalPublicationOutbox"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM healthKitMutationWatermark"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM verifiedHealthProjection"), 0)
        }
    }

    func testCanonicalHealthSurfaceBatchesSparseWindowsIntoFourTableReads() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let trace = SQLTraceCollector()
        try await writer.read { db in
            db.trace(options: .statement) { event in
                if case let .statement(statement) = event {
                    trace.append(statement.sql)
                }
            }
        }

        _ = try await store.canonicalHealthSurfaceSnapshot(
            sourceIds: ["device"],
            windows: [
                CanonicalHealthSurfaceReadWindow(
                    fromDay: "2026-08-01", throughDay: "2026-08-03",
                    sleepFromTs: 1_785_456_000, sleepThroughTs: 1_785_844_800),
                CanonicalHealthSurfaceReadWindow(
                    fromDay: "2026-08-02", throughDay: "2026-08-04",
                    sleepFromTs: 1_785_542_400, sleepThroughTs: 1_785_931_200),
                CanonicalHealthSurfaceReadWindow(
                    fromDay: "2026-08-20", throughDay: "2026-08-20",
                    sleepFromTs: 1_787_097_600, sleepThroughTs: 1_787_184_000)
            ],
            metricKeys: ["sleep_performance"])

        try await writer.read { db in db.trace(options: []) }
        let statements = trace.snapshot()
        let tableQueries = statements.filter { sql in
            let normalized = sql.replacingOccurrences(of: "\n", with: " ")
            return ["dailyMetric", "sleepSession", "metricSeries", "appleDaily"]
                .contains { normalized.range(of: $0, options: .caseInsensitive) != nil }
        }
        XCTAssertEqual(tableQueries.count, 4, statements.joined(separator: "\n"))
    }

    func testCanonicalHealthSurfaceUsesIndexedRangeSeeksForEveryTable() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        try await writer.read { db in
            let dayRanges = [CanonicalHealthIndexedRangePlanner.DayRange(
                from: "2016-01-01", through: "2016-01-03")]
            let sleepRanges = [CanonicalHealthIndexedRangePlanner.TimestampRange(
                fromExclusive: 1_451_600_000, throughInclusive: 1_451_900_000)]

            func detail(_ sql: String, _ arguments: StatementArguments) throws -> String {
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
                    .compactMap { $0["detail"] as String? }
                    .joined(separator: "\n")
            }

            let daily = try detail(
                WhoopStore.indexedCanonicalDailySQL(sourceCount: 1, rangeCount: 1),
                WhoopStore.canonicalDailyArguments(ranges: dayRanges, sourceIds: ["device"]))
            let metric = try detail(
                WhoopStore.indexedCanonicalMetricSQL(sourceCount: 1, keyCount: 1, rangeCount: 1),
                WhoopStore.canonicalMetricArguments(
                    ranges: dayRanges, sourceIds: ["device"], metricKeys: ["stress"]))
            let apple = try detail(
                WhoopStore.indexedCanonicalAppleSQL(sourceCount: 1, rangeCount: 1),
                WhoopStore.canonicalDailyArguments(ranges: dayRanges, sourceIds: ["apple-health"]))
            let sleep = try detail(
                WhoopStore.indexedCanonicalSleepSQL(sourceCount: 1, rangeCount: 1),
                WhoopStore.canonicalSleepArguments(ranges: sleepRanges, sourceIds: ["device"]))

            XCTAssertTrue(daily.contains("SEARCH d USING INDEX") && daily.contains("day>?"), daily)
            XCTAssertTrue(metric.contains("SEARCH m USING INDEX") && metric.contains("key=?") && metric.contains("day>?"), metric)
            XCTAssertTrue(apple.contains("SEARCH a USING INDEX") && apple.contains("day>?"), apple)
            XCTAssertTrue(sleep.contains("SEARCH s USING INDEX") && sleep.contains("endTs>?"), sleep)
            XCTAssertFalse([daily, metric, apple, sleep].joined().contains("CORRELATED SCALAR"))
        }
    }

    func testFullHistoryRepairLeaseCancellationIsImmediateAndDoesNotConsumeAttempt() async throws {
        let store = try await WhoopStore.inMemory()
        let databaseId = try await store.databaseInstanceId()
        let scope = try HistoricalAnalysisScope(
            databaseInstanceId: databaseId,
            sourceId: "legacy-source",
            deviceId: "legacy-device",
            deviceLineageId: "legacy-lineage",
            cursorEpoch: 0,
            trimScope: "historical")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let writer = await store.dbWriter
        try await writer.write { db in
            try WhoopStore.upsertFullHistoryRepairMaintenance(
                scope: scope,
                throughReceiptGeneration: 7,
                reasons: ["legacy_receipt_v1"],
                now: now,
                in: db)
        }

        let leased = try await store.leaseNextFullHistoryRepair(
            owner: "maintenance-test", now: now, leaseDuration: 90)
        let work = try XCTUnwrap(leased)
        XCTAssertEqual(work.state, .running)
        XCTAssertEqual(work.attemptCount, 0)

        try await store.cancelFullHistoryRepairLease(work, owner: "maintenance-test", now: now)
        try await writer.read { db in
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: "SELECT state, attemptCount, leaseOwner, lastErrorCode FROM historicalMaintenanceWork WHERE workId = ?",
                arguments: [work.id.uuidString]))
            XCTAssertEqual(row["state"] as String?, "retryable")
            XCTAssertEqual(row["attemptCount"] as Int?, 0)
            XCTAssertNil(row["leaseOwner"] as String?)
            XCTAssertEqual(row["lastErrorCode"] as String?, "owner_cancelled")
        }
    }

    func testFullHistoryRepairProgressPersistsChronologicalCursorAndRecordedZone() async throws {
        let store = try await WhoopStore.inMemory()
        let databaseId = try await store.databaseInstanceId()
        let scope = try HistoricalAnalysisScope(
            databaseInstanceId: databaseId,
            sourceId: "legacy-source",
            deviceId: "legacy-device",
            deviceLineageId: "legacy-lineage",
            cursorEpoch: 0,
            trimScope: "historical")
        let cursorScope = HistoricalCursorScope(
            deviceId: scope.deviceId,
            lineage: scope.deviceLineageId,
            cursorEpoch: scope.cursorEpoch,
            trimScope: scope.trimScope)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let writer = await store.dbWriter
        try await writer.write { db in
            try WhoopStore.upsertFullHistoryRepairMaintenance(
                scope: scope,
                throughReceiptGeneration: 7,
                reasons: ["legacy_receipt_v1"],
                recordedTimeZoneIdentifier: "America/New_York",
                now: now,
                in: db)
        }

        let first = try await store.leaseNextFullHistoryRepair(
            owner: "maintenance-cursor-test", now: now, leaseDuration: 90, scope: cursorScope)
        let work = try XCTUnwrap(first)
        let nextDay = try CivilDay(key: "2016-01-15")
        try await store.markFullHistoryRepairProgress(
            work,
            owner: "maintenance-cursor-test",
            hasMore: true,
            nextStartDay: nextDay,
            now: now)

        let resumed = try await store.leaseNextFullHistoryRepair(
            owner: "maintenance-cursor-test-2", now: now, leaseDuration: 90, scope: cursorScope)
        let resumedWork = try XCTUnwrap(resumed)
        XCTAssertEqual(resumedWork.nextStartDay, nextDay)
        XCTAssertEqual(resumedWork.recordedTimeZoneIdentifier, "America/New_York")
        XCTAssertEqual(resumedWork.attemptCount, 0)
    }

    private func consecutiveDays(count: Int) throws -> Set<CivilDay> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return try Set((0..<count).map { offset in
            try CivilDay(key: formatter.string(from: calendar.date(byAdding: .day, value: offset, to: start)!))
        })
    }
}
