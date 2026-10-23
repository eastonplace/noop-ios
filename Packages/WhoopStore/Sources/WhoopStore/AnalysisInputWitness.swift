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
    let appendGlobalRevision: UInt64
    let appendRevisions: [AnalysisAppendBucket: UInt64]
    let gravityGlobalRevision: UInt64
    let gravityRevisions: [AnalysisGravityBucket: UInt64]

    /// All changes to a dependency table invalidate, including same-key value/quality repairs.
    public func signature(tables: [String]) -> String {
        let base = "\(generation):\(externalVersion):\(schemaVersion):\(tempSchemaVersion):\(unknownRevision)"
        return tables.map { $0.lowercased() }.sorted().reduce(base) {
            $0 + ":\($1.utf8.count):\($1)=\(tableRevisions[$1, default: 0])"
        }
    }

    /// Complete identity for the inclusive union of night, full-day fallback and cycle-tail reads.
    /// Only proved inserts in the three refined families use intersecting UTC hours, across ALL sources.
    /// Repairs/unknown writes remain global; other input tables retain their complete table revisions.
    public func dayScanSignature(tables: [String], from: Int, to: Int) -> String {
        let requested = Set(tables.map { $0.lowercased() })
        let refined = AnalysisAppendTable.allCases.filter { requested.contains($0.rawValue) }
        let first = Self.utcHour(from), last = Self.utcHour(to)
        guard !refined.isEmpty, to >= from, last - first <= 7 * 24 else {
            return signature(tables: tables) + ":range\(from):\(to)"
        }
        let unchangedTables = tables.filter { AnalysisAppendTable(rawValue: $0.lowercased()) == nil }
        var value = signature(tables: unchangedTables) + ":range\(from):\(to):append\(appendGlobalRevision)"
        for table in refined {
            value += ":\(table.rawValue)"
            for hour in first...last {
                value += ":\(hour)=\(appendRevisions[.init(table: table, hour: hour), default: 0])"
            }
        }
        return value
    }

    /// Advance only exact contiguous output commits owned by this pass. Any unowned same-table commit
    /// creates a revision gap; all raw/control/session/config/store fences remain the original START value.
    public func acknowledgingOwnOutputs(_ ledger: AnalysisOutputWriteLedger) -> AnalysisInputWitness {
        var acknowledged = tableRevisions
        var blocked = Set<String>()
        for transition in ledger.snapshot() where transition.generation == generation {
            guard !blocked.contains(transition.table) else { continue }
            guard acknowledged[transition.table, default: 0] == transition.before else {
                blocked.insert(transition.table)
                continue
            }
            acknowledged[transition.table] = transition.after
        }
        return AnalysisInputWitness(
            generation: generation, externalVersion: externalVersion, schemaVersion: schemaVersion,
            tempSchemaVersion: tempSchemaVersion, unknownRevision: unknownRevision,
            tableRevisions: acknowledged, appendGlobalRevision: appendGlobalRevision,
            appendRevisions: appendRevisions, gravityGlobalRevision: gravityGlobalRevision,
            gravityRevisions: gravityRevisions)
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

    static func utcHour(_ timestamp: Int) -> Int {
        timestamp / 3_600 - (timestamp < 0 && timestamp % 3_600 != 0 ? 1 : 0)
    }

    static func utcDay(_ timestamp: Int) -> Int {
        timestamp / 86_400 - (timestamp < 0 && timestamp % 86_400 != 0 ? 1 : 0)
    }
}

enum AnalysisAppendTable: String, CaseIterable, Sendable {
    case hr = "hrsample", rr = "rrinterval", gravity = "gravitysample"

    var primaryKey: [String] {
        self == .rr ? ["deviceid", "ts", "rrms", "seq"] : ["deviceid", "ts"]
    }
}

struct AnalysisAppendBucket: Sendable, Hashable {
    let table: AnalysisAppendTable
    let hour: Int
}

private struct AnalysisAppendRow: Hashable {
    let table: AnalysisAppendTable
    let rowID: Int64
}

struct AnalysisGravityBucket: Sendable, Hashable {
    let owner: String
    let day: Int
}

/// All mutable state is confined to the shared GRDB writer queue. Pool handles share this instance.
/// Count every event: early observation shutdown would hide mixed/unobserved changes from the total fence.
final class AnalysisInputObservation: TransactionObserver, @unchecked Sendable {
    private enum OutputOrigin {
        case owned(AnalysisOutputWriteLedger)
        case unowned
    }
    private let generation = UUID().uuidString
    private var accountedTotal: Int64 = 0
    private var observedRows: Int64 = 0
    private var pendingTables = Set<String>()
    private var pendingUnknown = false
    private var tableRevisions: [String: UInt64] = [:]
    private var unknownRevision: UInt64 = 0
    private var gravityGlobalRevision: UInt64 = 0
    private var gravityRevisions: [AnalysisGravityBucket: UInt64] = [:]
    private var appendGlobalRevision: UInt64 = 0
    private var appendRevisions: [AnalysisAppendBucket: UInt64] = [:]
    // ONE shared pending-row budget for all three tables; motion reuses the same gravity row IDs.
    private var pendingAppendRows = Set<AnalysisAppendRow>()
    private var pendingAppendGlobal = false
    private var pendingAppendOverflow = false
    private var pendingGravityGlobal = false
    private var knownAppendTable: AnalysisAppendTable?
    private var appendSchemaKey: String?
    private var appendSchemaSafety: [AnalysisAppendTable: Bool] = [:]
    private var activeOutputLedger: AnalysisOutputWriteLedger?
    private var outputSchemaKey: String?
    private var outputSchemaAllowsReceipts = false
    private var pendingOutputOrigins: [String: OutputOrigin] = [:]
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
        if table == "dailymetric" || table == "metricseries" {
            if let origin = pendingOutputOrigins[table] {
                if case let .owned(owner) = origin, owner !== activeOutputLedger {
                    pendingOutputOrigins[table] = .unowned
                }
            } else {
                pendingOutputOrigins[table] = activeOutputLedger.map(OutputOrigin.owned) ?? .unowned
            }
        }
        guard let family = AnalysisAppendTable(rawValue: table) else { return }
        guard knownAppendTable == family, event.kind == .insert else {
            pendingAppendGlobal = true
            if family == .gravity { pendingGravityGlobal = true }
            return
        }
        guard !pendingAppendOverflow else {
            if family == .gravity { pendingGravityGlobal = true }
            return
        }
        guard pendingAppendRows.count < Self.regionLimit else {
            pendingAppendOverflow = true
            pendingAppendGlobal = true
            pendingGravityGlobal = pendingTables.contains(AnalysisAppendTable.gravity.rawValue)
            pendingAppendRows.removeAll(keepingCapacity: true)
            return
        }
        pendingAppendRows.insert(.init(table: family, rowID: event.rowID))
    }

    func databaseWillCommit() throws {}
    func databaseDidCommit(_ db: Database) { reconcile(db) }

    func recordingOutputWrites<T>(
        _ ledger: AnalysisOutputWriteLedger, in db: Database, _ body: () throws -> T
    ) rethrows -> T {
        let previous = activeOutputLedger
        let totalBefore = sqlite3_total_changes64(db.sqliteConnection)
        activeOutputLedger = outputReceiptsAreSafe(in: db) ? ledger : nil
        defer { activeOutputLedger = previous }
        let result = try body()
        // These explicit APIs return their direct affected-row count. A trigger/FK side effect is
        // input feedback, even when it lands in the same table. It must require a settling pass.
        if let directChanges = result as? Int,
           sqlite3_total_changes64(db.sqliteConnection) - totalBefore == Int64(directChanges) {
            return result
        }
        for (table, origin) in pendingOutputOrigins {
            if case let .owned(owner) = origin, owner === ledger { pendingOutputOrigins[table] = .unowned }
        }
        return result
    }

    func databaseDidRollback(_ db: Database) {
        // A matched, fully observed rollback publishes no input change. Unaccounted changes may instead
        // be an earlier committed direct-SQL write; a later rollback must never acknowledge that drift.
        let total = sqlite3_total_changes64(db.sqliteConnection)
        if pendingUnknown || total - accountedTotal != observedRows {
            unknownRevision &+= 1
            appendGlobalRevision &+= 1
            appendRevisions.removeAll(keepingCapacity: true)
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
            appendGlobalRevision: appendGlobalRevision, appendRevisions: appendRevisions,
            gravityGlobalRevision: gravityGlobalRevision, gravityRevisions: gravityRevisions)
    }

    /// Only fixed decoded-stream INSERT ... DO NOTHING bodies opt in. A same-transaction UPDATE,
    /// including RR provenance/quality upgrades, still takes the global path in databaseDidChange.
    func withKnownAppend<T>(table: AnalysisAppendTable, in db: Database, _ body: () throws -> T) rethrows -> T {
        let previous = knownAppendTable
        knownAppendTable = appendRegionsAreSafe(table: table, in: db) ? table : nil
        defer { knownAppendTable = previous }
        return try body()
    }

    private func appendRegionsAreSafe(table: AnalysisAppendTable, in db: Database) -> Bool {
        do {
            guard let main = try Int.fetchOne(db, sql: "PRAGMA schema_version"),
                  let temp = try Int.fetchOne(db, sql: "PRAGMA temp.schema_version") else { return false }
            let key = "\(main):\(temp)"
            if appendSchemaKey != key {
                appendSchemaKey = key
                appendSchemaSafety.removeAll(keepingCapacity: true)
            }
            if let safe = appendSchemaSafety[table] { return safe }
            let name = table.rawValue
            let columns = try Row.fetchAll(db, sql: "PRAGMA main.table_xinfo(\(name))")
            let shadowsRowID = columns.contains { ["rowid", "_rowid_", "oid"].contains(($0["name"] as String).lowercased()) }
            let primary = columns.filter { ($0["pk"] as Int) > 0 }
                .sorted { ($0["pk"] as Int) < ($1["pk"] as Int) }.map { ($0["name"] as String).lowercased() }
            let timestampIsInteger = columns.contains {
                ($0["name"] as String).lowercased() == "ts" && ($0["type"] as String).uppercased() == "INTEGER"
            }
            let ownerIsText = columns.contains {
                ($0["name"] as String).lowercased() == "deviceid" && ($0["type"] as String).uppercased() == "TEXT"
            }
            let rowid = try Int.fetchOne(db, sql:
                "SELECT wr FROM pragma_table_list WHERE schema='main' AND name=? COLLATE NOCASE", arguments: [name]) == 0
            let extraUnique = try Row.fetchAll(db, sql: "PRAGMA main.index_list(\(name))")
                .contains { ($0["unique"] as Int) != 0 && ($0["origin"] as String) != "pk" }
            let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA main.foreign_key_list(\(name))")
            let triggers = try Int.fetchOne(db, sql: """
                SELECT (SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND tbl_name=? COLLATE NOCASE)
                     + (SELECT COUNT(*) FROM sqlite_temp_master WHERE type='trigger' AND tbl_name=? COLLATE NOCASE)
                     + (SELECT COUNT(*) FROM sqlite_temp_master WHERE name=? COLLATE NOCASE)
                """, arguments: [name, name, name]) ?? 1
            let safe = primary == table.primaryKey && rowid && !shadowsRowID && !extraUnique
                && timestampIsInteger && ownerIsText && foreignKeys.isEmpty && triggers == 0
            appendSchemaSafety[table] = safe
            return safe
        } catch {
            return false
        }
    }

    /// An unexpected unique constraint can REPLACE another fallback row without a delete event/count.
    /// Disable acknowledgment under changed output schemas; ordinary invalidation remains complete.
    private func outputReceiptsAreSafe(in db: Database) -> Bool {
        do {
            guard let main = try Int.fetchOne(db, sql: "PRAGMA schema_version"),
                  let temp = try Int.fetchOne(db, sql: "PRAGMA temp.schema_version") else { return false }
            let key = "\(main):\(temp)"
            if outputSchemaKey == key { return outputSchemaAllowsReceipts }
            var safe = true
            for (table, expectedPK) in [("dailyMetric", ["deviceid", "day"]),
                                         ("metricSeries", ["deviceid", "day", "key"])] {
                let columns = try Row.fetchAll(db, sql: "PRAGMA main.table_xinfo(\(table))")
                let primary = columns.filter { ($0["pk"] as Int) > 0 }
                    .sorted { ($0["pk"] as Int) < ($1["pk"] as Int) }
                    .map { ($0["name"] as String).lowercased() }
                let rowid = try Int.fetchOne(db, sql:
                    "SELECT wr FROM pragma_table_list WHERE schema='main' AND name=? COLLATE NOCASE",
                    arguments: [table]) == 0
                let extraUnique = try Row.fetchAll(db, sql: "PRAGMA main.index_list(\(table))")
                    .contains { ($0["unique"] as Int) != 0 && ($0["origin"] as String) != "pk" }
                let foreignKeys = try Row.fetchAll(db, sql: "PRAGMA main.foreign_key_list(\(table))")
                let shadow = try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM sqlite_temp_master WHERE name=? COLLATE NOCASE", arguments: [table]) ?? 1
                safe = safe && primary == expectedPK && rowid && !extraUnique && foreignKeys.isEmpty && shadow == 0
            }
            outputSchemaKey = key
            outputSchemaAllowsReceipts = safe
            return safe
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
        for table in pendingTables {
            let before = tableRevisions[table, default: 0]
            tableRevisions[table] = before &+ 1
            if !unknown, case let .owned(ledger) = pendingOutputOrigins[table] {
                ledger.record(generation: generation, table: table, before: before, after: before &+ 1)
            }
        }

        var appendGlobal = unknown || pendingAppendGlobal
        var gravityGlobal = unknown || pendingGravityGlobal
        var hours = Set<AnalysisAppendBucket>()
        var motionDays = Set<AnalysisGravityBucket>()
        if !unknown {
            let byTable = Dictionary(grouping: pendingAppendRows, by: \.table)
            for (table, pending) in byTable {
                // A global scan fence needs no row lookup, except gravity still supplies motion precision.
                guard !appendGlobal || table == .gravity && !gravityGlobal else { continue }
                do {
                    let ids = pending.map(\.rowID)
                    var found = 0
                    for start in stride(from: 0, to: ids.count, by: 500) {
                        let chunk = Array(ids[start..<min(start + 500, ids.count)])
                        let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                        let rows = try Row.fetchAll(db, sql:
                            "SELECT deviceId,ts FROM main.\(table.rawValue) WHERE rowid IN (\(placeholders))",
                            arguments: StatementArguments(chunk))
                        found += rows.count
                        for row in rows {
                            let ts: Int = row["ts"]
                            if !appendGlobal { hours.insert(.init(table: table, hour: AnalysisInputWitness.utcHour(ts))) }
                            if table == .gravity, !gravityGlobal {
                                let owner: String = row["deviceId"]
                                motionDays.insert(.init(owner: owner, day: AnalysisInputWitness.utcDay(ts)))
                            }
                        }
                    }
                    if found != ids.count {
                        appendGlobal = true
                        if table == .gravity { gravityGlobal = true }
                    }
                } catch {
                    appendGlobal = true
                    if table == .gravity { gravityGlobal = true }
                }
            }
        }
        if appendGlobal {
            appendGlobalRevision &+= 1
            appendRevisions.removeAll(keepingCapacity: true)
            hours.removeAll()
        }
        if gravityGlobal {
            gravityGlobalRevision &+= 1
            gravityRevisions.removeAll(keepingCapacity: true)
            motionDays.removeAll()
        }
        let newHours = hours.reduce(0) { $0 + (appendRevisions[$1] == nil ? 1 : 0) }
        let newMotionDays = motionDays.reduce(0) { $0 + (gravityRevisions[$1] == nil ? 1 : 0) }
        // ONE combined retained-state budget. Clearing either precision map always advances its fence.
        if appendRevisions.count + gravityRevisions.count + newHours + newMotionDays > Self.regionLimit {
            appendGlobalRevision &+= 1
            gravityGlobalRevision &+= 1
            appendRevisions.removeAll(keepingCapacity: true)
            gravityRevisions.removeAll(keepingCapacity: true)
        } else {
            for hour in hours { appendRevisions[hour, default: 0] &+= 1 }
            for day in motionDays { gravityRevisions[day, default: 0] &+= 1 }
        }
        accountedTotal = total
        resetPending()
    }

    private func resetPending() {
        observedRows = 0
        pendingTables.removeAll(keepingCapacity: true)
        pendingUnknown = false
        pendingAppendRows.removeAll(keepingCapacity: true)
        pendingAppendGlobal = false
        pendingAppendOverflow = false
        pendingGravityGlobal = false
        pendingOutputOrigins.removeAll(keepingCapacity: true)
    }
}

extension WhoopStore {
    /// Constant-size metadata/RAM snapshot; no raw stream is scanned to decide whether a cache can reuse.
    public func analysisInputWitness() throws -> AnalysisInputWitness {
        try dbWriter.writeWithoutTransaction { db in try analysisInputObservation.snapshot(db) }
    }
}
