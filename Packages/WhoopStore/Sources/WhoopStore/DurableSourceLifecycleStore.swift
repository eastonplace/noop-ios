// Store-level source lifecycle transaction. Adapt table/helper visibility to WhoopStore.

import Foundation
import GRDB
import NoopPhase34Core

public enum DeviceLifecycleStoreError: Error, Equatable, Sendable {
    case unknownDevice(String)
    case archivedDevice(String)
    case invalidScope
}

public enum DurableSourceLifecycleMutation: Sendable {
    case replacePeripheral(
        deviceId: String,
        expectedOldLineage: String,
        peripheralId: String,
        consumerId: String
    )
    case archive(
        deviceId: String,
        replacementActiveId: String?,
        consumerId: String
    )
    case deleteData(
        deviceId: String,
        consumerId: String
    )
}

public struct DurableSourceLifecycleCommit: Codable, Equatable, Sendable {
    public let deviceId: String
    public let previousScope: HistoricalCursorScope
    public let nextScope: HistoricalCursorScope
    public let activeDeviceId: String?
}

public enum DurableSourceLifecycleError: Error, Equatable, Sendable {
    case unknownDevice(String)
    case archivedDevice(String)
    case invalidReplacement(String)
    case lineageChanged
    case invalidMutation
}

extension WhoopStore {
    public func persistSourceTransitionRecovery(
        _ record: SourceTransitionRecoveryRecord,
        now: Date = Date()
    ) async throws {
        try syncWrite { db in
            let existingRaw = try String.fetchOne(
                db,
                sql: "SELECT stage FROM sourceTransitionJournal WHERE transitionId = ?",
                arguments: [record.id.uuidString]
            )
            if let existingRaw {
                guard let existing = SourceTransitionStage(rawValue: existingRaw),
                      Self.canAdvanceSourceTransition(from: existing, to: record.stage) else {
                    throw DurableSourceLifecycleError.invalidMutation
                }
            } else {
                guard record.stage == .prepared else {
                    throw DurableSourceLifecycleError.invalidMutation
                }
                let conflictingTransitionId: String? = try String.fetchOne(db, sql: """
                    SELECT transitionId FROM sourceTransitionJournal
                    WHERE stage NOT IN ('complete', 'aborted')
                    ORDER BY updatedAt DESC LIMIT 1
                    """)
                guard conflictingTransitionId == nil else {
                    // A second transition must never overtake unresolved durable state. Otherwise the older
                    // postcommit journal can become visible again after the newer transition completes and
                    // replay an obsolete source/commit during launch recovery.
                    throw DurableSourceLifecycleError.invalidMutation
                }
            }
            try db.execute(sql: """
                INSERT INTO sourceTransitionJournal (
                    transitionId, mutationKind, sourceDeviceId, targetDeviceId,
                    historicalEpoch, externalEpoch, sinkEpoch, stage,
                    commitJSON, lastErrorCode, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
                ON CONFLICT(transitionId) DO UPDATE SET
                    stage = excluded.stage,
                    lastErrorCode = excluded.lastErrorCode,
                    updatedAt = excluded.updatedAt
                """, arguments: [
                    record.id.uuidString,
                    record.mutationKind,
                    record.sourceDeviceId,
                    record.targetDeviceId,
                    Int64(record.historicalEpoch),
                    Int64(record.externalEpoch),
                    Int64(record.sinkEpoch),
                    record.stage.rawValue,
                    record.lastErrorCode,
                    Int(now.timeIntervalSince1970),
                    Int(now.timeIntervalSince1970),
                ])

            // AppModel already writes the prepared record immediately before its store mutation. Keep that
            // exact transition ID in the writer connection's TEMP schema so the existing call path can join
            // the following source mutation to the same durable transaction without guessing a stale journal
            // row. TEMP state disappears on process death, which is precisely the precommit boundary.
            try Self.ensurePreparedTransitionBindingTable(in: db)
            if record.stage == .prepared {
                try db.execute(sql: """
                    INSERT INTO sourceTransitionPreparedBinding
                        (sourceDeviceId, mutationKind, transitionId)
                    VALUES (?, ?, ?)
                    ON CONFLICT(sourceDeviceId, mutationKind) DO UPDATE SET
                        transitionId = excluded.transitionId
                    """, arguments: [
                    record.sourceDeviceId,
                    record.mutationKind,
                    record.id.uuidString,
                ])
            } else {
                try db.execute(
                    sql: "DELETE FROM sourceTransitionPreparedBinding WHERE transitionId = ?",
                    arguments: [record.id.uuidString]
                )
            }
        }
    }

    public func latestSourceTransitionRecovery() async throws -> SourceTransitionRecoveryRecord? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT transitionId, mutationKind, sourceDeviceId, targetDeviceId,
                       historicalEpoch, externalEpoch, sinkEpoch, stage, lastErrorCode
                FROM sourceTransitionJournal
                WHERE stage NOT IN ('complete', 'aborted')
                ORDER BY updatedAt DESC LIMIT 1
                """) else { return nil }
            return try Self.decodeSourceTransitionRecovery(row)
        }
    }

    /// Load the exact lifecycle commit captured in the same SQLite transaction as the source mutation.
    /// Launch recovery must use this value instead of reconstructing state from the current registry.
    public func sourceTransitionCommit(
        transitionId: UUID
    ) async throws -> DurableSourceLifecycleCommit? {
        try syncRead { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT commitJSON FROM sourceTransitionJournal WHERE transitionId = ?",
                arguments: [transitionId.uuidString]
            ) else { return nil }
            let data: Data? = row["commitJSON"]
            guard let data else { return nil }
            return try JSONDecoder().decode(DurableSourceLifecycleCommit.self, from: data)
        }
    }

    /// Mutate one source. When `recovery` is supplied, the lifecycle change, durable commit payload,
    /// and `storeCommitted` journal edge are one SQLite transaction. The existing AppModel path may omit
    /// `recovery`; in that case the process-local TEMP binding created by `persistSourceTransitionRecovery`
    /// resolves only the prepared record written by this writer connection immediately before the mutation.
    public func commitSourceLifecycleMutation(
        _ mutation: DurableSourceLifecycleMutation,
        recovery: SourceTransitionRecoveryRecord? = nil,
        now: Date = Date()
    ) async throws -> DurableSourceLifecycleCommit {
        let fenceDeviceId: String
        switch mutation {
        case let .replacePeripheral(deviceId, _, _, _),
             let .archive(deviceId, _, _),
             let .deleteData(deviceId, _):
            fenceDeviceId = deviceId
        }
        if let recovery {
            guard recovery.sourceDeviceId == fenceDeviceId,
                  recovery.stage == .prepared,
                  recovery.mutationKind == Self.lifecycleMutationName(mutation) else {
                throw DurableSourceLifecycleError.invalidMutation
            }
        }

        let fencedSources = [fenceDeviceId, fenceDeviceId + "-noop"]
        for sourceId in fencedSources {
            await TargetScopedPipelineFence.shared.quiesce(sourceId: sourceId)
        }

        do {
            let commit = try syncWrite { db in
                let nowTs = Int(now.timeIntervalSince1970)
                let deviceId: String
                let expectedOldLineage: String?
                let replacement: String?

                switch mutation {
                case let .replacePeripheral(id, lineage, _, _):
                    deviceId = id
                    expectedOldLineage = lineage
                    replacement = nil
                case let .archive(id, replacementId, _):
                    deviceId = id
                    expectedOldLineage = nil
                    replacement = replacementId
                case let .deleteData(id, _):
                    deviceId = id
                    expectedOldLineage = nil
                    replacement = nil
                }

                let effectiveRecovery: SourceTransitionRecoveryRecord?
                if let recovery {
                    effectiveRecovery = recovery
                } else {
                    effectiveRecovery = try Self.boundPreparedSourceTransition(
                        sourceDeviceId: deviceId,
                        mutationKind: Self.lifecycleMutationName(mutation),
                        in: db
                    )
                }
                if let effectiveRecovery {
                    guard effectiveRecovery.sourceDeviceId == deviceId,
                          effectiveRecovery.stage == .prepared,
                          effectiveRecovery.mutationKind == Self.lifecycleMutationName(mutation) else {
                        throw DurableSourceLifecycleError.invalidMutation
                    }
                } else {
                    // If the process died after persisting `prepared`, the TEMP binding is intentionally gone.
                    // Do not let a later mutation silently commit outside that durable recovery record. Launch
                    // recovery must first abort the stale precommit transition or explicitly resume it.
                    let stalePreparedId: String? = try String.fetchOne(db, sql: """
                        SELECT transitionId FROM sourceTransitionJournal
                        WHERE sourceDeviceId = ? AND mutationKind = ? AND stage = 'prepared'
                        ORDER BY updatedAt DESC LIMIT 1
                        """, arguments: [deviceId, Self.lifecycleMutationName(mutation)])
                    guard stalePreparedId == nil else {
                        throw DurableSourceLifecycleError.invalidMutation
                    }
                }

                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT id, status, historyLineage, historyCursorEpoch
                        FROM pairedDevice WHERE id = ?
                        """,
                    arguments: [deviceId]
                ) else {
                    throw DurableSourceLifecycleError.unknownDevice(deviceId)
                }
                let oldLineage: String = row["historyLineage"]
                let oldEpoch: Int = row["historyCursorEpoch"]
                let oldScope = HistoricalCursorScope(
                    deviceId: deviceId,
                    lineage: oldLineage,
                    cursorEpoch: oldEpoch
                )
                if let expectedOldLineage, expectedOldLineage != oldLineage {
                    throw DurableSourceLifecycleError.lineageChanged
                }

                if let replacement {
                    guard let replacementStatus: String = try String.fetchOne(
                        db,
                        sql: "SELECT status FROM pairedDevice WHERE id = ?",
                        arguments: [replacement]
                    ) else {
                        throw DurableSourceLifecycleError.invalidReplacement(replacement)
                    }
                    guard replacementStatus != "archived" else {
                        throw DurableSourceLifecycleError.archivedDevice(replacement)
                    }
                }

                // Archive and physical replacement close the old ingest scope but preserve every
                // already-committed receipt for analysis. Privacy deletion is the only operation allowed
                // to discard that work. All lifecycle state is written inside this transaction.
                switch mutation {
                case let .replacePeripheral(_, _, peripheralId, _):
                    _ = try Self.closeHistoricalScopeForDrain(
                        oldScope,
                        reason: Self.lifecycleReason(mutation),
                        now: now,
                        in: db
                    )
                    let nextLineage = UUID().uuidString
                    try db.execute(sql: """
                        UPDATE pairedDevice
                        SET peripheralId = ?, historyLineage = ?,
                            historyCursorEpoch = historyCursorEpoch + 1,
                            lastSeenAt = ?
                        WHERE id = ? AND historyLineage = ?
                        """, arguments: [
                        peripheralId, nextLineage, nowTs, deviceId, oldLineage,
                    ])
                    guard db.changesCount == 1 else {
                        throw DurableSourceLifecycleError.lineageChanged
                    }

                case .archive:
                    _ = try Self.closeHistoricalScopeForDrain(
                        oldScope,
                        reason: Self.lifecycleReason(mutation),
                        now: now,
                        in: db
                    )
                    try db.execute(
                        sql: "UPDATE pairedDevice SET status = 'archived' WHERE id = ?",
                        arguments: [deviceId]
                    )
                    guard db.changesCount == 1 else {
                        throw DurableSourceLifecycleError.unknownDevice(deviceId)
                    }
                    if let replacement {
                        try db.execute(sql: """
                            UPDATE pairedDevice
                            SET status = CASE
                                WHEN id = ? THEN 'active'
                                WHEN status = 'active' THEN 'paired'
                                ELSE status END,
                                lastSeenAt = CASE WHEN id = ? THEN ? ELSE lastSeenAt END
                            WHERE id = ? OR status = 'active'
                            """, arguments: [replacement, replacement, nowTs, replacement])
                        guard try String.fetchOne(
                            db,
                            sql: "SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1"
                        ) == replacement else {
                            throw DurableSourceLifecycleError.invalidReplacement(replacement)
                        }
                    }

                case .deleteData:
                    try Self.discardHistoricalScope(
                        oldScope,
                        reason: Self.lifecycleReason(mutation),
                        now: now,
                        in: db
                    )
                    let existing = Set(try String.fetchAll(
                        db,
                        sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
                    ))
                    // Exact historical analysis owns both the raw source namespace and its derived
                    // `<source>-noop` namespace. Privacy deletion must remove both atomically so a
                    // deferred or previously-published derived row cannot survive the raw source.
                    let ownedDeviceIds = [deviceId, deviceId + "-noop"]
                    for table in DeviceRegistryStore.deviceScopedTables
                        where existing.contains(table) && table != "historicalReceiptScopeLifecycle" {
                        for ownedDeviceId in ownedDeviceIds {
                            try db.execute(
                                sql: "DELETE FROM \(table) WHERE deviceId = ?",
                                arguments: [ownedDeviceId]
                            )
                        }
                    }
                    // Keep the raw source's `discarded` lifecycle tombstone written above. Admission uses it
                    // to reject a stale receipt batch that was read before deletion but reaches its write
                    // transaction after deletion. A computed namespace does not own raw receipt lifecycle.
                    if existing.contains("historicalReceiptScopeLifecycle") {
                        try db.execute(
                            sql: "DELETE FROM historicalReceiptScopeLifecycle WHERE deviceId = ?",
                            arguments: [deviceId + "-noop"]
                        )
                    }
                    if existing.contains("historicalMaintenanceWork") {
                        try db.execute(
                            sql: "DELETE FROM historicalMaintenanceWork WHERE deviceId IN (?, ?)",
                            arguments: [deviceId, deviceId + "-noop"]
                        )
                    }
                    // Keep sourceTransitionJournal intact. The recovery coordinator owns this record
                    // and must be able to resume a crash after the privacy transaction commits. It marks
                    // the transition complete/aborted only after the remaining fenced stages finish.
                    try db.execute(sql: """
                        UPDATE pairedDevice
                        SET historyLineage = ?, historyCursorEpoch = historyCursorEpoch + 1
                        WHERE id = ? AND historyLineage = ?
                        """, arguments: [UUID().uuidString, deviceId, oldLineage])
                    guard db.changesCount == 1 else {
                        throw DurableSourceLifecycleError.lineageChanged
                    }
                }

                guard let next = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT historyLineage, historyCursorEpoch
                        FROM pairedDevice WHERE id = ?
                        """,
                    arguments: [deviceId]
                ) else {
                    throw DurableSourceLifecycleError.unknownDevice(deviceId)
                }
                let nextScope = HistoricalCursorScope(
                    deviceId: deviceId,
                    lineage: next["historyLineage"],
                    cursorEpoch: next["historyCursorEpoch"]
                )
                let active: String? = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM pairedDevice WHERE status = 'active' LIMIT 1"
                )
                let commit = DurableSourceLifecycleCommit(
                    deviceId: deviceId,
                    previousScope: oldScope,
                    nextScope: nextScope,
                    activeDeviceId: active
                )

                if let effectiveRecovery {
                    let commitJSON = try JSONEncoder().encode(commit)
                    try db.execute(sql: """
                        UPDATE sourceTransitionJournal
                        SET stage = 'storeCommitted', commitJSON = ?, lastErrorCode = NULL, updatedAt = ?
                        WHERE transitionId = ? AND stage = 'prepared'
                          AND mutationKind = ? AND sourceDeviceId = ?
                        """, arguments: [
                        commitJSON,
                        nowTs,
                        effectiveRecovery.id.uuidString,
                        effectiveRecovery.mutationKind,
                        effectiveRecovery.sourceDeviceId,
                    ])
                    guard db.changesCount == 1 else {
                        throw DurableSourceLifecycleError.invalidMutation
                    }
                    try db.execute(
                        sql: "DELETE FROM sourceTransitionPreparedBinding WHERE transitionId = ?",
                        arguments: [effectiveRecovery.id.uuidString]
                    )
                }
                return commit
            }
            for sourceId in fencedSources.reversed() {
                await TargetScopedPipelineFence.shared.resume(sourceId: sourceId)
            }
            return commit
        } catch {
            for sourceId in fencedSources.reversed() {
                await TargetScopedPipelineFence.shared.resume(sourceId: sourceId)
            }
            throw error
        }
    }

    private static func ensurePreparedTransitionBindingTable(in db: Database) throws {
        try db.execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS sourceTransitionPreparedBinding (
                sourceDeviceId TEXT NOT NULL,
                mutationKind TEXT NOT NULL,
                transitionId TEXT NOT NULL,
                PRIMARY KEY (sourceDeviceId, mutationKind)
            )
            """)
    }

    private static func boundPreparedSourceTransition(
        sourceDeviceId: String,
        mutationKind: String,
        in db: Database
    ) throws -> SourceTransitionRecoveryRecord? {
        try ensurePreparedTransitionBindingTable(in: db)
        guard let transitionId: String = try String.fetchOne(
            db,
            sql: """
                SELECT transitionId FROM sourceTransitionPreparedBinding
                WHERE sourceDeviceId = ? AND mutationKind = ?
                """,
            arguments: [sourceDeviceId, mutationKind]
        ), let row = try Row.fetchOne(db, sql: """
            SELECT transitionId, mutationKind, sourceDeviceId, targetDeviceId,
                   historicalEpoch, externalEpoch, sinkEpoch, stage, lastErrorCode
            FROM sourceTransitionJournal WHERE transitionId = ?
            """, arguments: [transitionId]) else { return nil }
        let record = try decodeSourceTransitionRecovery(row)
        guard record.stage == .prepared else {
            try db.execute(
                sql: "DELETE FROM sourceTransitionPreparedBinding WHERE transitionId = ?",
                arguments: [transitionId]
            )
            return nil
        }
        return record
    }

    private static func decodeSourceTransitionRecovery(
        _ row: Row
    ) throws -> SourceTransitionRecoveryRecord {
        guard let id = UUID(uuidString: row["transitionId"] as String),
              let stage = SourceTransitionStage(rawValue: row["stage"] as String) else {
            throw DurableSourceLifecycleError.invalidMutation
        }
        return SourceTransitionRecoveryRecord(
            id: id,
            mutationKind: row["mutationKind"],
            sourceDeviceId: row["sourceDeviceId"],
            targetDeviceId: row["targetDeviceId"],
            historicalEpoch: UInt64(row["historicalEpoch"] as Int64),
            externalEpoch: UInt64(row["externalEpoch"] as Int64),
            sinkEpoch: UInt64(row["sinkEpoch"] as Int64),
            stage: stage,
            lastErrorCode: row["lastErrorCode"]
        )
    }

    private static func canAdvanceSourceTransition(
        from old: SourceTransitionStage,
        to new: SourceTransitionStage
    ) -> Bool {
        if old == new { return true }
        switch (old, new) {
        case (.prepared, .storeCommitted),
             (.prepared, .aborted),
             (.storeCommitted, .sinkActivated),
             (.storeCommitted, .workersResumed),
             (.storeCommitted, .complete),
             (.sinkActivated, .workersResumed),
             (.sinkActivated, .complete),
             (.workersResumed, .complete):
            return true
        default:
            return false
        }
    }

    private static func lifecycleMutationName(
        _ mutation: DurableSourceLifecycleMutation
    ) -> String {
        switch mutation {
        case .replacePeripheral: return "replacePeripheral"
        case .archive: return "archive"
        case .deleteData: return "deleteData"
        }
    }

    private static func lifecycleReason(
        _ mutation: DurableSourceLifecycleMutation
    ) -> String {
        switch mutation {
        case .replacePeripheral: return "peripheral_identity_transition"
        case .archive: return "source_archived"
        case .deleteData: return "source_deleted"
        }
    }

    /*
    Archive/re-pair integration continues through HistoricalScopeDrainLifecycle.swift.
    Add the v48 tables above to `DeviceRegistryStore.deviceScopedTables` and its schema audit.
    Do not call the legacy retire/quarantine helper from these mutations.
    */
}
