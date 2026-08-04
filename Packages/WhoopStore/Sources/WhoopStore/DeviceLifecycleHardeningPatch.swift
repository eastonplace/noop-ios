// Replace DeviceRegistryStore.setActive and add source-transition cleanup helpers.

import Foundation
import GRDB

public enum DeviceLifecycleStoreError: Error, Equatable, Sendable {
    case unknownDevice(String)
    case archivedDevice(String)
    case invalidScope
}

extension WhoopStore {
    /// Retire one old physical-source scope in a single transaction. The consumer watermark advances through
    /// every durable receipt in that scope, while nonterminal analysis work is quarantined. Receipt rows stay
    /// available for audit. This prevents a re-pair from leaving old-lineage work permanently pending.
    @discardableResult
    public func retireHistoricalReceiptScope(
        consumerId: String,
        scope: HistoricalCursorScope,
        reason: String,
        now: Int = Int(Date().timeIntervalSince1970)
    ) async throws -> Int64 {
        guard !consumerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !scope.deviceId.isEmpty,
              !scope.lineage.isEmpty,
              scope.cursorEpoch >= 0,
              !scope.trimScope.isEmpty,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceLifecycleStoreError.invalidScope
        }

        return try syncWrite { db in
            let databaseInstanceId = try WhoopStore.databaseInstanceId(in: db)
            let throughGeneration = try Int64.fetchOne(db, sql: """
                SELECT MAX(generation) FROM historicalDataCommitJournal
                WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
                  AND cursorEpoch = ? AND trimScope = ?
                """, arguments: [
                    databaseInstanceId,
                    scope.deviceId,
                    scope.lineage,
                    scope.cursorEpoch,
                    scope.trimScope,
                ]) ?? 0

            try db.execute(sql: """
                INSERT INTO historicalReceiptConsumer (
                    consumerId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                    throughGeneration, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(consumerId, databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope)
                DO UPDATE SET
                    throughGeneration = MAX(historicalReceiptConsumer.throughGeneration, excluded.throughGeneration),
                    updatedAt = excluded.updatedAt
                """, arguments: [
                    consumerId,
                    databaseInstanceId,
                    scope.deviceId,
                    scope.lineage,
                    scope.cursorEpoch,
                    scope.trimScope,
                    throughGeneration,
                    now,
                ])

            try db.execute(sql: """
                UPDATE historicalAnalysisWork
                SET state = 'quarantined', lastErrorCode = ?, nextAttemptAt = NULL,
                    leaseOwner = NULL, leaseExpiresAt = NULL, updatedAt = ?
                WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
                  AND cursorEpoch = ? AND trimScope = ?
                  AND state NOT IN ('complete', 'quarantined')
                """, arguments: [
                    reason,
                    now,
                    databaseInstanceId,
                    scope.deviceId,
                    scope.lineage,
                    scope.cursorEpoch,
                    scope.trimScope,
                ])
            return throughGeneration
        }
    }

    /// Fence nonterminal work from a physical source that has just been replaced. Completed rows remain as
    /// diagnostics. Prefer `retireHistoricalReceiptScope` when the old durable receipt scope is available.
    public func quarantineHistoricalPipelineWork(
        deviceId: String,
        lineage: String,
        cursorEpoch: Int,
        reason: String,
        now: Int = Int(Date().timeIntervalSince1970)
    ) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE historicalAnalysisWork
                SET state = 'quarantined', lastErrorCode = ?, nextAttemptAt = NULL,
                    leaseOwner = NULL, leaseExpiresAt = NULL, updatedAt = ?
                WHERE deviceId = ? AND lineage = ? AND cursorEpoch = ?
                  AND state NOT IN ('complete', 'quarantined')
                """, arguments: [reason, now, deviceId, lineage, cursorEpoch])
        }
    }

    /// Remove every external payload and destination row for one logical device owner. The tables carry an
    /// explicit deviceId so privacy deletion never parses a context string.
    public func deleteExternalPublications(deviceId: String) async throws {
        guard !deviceId.isEmpty else { return }
        try syncWrite { db in
            try db.execute(
                sql: "DELETE FROM externalPublicationOutbox WHERE deviceId = ?",
                arguments: [deviceId]
            )
            try db.execute(
                sql: "DELETE FROM verifiedSnapshotCommit WHERE deviceId = ?",
                arguments: [deviceId]
            )
            try db.execute(
                sql: "DELETE FROM verifiedHealthProjection WHERE deviceId = ?",
                arguments: [deviceId]
            )
            try db.execute(
                sql: "DELETE FROM analysisMutationJournal WHERE deviceId = ?",
                arguments: [deviceId]
            )
        }
    }
}

/*
Mechanical integration:

1. Rename `setActiveV2` to `setActive` and remove the old demote-first implementation.
2. Add `historicalReceiptConsumer`, `historicalAnalysisWork`, `analysisMutationJournal`,
   `externalPublicationOutbox`, `verifiedSnapshotCommit`, and `verifiedHealthProjection` to the
   device-family deletion audit.
3. Before `setPeripheralId`, registry upsert, delete-all epoch change, archive/remove, or source replacement:
   - capture the old `HistoricalCursorScope`;
   - cancel the in-memory runtime;
   - call `retireHistoricalReceiptScope` using the Phase 3/4 consumer ID;
   - perform the registry/source transition;
   - clear incompatible Today and external projection state;
   - restart admission only for the new scope.
4. Backup restore cancels both workers and relies on databaseInstanceId to reject pre-restore work.
*/
