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
            "ppgWaveformSample", "todayHealthSnapshot",
        ] {
            XCTAssertTrue(tables.contains(t), "missing table \(t)")
        }
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
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 34)
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
