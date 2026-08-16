import Foundation
import GRDB
import WhoopProtocol

/// Repairs V55-derived mapped progress and protected-byte accounting without rewriting V55.
/// Every job is repaired against its receipt-time evidence in one GRDB migration transaction.
public enum PR37V56Migrations {
    public static let identifier = "v56-pr37-receipt-time-frontier-and-protected-bytes"

    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            let jobs = try Row.fetchAll(db, sql: """
                SELECT job.*, receipt.committedAt
                FROM historicalMaterializationJob AS job
                JOIN historicalDataCommitJournal AS receipt ON receipt.receiptId = job.receiptId
                ORDER BY job.createdAt, job.receiptId
                """)

            for job in jobs {
                let repair = try repairValues(for: job, in: db)
                try db.execute(sql: """
                    UPDATE historicalMaterializationJob
                    SET mappedRawMinTs = ?, mappedRawMaxTs = ?, protectedByteCount = ?
                    WHERE receiptId = ?
                    """, arguments: [
                        repair.trustedTimestamps.min(), repair.trustedTimestamps.max(),
                        repair.protectedByteCount, job["receiptId"],
                    ])
                guard db.changesCount == 1 else {
                    throw PR37V56MigrationError.verificationFailed(job["receiptId"])
                }
            }

            guard try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty,
                  try String.fetchOne(db, sql: "PRAGMA quick_check") == "ok" else {
                throw PR37V56MigrationError.databaseVerificationFailed
            }
        }
    }

    /// One strict archive pass owns both V56 repairs so timestamp and byte-count semantics cannot drift.
    private struct RepairValues {
        let trustedTimestamps: [Int]
        let protectedByteCount: Int
    }

    private struct MappedFrame {
        let originalFrameIndex: Int
        let rawFrameOffset: Int
        let version: Int
        let unix: Int
        let exactByteCount: Int
        let parsed: ParsedFrame
    }

    private struct StoredMappedFrame {
        let originalFrameIndex: Int
        let rawFrameOffset: Int
        let version: Int
        let unix: Int
        let exactByteCount: Int
    }

    private static func repairValues(for job: Row, in db: Database) throws -> RepairValues {
        let receiptId: String = job["receiptId"]
        let state: String = job["state"]
        let selectionMode: String = job["selectionMode"]
        let committedAt: Int = job["committedAt"]
        let evictedAt: Int? = job["evictedAt"]
        let existingProtectedByteCount: Int = job["protectedByteCount"]
        guard existingProtectedByteCount >= 0 else {
            throw PR37V56MigrationError.invalidByteCount(receiptId)
        }
        let indexes: [Int]
        do {
            indexes = try decodedIndexes(job["originalFrameIndexesJSON"], receiptId: receiptId)
        } catch let error as PR37V56MigrationError {
            if state == HistoricalMaterializationJobState.quarantined.rawValue {
                return quarantinedFallback(protectedByteCount: existingProtectedByteCount)
            }
            throw error
        }
        let storedRows = try mappedRows(receiptId: receiptId, in: db)
        let archiveFrames: [[UInt8]]?
        do {
            archiveFrames = try archivedFrames(for: job, in: db)
        } catch let error as PR37V56MigrationError {
            if state == HistoricalMaterializationJobState.quarantined.rawValue {
                return quarantinedFallback(protectedByteCount: existingProtectedByteCount)
            }
            throw error
        }

        guard let archiveFrames else {
            if state == HistoricalMaterializationJobState.quarantined.rawValue {
                return quarantinedFallback(protectedByteCount: existingProtectedByteCount)
            }
            guard state == HistoricalMaterializationJobState.completed.rawValue,
                  !storedRows.isEmpty || evictedAt != nil else {
                throw PR37V56MigrationError.missingArchive(receiptId)
            }
            let protectedByteCount = storedRows.isEmpty
                ? existingProtectedByteCount
                : try storedExactByteCount(of: storedRows, receiptId: receiptId)
            return RepairValues(trustedTimestamps: [], protectedByteCount: protectedByteCount)
        }

        do {
            guard archiveFrames.count == indexes.count else {
                throw PR37V56MigrationError.archiveIndexMismatch(receiptId)
            }
            let mapped = try mappedFrames(
                archiveFrames,
                originalFrameIndexes: indexes,
                selectionMode: selectionMode,
                receiptId: receiptId
            )
            try verify(
                storedRows: storedRows,
                against: mapped,
                state: state,
                evictedAt: evictedAt,
                receiptId: receiptId
            )

            let protectedByteCount: Int
            let archiveMappedByteCount = try mappedExactByteCount(of: mapped, receiptId: receiptId)
            if state == HistoricalMaterializationJobState.completed.rawValue, evictedAt == nil {
                let storedMappedByteCount = try storedExactByteCount(
                    of: storedRows,
                    receiptId: receiptId
                )
                guard storedMappedByteCount == archiveMappedByteCount else {
                    throw PR37V56MigrationError.mappedFrameMismatch(receiptId)
                }
                protectedByteCount = storedMappedByteCount
            } else {
                protectedByteCount = archiveMappedByteCount
            }
            let trusted = mapped.compactMap { frame in
                trustedProgress(frame, committedAt: committedAt) ? frame.unix : nil
            }
            return RepairValues(
                trustedTimestamps: trusted,
                protectedByteCount: protectedByteCount
            )
        } catch let error as PR37V56MigrationError {
            if state == HistoricalMaterializationJobState.quarantined.rawValue {
                return quarantinedFallback(protectedByteCount: existingProtectedByteCount)
            }
            throw error
        }
    }

    private static func quarantinedFallback(protectedByteCount: Int) -> RepairValues {
        RepairValues(trustedTimestamps: [], protectedByteCount: protectedByteCount)
    }

    private static func decodedIndexes(_ data: Data, receiptId: String) throws -> [Int] {
        guard let indexes = try? JSONDecoder().decode([Int].self, from: data),
              !indexes.isEmpty,
              Set(indexes).count == indexes.count,
              indexes.allSatisfy({ $0 >= 0 }),
              zip(indexes, indexes.dropFirst()).allSatisfy(<) else {
            throw PR37V56MigrationError.invalidIndexes(receiptId)
        }
        return indexes
    }

    private static func archivedFrames(for job: Row, in db: Database) throws -> [[UInt8]]? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT frameCount, byteSize, framesBlob
            FROM rawBatch
            WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = ?
            """, arguments: [
                job["rawBatchId"], job["deviceId"], job["lineage"], job["cursorEpoch"],
            ]) else { return nil }
        do {
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
        } catch {
            throw PR37V56MigrationError.invalidArchive(job["receiptId"])
        }
    }

    private static func mappedFrames(
        _ frames: [[UInt8]],
        originalFrameIndexes: [Int],
        selectionMode: String,
        receiptId: String
    ) throws -> [MappedFrame] {
        guard selectionMode == "selectiveMapped" || selectionMode == "legacyFullCapture" else {
            throw PR37V56MigrationError.invalidSelectionMode(receiptId)
        }
        let mapped = try zip(originalFrameIndexes, frames).enumerated().compactMap {
            rawFrameOffset, pair -> MappedFrame? in
            let (originalFrameIndex, frame) = pair
            let parsed = parseFrame(frame, family: .whoop5)
            guard parsed.ok, parsed.envelopeOK,
                  parsed.headerCRCOK == true, parsed.payloadCRCOK == true else {
                throw PR37V56MigrationError.invalidEnvelope(receiptId)
            }
            guard case .mappedRaw(let version) = historicalRecordDisposition(
                parsed: parsed,
                rawFrame: frame,
                family: .whoop5
            ) else { return nil }
            guard (version == 20 || version == 21),
                  let unix = parsed.parsed["unix"]?.intValue else {
                throw PR37V56MigrationError.unsupportedLayout(receiptId)
            }
            return MappedFrame(
                originalFrameIndex: originalFrameIndex,
                rawFrameOffset: rawFrameOffset,
                version: version,
                unix: unix,
                exactByteCount: frame.count,
                parsed: parsed
            )
        }
        guard !mapped.isEmpty,
              selectionMode != "selectiveMapped" || mapped.count == frames.count else {
            throw PR37V56MigrationError.unsupportedLayout(receiptId)
        }
        return mapped
    }

    private static func mappedRows(receiptId: String, in db: Database) throws -> [StoredMappedFrame] {
        try Row.fetchAll(db, sql: """
            SELECT originalFrameIndex, rawFrameOffset, version, unix, exactByteCount
            FROM historicalMappedRawFrame
            WHERE receiptId = ?
            ORDER BY originalFrameIndex
            """, arguments: [receiptId]).map { row in
                StoredMappedFrame(
                    originalFrameIndex: row["originalFrameIndex"],
                    rawFrameOffset: row["rawFrameOffset"],
                    version: row["version"],
                    unix: row["unix"],
                    exactByteCount: row["exactByteCount"]
                )
            }
    }

    private static func verify(
        storedRows: [StoredMappedFrame],
        against mapped: [MappedFrame],
        state: String,
        evictedAt: Int?,
        receiptId: String
    ) throws {
        if state == HistoricalMaterializationJobState.completed.rawValue, evictedAt == nil,
           storedRows.count != mapped.count {
            throw PR37V56MigrationError.missingCompletedFrames(receiptId)
        }
        let byIndex = Dictionary(uniqueKeysWithValues: mapped.map { ($0.originalFrameIndex, $0) })
        for stored in storedRows {
            guard let archive = byIndex[stored.originalFrameIndex],
                  stored.rawFrameOffset == archive.rawFrameOffset,
                  stored.version == archive.version,
                  stored.unix == archive.unix,
                  stored.exactByteCount == archive.exactByteCount else {
                throw PR37V56MigrationError.mappedFrameMismatch(receiptId)
            }
        }
    }

    private static func mappedExactByteCount(of frames: [MappedFrame], receiptId: String) throws -> Int {
        try frames.reduce(0) { total, frame in
            let (sum, overflow) = total.addingReportingOverflow(frame.exactByteCount)
            guard !overflow, frame.exactByteCount >= 0 else {
                throw PR37V56MigrationError.invalidByteCount(receiptId)
            }
            return sum
        }
    }

    private static func storedExactByteCount(
        of frames: [StoredMappedFrame],
        receiptId: String
    ) throws -> Int {
        try frames.reduce(0) { total, frame in
            let (sum, overflow) = total.addingReportingOverflow(frame.exactByteCount)
            guard !overflow, frame.exactByteCount >= 0 else {
                throw PR37V56MigrationError.invalidByteCount(receiptId)
            }
            return sum
        }
    }

    private static func trustedProgress(_ frame: MappedFrame, committedAt: Int) -> Bool {
        guard isPlausibleHistoricalUnix(frame.unix, wallNow: committedAt) else { return false }
        switch frame.version {
        case 20:
            return frame.parsed.parsed.contains { key, value in
                key.hasPrefix("channel_b")
                    && !key.contains("sample_count")
                    && value.intArrayValue?.contains(where: { $0 != 0 }) == true
            }
        case 21:
            return ["accel_x", "accel_y", "accel_z"].contains { key in
                frame.parsed.parsed[key]?.intArrayValue?.contains(where: { $0 != 0 }) == true
            }
        default:
            return false
        }
    }
}

public enum PR37V56MigrationError: Error, Equatable, Sendable {
    case invalidIndexes(String)
    case missingArchive(String)
    case invalidArchive(String)
    case archiveIndexMismatch(String)
    case invalidSelectionMode(String)
    case invalidEnvelope(String)
    case unsupportedLayout(String)
    case missingCompletedFrames(String)
    case mappedFrameMismatch(String)
    case invalidByteCount(String)
    case verificationFailed(String)
    case databaseVerificationFailed
}
