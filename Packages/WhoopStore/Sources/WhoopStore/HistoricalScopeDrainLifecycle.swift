import Foundation
import GRDB
import NoopPhase34Core

public enum HistoricalScopeLifecycleState: String, Codable, Equatable, Sendable {
    case open
    case draining
    case drained
    case discarded
}

public struct HistoricalScopeLifecycleRecord: Equatable, Sendable {
    public let databaseInstanceId: String
    public let scope: HistoricalCursorScope
    public let state: HistoricalScopeLifecycleState
    public let closedThroughGeneration: Int64
    public let reason: String
    public let updatedAt: Date
}

public enum HistoricalScopeLifecycleError: Error, Equatable, Sendable {
    case invalidScope
    case invalidState
    case ingestClosed
}

extension WhoopStore {

    /// Call inside the same transaction that persists decoded raw rows, cursor, and receipt.
    /// A scope with no lifecycle row is an ordinary open scope. Once archive/re-pair closes it,
    /// a late BLE chunk cannot commit after the frozen frontier.
    static func assertHistoricalScopeAcceptingIngest(
        _ scope: HistoricalCursorScope,
        in db: Database
    ) throws {
        let databaseId = try WhoopStore.databaseInstanceId(in: db)
        let state: String? = try String.fetchOne(db, sql: """
            SELECT state FROM historicalReceiptScopeLifecycle
            WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
              AND cursorEpoch = ? AND trimScope = ?
            """, arguments: [
                databaseId, scope.deviceId, scope.lineage,
                scope.cursorEpoch, scope.trimScope,
            ])
        guard state == nil || state == HistoricalScopeLifecycleState.open.rawValue else {
            throw HistoricalScopeLifecycleError.ingestClosed
        }
    }
    /// Close a physical/source scope to new ingest while preserving every receipt already committed.
    /// Archive and physical replacement use this path. They must not advance the analysis consumer or
    /// quarantine pending work, because the product promises that recorded history remains complete.
    static func closeHistoricalScopeForDrain(
        _ scope: HistoricalCursorScope,
        reason: String,
        now: Date,
        in db: Database
    ) throws -> HistoricalScopeLifecycleRecord {
        guard !scope.deviceId.isEmpty, !scope.lineage.isEmpty,
              scope.cursorEpoch >= 0, !scope.trimScope.isEmpty,
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HistoricalScopeLifecycleError.invalidScope
        }
        let databaseId = try WhoopStore.databaseInstanceId(in: db)
        let closedThrough = try Int64.fetchOne(db, sql: """
            SELECT MAX(generation)
            FROM historicalDataCommitJournal
            WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
              AND cursorEpoch = ? AND trimScope = ?
            """, arguments: [
                databaseId, scope.deviceId, scope.lineage,
                scope.cursorEpoch, scope.trimScope,
            ]) ?? 0
        let updatedAt = Int(now.timeIntervalSince1970)
        try db.execute(sql: """
            INSERT INTO historicalReceiptScopeLifecycle (
                databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                state, closedThroughGeneration, reason, updatedAt
            ) VALUES (?, ?, ?, ?, ?, 'draining', ?, ?, ?)
            ON CONFLICT(databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope)
            DO UPDATE SET
                state = CASE
                    WHEN historicalReceiptScopeLifecycle.state = 'discarded'
                        THEN 'discarded'
                    ELSE 'draining'
                END,
                closedThroughGeneration = MAX(
                    historicalReceiptScopeLifecycle.closedThroughGeneration,
                    excluded.closedThroughGeneration
                ),
                reason = excluded.reason,
                updatedAt = excluded.updatedAt
            """, arguments: [
                databaseId, scope.deviceId, scope.lineage,
                scope.cursorEpoch, scope.trimScope,
                closedThrough, reason, updatedAt,
            ])
        return HistoricalScopeLifecycleRecord(
            databaseInstanceId: databaseId,
            scope: scope,
            state: .draining,
            closedThroughGeneration: closedThrough,
            reason: reason,
            updatedAt: now
        )
    }

    /// Privacy deletion is the only lifecycle mutation allowed to abandon old-scope analysis. The caller
    /// deletes raw/derived rows and durable pipeline state in the same surrounding transaction.
    static func discardHistoricalScope(
        _ scope: HistoricalCursorScope,
        reason: String,
        now: Date,
        in db: Database
    ) throws {
        let databaseId = try WhoopStore.databaseInstanceId(in: db)
        try db.execute(sql: """
            INSERT INTO historicalReceiptScopeLifecycle (
                databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                state, closedThroughGeneration, reason, updatedAt
            ) VALUES (?, ?, ?, ?, ?, 'discarded', 0, ?, ?)
            ON CONFLICT(databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope)
            DO UPDATE SET state = 'discarded', reason = excluded.reason,
                          updatedAt = excluded.updatedAt
            """, arguments: [
                databaseId, scope.deviceId, scope.lineage,
                scope.cursorEpoch, scope.trimScope,
                reason, Int(now.timeIntervalSince1970),
            ])
    }

    /// Return closed scopes whose immutable receipts or already-admitted work still need to drain. Add
    /// these contexts to the current registry contexts; do not synthesize an active BLE source for them.
    public func drainingHistoricalReceiptScopes(
        consumerId: String = "phase34.analysis"
    ) async throws -> [HistoricalCursorScope] {
        try syncRead { db in
            let databaseId = try WhoopStore.databaseInstanceId(in: db)
            let rows = try Row.fetchAll(db, sql: """
                SELECT l.deviceId, l.lineage, l.cursorEpoch, l.trimScope
                FROM historicalReceiptScopeLifecycle AS l
                LEFT JOIN historicalReceiptConsumer AS c
                  ON c.consumerId = ?
                 AND c.databaseInstanceId = l.databaseInstanceId
                 AND c.deviceId = l.deviceId
                 AND c.lineage = l.lineage
                 AND c.cursorEpoch = l.cursorEpoch
                 AND c.trimScope = l.trimScope
                WHERE l.databaseInstanceId = ? AND l.state = 'draining'
                  AND (
                    COALESCE(c.throughGeneration, 0) < l.closedThroughGeneration
                    OR EXISTS (
                        SELECT 1 FROM historicalAnalysisWork AS w
                        WHERE w.databaseInstanceId = l.databaseInstanceId
                          AND w.deviceId = l.deviceId
                          AND w.lineage = l.lineage
                          AND w.cursorEpoch = l.cursorEpoch
                          AND w.trimScope = l.trimScope
                          AND w.state NOT IN ('complete', 'quarantined')
                    )
                  )
                ORDER BY l.updatedAt ASC
                """, arguments: [consumerId, databaseId])
            return rows.map { row in
                HistoricalCursorScope(
                    deviceId: row["deviceId"],
                    lineage: row["lineage"],
                    cursorEpoch: row["cursorEpoch"],
                    trimScope: row["trimScope"]
                )
            }
        }
    }

    /// Mark a closed scope drained only after the consumer reached the frozen receipt frontier and no
    /// nonterminal analysis work remains. This is safe to call after every coordinator drain.
    @discardableResult
    public func finalizeDrainedHistoricalScopes(
        consumerId: String = "phase34.analysis",
        now: Date = Date()
    ) async throws -> Int {
        try syncWrite { db in
            let databaseId = try WhoopStore.databaseInstanceId(in: db)
            try db.execute(sql: """
                UPDATE historicalReceiptScopeLifecycle AS l
                SET state = 'drained', updatedAt = ?
                WHERE l.databaseInstanceId = ? AND l.state = 'draining'
                  AND COALESCE((
                    SELECT c.throughGeneration
                    FROM historicalReceiptConsumer AS c
                    WHERE c.consumerId = ?
                      AND c.databaseInstanceId = l.databaseInstanceId
                      AND c.deviceId = l.deviceId
                      AND c.lineage = l.lineage
                      AND c.cursorEpoch = l.cursorEpoch
                      AND c.trimScope = l.trimScope
                  ), 0) >= l.closedThroughGeneration
                  AND NOT EXISTS (
                    SELECT 1 FROM historicalAnalysisWork AS w
                    WHERE w.databaseInstanceId = l.databaseInstanceId
                      AND w.deviceId = l.deviceId
                      AND w.lineage = l.lineage
                      AND w.cursorEpoch = l.cursorEpoch
                      AND w.trimScope = l.trimScope
                      AND w.state NOT IN ('complete', 'quarantined')
                  )
                """, arguments: [
                    Int(now.timeIntervalSince1970), databaseId, consumerId,
                ])
            return db.changesCount
        }
    }
}

/*
Runtime integration:

1. Current non-archived registry scopes remain ordinary admission contexts.
2. Append `drainingHistoricalReceiptScopes()` even when the registry has no active source.
3. After coordinator drain, call `finalizeDrainedHistoricalScopes()`.
4. Physical replacement/archive calls `closeHistoricalScopeForDrain` in the same transaction as the
   registry mutation. It does NOT advance the consumer or quarantine work.
5. Privacy deletion calls `discardHistoricalScope` and deletes receipts/work/raw data transactionally.
6. The atomic raw-row/cursor/receipt commit calls `assertHistoricalScopeAcceptingIngest` before writing.
7. The removed retirement/quarantine helper is not an archive or re-pair path. Durable close-and-drain
   lifecycle is the only such path after this migration.
*/
