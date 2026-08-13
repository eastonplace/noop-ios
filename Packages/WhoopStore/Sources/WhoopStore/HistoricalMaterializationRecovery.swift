import Foundation
import GRDB

/// User-recoverable evidence for deterministic historical materialization failures.
/// `archiveByteCount` is the exact uncompressed frame-byte count; `storedByteCount` is the
/// compressed SQLite BLOB size. The mapped count is the only value charged to the mandatory ceiling.
public struct HistoricalQuarantinedJob: Codable, Equatable, Identifiable, Sendable {
    public var id: String { receiptId }
    public let receiptId: String
    public let rawBatchId: String
    public let deviceId: String
    public let lineage: String
    public let cursorEpoch: Int
    public let protectedMappedByteCount: Int
    public let archiveByteCount: Int
    public let storedByteCount: Int
    public let lastErrorCode: String?
    public let updatedAt: Int

    public init(
        receiptId: String,
        rawBatchId: String,
        deviceId: String,
        lineage: String,
        cursorEpoch: Int,
        protectedMappedByteCount: Int,
        archiveByteCount: Int,
        storedByteCount: Int,
        lastErrorCode: String?,
        updatedAt: Int
    ) {
        self.receiptId = receiptId
        self.rawBatchId = rawBatchId
        self.deviceId = deviceId
        self.lineage = lineage
        self.cursorEpoch = cursorEpoch
        self.protectedMappedByteCount = protectedMappedByteCount
        self.archiveByteCount = archiveByteCount
        self.storedByteCount = storedByteCount
        self.lastErrorCode = lastErrorCode
        self.updatedAt = updatedAt
    }
}

public struct HistoricalQuarantineSummary: Equatable, Sendable {
    public let jobCount: Int
    public let protectedMappedByteCount: Int
    public let archiveByteCount: Int
    public let storedByteCount: Int

    public init(
        jobCount: Int = 0,
        protectedMappedByteCount: Int = 0,
        archiveByteCount: Int = 0,
        storedByteCount: Int = 0
    ) {
        self.jobCount = jobCount
        self.protectedMappedByteCount = protectedMappedByteCount
        self.archiveByteCount = archiveByteCount
        self.storedByteCount = storedByteCount
    }
}

/// A diagnostic export preserves the compressed SQLite representation byte-for-byte, including a
/// deterministically corrupt archive that the worker could not decode.
public struct HistoricalQuarantinedArchive: Equatable, Sendable {
    public let job: HistoricalQuarantinedJob
    public let compressedArchive: Data
}

private enum HistoricalMaterializationRecoveryError: Error {
    case concurrentMutation
}

extension WhoopStore {
    public func historicalQuarantineSummary() async throws -> HistoricalQuarantineSummary {
        try syncRead { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT COUNT(*) AS jobCount,
                       COALESCE(SUM(job.protectedByteCount), 0) AS protectedMappedByteCount,
                       COALESCE(SUM(raw.byteSize), 0) AS archiveByteCount,
                       COALESCE(SUM(LENGTH(raw.framesBlob)), 0) AS storedByteCount
                FROM historicalMaterializationJob AS job
                LEFT JOIN rawBatch AS raw
                  ON raw.batchId = job.rawBatchId
                 AND raw.deviceId = job.deviceId
                 AND raw.lineage = job.lineage
                 AND raw.cursorEpoch = job.cursorEpoch
                WHERE job.state = 'quarantined'
                """)
            return HistoricalQuarantineSummary(
                jobCount: row?["jobCount"] ?? 0,
                protectedMappedByteCount: row?["protectedMappedByteCount"] ?? 0,
                archiveByteCount: row?["archiveByteCount"] ?? 0,
                storedByteCount: row?["storedByteCount"] ?? 0
            )
        }
    }

    public func historicalQuarantinedJobs(limit: Int = 50) async throws -> [HistoricalQuarantinedJob] {
        guard limit > 0 else { return [] }
        return try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT job.receiptId, job.rawBatchId, job.deviceId, job.lineage,
                       job.cursorEpoch, job.protectedByteCount,
                       COALESCE(raw.byteSize, 0) AS archiveByteCount,
                       COALESCE(LENGTH(raw.framesBlob), 0) AS storedByteCount,
                       job.lastErrorCode, job.updatedAt
                FROM historicalMaterializationJob AS job
                LEFT JOIN rawBatch AS raw
                  ON raw.batchId = job.rawBatchId
                 AND raw.deviceId = job.deviceId
                 AND raw.lineage = job.lineage
                 AND raw.cursorEpoch = job.cursorEpoch
                WHERE job.state = 'quarantined'
                ORDER BY job.updatedAt DESC, job.receiptId DESC
                LIMIT ?
                """, arguments: [limit]).map(Self.historicalQuarantinedJob)
        }
    }

    public func historicalQuarantinedArchive(receiptId: String) async throws -> HistoricalQuarantinedArchive? {
        try syncRead { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT job.receiptId, job.rawBatchId, job.deviceId, job.lineage,
                       job.cursorEpoch, job.protectedByteCount,
                       raw.byteSize AS archiveByteCount, LENGTH(raw.framesBlob) AS storedByteCount,
                       job.lastErrorCode, job.updatedAt, raw.framesBlob
                FROM historicalMaterializationJob AS job
                JOIN rawBatch AS raw
                  ON raw.batchId = job.rawBatchId
                 AND raw.deviceId = job.deviceId
                 AND raw.lineage = job.lineage
                 AND raw.cursorEpoch = job.cursorEpoch
                WHERE job.receiptId = ? AND job.state = 'quarantined'
                """, arguments: [receiptId]) else { return nil }
            let blob: Data = row["framesBlob"]
            return HistoricalQuarantinedArchive(
                job: Self.historicalQuarantinedJob(row),
                compressedArchive: blob
            )
        }
    }

    /// Explicitly make a quarantined job due after a decoder or migration repair. Attempts restart
    /// because the prior deterministic decoder version, not the archive, consumed those attempts.
    @discardableResult
    public func retryQuarantinedHistoricalMaterialization(
        receiptId: String,
        now: Int = Int(Date().timeIntervalSince1970)
    ) async throws -> Bool {
        try syncWrite { db in
            try db.execute(sql: """
                UPDATE historicalMaterializationJob
                SET state = 'pending', attemptCount = 0, nextAttemptAt = NULL,
                    leaseOwner = NULL, leaseExpiresAt = NULL,
                    lastErrorCode = NULL, lastError = NULL, updatedAt = ?
                WHERE receiptId = ? AND state = 'quarantined'
                """, arguments: [now, receiptId])
            return db.changesCount == 1
        }
    }

    /// Explicit destructive recovery. The receipt stays as the ACK/fingerprint audit record, but is
    /// changed to `unavailable` raw evidence before the only local archive and its failed job are removed.
    /// Callers must require a separate user confirmation before invoking this API.
    @discardableResult
    public func discardQuarantinedHistoricalArchive(
        receiptId: String
    ) async throws -> Bool {
        try syncWrite { db in
            guard let job = try Row.fetchOne(db, sql: """
                SELECT rawBatchId, deviceId, lineage, cursorEpoch
                FROM historicalMaterializationJob
                WHERE receiptId = ? AND state = 'quarantined'
                """, arguments: [receiptId]) else { return false }

            let previousRangeData: Data? = try Data.fetchOne(
                db,
                sql: "SELECT rawRangeJSON FROM historicalDataCommitJournal WHERE receiptId = ?",
                arguments: [receiptId]
            )
            let previousRange = previousRangeData.flatMap {
                try? JSONDecoder().decode(HistoricalRawRangeEvidence.self, from: $0)
            }
            let remainingEvidence = HistoricalRawRangeEvidence(
                source: .receivedFrames,
                minReceivedTs: previousRange?.minReceivedTs,
                maxReceivedTs: previousRange?.maxReceivedTs,
                frameCount: previousRange?.frameCount ?? 0,
                byteCount: previousRange?.byteCount ?? 0,
                hasHistoryEnd: previousRange?.hasHistoryEnd ?? true
            )
            let rangeData = try JSONEncoder().encode(remainingEvidence)
            try db.execute(sql: """
                UPDATE historicalDataCommitJournal
                SET rawBatchId = NULL, rawStatus = 'unavailable', rawRangeJSON = ?
                WHERE receiptId = ? AND rawStatus = 'materializationRequired'
                """, arguments: [rangeData, receiptId])
            guard db.changesCount == 1 else {
                throw HistoricalMaterializationRecoveryError.concurrentMutation
            }

            try db.execute(
                sql: "DELETE FROM historicalMappedRawFrame WHERE receiptId = ?",
                arguments: [receiptId]
            )
            try db.execute(
                sql: "DELETE FROM historicalMaterializationJob WHERE receiptId = ? AND state = 'quarantined'",
                arguments: [receiptId]
            )
            guard db.changesCount == 1 else {
                throw HistoricalMaterializationRecoveryError.concurrentMutation
            }

            let batchId: String = job["rawBatchId"]
            let deviceId: String = job["deviceId"]
            let lineage: String = job["lineage"]
            let cursorEpoch: Int = job["cursorEpoch"]
            try db.execute(sql: """
                DELETE FROM rawBatch
                WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = ?
                  AND NOT EXISTS (
                      SELECT 1 FROM historicalDataCommitJournal
                      WHERE rawBatchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = ?
                  )
                """, arguments: [
                    batchId, deviceId, lineage, cursorEpoch,
                    batchId, deviceId, lineage, cursorEpoch,
                ])
            return true
        }
    }

    private static func historicalQuarantinedJob(_ row: Row) -> HistoricalQuarantinedJob {
        HistoricalQuarantinedJob(
            receiptId: row["receiptId"],
            rawBatchId: row["rawBatchId"],
            deviceId: row["deviceId"],
            lineage: row["lineage"],
            cursorEpoch: row["cursorEpoch"],
            protectedMappedByteCount: row["protectedByteCount"],
            archiveByteCount: row["archiveByteCount"],
            storedByteCount: row["storedByteCount"],
            lastErrorCode: row["lastErrorCode"],
            updatedAt: row["updatedAt"]
        )
    }
}
