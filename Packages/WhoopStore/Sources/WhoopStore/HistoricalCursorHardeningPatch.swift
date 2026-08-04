// Replace WhoopStore.setHistoricalCursor in Packages/WhoopStore/Sources/WhoopStore/Cursors.swift.
// The old CASE/MAX upsert allowed an equal-generation write to change trim without proving idempotency.

import Foundation
import GRDB

public enum HistoricalCursorWriteError: Error, Equatable, Sendable {
    case invalidScope
    case invalidGeneration
    case generationRegression(existing: Int64, attempted: Int64)
    case equalGenerationConflict(generation: Int64, existingTrim: Int, attemptedTrim: Int)
    case concurrentMutation
}

extension WhoopStore {
    static func setHistoricalCursorV2(
        _ scope: HistoricalCursorScope,
        value: Int,
        watermarkGeneration: Int64,
        in db: Database
    ) throws {
        guard !scope.deviceId.isEmpty,
              !scope.lineage.isEmpty,
              scope.cursorEpoch >= 0,
              !scope.trimScope.isEmpty else {
            throw HistoricalCursorWriteError.invalidScope
        }
        guard watermarkGeneration > 0 else {
            throw HistoricalCursorWriteError.invalidGeneration
        }

        let row = try Row.fetchOne(db, sql: """
            SELECT trim, watermarkGeneration
            FROM historicalCursor
            WHERE deviceId = ? AND lineage = ? AND cursorEpoch = ? AND trimScope = ?
            """, arguments: [scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope])

        guard let row else {
            try db.execute(sql: """
                INSERT INTO historicalCursor
                    (deviceId, lineage, cursorEpoch, trimScope, trim, watermarkGeneration)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [
                    scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope,
                    value, watermarkGeneration,
                ])
            return
        }

        let existingTrim: Int = row["trim"]
        let existingGeneration: Int64 = row["watermarkGeneration"]
        if watermarkGeneration < existingGeneration {
            throw HistoricalCursorWriteError.generationRegression(
                existing: existingGeneration,
                attempted: watermarkGeneration
            )
        }
        if watermarkGeneration == existingGeneration {
            guard value == existingTrim else {
                throw HistoricalCursorWriteError.equalGenerationConflict(
                    generation: watermarkGeneration,
                    existingTrim: existingTrim,
                    attemptedTrim: value
                )
            }
            return // exact idempotent replay
        }

        try db.execute(sql: """
            UPDATE historicalCursor
            SET trim = ?, watermarkGeneration = ?
            WHERE deviceId = ? AND lineage = ? AND cursorEpoch = ? AND trimScope = ?
              AND watermarkGeneration = ?
            """, arguments: [
                value, watermarkGeneration,
                scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope,
                existingGeneration,
            ])
        guard db.changesCount == 1 else {
            throw HistoricalCursorWriteError.concurrentMutation
        }
    }
}

/*
Mechanical integration:

1. Rename this function to `setHistoricalCursor` and remove the old CASE/MAX implementation.
2. The historical commit transaction must call it only after inserting the receipt and must pass the
   inserted receipt generation. A replay that found an existing receipt returns before this call.
3. Add tests for exact replay, generation regression, equal-generation/different-trim conflict, and a newer
   generation update.
*/
