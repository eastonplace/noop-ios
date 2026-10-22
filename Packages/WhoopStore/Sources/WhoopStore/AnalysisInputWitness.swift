import Foundation
import GRDB
import SQLite3

/// Committed-input identity for RAM analysis caches. It never persists or crosses a store reopen.
public struct AnalysisInputWitness: Sendable, Equatable {
    let generation: String
    let externalVersion: Int
    let schemaVersion: Int
    let tempSchemaVersion: Int
    let unknownRevision: UInt64
    let tableRevisions: [String: UInt64]
    let gravityGlobalRevision: UInt64
    let gravityRevisions: [AnalysisGravityBucket: UInt64]

    /// All changes to a dependency table invalidate, including same-key value/quality repairs.
    public func signature(tables: [String]) -> String {
        let base = "\(generation):\(externalVersion):\(schemaVersion):\(tempSchemaVersion):\(unknownRevision)"
        return tables.map { $0.lowercased() }.sorted().reduce(base) {
            $0 + ":\($1.utf8.count):\($1)=\(tableRevisions[$1, default: 0])"
        }
    }

    /// Normal gravity inserts affect only intersecting owner/UTC-day buckets. Repairs and unknown writes
    /// use a global revision. Every physical/ownership mutation still invalidates all motion entries.
    public func motionSignature(deviceId: String, from: Int, to: Int) -> String {
        let base = signature(tables: ["device", "pairedDevice", "dayOwnership"])
            + ":g\(gravityGlobalRevision):\(deviceId.utf8.count):\(deviceId)"
        let first = Self.utcDay(from), last = Self.utcDay(to)
        // Callers use one civil day. A wider/malformed request stays correct with the whole-table fence.
        guard last >= first, last - first <= 7 else {
            return base + ":all\(tableRevisions["gravitysample", default: 0])"
        }
        return (first...last).reduce(base) { partial, day in
            partial + ":\(day)=\(gravityRevisions[.init(owner: deviceId, day: day), default: 0])"
        }
    }

    static func utcDay(_ timestamp: Int) -> Int {
        timestamp / 86_400 - (timestamp < 0 && timestamp % 86_400 != 0 ? 1 : 0)
    }
}

struct AnalysisGravityBucket: Sendable, Hashable {
    let owner: String
    let day: Int
}

/// All mutable state is confined to the shared GRDB writer queue. Pool handles share this instance.
/// Count every event: early observation shutdown would hide mixed/unobserved changes from the total fence.
final class AnalysisInputObservation: TransactionObserver, @unchecked Sendable {
    private let generation = UUID().uuidString
    private var accountedTotal: Int64 = 0
    private var observedRows: Int64 = 0
    private var pendingTables = Set<String>()
    private var pendingUnknown = false
    private var tableRevisions: [String: UInt64] = [:]
    private var unknownRevision: UInt64 = 0
    private var gravityGlobalRevision: UInt64 = 0
    private var gravityRevisions: [AnalysisGravityBucket: UInt64] = [:]
    private var pendingGravityRows = Set<Int64>()
    private var pendingGravityGlobal = false
    private var knownGravityAppend = false
    private var gravitySchemaKey: String?
    private var gravitySchemaAllowsAppendRegions = false
    private static let regionLimit = 4_096

    static func install(on writer: any DatabaseWriter) -> AnalysisInputObservation {
        let observation = AnalysisInputObservation()
        writer.writeWithoutTransaction { db in
            observation.accountedTotal = sqlite3_total_changes64(db.sqliteConnection)
            db.add(transactionObserver: observation, extent: .databaseLifetime)
        }
        return observation
    }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }

    func databaseDidChange() { pendingUnknown = true }

    func databaseDidChange(with event: DatabaseEvent) {
        observedRows += 1
        let table = event.tableName.lowercased()
        pendingTables.insert(table)
        guard table == "gravitysample", !pendingGravityGlobal else { return }
        guard knownGravityAppend, event.kind == .insert, pendingGravityRows.count < Self.regionLimit else {
            pendingGravityGlobal = true
            pendingGravityRows.removeAll(keepingCapacity: true)
            return
        }
        pendingGravityRows.insert(event.rowID)
    }

    func databaseWillCommit() throws {}
    func databaseDidCommit(_ db: Database) { reconcile(db) }

    func databaseDidRollback(_ db: Database) {
        // A matched, fully observed rollback publishes no input change. Unaccounted changes may instead
        // be an earlier committed direct-SQL write; a later rollback must never acknowledge that drift.
        let total = sqlite3_total_changes64(db.sqliteConnection)
        if pendingUnknown || total - accountedTotal != observedRows {
            unknownRevision &+= 1
            gravityGlobalRevision &+= 1
            gravityRevisions.removeAll(keepingCapacity: true)
        }
        accountedTotal = total
        resetPending()
    }

    /// Must run on the actual writer, never a pooled reader: its data_version excludes its own commits.
    func snapshot(_ db: Database) throws -> AnalysisInputWitness {
        reconcile(db)
        guard let external = try Int.fetchOne(db, sql: "PRAGMA data_version"),
              let schema = try Int.fetchOne(db, sql: "PRAGMA schema_version"),
              let tempSchema = try Int.fetchOne(db, sql: "PRAGMA temp.schema_version") else {
            throw DatabaseError(resultCode: .SQLITE_ERROR, message: "Analysis input metadata is unavailable")
        }
        return AnalysisInputWitness(
            generation: generation, externalVersion: external, schemaVersion: schema, tempSchemaVersion: tempSchema,
            unknownRevision: unknownRevision, tableRevisions: tableRevisions,
            gravityGlobalRevision: gravityGlobalRevision, gravityRevisions: gravityRevisions)
    }

    /// Only the fixed INSERT ... ON CONFLICT(deviceId,ts) DO NOTHING writer can opt into day regions.
    /// Other INSERT SQL may REPLACE an explicit rowid and silently delete a different owner/day.
    func withGravityAppend<T>(in db: Database, _ body: () throws -> T) rethrows -> T {
        let previous = knownGravityAppend
        knownGravityAppend = appendRegionsAreSafe(in: db)
        defer { knownGravityAppend = previous }
        return try body()
    }

    private func appendRegionsAreSafe(in db: Database) -> Bool {
        do {
            let main = try Int.fetchOne(db, sql: "PRAGMA schema_version")
            let temp = try Int.fetchOne(db, sql: "PRAGMA temp.schema_version")
            guard let main, let temp else { return false }
            let key = "\(main):\(temp)"
            if gravitySchemaKey == key { return gravitySchemaAllowsAppendRegions }
            let columns = try Row.fetchAll(db, sql: "PRAGMA main.table_info(gravitySample)")
            let shadowsRowID = columns.contains { ["rowid", "_rowid_", "oid"].contains(($0["name"] as String).lowercased()) }
            let primary = columns.filter { ($0["pk"] as Int) > 0 }
                .sorted { ($0["pk"] as Int) < ($1["pk"] as Int) }.map { $0["name"] as String }
            let rowid = try Int.fetchOne(db, sql:
                "SELECT wr FROM pragma_table_list WHERE schema='main' AND name='gravitySample' COLLATE NOCASE") == 0
            let extraUnique = try Row.fetchAll(db, sql: "PRAGMA main.index_list(gravitySample)")
                .contains { ($0["unique"] as Int) != 0 && ($0["origin"] as String) != "pk" }
            let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA main.foreign_key_list(gravitySample)")
            let triggers = try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name='gravitySample' COLLATE NOCASE)
                     + (SELECT COUNT(*) FROM sqlite_temp_master WHERE type='trigger' AND tbl_name='gravitySample' COLLATE NOCASE)
                     + (SELECT COUNT(*) FROM sqlite_temp_master WHERE name='gravitySample' COLLATE NOCASE)
                """) ?? 1
            gravitySchemaAllowsAppendRegions = primary.map { $0.lowercased() } == ["deviceid", "ts"]
                && rowid && !shadowsRowID && !extraUnique
                && foreignKeys.isEmpty && triggers == 0
            gravitySchemaKey = key
            return gravitySchemaAllowsAppendRegions
        } catch {
            return false
        }
    }

    private func reconcile(_ db: Database) {
        let total = sqlite3_total_changes64(db.sqliteConnection)
        // WITHOUT ROWID, direct SQLite calls outside GRDB statements, and savepoint rollbacks can be
        // absent from row callbacks. Never acknowledge their count as a known table-only mutation.
        let unknown = pendingUnknown || total - accountedTotal != observedRows
        if unknown { unknownRevision &+= 1 }
        for table in pendingTables { tableRevisions[table, default: 0] &+= 1 }

        var gravityGlobal = unknown || pendingGravityGlobal
        if !gravityGlobal, !pendingGravityRows.isEmpty {
            do {
                let ids = Array(pendingGravityRows)
                var buckets = Set<AnalysisGravityBucket>()
                var found = 0
                for start in stride(from: 0, to: ids.count, by: 500) {
                    let chunk = Array(ids[start..<min(start + 500, ids.count)])
                    let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                    let rows = try Row.fetchAll(db, sql:
                        "SELECT deviceId,ts FROM gravitySample WHERE rowid IN (\(placeholders))",
                        arguments: StatementArguments(chunk))
                    found += rows.count
                    for row in rows {
                        let owner: String = row["deviceId"], ts: Int = row["ts"]
                        buckets.insert(.init(owner: owner, day: AnalysisInputWitness.utcDay(ts)))
                    }
                }
                if found != ids.count || gravityRevisions.count + buckets.count > Self.regionLimit {
                    gravityGlobal = true
                } else {
                    for bucket in buckets { gravityRevisions[bucket, default: 0] &+= 1 }
                }
            } catch {
                gravityGlobal = true
            }
        }
        if gravityGlobal {
            gravityGlobalRevision &+= 1
            gravityRevisions.removeAll(keepingCapacity: true)
        }
        accountedTotal = total
        resetPending()
    }

    private func resetPending() {
        observedRows = 0
        pendingTables.removeAll(keepingCapacity: true)
        pendingUnknown = false
        pendingGravityRows.removeAll(keepingCapacity: true)
        pendingGravityGlobal = false
    }
}

extension WhoopStore {
    /// Constant-size metadata/RAM snapshot; no raw stream is scanned to decide whether a cache can reuse.
    public func analysisInputWitness() throws -> AnalysisInputWitness {
        try dbWriter.writeWithoutTransaction { db in try analysisInputObservation.snapshot(db) }
    }
}
