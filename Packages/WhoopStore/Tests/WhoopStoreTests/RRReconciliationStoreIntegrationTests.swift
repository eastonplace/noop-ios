import Foundation
import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// Requires the full WhoopStore target on macOS. These cover actor, transaction,
/// migration registration, and snapshot integrations beyond the isolated SQL tests.
final class RRReconciliationStoreIntegrationTests: XCTestCase {
    func testOrdinaryInsertMarksLateHRWithoutDeletingRawBeat() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(rr: [
            RRInterval(ts: 100, rrMs: 500, source: .whoop5Historical),
            RRInterval(ts: 101, rrMs: 820, source: .whoop5Standard)
        ]), deviceId: "strap")
        let before = try await store.rrIntervals(deviceId: "strap", from: 0, to: 200, limit: 10)
        XCTAssertEqual(before.map(\.rrMs), [500])
        _ = try await store.insert(Streams(hr: [HRSample(ts: 100, bpm: 80)]), deviceId: "strap")
        let after = try await store.rrIntervals(deviceId: "strap", from: 0, to: 200, limit: 10)
        let bundle = try await store.analysisDayBundle(deviceId: "strap", from: 0, to: 200, limit: 10)
        XCTAssertEqual(after.map(\.rrMs), [820])
        XCTAssertEqual(after.map(\.source), bundle.rr.map(\.source))
        XCTAssertEqual(after.map(\.rrMs), bundle.rr.map(\.rrMs))
        let count = try await store.registryWriter.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval WHERE deviceId='strap'")
        }
        XCTAssertEqual(count, 2)
    }

    func testSameNaturalKeyPromotesWHOOP4HistoryInEitherArrivalOrder() async throws {
        for sources: [RRSource] in [[.whoop4Standard, .whoop4Realtime, .whoop4Historical],
                                   [.whoop4Historical, .whoop4Realtime, .whoop4Standard]] {
            let store = try await WhoopStore.inMemory()
            for source in sources {
                _ = try await store.insert(Streams(rr: [
                    RRInterval(ts: 100, rrMs: 800, sourceOrdinal: 0, source: source),
                    RRInterval(ts: 100, rrMs: 800, sourceOrdinal: 1, source: source)
                ]), deviceId: "strap")
            }
            let rows = try await store.rrIntervals(deviceId: "strap", from: 0, to: 200, limit: 10)
            XCTAssertEqual(rows.count, 2)
            XCTAssertEqual(rows.map(\.sourceOrdinal), [0, 1])
            XCTAssertTrue(rows.allSatisfy { $0.source == .whoop4Historical })
        }
    }

    func testQualityChangesRollbackWithSharedDecodedTransaction() async throws {
        enum Abort: Error { case fixture }
        let store = try await WhoopStore.inMemory()
        do {
            try await store.registryWriter.write { db in
                _ = try WhoopStore.insertDecodedStreams(
                    Streams(hr: [HRSample(ts: 100, bpm: 80)],
                            rr: [RRInterval(ts: 100, rrMs: 500, source: .whoop5Historical)]),
                    deviceId: "strap", in: db)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT tsSuspect FROM rrInterval WHERE deviceId='strap'"), 1)
                throw Abort.fixture
            }
            XCTFail("Expected transaction rollback")
        } catch Abort.fixture {}
        let counts = try await store.registryWriter.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval WHERE deviceId='strap'"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample WHERE deviceId='strap'"))
        }
        XCTAssertEqual(counts.0, 0)
        XCTAssertEqual(counts.1, 0)
    }

    func testRRWitnessChangesForSourceUpgradeAndFillMarkWithUnchangedHR() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800, source: .whoop4Standard)]), deviceId: "strap")
        let before = try await store.rrScoringFingerprint(deviceId: "strap", from: 0, to: 200)
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800, source: .whoop4Historical)]), deviceId: "strap")
        let promoted = try await store.rrScoringFingerprint(deviceId: "strap", from: 0, to: 200)
        XCTAssertNotEqual(before, promoted)
        let hrBefore = try await store.hrFingerprint(deviceId: "strap", from: 0, to: 200)
        try await store.registryWriter.write { db in
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect=1 WHERE deviceId='strap' AND ts=100")
        }
        let flagged = try await store.rrScoringFingerprint(deviceId: "strap", from: 0, to: 200)
        let hrAfter = try await store.hrFingerprint(deviceId: "strap", from: 0, to: 200)
        XCTAssertNotEqual(promoted, flagged)
        XCTAssertEqual(hrBefore.count, hrAfter.count)
        XCTAssertEqual(hrBefore.maxTs, hrAfter.maxTs)
    }

    func testRRWitnessIncludesFullBoundaryHourAndGlobalFamilyEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 100, rrMs: 800)]), deviceId: "unknown")
        let before = try await store.rrScoringFingerprint(deviceId: "unknown", from: 100, to: 200)
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 20000, rrMs: 810, source: .whoop4Realtime)]), deviceId: "unknown")
        let classified = try await store.rrScoringFingerprint(deviceId: "unknown", from: 100, to: 200)
        XCTAssertNotEqual(before, classified)
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 50, rrMs: 820, source: .whoop4Historical)]), deviceId: "unknown")
        let boundary = try await store.rrScoringFingerprint(deviceId: "unknown", from: 100, to: 200)
        XCTAssertNotEqual(classified, boundary)
    }

    func testCurrentMigratorUpgradesV58WithoutRewritingPrimaryKey() throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: StoreIndexHygieneMigration.identifier)
        try queue.write { db in
            XCTAssertFalse(try db.columns(in: "rrInterval").contains { $0.name == "tsSuspect" })
            try db.execute(sql: """
                INSERT INTO rrInterval(deviceId,ts,rrMs,seq,source,sourceOrdinal)
                VALUES ('strap',100,500,0,'whoop5_historical',4);
                INSERT INTO hrSample(deviceId,ts,bpm) VALUES ('strap',100,80);
                """)
        }
        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try db.primaryKey("rrInterval").columns, ["deviceId", "ts", "rrMs", "seq"])
            let row = try XCTUnwrap(Row.fetchOne(db, sql: "SELECT * FROM rrInterval WHERE deviceId='strap'"))
            XCTAssertEqual(row["rrMs"] as Int, 500)
            XCTAssertEqual(row["sourceOrdinal"] as Int, 4)
            XCTAssertEqual(row["tsSuspect"] as Int?, 1)
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 60)
    }

    func testCurrentMigratorUpgradesV59WithoutChangingStrengthStateOrRawRR() throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: LiftStrainMigration.identifier)
        try queue.write { db in
            XCTAssertFalse(try db.columns(in: "rrInterval").contains { $0.name == "tsSuspect" })
            XCTAssertEqual(try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid").last,
                           "v59-lift-strain")
            // Every column is explicit, including reversible Strength snapshots, bookkeeping,
            // nullable values, JSON bytes, and the original timestamps.
            try db.execute(sql: """
                INSERT INTO liftStrain
                    (deviceId, liftSessionId, workoutStartTs, workoutSport, dayKey, formulaVersion,
                     bodyweightKg, bodyweightIsDefault, dose, volume, muscularLoad, workingSets,
                     warmupSets, countedSets, skippedJSON, unmappedSets, hrOnlyStrain, combinedStrain,
                     appliedMuscularLoad, state, computedAt, updatedAt)
                VALUES
                    ('strap','lift-applied',1784300000,'Strength Training','2026-07-17',1,
                     81.25,0,50.125,1234.5,10.25,9,2,8,'[ {"reason":"unmapped"} ]',1,
                     30.125,50.625,10.25,'applied',1784304001,1784304002),
                    ('strap','lift-detached',1784390000,'Strength Training','2026-07-18',2,
                     80.5,1,12.375,456.75,3.125,4,1,3,'[]',0,
                     NULL,NULL,0,'detached',1784394001,1784394002);
                INSERT INTO liftStrainTarget
                    (deviceId, kind, keyTs, keyText, origStrain, origStrainVersion, hrOnlyStrain,
                     writtenStrain, writtenStrainVersion, appliedMuscularLoad, formulaVersion, snapshotAt, updatedAt)
                VALUES
                    ('strap','workout',1784300000,'Strength Training',33.3,NULL,30.125,
                     50.625,2,10.25,1,1784304003,1784304004),
                    ('strap-noop','day',0,'2026-07-17',NULL,2,NULL,
                     60.875,2,10.25,1,1784304005,1784304006);
                INSERT INTO liftStrainJob
                    (jobKey, deviceId, formulaVersion, state, cursorDay, upperDay, liftsApplied,
                     liftsSkipped, daysApplied, conflicts, startedAt, completedAt, refreshedAt)
                VALUES
                    ('strength:1:strap','strap',1,'running','2026-07-17','2026-07-18',7,2,3,1,
                     1784304010,NULL,1784304020),
                    ('strength:2:strap','strap',2,'complete',NULL,'2026-07-18',8,1,4,0,
                     1784394010,1784394020,NULL);
                INSERT INTO liftStrainControl (scope, disabled, reason, updatedAt)
                VALUES ('global',1,'fixture: preserve disabled state',1784394030);
                INSERT INTO workout
                    (deviceId, startTs, endTs, sport, source, durationS, energyKcal, avgHr, maxHr,
                     strain, distanceM, zonesJSON, notes, strainVersion)
                VALUES
                    ('strap',1784300000,1784303600,'Strength Training','manual',3600.25,250.5,120,151,
                     50.625,12.75,'[ 1, 2, 3 ]','preserve applied lift',2),
                    ('strap',1784390000,1784391800,'Strength Training','manual',1800,NULL,NULL,NULL,
                     NULL,NULL,NULL,NULL,NULL);
                INSERT INTO dailyMetric
                    (deviceId, day, totalSleepMin, efficiency, deepMin, remMin, lightMin, disturbances,
                     restingHr, avgHrv, recovery, strain, exerciseCount, spo2Pct, skinTempDevC,
                     respRateBpm, steps, activeKcalEst, spo2Red, spo2Ir, strainVersion)
                VALUES
                    ('strap-noop','2026-07-17',420.5,0.9125,80.25,90.5,249.75,3,
                     52,61.125,70.25,60.875,1,97.125,-0.375,14.25,9001,400.5,12345,23456,2),
                    ('strap-noop','2026-07-18',NULL,NULL,NULL,NULL,NULL,NULL,
                     NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL,NULL);
                INSERT INTO rrInterval (deviceId, ts, rrMs, seq, synced, source, sourceOrdinal)
                VALUES
                    ('strap',100,500,0,1,'whoop5_historical',9),
                    ('strap',100,500,1,0,'whoop5_historical',4),
                    ('strap',101,500,0,1,'whoop5_standard_2a37',7),
                    ('strap',102,821,0,0,'whoop5_standard_2a37',5);
                INSERT INTO hrSample (deviceId, ts, bpm, synced)
                VALUES ('strap',100,80,1), ('strap',101,80,0), ('strap',102,80,1);
                """)
        }
        let before = try queue.read { db in
            let rrColumns = try db.columns(in: "rrInterval").map(\.name)
            return (try Self.strengthSnapshots(db), rrColumns,
                    try Self.snapshot(db, sql: Self.rawRRSQL(columns: rrColumns)),
                    try Self.snapshot(db, sql: "SELECT * FROM hrSample ORDER BY deviceId, ts"))
        }

        var firstMigrationIDs: [String]?
        for pass in 1...2 {
            try migrator.migrate(queue)
            let identifiers = try queue.read { db in
                XCTAssertEqual(try Self.strengthSnapshots(db), before.0,
                               "Pass \(pass) must preserve every Strength cell and timestamp")
                XCTAssertEqual(try Self.snapshot(db, sql: Self.rawRRSQL(columns: before.1)), before.2,
                               "Pass \(pass) must preserve all raw RR values, keys, timestamps, and order")
                XCTAssertEqual(try Self.snapshot(db, sql: "SELECT * FROM hrSample ORDER BY deviceId, ts"), before.3)
                XCTAssertEqual(try db.primaryKey("rrInterval").columns, ["deviceId", "ts", "rrMs", "seq"])
                XCTAssertEqual(try db.columns(in: "rrInterval").map(\.name), before.1 + ["tsSuspect"])
                let annotations = try Row.fetchAll(db, sql: """
                    SELECT tsSuspect FROM rrInterval ORDER BY deviceId, ts, rrMs, seq
                    """).map { $0["tsSuspect"] as Int? }
                XCTAssertEqual(annotations, [1, 1, 1, nil])
                let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
                for identifier in ["v59-lift-strain", "v60-rr-quality-policy"] {
                    XCTAssertEqual(identifiers.filter { $0 == identifier }.count, 1, identifier)
                }
                XCTAssertEqual(Array(identifiers.suffix(2)), ["v59-lift-strain", "v60-rr-quality-policy"])
                return identifiers
            }
            if let firstMigrationIDs {
                XCTAssertEqual(identifiers, firstMigrationIDs, "A second migration must be a no-op")
            } else {
                firstMigrationIDs = identifiers
            }
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 60)
    }

    /// Compare exact SQLite storage classes, UTF-8/blob bytes, and floating-point bits.
    /// Row descriptions and numeric equality alone can hide storage or rounding changes.
    private enum SQLiteCell: Equatable {
        case null
        case integer(Int64)
        case real(UInt64)
        case text([UInt8])
        case blob(Data)

        init(_ value: DatabaseValue) {
            switch value.storage {
            case .null: self = .null
            case let .int64(value): self = .integer(value)
            case let .double(value): self = .real(value.bitPattern)
            case let .string(value): self = .text(Array(value.utf8))
            case let .blob(value): self = .blob(value)
            }
        }
    }

    private struct TableSnapshot: Equatable {
        let columns: [String]
        let rows: [[SQLiteCell]]
    }

    private static func snapshot(_ db: Database, sql: String) throws -> TableSnapshot {
        let rows = try Row.fetchAll(db, sql: sql)
        return TableSnapshot(columns: rows.first.map { Array($0.columnNames) } ?? [], rows: rows.map { row in
            row.columnNames.map { column in
                let value: DatabaseValue = row[column]
                return SQLiteCell(value)
            }
        })
    }

    private static func strengthSnapshots(_ db: Database) throws -> [String: TableSnapshot] {
        let tables = [
            ("liftStrain", "deviceId, liftSessionId"),
            ("liftStrainTarget", "deviceId, kind, keyTs, keyText"),
            ("liftStrainJob", "jobKey"),
            ("liftStrainControl", "scope"),
            ("workout", "deviceId, startTs, sport"),
            ("dailyMetric", "deviceId, day")
        ]
        var result: [String: TableSnapshot] = [:]
        for (table, order) in tables {
            result[table] = try snapshot(db, sql: "SELECT * FROM \(table) ORDER BY \(order)")
        }
        return result
    }

    private static func rawRRSQL(columns: [String]) -> String {
        "SELECT \(columns.joined(separator: ", ")) FROM rrInterval ORDER BY deviceId, ts, rrMs, seq"
    }
}
