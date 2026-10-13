import XCTest
import GRDB
import SQLite3
import WhoopProtocol
@testable import WhoopStore

/// DL-02, DL-13, DL-15: the hot store paths search an index and never scan a whole table.
private func plan(_ db: Database, _ sql: String, _ arguments: StatementArguments) throws -> String {
    try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
        .compactMap { $0["detail"] as String? }
        .joined(separator: "\n")
}

/// True when a plan line reads a table (or its alias) front to back. Scans of a materialized two-row
/// subquery are fine; scans of a sample table are what DL-02 removed.
private func scansTable(_ plan: String, _ names: Set<String>) -> Bool {
    plan.split(separator: "\n").contains { line in
        let words = line.drop { "|`- ".contains($0) }.split(separator: " ")
        return words.count >= 2 && words[0] == "SCAN" && names.contains(String(words[1]))
    }
}

/// SQLite virtual-machine steps one run of `sql` takes. A seek costs the same at any history length; a walk
/// over every row grows with it.
private func vmSteps(_ db: Database, _ sql: String, _ arguments: StatementArguments) throws -> Int32 {
    let statement = try db.makeStatement(sql: sql)
    _ = try Row.fetchAll(statement, arguments: arguments)
    return sqlite3_stmt_status(statement.sqliteStatement, SQLITE_STMTSTATUS_VM_STEP, 0)
}

final class StoreQueryPlanTests: XCTestCase {
    /// DL-02: before the fix the 20 s live-strain frontier and the history bounds walked every HR and PPG row
    /// (about 18 VM steps per row); now each is a fixed number of index seeks.
    func testHeartRateFrontierAndBoundsCostIsIndependentOfHistoryLength() async throws {
        func steps(rows: Int) async throws -> (latest: Int32, bounds: Int32) {
            let store = try await WhoopStore.inMemory()
            _ = try await store.insert(
                Streams(hr: (0..<rows).map { HRSample(ts: $0 * 2, bpm: 60) },
                        ppgHr: (0..<rows).map { PpgHrSample(ts: $0 * 3, bpm: 60, conf: 0.8) }),
                deviceId: "d")
            let writer = await store.dbWriter
            return try await writer.read { db in
                (try vmSteps(db, WhoopStore.latestHRSampleTsSQL, ["d", "d"]),
                 try vmSteps(db, WhoopStore.hrTimestampBoundsSQL, ["d": "d"]))
            }
        }
        let short = try await steps(rows: 200)
        let long = try await steps(rows: 4_000)
        XCTAssertEqual(long.latest, short.latest, "latestHRSampleTs walks the history")
        XCTAssertEqual(long.bounds, short.bounds, "hrTimestampBounds walks the history")
        XCTAssertLessThan(long.latest, 200)
        XCTAssertLessThan(long.bounds, 400)
    }

    func testHeartRateFrontierFingerprintAndBoundsSearchTheTsIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        try await writer.read { db in
            let latest = try plan(db, WhoopStore.latestHRSampleTsSQL, ["d", "d"])
            let fingerprint = try plan(db, WhoopStore.hrFingerprintSQL, ["d": "d", "f": 0, "t": 1_000])
            let bounds = try plan(db, WhoopStore.hrTimestampBoundsSQL, ["d": "d"])
            for detail in [latest, fingerprint, bounds] {
                XCTAssertTrue(detail.contains("SEARCH"), detail)
                XCTAssertFalse(scansTable(detail, ["hrSample", "ppgHrSample", "h", "p"]), detail)
            }
        }
    }

    func testGlobalMetricSeriesDeletesSearchTheKeyDayIndex() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        try await writer.read { db in
            let byKey = try plan(db, "DELETE FROM metricSeries WHERE key IN (?)", ["k"])
            let byKeyAndDay = try plan(
                db, "DELETE FROM metricSeries WHERE key IN (?) AND day IN (?)", ["k", "2026-08-01"])
            for detail in [byKey, byKeyAndDay] {
                XCTAssertTrue(detail.contains("idx_metricSeries_key_day"), detail)
                XCTAssertFalse(scansTable(detail, ["metricSeries"]), detail)
            }
        }
    }

    func testRRProvenanceUpgradeIsAPrimaryKeySearch() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        try await writer.read { db in
            let detail = try plan(
                db, WhoopStore.rrProvenanceUpgradeSQL,
                ["whoop5_historical", 0, "d", 1, 800, 0, 800])
            XCTAssertTrue(detail.contains("SEARCH rrInterval"), detail)
            XCTAssertFalse(scansTable(detail, ["rrInterval"]), detail)
        }
    }

    func testSQLPriorityMatchesTheSwiftPriorityForEverySource() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let expression = RRReadPolicy.sqlPriority(ofColumn: "?")
        try await writer.read { db in
            for source in RRSource.allCases {
                let value = try Int.fetchOne(db, sql: "SELECT \(expression)", arguments: [source.rawValue])
                XCTAssertEqual(value, RRReadPolicy.priority(for: source), source.rawValue)
            }
            let legacy = RRReadPolicy.priority(for: .legacy)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT \(expression)", arguments: ["no-such-source"]), legacy)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT \(expression)", arguments: [nil as String?]), legacy)
        }
    }

    func testReplayedBeatKeepsTheHigherPriorityProvenanceAndCountsNoInsert() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        func storedSource() async throws -> String? {
            try await writer.read { db in
                try String.fetchOne(db, sql: "SELECT source FROM rrInterval WHERE deviceId = 'd' AND ts = 10")
            }
        }

        let first = try await store.insert(Streams(rr: [RRInterval(ts: 10, rrMs: 800, source: .whoop5Realtime)]), deviceId: "d")
        XCTAssertEqual(first.rr, 1)

        let upgrade = try await store.insert(
            Streams(rr: [RRInterval(ts: 10, rrMs: 800, sourceOrdinal: 3, source: .whoop5Historical)]), deviceId: "d")
        XCTAssertEqual(upgrade.rr, 0, "a provenance upgrade is not an inserted row")
        let upgraded = try await storedSource()
        XCTAssertEqual(upgraded, RRSource.whoop5Historical.rawValue)

        let downgrade = try await store.insert(Streams(rr: [RRInterval(ts: 10, rrMs: 800, source: .whoop5Standard)]), deviceId: "d")
        XCTAssertEqual(downgrade.rr, 0)
        let kept = try await storedSource()
        XCTAssertEqual(kept, RRSource.whoop5Historical.rawValue, "a lower-priority replay never rewrites the row")
        let ordinal = try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT sourceOrdinal FROM rrInterval WHERE deviceId = 'd' AND ts = 10")
        }
        XCTAssertEqual(ordinal, 3)
    }

    func testDuplicateJournalIndexIsGoneOnFreshAndUpgradedInstalls() throws {
        let duplicate = "idx_historicalDataCommitJournal_scope_generation_v40"
        func indexNames(_ db: Database) throws -> Set<String> {
            Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
        }
        let migrator = WhoopStore.makeMigrator()

        let fresh = try DatabaseQueue()
        try migrator.migrate(fresh)
        try fresh.read { db in
            let names = try indexNames(db)
            XCTAssertFalse(names.contains(duplicate))
            XCTAssertTrue(names.contains("idx_historicalDataCommitJournal_scope_generation"))
            XCTAssertTrue(names.contains("idx_metricSeries_key_day"))
        }

        // An install from an earlier build still carries the copy that v40 or v53 created.
        let upgraded = try DatabaseQueue()
        try migrator.migrate(upgraded, upTo: LiftReceiptStateSchema.migrationIdentifier)
        try upgraded.write { db in
            try db.execute(sql: """
                CREATE INDEX \(duplicate) ON historicalDataCommitJournal
                    (databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, generation)
                """)
        }
        try migrator.migrate(upgraded)
        try upgraded.read { db in
            let names = try indexNames(db)
            XCTAssertFalse(names.contains(duplicate))
            XCTAssertTrue(names.contains("idx_historicalDataCommitJournal_scope_generation"))
            XCTAssertTrue(names.contains("idx_metricSeries_key_day"))
        }
    }
}
