import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class MigrationTests: XCTestCase {
    func testInMemoryRunsMigrations() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for t in [
            "device", "hrSample", "rrInterval", "event", "battery", "rawBatch",
            "coachingBehaviorSet", "coachingBehaviorMembership",
            "coachingStack", "coachingStackItem", "coachingStackUse",
            "ppgWaveformSample", "todayHealthSnapshot", "historicalDataCommitJournal",
            "historicalReceiptConsumer", "historicalAnalysisWork", "analysisMutationJournal",
            "verifiedHealthProjection", "verifiedSnapshotCommit", "externalPublicationOutbox",
        ] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 43)
    }

    func testFileInitRunsMigrations() async throws {
        let path = NSTemporaryDirectory() + "whoopstore-\(UUID().uuidString).sqlite"
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let store = try await WhoopStore(path: path)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("hrSample"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testV36HistoricalReceiptSchemaRequiresDurableIdentityAndRawEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let receiptColumns = Set(try await store.columnNamesForTest(table: "historicalDataCommitJournal"))
        let cursorColumns = Set(try await store.columnNamesForTest(table: "historicalCursor"))
        let pairedDeviceColumns = Set(try await store.columnNamesForTest(table: "pairedDevice"))

        XCTAssertTrue(receiptColumns.isSuperset(of: [
            "fingerprint", "lineage", "cursorEpoch", "trimScope", "rawStatus", "rawRangeJSON",
        ]))
        XCTAssertTrue(cursorColumns.isSuperset(of: [
            "deviceId", "lineage", "cursorEpoch", "trimScope", "watermarkGeneration",
        ]))
        XCTAssertTrue(pairedDeviceColumns.isSuperset(of: ["historyLineage", "historyCursorEpoch"]))
    }

    func testV36MarksLegacyReceiptsBeforeNewFingerprintBinding() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v35-historical-data-commit-journal")
        let countsJSON = try JSONEncoder().encode(HistoricalStreamInsertCounts(hr: 1))

        try await dbQueue.write { db in
            let databaseInstanceId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")
            )
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix, committedAt,
                     rawBatchId, insertedRowsJSON)
                VALUES (?, ?, ?, ?, ?, ?, NULL, ?)
                """, arguments: [
                    "legacy-receipt", databaseInstanceId, "my-whoop", 42, 100, 101, countsJSON,
                ])
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT fingerprint FROM historicalDataCommitJournal WHERE receiptId = 'legacy-receipt'"
                ),
                "legacy:legacy-receipt"
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db,
                    sql: "SELECT rawStatus FROM historicalDataCommitJournal WHERE receiptId = 'legacy-receipt'"
                ),
                "disabled"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM historicalCursor WHERE deviceId = 'my-whoop'"
                ),
                1
            )
        }
    }

    func testV37ScopesRawBatchIdentityAndSchemaVersion() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v36-historical-data-receipt-hardening")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES ('legacy-batch', 'legacy-device', 1, 2, 3, 4, 5, 0, 0, ?, NULL)
                """, arguments: [Data([0, 0, 0, 0])])
        }
        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            let columns = Set(try db.columns(in: "rawBatch").map(\.name))
            XCTAssertTrue(columns.isSuperset(of: ["lineage", "cursorEpoch"]))
            XCTAssertEqual(
                try db.primaryKey("rawBatch").columns,
                ["batchId", "deviceId", "lineage", "cursorEpoch"]
            )
            XCTAssertEqual(
                try String.fetchOne(
                    db, sql: "SELECT lineage FROM rawBatch WHERE batchId = 'legacy-batch'"
                ),
                "device:legacy-device"
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db, sql: "SELECT cursorEpoch FROM rawBatch WHERE batchId = 'legacy-batch'"
                ),
                0
            )
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 43)
    }

    func testV37MigratesLegacyRawBatchIntoItsReceiptScope() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v35-historical-data-commit-journal")
        let countsJSON = try JSONEncoder().encode(HistoricalStreamInsertCounts(hr: 1))

        try await dbQueue.write { db in
            let databaseInstanceId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")
            )
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES ('legacy-batch', 'my-whoop', 1, 2, 3, 4, 5, 0, 0, ?, NULL)
                """, arguments: [Data([0, 0, 0, 0])])
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal
                    (receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix, committedAt,
                     rawBatchId, insertedRowsJSON)
                VALUES ('legacy-receipt', ?, 'my-whoop', 42, 100, 101, 'legacy-batch', ?)
                """, arguments: [databaseInstanceId, countsJSON])
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            let receiptLineage = try XCTUnwrap(String.fetchOne(
                db,
                sql: "SELECT lineage FROM historicalDataCommitJournal WHERE receiptId = 'legacy-receipt'"
            ))
            let receiptEpoch = try XCTUnwrap(Int.fetchOne(
                db,
                sql: "SELECT cursorEpoch FROM historicalDataCommitJournal WHERE receiptId = 'legacy-receipt'"
            ))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT lineage FROM rawBatch WHERE batchId = 'legacy-batch'"),
                receiptLineage
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT cursorEpoch FROM rawBatch WHERE batchId = 'legacy-batch'"),
                receiptEpoch
            )
        }
    }

    func testV36MigratesCursorTrimWithItsWatermarkGeneration() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v35-historical-data-commit-journal")
        let countsJSON = try JSONEncoder().encode(HistoricalStreamInsertCounts(hr: 1))

        try await dbQueue.write { db in
            let databaseInstanceId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")
            )
            for (receiptId, trim) in [("legacy-first", 90), ("legacy-second", 20)] {
                try db.execute(sql: """
                    INSERT INTO historicalDataCommitJournal
                        (receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix, committedAt,
                         rawBatchId, insertedRowsJSON)
                    VALUES (?, ?, 'my-whoop', ?, 100, 101, NULL, ?)
                    """, arguments: [receiptId, databaseInstanceId, trim, countsJSON])
            }
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT trim FROM historicalCursor WHERE deviceId = 'my-whoop'"),
                20
            )
            XCTAssertEqual(
                try Int64.fetchOne(
                    db,
                    sql: "SELECT watermarkGeneration FROM historicalCursor WHERE deviceId = 'my-whoop'"
                ),
                2
            )
        }
    }

    func testV39RepairsPreviouslyRecordedRawAndCursorScopes() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v35-historical-data-commit-journal")
        let countsJSON = try JSONEncoder().encode(HistoricalStreamInsertCounts(hr: 1))

        try await dbQueue.write { db in
            let databaseInstanceId = try XCTUnwrap(
                String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")
            )
            try db.execute(sql: """
                INSERT INTO rawBatch
                    (batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                     startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                VALUES ('legacy-batch', 'my-whoop', 1, 2, 3, 4, 5, 0, 0, ?, NULL)
                """, arguments: [Data([0, 0, 0, 0])])
            for (receiptId, trim, rawBatchId) in [
                ("legacy-first", 90, Optional("legacy-batch")),
                ("legacy-second", 20, Optional<String>.none),
            ] {
                try db.execute(sql: """
                    INSERT INTO historicalDataCommitJournal
                        (receiptId, databaseInstanceId, deviceId, trim, chunkEndUnix, committedAt,
                         rawBatchId, insertedRowsJSON)
                    VALUES (?, ?, 'my-whoop', ?, 100, 101, ?, ?)
                    """, arguments: [receiptId, databaseInstanceId, trim, rawBatchId, countsJSON])
            }
        }
        try migrator.migrate(dbQueue, upTo: "v38-historical-analysis-checkpoint")

        try await dbQueue.write { db in
            // Model the old v36/v37 result: an independently maxed cursor and raw evidence left in the
            // fallback device scope despite the registered receipt carrying its durable registry scope.
            try db.execute(sql: """
                UPDATE rawBatch
                SET lineage = 'device:my-whoop', cursorEpoch = 0
                WHERE batchId = 'legacy-batch' AND deviceId = 'my-whoop'
                """)
            try db.execute(sql: """
                UPDATE historicalCursor
                SET trim = 90, watermarkGeneration = 2
                WHERE deviceId = 'my-whoop'
                """)
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            let receiptLineage = try XCTUnwrap(String.fetchOne(
                db,
                sql: "SELECT lineage FROM historicalDataCommitJournal WHERE receiptId = 'legacy-first'"
            ))
            let receiptEpoch = try XCTUnwrap(Int.fetchOne(
                db,
                sql: "SELECT cursorEpoch FROM historicalDataCommitJournal WHERE receiptId = 'legacy-first'"
            ))
            XCTAssertEqual(
                try String.fetchOne(db, sql: "SELECT lineage FROM rawBatch WHERE batchId = 'legacy-batch'"),
                receiptLineage
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT cursorEpoch FROM rawBatch WHERE batchId = 'legacy-batch'"),
                receiptEpoch
            )
            XCTAssertEqual(
                try Int.fetchOne(db, sql: "SELECT trim FROM historicalCursor WHERE deviceId = 'my-whoop'"),
                20
            )
            XCTAssertEqual(
                try Int64.fetchOne(
                    db,
                    sql: "SELECT watermarkGeneration FROM historicalCursor WHERE deviceId = 'my-whoop'"
                ),
                2
            )
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'v39-historical-receipt-scope-repair'"
                ),
                1
            )
        }
    }

    func testHrSamplePrimaryKeyIsDeviceIdTs() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("hrSample")
        XCTAssertEqual(cols, ["deviceId", "ts"])
    }

    func testRrIntervalPrimaryKeyIncludesSeq() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.primaryKeyColumns("rrInterval")
        XCTAssertEqual(cols, ["deviceId", "ts", "rrMs", "seq"])
    }

    func testV26KeepsEqualSameSecondBeatsAndReplayIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let batch = Streams(rr: [
            RRInterval(ts: 100, rrMs: 812),
            RRInterval(ts: 100, rrMs: 812),
            RRInterval(ts: 101, rrMs: 805),
        ])

        let first = try await store.insert(batch, deviceId: "dev1")
        let second = try await store.insert(batch, deviceId: "dev1")
        XCTAssertEqual(first.rr, 3)
        XCTAssertEqual(second.rr, 0)

        let rows = try await store.rrIntervals(
            deviceId: "dev1", from: 0, to: 1_000, limit: 100)
        XCTAssertEqual(rows.filter { $0.ts == 100 && $0.rrMs == 812 }.count, 2)
    }

    /// v5 adds a `synced` column to all 8 decoded tables.
    func testV5AddsSyncedColumnToDecodedTables() async throws {
        let store = try await WhoopStore.inMemory()
        for table in ["hrSample", "rrInterval", "event", "battery",
                      "spo2Sample", "skinTempSample", "respSample", "gravitySample"] {
            let cols = try await store.columnNamesForTest(table: table)
            XCTAssertTrue(cols.contains("synced"), "\(table) missing synced column")
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 43)
    }

    func testV34AddsDurableTodayHealthSnapshotGeneration() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("todayHealthSnapshotGeneration"))
        let snapshotColumns = try await store.columnNamesForTest(table: "todayHealthSnapshot")
        XCTAssertTrue(snapshotColumns.contains("generation"))
        let generationColumns = try await store.columnNamesForTest(table: "todayHealthSnapshotGeneration")
        XCTAssertTrue(generationColumns.contains("value"))
    }

    func testV35CreatesHistoricalDataCommitJournal() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("historicalDataCommitJournal"))
        let columns = try await store.columnNamesForTest(table: "historicalDataCommitJournal")
        for column in [
            "generation", "receiptId", "databaseInstanceId", "deviceId", "trim", "chunkEndUnix",
            "committedAt", "rawBatchId", "insertedRowsJSON",
        ] {
            XCTAssertTrue(columns.contains(column), "historicalDataCommitJournal missing \(column)")
        }
    }

    func testV35RecoversJournalCreatedBeforeItsMigrationRecord() async throws {
        let dbQueue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(dbQueue, upTo: "v34-today-health-snapshot-generation")

        try await dbQueue.write { db in
            // Model the exact pre-release state: the v35 table exists, while GRDB has never recorded v35.
            try db.execute(sql: """
                CREATE TABLE historicalDataCommitJournal (
                    generation INTEGER PRIMARY KEY AUTOINCREMENT,
                    receiptId TEXT NOT NULL UNIQUE,
                    databaseInstanceId TEXT NOT NULL,
                    deviceId TEXT NOT NULL,
                    trim INTEGER NOT NULL,
                    chunkEndUnix INTEGER NOT NULL,
                    committedAt INTEGER NOT NULL,
                    rawBatchId TEXT,
                    insertedRowsJSON BLOB NOT NULL,
                    UNIQUE (databaseInstanceId, deviceId, trim)
                )
                """)
        }

        try migrator.migrate(dbQueue)

        try await dbQueue.read { db in
            let columns = Set(try db.columns(in: "historicalDataCommitJournal").map(\.name))
            XCTAssertTrue(columns.isSuperset(of: ["lineage", "cursorEpoch", "trimScope", "fingerprint"]))
            for identifier in [
                "v35-historical-data-commit-journal",
                "v36-historical-data-receipt-hardening",
                "v37-scoped-raw-batch-identity",
                "v38-historical-analysis-checkpoint",
                "v39-historical-receipt-scope-repair",
            ] {
                XCTAssertEqual(
                    try Int.fetchOne(
                        db,
                        sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                        arguments: [identifier]
                    ),
                    1,
                    "missing migration record for \(identifier)"
                )
            }
        }
    }

    func testRecoveryChargeContextMigrationUpgradesExistingOverrideTable() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.write { db in
            // Model a database that already recorded the shipped recovery migrations,
            // before this follow-on added its five score-context columns. Running the
            // current `daily-v1` migration would create the modern fresh shape, so the
            // historical table is intentionally assembled here.
            try db.execute(sql: """
                CREATE TABLE sleepRecoveryDailyOverride (
                    deviceId TEXT NOT NULL,
                    day TEXT NOT NULL,
                    sessionStartTs INTEGER NOT NULL,
                    totalSleepMin DOUBLE,
                    efficiency DOUBLE,
                    deepMin DOUBLE,
                    remMin DOUBLE,
                    lightMin DOUBLE,
                    disturbances INTEGER,
                    restingHr INTEGER,
                    avgHrv DOUBLE,
                    recovery DOUBLE,
                    restScore DOUBLE,
                    updatedAt INTEGER NOT NULL,
                    PRIMARY KEY (deviceId, day)
                )
                """)
            for identifier in [
                "sleep-window-recovery-v1",
                "sleep-window-recovery-daily-v1",
                "sleep-window-recovery-invalidation-v1",
            ] {
                try db.execute(
                    sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                    arguments: [identifier])
            }
            let oldColumns = try Set(db.columns(in: "sleepRecoveryDailyOverride").map(\.name))
            XCTAssertFalse(oldColumns.contains("chargeWeightedSumWithoutSleep"))
            XCTAssertFalse(oldColumns.contains("chargeWeightWithoutSleep"))
            XCTAssertFalse(oldColumns.contains("chargeBaselineUsable"))
            XCTAssertFalse(oldColumns.contains("sleepNeedHours"))
            XCTAssertFalse(oldColumns.contains("sleepConsistency"))
            try db.execute(sql: """
                INSERT INTO sleepRecoveryDailyOverride
                    (deviceId, day, sessionStartTs, totalSleepMin, updatedAt)
                VALUES ('my-whoop-noop', '2026-07-26', 1000, 420, 10000)
                """)
        }

        try WhoopStore.makeSleepRecoveryMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            let columns = try Set(db.columns(in: "sleepRecoveryDailyOverride").map(\.name))
            XCTAssertTrue([
                "chargeWeightedSumWithoutSleep", "chargeWeightWithoutSleep",
                "chargeBaselineUsable", "sleepNeedHours", "sleepConsistency",
            ].allSatisfy(columns.contains))
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT chargeBaselineUsable FROM sleepRecoveryDailyOverride"),
                0)
            XCTAssertEqual(
                try Double.fetchOne(
                    db,
                    sql: "SELECT sleepNeedHours FROM sleepRecoveryDailyOverride"),
                8.0)
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: ["sleep-window-recovery-charge-context-v1"]),
                1)
        }
    }

    /// v13 adds the `userEdited` flag to sleepSession (user-corrected wake times survive re-sync).
    func testV13AddsUserEditedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("userEdited"), "sleepSession missing v13 userEdited column")
    }

    /// v14 adds `startTsAdjusted` (the user-corrected sleep onset; detected startTs stays the key).
    func testV14AddsStartTsAdjustedColumnToSleepSession() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "sleepSession")
        XCTAssertTrue(cols.contains("startTsAdjusted"), "sleepSession missing v14 startTsAdjusted column")
    }

    /// v16 adds `peripheralId` to pairedDevice (stable per-strap BLE identity for multi-WHOOP support).
    func testV16AddsPeripheralIdColumnToPairedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let cols = try await store.columnNamesForTest(table: "pairedDevice")
        XCTAssertTrue(cols.contains("peripheralId"), "pairedDevice missing v16 peripheralId column")
    }

    func testPrivateCoachingMigrationsRemainPresent() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        for table in [
            "coachingBehaviorSet", "coachingBehaviorMembership",
            "coachingStack", "coachingStackItem", "coachingStackUse",
        ] {
            XCTAssertTrue(tables.contains(table), "private migration lost table \(table)")
        }
    }

    func testV25AddsRawSpo2Columns() async throws {
        let store = try await WhoopStore.inMemory()
        let columns = try await store.columnNamesForTest(table: "dailyMetric")
        XCTAssertTrue(columns.contains("spo2Red"))
        XCTAssertTrue(columns.contains("spo2Ir"))
    }

    func testV27HealsEfficiencyPercentToFraction() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v26-rr-seq")
        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sleepSession (deviceId, startTs, endTs, efficiency)
                VALUES ('my-whoop', 100, 200, 90), ('my-whoop', 300, 400, 0.90)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric (deviceId, day, efficiency)
                VALUES ('my-whoop', '2026-01-01', 90), ('my-whoop', '2026-01-02', 0.90)
                """)
        }

        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertEqual(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 100"), 0.90)
            XCTAssertEqual(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 300"), 0.90)
            XCTAssertEqual(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-01'"), 0.90)
            XCTAssertEqual(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-01-02'"), 0.90)
        }
    }

    func testV28CreatesPpgWaveformTable() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        let primaryKey = try await store.primaryKeyColumns("ppgWaveformSample")
        let columns = try await store.columnNamesForTest(table: "ppgWaveformSample")

        XCTAssertTrue(tables.contains("ppgWaveformSample"))
        XCTAssertEqual(primaryKey, ["deviceId", "ts"])
        XCTAssertTrue(columns.contains("samples"))
    }

    /// A pre-release Strain V2 build added the provenance columns before the final migration
    /// identifier landed. Reopening that real-world database must finish v29 instead of leaving
    /// every app surface blank because the store cannot open.
    func testV29RecoversPartiallyAppliedStrainProvenanceSchema() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue, upTo: "v28-ppg-waveform")
        try await dbQueue.write { db in
            try db.alter(table: "dailyMetric") { table in
                table.add(column: "strainVersion", .integer)
            }
            try db.alter(table: "workout") { table in
                table.add(column: "strainVersion", .integer)
            }
        }

        try WhoopStore.makeMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertTrue(try db.columns(in: "dailyMetric").map(\.name).contains("strainVersion"))
            XCTAssertTrue(try db.columns(in: "workout").map(\.name).contains("strainVersion"))
            XCTAssertTrue(try db.tableExists("strainV2Shadow"))
            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: ["v29-strain-v2-provenance"]
                ),
                1
            )
        }
    }
}
