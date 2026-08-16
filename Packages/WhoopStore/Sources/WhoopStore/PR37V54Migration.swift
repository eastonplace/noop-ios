import Foundation
import GRDB

/// Durable deferred-materialization state for mapped WHOOP 5 V20/V21 history.
/// V53 remains immutable; this additive migration owns the next schema version.
public enum PR37V54Migrations {
    public static let identifier = "v54-pr37-historical-raw-materialization"

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            try db.execute(sql: """
                CREATE TABLE historicalMaterializationJob (
                    receiptId TEXT PRIMARY KEY NOT NULL
                        REFERENCES historicalDataCommitJournal(receiptId) ON DELETE CASCADE,
                    rawBatchId TEXT NOT NULL,
                    deviceId TEXT NOT NULL,
                    lineage TEXT NOT NULL,
                    cursorEpoch INTEGER NOT NULL,
                    state TEXT NOT NULL CHECK (
                        state IN ('pending', 'running', 'retryable', 'completed', 'quarantined')
                    ),
                    originalFrameIndexesJSON BLOB NOT NULL,
                    protectedByteCount INTEGER NOT NULL CHECK (protectedByteCount >= 0),
                    attemptCount INTEGER NOT NULL DEFAULT 0 CHECK (attemptCount >= 0),
                    leaseOwner TEXT,
                    leaseExpiresAt INTEGER,
                    lastError TEXT,
                    createdAt INTEGER NOT NULL,
                    updatedAt INTEGER NOT NULL,
                    completedAt INTEGER
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_historicalMaterializationJob_claim
                ON historicalMaterializationJob (state, leaseExpiresAt, createdAt)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_historicalMaterializationJob_raw_identity
                ON historicalMaterializationJob (rawBatchId, deviceId, lineage, cursorEpoch)
                """)

            // The materialized record keeps the exact WHOOP frame, but moves it out of the transient
            // raw outbox and gives it durable version/timestamp/index identity. V20 therefore retains
            // the complete 200-byte channel slots, transport envelope, and unused capacity.
            try db.execute(sql: """
                CREATE TABLE historicalMappedRawFrame (
                    receiptId TEXT NOT NULL
                        REFERENCES historicalDataCommitJournal(receiptId) ON DELETE CASCADE,
                    originalFrameIndex INTEGER NOT NULL CHECK (originalFrameIndex >= 0),
                    version INTEGER NOT NULL CHECK (version IN (20, 21)),
                    unix INTEGER NOT NULL,
                    exactFrame BLOB NOT NULL,
                    frameByteCount INTEGER NOT NULL CHECK (frameByteCount >= 0),
                    materializedAt INTEGER NOT NULL,
                    PRIMARY KEY (receiptId, originalFrameIndex)
                )
                """)
            try db.execute(sql: """
                CREATE INDEX idx_historicalMappedRawFrame_unix
                ON historicalMappedRawFrame (unix, receiptId)
                """)

            // Backfill any protected batches written by an earlier PR #37 build. Those builds retained
            // the complete chunk, so their only recoverable index mapping is the contiguous frame order.
            let legacyRows = try Row.fetchAll(db, sql: """
                SELECT receipt.receiptId, receipt.rawBatchId, receipt.deviceId, receipt.lineage,
                       receipt.cursorEpoch, receipt.committedAt, raw.frameCount, raw.byteSize
                FROM historicalDataCommitJournal AS receipt
                JOIN rawBatch AS raw
                  ON raw.batchId = receipt.rawBatchId
                 AND raw.deviceId = receipt.deviceId
                 AND raw.lineage = receipt.lineage
                 AND raw.cursorEpoch = receipt.cursorEpoch
                WHERE receipt.rawStatus = 'materializationRequired'
                """)
            for row in legacyRows {
                let frameCount: Int = row["frameCount"]
                let indexes = try JSONEncoder().encode(Array(0..<max(0, frameCount)))
                let committedAt: Int = row["committedAt"]
                try db.execute(sql: """
                    INSERT INTO historicalMaterializationJob
                        (receiptId, rawBatchId, deviceId, lineage, cursorEpoch, state,
                         originalFrameIndexesJSON, protectedByteCount, attemptCount,
                         createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, ?, 'pending', ?, ?, 0, ?, ?)
                    """, arguments: [
                        row["receiptId"], row["rawBatchId"], row["deviceId"], row["lineage"],
                        row["cursorEpoch"], indexes, row["byteSize"], committedAt, committedAt,
                    ])
            }

            guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                throw PR37V54MigrationError.invalidSchema
            }
        }
    }
}

public enum PR37V54MigrationError: Error, Equatable, Sendable {
    case invalidSchema
}
