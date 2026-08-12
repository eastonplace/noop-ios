import Foundation
import GRDB

extension WhoopStore {
    public func setCursor(_ name: String, _ value: Int) async throws {
        try syncWrite { db in
            try WhoopStore.setCursor(name, value, in: db)
        }
    }

    static func setCursor(_ name: String, _ value: Int, in db: Database) throws {
        try db.execute(sql: """
            INSERT INTO cursors (name, value) VALUES (?, ?)
            ON CONFLICT(name) DO UPDATE SET value = excluded.value
            """, arguments: [name, value])
    }

    public func cursor(_ name: String) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: "SELECT value FROM cursors WHERE name = ?", arguments: [name])
        }
    }

    /// Store the trim frontier for one historical cursor scope.
    ///
    /// Historical trim state is not a single database-wide value. A physical strap can be replaced,
    /// re-paired, or read through more than one source while the old rows remain in SQLite. The scope
    /// keeps those frontiers independent and records the journal generation that made the frontier safe.
    public func setCursor(_ scope: HistoricalCursorScope, _ value: Int,
                          watermarkGeneration: Int64 = 0) async throws {
        try syncWrite { db in
            try WhoopStore.setHistoricalCursor(scope, value: value,
                                               watermarkGeneration: watermarkGeneration, in: db)
        }
    }

    /// Read the trim frontier for one historical cursor scope.
    public func cursor(_ scope: HistoricalCursorScope) async throws -> Int? {
        try syncRead { db in
            try Int.fetchOne(db, sql: """
                SELECT trim
                FROM historicalCursor
                WHERE deviceId = ? AND lineage = ? AND cursorEpoch = ? AND trimScope = ?
                """, arguments: [scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope])
        }
    }

    /// The journal generation associated with a historical cursor scope.
    public func historicalCursorWatermark(_ scope: HistoricalCursorScope) async throws -> Int64? {
        try syncRead { db in
            try Int64.fetchOne(db, sql: """
                SELECT watermarkGeneration
                FROM historicalCursor
                WHERE deviceId = ? AND lineage = ? AND cursorEpoch = ? AND trimScope = ?
                """, arguments: [scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope])
        }
    }

    /// Resolve the durable history scope for a registered device. Unregistered test/import sources use a
    /// stable device-derived lineage and epoch zero, so they still avoid the old global `strap_trim` key.
    public func historicalCursorScope(
        deviceId: String,
        trimScope: String = HistoricalCursorScope.defaultTrimScope
    ) async throws -> HistoricalCursorScope {
        try syncRead { db in
            try WhoopStore.historicalCursorScope(deviceId: deviceId, trimScope: trimScope, in: db)
        }
    }

    static func setHistoricalCursor(
        _ scope: HistoricalCursorScope,
        value: Int,
        watermarkGeneration: Int64,
        in db: Database
    ) throws {
        try db.execute(sql: """
            INSERT INTO historicalCursor
                (deviceId, lineage, cursorEpoch, trimScope, trim, watermarkGeneration)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(deviceId, lineage, cursorEpoch, trimScope) DO UPDATE SET
                -- The trim and journal generation describe one durable receipt edge. Updating them
                -- independently can manufacture a pair that never existed after an out-of-order replay.
                trim = CASE
                    WHEN excluded.watermarkGeneration >= historicalCursor.watermarkGeneration
                        THEN excluded.trim
                    ELSE historicalCursor.trim
                END,
                watermarkGeneration = MAX(historicalCursor.watermarkGeneration, excluded.watermarkGeneration)
            """, arguments: [
                scope.deviceId, scope.lineage, scope.cursorEpoch, scope.trimScope,
                value, watermarkGeneration,
            ])
    }

    public func setHighwater(_ stream: String, _ ts: Int) async throws { try await setCursor("highwater:" + stream, ts) }
    public func highwater(_ stream: String) async throws -> Int? { try await cursor("highwater:" + stream) }

    // MARK: - Read highwater (server-pull cursor)
    // A DISTINCT "read:" prefix so the pull cursor never collides with the upload "highwater:"
    // cursor for the same stream. Tracks the max server ts pulled-and-upserted per stream so
    // pulls are incremental.
    public func setReadHighwater(_ stream: String, _ ts: Int) async throws { try await setCursor("read:" + stream, ts) }
    public func readHighwater(_ stream: String) async throws -> Int? { try await cursor("read:" + stream) }
}
