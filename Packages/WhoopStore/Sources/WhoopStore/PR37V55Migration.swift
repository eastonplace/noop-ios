import Foundation
import GRDB
import WhoopProtocol

/// Replaces V54's duplicate exact-frame table with one verified compressed raw archive plus indexes.
/// GRDB runs each migration in a transaction: any missing evidence, decode error, or byte mismatch throws,
/// leaving the complete V54 schema and data unchanged.
public enum PR37V55Migrations {
    public static let identifier = "v55-pr37-historical-raw-lifecycle-repair"

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            let wallNow = Int(Date().timeIntervalSince1970)
            let jobs = try Row.fetchAll(db, sql: """
                SELECT job.*, receipt.databaseInstanceId, receipt.trimScope, receipt.committedAt
                FROM historicalMaterializationJob AS job
                JOIN historicalDataCommitJournal AS receipt ON receipt.receiptId = job.receiptId
                ORDER BY job.createdAt, job.receiptId
                """)

            try createReplacementTables(in: db)

            for job in jobs {
                try migrate(job: job, wallNow: wallNow, in: db)
            }

            try verifyReplacement(in: db)

            // Authorized destructive edge: it runs only after every archive and mapping above verified.
            // Any failure here or later rolls the entire migration back, restoring the V54 tables.
            try db.execute(sql: "DROP TABLE historicalMappedRawFrame")
            try db.execute(sql: "DROP TABLE historicalMaterializationJob")
            try db.execute(sql: "ALTER TABLE historicalMaterializationJob_v55 RENAME TO historicalMaterializationJob")
            try db.execute(sql: "ALTER TABLE historicalMappedRawFrame_v55 RENAME TO historicalMappedRawFrame")
            try createIndexes(in: db)

            guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty,
                  try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else {
                throw PR37V55MigrationError.verificationFailed
            }
        }
    }

    private static func createReplacementTables(in db: Database) throws {
        try db.execute(sql: """
            CREATE TABLE historicalMaterializationJob_v55 (
                receiptId TEXT PRIMARY KEY NOT NULL
                    REFERENCES historicalDataCommitJournal(receiptId) ON DELETE CASCADE,
                databaseInstanceId TEXT NOT NULL,
                rawBatchId TEXT NOT NULL,
                deviceId TEXT NOT NULL,
                lineage TEXT NOT NULL,
                cursorEpoch INTEGER NOT NULL,
                trimScope TEXT NOT NULL,
                selectionMode TEXT NOT NULL CHECK (
                    selectionMode IN ('selectiveMapped', 'legacyFullCapture')
                ),
                state TEXT NOT NULL CHECK (
                    state IN ('pending', 'running', 'retryable', 'completed', 'quarantined')
                ),
                originalFrameIndexesJSON BLOB NOT NULL,
                protectedByteCount INTEGER NOT NULL CHECK (protectedByteCount >= 0),
                mappedRawMinTs INTEGER,
                mappedRawMaxTs INTEGER,
                attemptCount INTEGER NOT NULL DEFAULT 0 CHECK (attemptCount >= 0),
                nextAttemptAt INTEGER,
                leaseOwner TEXT,
                leaseExpiresAt INTEGER,
                lastErrorCode TEXT,
                lastError TEXT,
                createdAt INTEGER NOT NULL,
                updatedAt INTEGER NOT NULL,
                completedAt INTEGER,
                evictedAt INTEGER,
                CHECK ((leaseOwner IS NULL) = (leaseExpiresAt IS NULL)),
                CHECK (mappedRawMinTs IS NULL OR mappedRawMaxTs IS NULL
                    OR mappedRawMinTs <= mappedRawMaxTs)
            )
            """)
        try db.execute(sql: """
            CREATE TABLE historicalMappedRawFrame_v55 (
                receiptId TEXT NOT NULL
                    REFERENCES historicalDataCommitJournal(receiptId) ON DELETE CASCADE,
                databaseInstanceId TEXT NOT NULL,
                rawBatchId TEXT NOT NULL,
                deviceId TEXT NOT NULL,
                lineage TEXT NOT NULL,
                cursorEpoch INTEGER NOT NULL,
                trimScope TEXT NOT NULL,
                originalFrameIndex INTEGER NOT NULL CHECK (originalFrameIndex >= 0),
                rawFrameOffset INTEGER NOT NULL CHECK (rawFrameOffset >= 0),
                version INTEGER NOT NULL CHECK (version IN (20, 21)),
                unix INTEGER NOT NULL,
                exactByteCount INTEGER NOT NULL CHECK (exactByteCount >= 0),
                materializedAt INTEGER NOT NULL,
                PRIMARY KEY (receiptId, originalFrameIndex)
            )
            """)
    }

    private static func createIndexes(in db: Database) throws {
        try db.execute(sql: """
            CREATE INDEX idx_historicalMaterializationJob_claim
            ON historicalMaterializationJob
                (state, nextAttemptAt, leaseExpiresAt, createdAt, receiptId)
            """)
        try db.execute(sql: """
            CREATE INDEX idx_historicalMaterializationJob_raw_identity
            ON historicalMaterializationJob (rawBatchId, deviceId, lineage, cursorEpoch)
            """)
        try db.execute(sql: """
            CREATE INDEX idx_historicalMaterializationJob_frontier
            ON historicalMaterializationJob
                (databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, mappedRawMaxTs)
            """)
        try db.execute(sql: """
            CREATE INDEX idx_historicalMaterializationJob_completed_retention
            ON historicalMaterializationJob (state, evictedAt, completedAt, receiptId)
            """)
        try db.execute(sql: """
            CREATE INDEX idx_historicalMappedRawFrame_source_frontier
            ON historicalMappedRawFrame
                (databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope, unix, receiptId)
            """)
    }

    private static func migrate(job: Row, wallNow: Int, in db: Database) throws {
        let receiptId: String = job["receiptId"]
        let rawBatchId: String = job["rawBatchId"]
        let deviceId: String = job["deviceId"]
        let lineage: String = job["lineage"]
        let cursorEpoch: Int = job["cursorEpoch"]
        let databaseInstanceId: String = job["databaseInstanceId"]
        let trimScope: String = job["trimScope"]
        let oldState: String = job["state"]
        let oldIndexData: Data = job["originalFrameIndexesJSON"]
        guard let oldIndexes = try? JSONDecoder().decode([Int].self, from: oldIndexData),
              !oldIndexes.isEmpty,
              Set(oldIndexes).count == oldIndexes.count,
              oldIndexes.allSatisfy({ $0 >= 0 }),
              zip(oldIndexes, oldIndexes.dropFirst()).allSatisfy(<) else {
            throw PR37V55MigrationError.invalidIndexes(receiptId)
        }

        let exactRows = try Row.fetchAll(db, sql: """
            SELECT originalFrameIndex, version, unix, exactFrame, frameByteCount, materializedAt
            FROM historicalMappedRawFrame
            WHERE receiptId = ?
            ORDER BY originalFrameIndex
            """, arguments: [receiptId])

        var archiveFrames = try existingArchiveFrames(
            batchId: rawBatchId,
            deviceId: deviceId,
            lineage: lineage,
            cursorEpoch: cursorEpoch,
            in: db
        )
        var indexes = oldIndexes

        if archiveFrames == nil {
            guard oldState == HistoricalMaterializationJobState.completed.rawValue,
                  !exactRows.isEmpty else {
                throw PR37V55MigrationError.missingExactArchive(receiptId)
            }
            let reconstructedIndexes = exactRows.map { $0["originalFrameIndex"] as Int }
            guard reconstructedIndexes.allSatisfy(oldIndexes.contains) else {
                throw PR37V55MigrationError.archiveIndexMismatch(receiptId)
            }
            // A legacy full-chunk archive may already have been pruned after V54 completed. In that
            // case V54's exact rows are the complete surviving mapped representation. Reconstruct a
            // selective compressed archive from those verified rows and retain their original indexes.
            indexes = reconstructedIndexes
            let reconstructedFrames = exactRows.map { [UInt8]($0["exactFrame"] as Data) }
            try insertReconstructedArchive(
                frames: reconstructedFrames,
                job: job,
                rawBatchId: rawBatchId,
                deviceId: deviceId,
                lineage: lineage,
                cursorEpoch: cursorEpoch,
                exactRows: exactRows,
                in: db
            )
            // Verify the bytes actually persisted in rawBatch, not only the in-memory compressed blob.
            archiveFrames = try existingArchiveFrames(
                batchId: rawBatchId,
                deviceId: deviceId,
                lineage: lineage,
                cursorEpoch: cursorEpoch,
                in: db
            )
        }

        guard let frames = archiveFrames, frames.count == indexes.count else {
            throw PR37V55MigrationError.archiveIndexMismatch(receiptId)
        }

        let mapped = try mappedFrames(frames: frames, indexes: indexes, wallNow: wallNow)
        if oldState == HistoricalMaterializationJobState.completed.rawValue {
            let exactIndexes = exactRows.map { $0["originalFrameIndex"] as Int }
            guard !exactRows.isEmpty,
                  exactIndexes == mapped.map(\.originalIndex) else {
                throw PR37V55MigrationError.missingCompletedFrames(receiptId)
            }
        }
        // A V54 crash could leave a partial mapping while the job is still running. Every row that
        // exists is evidence we are about to delete, so verify it regardless of the job's state.
        if !exactRows.isEmpty {
            try verifyExactRows(exactRows, against: frames, indexes: indexes, receiptId: receiptId)
        }

        let selectionMode = mapped.count == frames.count ? "selectiveMapped" : "legacyFullCapture"
        let trusted = mapped.compactMap { frame -> Int? in
            trustedProgress(frame: frame.bytes, version: frame.version, unix: frame.unix, wallNow: wallNow)
                ? frame.unix : nil
        }
        let state = oldState == HistoricalMaterializationJobState.running.rawValue
            ? HistoricalMaterializationJobState.retryable.rawValue : oldState
        let nextAttemptAt: Int? = state == HistoricalMaterializationJobState.retryable.rawValue
            ? wallNow : nil
        let indexData = try JSONEncoder().encode(indexes)
        let protectedBytes = frames.reduce(0) { $0 + $1.count }

        try db.execute(sql: """
            INSERT INTO historicalMaterializationJob_v55
                (receiptId, databaseInstanceId, rawBatchId, deviceId, lineage, cursorEpoch,
                 trimScope, selectionMode, state, originalFrameIndexesJSON, protectedByteCount,
                 mappedRawMinTs, mappedRawMaxTs, attemptCount, nextAttemptAt, leaseOwner,
                 leaseExpiresAt, lastErrorCode, lastError, createdAt, updatedAt, completedAt, evictedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL, NULL, NULL, ?, ?, ?, ?, NULL)
            """, arguments: [
                receiptId, databaseInstanceId, rawBatchId, deviceId, lineage, cursorEpoch,
                trimScope, selectionMode, state, indexData, protectedBytes,
                trusted.min(), trusted.max(), job["attemptCount"], nextAttemptAt,
                job["lastError"], job["createdAt"], job["updatedAt"], job["completedAt"],
            ])

        for exact in exactRows {
            let originalIndex: Int = exact["originalFrameIndex"]
            guard let offset = indexes.firstIndex(of: originalIndex) else {
                throw PR37V55MigrationError.archiveIndexMismatch(receiptId)
            }
            let data: Data = exact["exactFrame"]
            try db.execute(sql: """
                INSERT INTO historicalMappedRawFrame_v55
                    (receiptId, databaseInstanceId, rawBatchId, deviceId, lineage, cursorEpoch,
                     trimScope, originalFrameIndex, rawFrameOffset, version, unix,
                     exactByteCount, materializedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    receiptId, databaseInstanceId, rawBatchId, deviceId, lineage, cursorEpoch,
                    trimScope, originalIndex, offset, exact["version"], exact["unix"],
                    data.count, exact["materializedAt"],
                ])
        }
    }

    private static func existingArchiveFrames(
        batchId: String,
        deviceId: String,
        lineage: String,
        cursorEpoch: Int,
        in db: Database
    ) throws -> [[UInt8]]? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT frameCount, byteSize, framesBlob FROM rawBatch
            WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = ?
            """, arguments: [batchId, deviceId, lineage, cursorEpoch]) else { return nil }
        let frameCount: Int = row["frameCount"]
        let byteSize: Int = row["byteSize"]
        let blob: Data = row["framesBlob"]
        let expectedLength = try WhoopStore.expectedPackedFrameLength(
            frameCount: frameCount,
            byteSize: byteSize
        )
        let packed = try WhoopStore.zlibDecompressWithLengthStrict(
            blob,
            expectedUncompressedLength: expectedLength
        )
        return try WhoopStore.unpackFramesStrict(
            packed,
            expectedFrameCount: frameCount,
            expectedFrameBytes: byteSize
        )
    }

    private static func insertReconstructedArchive(
        frames: [[UInt8]],
        job: Row,
        rawBatchId: String,
        deviceId: String,
        lineage: String,
        cursorEpoch: Int,
        exactRows: [Row],
        in db: Database
    ) throws {
        let packed = WhoopStore.packFrames(frames)
        let blob = try WhoopStore.zlibCompressWithLength(packed)
        let decoded = try WhoopStore.zlibDecompressWithLengthStrict(
            blob,
            expectedUncompressedLength: packed.count
        )
        let verified = try WhoopStore.unpackFramesStrict(
            decoded,
            expectedFrameCount: frames.count,
            expectedFrameBytes: frames.reduce(0) { $0 + $1.count }
        )
        guard verified == frames else {
            throw PR37V55MigrationError.byteMismatch(job["receiptId"])
        }
        let timestamps = exactRows.map { $0["unix"] as Int }
        let capturedAt: Int = job["completedAt"] ?? job["committedAt"]
        try db.execute(sql: """
            INSERT INTO rawBatch
                (batchId, deviceId, lineage, cursorEpoch, capturedAt, deviceClockRef,
                 wallClockRef, startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """, arguments: [
                rawBatchId, deviceId, lineage, cursorEpoch, capturedAt,
                timestamps.min()!, timestamps.min()!, timestamps.min()!, timestamps.max()!,
                frames.count, frames.reduce(0) { $0 + $1.count }, blob,
            ])
    }

    private static func verifyExactRows(
        _ rows: [Row],
        against frames: [[UInt8]],
        indexes: [Int],
        receiptId: String
    ) throws {
        for row in rows {
            let originalIndex: Int = row["originalFrameIndex"]
            let expected: Data = row["exactFrame"]
            guard let offset = indexes.firstIndex(of: originalIndex),
                  Data(frames[offset]) == expected,
                  expected.count == (row["frameByteCount"] as Int) else {
                throw PR37V55MigrationError.byteMismatch(receiptId)
            }
            let parsed = parseFrame(frames[offset], family: .whoop5)
            guard parsed.ok, parsed.envelopeOK,
                  parsed.headerCRCOK == true, parsed.payloadCRCOK == true,
                  parsed.parsed["hist_version"]?.intValue == (row["version"] as Int),
                  parsed.parsed["unix"]?.intValue == (row["unix"] as Int) else {
                throw PR37V55MigrationError.byteMismatch(receiptId)
            }
        }
    }

    private struct MappedFrame {
        let originalIndex: Int
        let bytes: [UInt8]
        let version: Int
        let unix: Int
    }

    private static func mappedFrames(
        frames: [[UInt8]],
        indexes: [Int],
        wallNow: Int
    ) throws -> [MappedFrame] {
        try zip(indexes, frames).compactMap { originalIndex, frame in
            let parsed = parseFrame(frame, family: .whoop5)
            guard parsed.ok, parsed.envelopeOK,
                  parsed.headerCRCOK == true, parsed.payloadCRCOK == true else {
                throw PR37V55MigrationError.invalidEnvelope
            }
            guard case .mappedRaw(let version) = historicalRecordDisposition(
                parsed: parsed,
                rawFrame: frame,
                family: .whoop5
            ) else { return nil }
            guard let unix = parsed.parsed["unix"]?.intValue else {
                throw PR37V55MigrationError.invalidEnvelope
            }
            return MappedFrame(
                originalIndex: originalIndex,
                bytes: frame,
                version: version,
                unix: unix
            )
        }
    }

    private static func trustedProgress(
        frame: [UInt8],
        version: Int,
        unix: Int,
        wallNow: Int
    ) -> Bool {
        guard isPlausibleHistoricalUnix(unix, wallNow: wallNow) else { return false }
        guard version == 20 else { return version == 21 }
        let parsed = parseFrame(frame, family: .whoop5)
        return parsed.parsed.contains { key, value in
            key.hasPrefix("channel_b")
                && !key.contains("sample_count")
                && value.intArrayValue?.contains(where: { $0 != 0 }) == true
        }
    }

    private static func verifyReplacement(in db: Database) throws {
        let oldJobs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historicalMaterializationJob") ?? -1
        let newJobs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historicalMaterializationJob_v55") ?? -2
        let oldFrames = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historicalMappedRawFrame") ?? -1
        let newFrames = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historicalMappedRawFrame_v55") ?? -2
        guard oldJobs == newJobs, oldFrames == newFrames else {
            throw PR37V55MigrationError.verificationFailed
        }
    }
}

public enum PR37V55MigrationError: Error, Equatable, Sendable {
    case invalidIndexes(String)
    case missingExactArchive(String)
    case missingCompletedFrames(String)
    case archiveIndexMismatch(String)
    case byteMismatch(String)
    case invalidEnvelope
    case verificationFailed
}
