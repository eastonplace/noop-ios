import GRDB

/// Allow multiple immutable content receipts at one WHOOP trim while preserving every historical row.
public enum PR29V53Migrations {
    public static let identifier = "v53-pr29-historical-content-version-receipts"

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            guard try db.tableExists("historicalDataCommitJournal") else {
                throw PR29V53MigrationError.invalidSchema
            }
            let originalReceiptCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM historicalDataCommitJournal"
            ) ?? -1

            try db.execute(sql: """
                CREATE TABLE historicalDataCommitJournal_v53 (
                    generation INTEGER PRIMARY KEY AUTOINCREMENT,
                    receiptId TEXT NOT NULL UNIQUE,
                    databaseInstanceId TEXT NOT NULL,
                    deviceId TEXT NOT NULL,
                    lineage TEXT NOT NULL,
                    cursorEpoch INTEGER NOT NULL,
                    trimScope TEXT NOT NULL,
                    trim INTEGER NOT NULL,
                    chunkEndUnix INTEGER NOT NULL,
                    committedAt INTEGER NOT NULL,
                    fingerprint TEXT NOT NULL CHECK (length(trim(fingerprint)) > 0),
                    minDecodedTs INTEGER,
                    maxDecodedTs INTEGER,
                    touchedDaysJSON BLOB NOT NULL,
                    decodedRowsJSON BLOB NOT NULL,
                    insertedRowsJSON BLOB NOT NULL,
                    rawBatchId TEXT,
                    rawStatus TEXT NOT NULL,
                    burstJSON BLOB,
                    rawRangeJSON BLOB NOT NULL,
                    timestampHealJSON BLOB NOT NULL,
                    isFinal INTEGER NOT NULL DEFAULT 0,
                    fingerprintVersion INTEGER NOT NULL DEFAULT 1,
                    timestampBucketsJSON BLOB,
                    recordedTimeZoneIdentifier TEXT,
                    explicitAffectedDaysJSON BLOB
                )
                """)
            try db.execute(sql: """
                INSERT INTO historicalDataCommitJournal_v53
                    (generation, receiptId, databaseInstanceId, deviceId, lineage, cursorEpoch,
                     trimScope, trim, chunkEndUnix, committedAt, fingerprint, minDecodedTs,
                     maxDecodedTs, touchedDaysJSON, decodedRowsJSON, insertedRowsJSON, rawBatchId,
                     rawStatus, burstJSON, rawRangeJSON, timestampHealJSON, isFinal,
                     fingerprintVersion, timestampBucketsJSON, recordedTimeZoneIdentifier,
                     explicitAffectedDaysJSON)
                SELECT generation, receiptId, databaseInstanceId, deviceId, lineage, cursorEpoch,
                       trimScope, trim, chunkEndUnix, committedAt, fingerprint, minDecodedTs,
                       maxDecodedTs, touchedDaysJSON, decodedRowsJSON, insertedRowsJSON, rawBatchId,
                       rawStatus, burstJSON, rawRangeJSON, timestampHealJSON, isFinal,
                       fingerprintVersion, timestampBucketsJSON, recordedTimeZoneIdentifier,
                       explicitAffectedDaysJSON
                FROM historicalDataCommitJournal
                ORDER BY generation
                """)
            try db.execute(sql: "DROP TABLE historicalDataCommitJournal")
            try db.execute(sql: "ALTER TABLE historicalDataCommitJournal_v53 RENAME TO historicalDataCommitJournal")
            try db.execute(sql: """
                CREATE UNIQUE INDEX idx_historicalDataCommitJournal_content_identity_v53
                ON historicalDataCommitJournal
                    (databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, trim,
                     fingerprintVersion, fingerprint)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_historicalDataCommitJournal_scope_generation
                ON historicalDataCommitJournal
                    (databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, generation)
                """)
            try db.execute(sql: """
                CREATE INDEX idx_historicalDataCommitJournal_scope_generation_v40
                ON historicalDataCommitJournal
                    (databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, generation)
                """)

            let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historicalDataCommitJournal") ?? -1
            let duplicateCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM (
                    SELECT 1
                    FROM historicalDataCommitJournal
                    GROUP BY databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, trim,
                             fingerprintVersion, fingerprint
                    HAVING COUNT(*) > 1
                )
                """) ?? -1
            guard sourceCount == originalReceiptCount,
                  duplicateCount == 0,
                  try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                throw PR29V53MigrationError.invalidSchema
            }
        }
    }
}

public enum PR29V53MigrationError: Error, Equatable, Sendable {
    case invalidSchema
}
