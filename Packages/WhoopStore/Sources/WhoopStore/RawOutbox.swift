import Foundation
import Compression
import GRDB
import WhoopProtocol

public struct ClockRef: Equatable, Codable, Sendable {
    public let device: Int
    public let wall: Int
    public init(device: Int, wall: Int) { self.device = device; self.wall = wall }
}

public struct RawBatchMeta: Equatable, Sendable {
    public let batchId: String
    public let deviceId: String
    /// Raw replay identity is scoped to the physical-source lineage and its deletion epoch.
    /// The default keeps legacy callers in a stable device-derived scope until they supply the
    /// registry-resolved scope explicitly.
    public let lineage: String
    public let cursorEpoch: Int
    public let clockRef: ClockRef
    public let capturedAt: Int
    public let startTs: Int
    public let endTs: Int
    public let frameCount: Int
    public let byteSize: Int
    public init(batchId: String, deviceId: String, clockRef: ClockRef, capturedAt: Int,
                startTs: Int, endTs: Int, frameCount: Int, byteSize: Int,
                lineage: String? = nil, cursorEpoch: Int = 0) {
        self.batchId = batchId; self.deviceId = deviceId
        self.lineage = lineage?.isEmpty == false ? lineage! : "device:\(deviceId)"
        self.cursorEpoch = max(0, cursorEpoch)
        self.clockRef = clockRef
        self.capturedAt = capturedAt; self.startTs = startTs; self.endTs = endTs
        self.frameCount = frameCount; self.byteSize = byteSize
    }

    func withHistoricalScope(lineage: String, cursorEpoch: Int) -> Self {
        Self(
            batchId: batchId,
            deviceId: deviceId,
            clockRef: clockRef,
            capturedAt: capturedAt,
            startTs: startTs,
            endTs: endTs,
            frameCount: frameCount,
            byteSize: byteSize,
            lineage: lineage,
            cursorEpoch: cursorEpoch
        )
    }
}

private struct RawBatchIdentity {
    let deviceId: String
    let lineage: String
    let cursorEpoch: Int
}

public enum RawOutboxIntegrityError: Error, Equatable, Sendable {
    case truncatedCompressedLength
    case unreasonableUncompressedLength(Int)
    case uncompressedLengthMismatch(expected: Int, actual: Int)
    case decompressionFailed(expected: Int, actual: Int)
    case truncatedHeader
    case unreasonableFrameCount(Int)
    case truncatedFrameLength(index: Int)
    case unreasonableFrameLength(index: Int, length: Int)
    case truncatedFrame(index: Int, expected: Int, remaining: Int)
    case trailingBytes(Int)
    case invalidStoredMetadata
    case conflictingBatchIdentity
}

extension WhoopStore {
    // MARK: - frame (de)serialization
    // Layout: [count u32 LE]{ [len u32 LE][bytes] } x count. zlib-compressed as a whole.

    static func packFrames(_ frames: [[UInt8]]) -> Data {
        var buf = Data()
        func appendU32(_ v: Int) {
            let u = UInt32(v)
            buf.append(UInt8(u & 0xFF)); buf.append(UInt8((u >> 8) & 0xFF))
            buf.append(UInt8((u >> 16) & 0xFF)); buf.append(UInt8((u >> 24) & 0xFF))
        }
        appendU32(frames.count)
        for f in frames {
            appendU32(f.count)
            buf.append(contentsOf: f)
        }
        return buf
    }

    // MARK: - zlib helpers using Apple Compression framework

    /// Compress `input` and prepend its uncompressed length as a UInt32 LE prefix.
    static func zlibCompressWithLength(_ input: Data) throws -> Data {
        let sourceSize = input.count
        let dstCapacity = max(64, sourceSize * 2 + 64)
        var dst = [UInt8](repeating: 0, count: dstCapacity)
        let written: Int = input.withUnsafeBytes { src in
            guard let srcPtr = src.baseAddress else { return 0 }
            return compression_encode_buffer(&dst, dstCapacity, srcPtr, sourceSize, nil, COMPRESSION_ZLIB)
        }
        guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
        // Prepend uncompressed length as UInt32 LE.
        let u = UInt32(sourceSize)
        var blob = Data(capacity: 4 + written)
        blob.append(UInt8(u & 0xFF)); blob.append(UInt8((u >> 8) & 0xFF))
        blob.append(UInt8((u >> 16) & 0xFF)); blob.append(UInt8((u >> 24) & 0xFF))
        blob.append(contentsOf: dst[0..<written])
        return blob
    }

    // MARK: - Public API

    /// Compress raw frames into the outbox and store batch meta.
    public func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
        let packed = WhoopStore.packFrames(frames)
        let blob = try WhoopStore.zlibCompressWithLength(packed)
        try syncWrite { db in
            try WhoopStore.enqueueRawBatch(meta, blob: blob, in: db)
        }
    }

    static func enqueueRawBatch(_ meta: RawBatchMeta, blob: Data, in db: Database) throws {
        try enqueueRawBatchV2(meta, blob: blob, in: db)
    }

    /// `nil` means this scoped batch identity is not stored. `true` means its metadata and exact frame
    /// payload match. `false` means another capture owns the id for a different device or the same
    /// lineage/epoch, so an atomic history receipt must fail closed.
    static func existingRawBatchMatches(_ meta: RawBatchMeta, blob: Data, in db: Database) throws -> Bool? {
        if let row = try Row.fetchOne(db, sql: """
            SELECT deviceId, lineage, cursorEpoch, frameCount, byteSize, framesBlob
            FROM rawBatch
            WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = ?
            """, arguments: [meta.batchId, meta.deviceId, meta.lineage, meta.cursorEpoch]) {
            let existingDeviceId: String = row["deviceId"]
            let existingLineage: String = row["lineage"]
            let existingEpoch: Int = row["cursorEpoch"]
            let existingFrameCount: Int = row["frameCount"]
            let existingByteSize: Int = row["byteSize"]
            let existingBlob: Data = row["framesBlob"]
            guard existingDeviceId == meta.deviceId,
                  existingLineage == meta.lineage,
                  existingEpoch == meta.cursorEpoch,
                  existingFrameCount == meta.frameCount,
                  existingByteSize == meta.byteSize else {
                return false
            }
            let expectedLength = try WhoopStore.expectedPackedFrameLength(
                frameCount: existingFrameCount,
                byteSize: existingByteSize
            )
            let existingPacked = try WhoopStore.zlibDecompressWithLengthStrict(
                existingBlob,
                expectedUncompressedLength: expectedLength
            )
            let incomingPacked = try WhoopStore.zlibDecompressWithLengthStrict(
                blob,
                expectedUncompressedLength: expectedLength
            )
            _ = try WhoopStore.unpackFramesStrict(
                existingPacked,
                expectedFrameCount: existingFrameCount,
                expectedFrameBytes: existingByteSize
            )
            _ = try WhoopStore.unpackFramesStrict(
                incomingPacked,
                expectedFrameCount: meta.frameCount,
                expectedFrameBytes: meta.byteSize
            )
            return existingPacked == incomingPacked
        }

        // Keep batch IDs globally collision-safe across logical devices. A reused ID is only allowed
        // when the device is the same and the physical lineage/epoch scope differs.
        let existingDeviceIds = try String.fetchAll(
            db,
            sql: "SELECT DISTINCT deviceId FROM rawBatch WHERE batchId = ?",
            arguments: [meta.batchId]
        )
        if existingDeviceIds.contains(where: { $0 != meta.deviceId }) {
            return false
        }
        return nil
    }

    /// Resolve a legacy batch ID only when exactly one physical-source identity owns it.
    /// `nil` means unknown or ambiguous, so legacy callers fail closed without selecting a row.
    private static func uniqueRawBatchIdentity(batchId: String, in db: Database) throws -> RawBatchIdentity? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT deviceId, lineage, cursorEpoch
            FROM rawBatch
            WHERE batchId = ?
            LIMIT 2
            """, arguments: [batchId])
        guard rows.count == 1 else { return nil }
        let row = rows[0]
        return RawBatchIdentity(
            deviceId: row["deviceId"],
            lineage: row["lineage"],
            cursorEpoch: row["cursorEpoch"]
        )
    }

    /// Resolve a scoped batch identity only when exactly one physical device owns it.
    /// `nil` means unknown or cross-device ambiguous, so legacy scoped callers fail closed.
    private static func uniqueRawBatchIdentity(
        batchId: String,
        lineage: String,
        cursorEpoch: Int,
        in db: Database
    ) throws -> RawBatchIdentity? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT deviceId, lineage, cursorEpoch
            FROM rawBatch
            WHERE batchId = ? AND lineage = ? AND cursorEpoch = ?
            LIMIT 2
            """, arguments: [batchId, lineage, cursorEpoch])
        guard rows.count == 1 else { return nil }
        let row = rows[0]
        return RawBatchIdentity(
            deviceId: row["deviceId"],
            lineage: row["lineage"],
            cursorEpoch: row["cursorEpoch"]
        )
    }

    /// Decompress and return the exact frame bytes for a batch (empty if unknown or ambiguous).
    public func rawFrames(batchId: String) async throws -> [[UInt8]] {
        try await loadRawFrames(batchId: batchId, deviceId: nil, lineage: nil, cursorEpoch: nil)
    }

    /// Decompress and return exact frame bytes for one scoped batch identity.
    /// Returns empty when that identity is unknown or cross-device ambiguous.
    public func rawFrames(batchId: String, lineage: String, cursorEpoch: Int) async throws -> [[UInt8]] {
        try await loadRawFrames(
            batchId: batchId, deviceId: nil, lineage: lineage, cursorEpoch: cursorEpoch
        )
    }

    /// Decompress and return exact frame bytes for the requested device and scoped batch identity.
    public func rawFrames(
        batchId: String,
        deviceId: String,
        lineage: String,
        cursorEpoch: Int
    ) async throws -> [[UInt8]] {
        try await loadRawFrames(
            batchId: batchId, deviceId: deviceId, lineage: lineage, cursorEpoch: cursorEpoch
        )
    }

    private func loadRawFrames(
        batchId: String,
        deviceId: String?,
        lineage: String?,
        cursorEpoch: Int?
    ) async throws -> [[UInt8]] {
        let row: Row? = try syncRead { db in
            let identity: RawBatchIdentity?
            if let deviceId, let lineage, let cursorEpoch {
                identity = RawBatchIdentity(
                    deviceId: deviceId, lineage: lineage, cursorEpoch: cursorEpoch
                )
            } else if let lineage, let cursorEpoch {
                identity = try WhoopStore.uniqueRawBatchIdentity(
                    batchId: batchId, lineage: lineage, cursorEpoch: cursorEpoch, in: db
                )
            } else {
                identity = try WhoopStore.uniqueRawBatchIdentity(batchId: batchId, in: db)
            }
            guard let identity else {
                return nil
            }
            return try Row.fetchOne(
                db,
                sql: """
                    SELECT frameCount, byteSize, framesBlob FROM rawBatch
                    WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = ?
                    """,
                arguments: [batchId, identity.deviceId, identity.lineage, identity.cursorEpoch]
            )
        }
        guard let row = row else { return [] }
        let frameCount: Int = row["frameCount"]
        let byteSize: Int = row["byteSize"]
        let blob: Data = row["framesBlob"]
        let expectedLength = try WhoopStore.expectedPackedFrameLength(
            frameCount: frameCount,
            byteSize: byteSize
        )
        let raw = try WhoopStore.zlibDecompressWithLengthStrict(
            blob,
            expectedUncompressedLength: expectedLength
        )
        return try WhoopStore.unpackFramesStrict(
            raw,
            expectedFrameCount: frameCount,
            expectedFrameBytes: byteSize
        )
    }

    private static func metaFromRow(_ row: Row) -> RawBatchMeta {
        RawBatchMeta(
            batchId: row["batchId"], deviceId: row["deviceId"],
            clockRef: ClockRef(device: row["deviceClockRef"], wall: row["wallClockRef"]),
            capturedAt: row["capturedAt"], startTs: row["startTs"], endTs: row["endTs"],
            frameCount: row["frameCount"], byteSize: row["byteSize"],
            lineage: row["lineage"], cursorEpoch: row["cursorEpoch"])
    }

    /// Un-synced batches (syncedAt IS NULL), oldest first, capped at `limit`.
    public func pendingRawBatches(limit: Int) async throws -> [RawBatchMeta] {
        try syncRead { db in
            try Row.fetchAll(db, sql: """
                SELECT batchId, deviceId, capturedAt, deviceClockRef, wallClockRef,
                       startTs, endTs, frameCount, byteSize, lineage, cursorEpoch
                FROM rawBatch
                WHERE syncedAt IS NULL
                ORDER BY capturedAt ASC
                LIMIT ?
                """, arguments: [limit]).map(WhoopStore.metaFromRow)
        }
    }

    /// Mark a batch synced (timestamp in unix seconds). An ambiguous legacy batch ID is a no-op.
    public func markRawBatchSynced(batchId: String, at: Int) async throws {
        try syncWrite { db in
            guard let identity = try WhoopStore.uniqueRawBatchIdentity(batchId: batchId, in: db) else {
                return
            }
            try db.execute(
                sql: """
                    UPDATE rawBatch SET syncedAt = ?
                    WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = ?
                    """,
                arguments: [at, batchId, identity.deviceId, identity.lineage, identity.cursorEpoch]
            )
        }
    }

    /// Mark one physical-source batch identity synced without touching a reused batch ID from another
    /// lineage or deletion epoch.
    public func markRawBatchSynced(
        batchId: String,
        lineage: String,
        cursorEpoch: Int,
        at: Int
    ) async throws {
        try syncWrite { db in
            guard let identity = try WhoopStore.uniqueRawBatchIdentity(
                batchId: batchId, lineage: lineage, cursorEpoch: cursorEpoch, in: db
            ) else {
                return
            }
            try db.execute(
                sql: """
                    UPDATE rawBatch SET syncedAt = ?
                    WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = ?
                    """,
                arguments: [at, batchId, identity.deviceId, identity.lineage, identity.cursorEpoch]
            )
        }
    }

    /// Mark one requested device's physical-source batch identity synced.
    public func markRawBatchSynced(
        batchId: String,
        deviceId: String,
        lineage: String,
        cursorEpoch: Int,
        at: Int
    ) async throws {
        try syncWrite { db in
            try db.execute(
                sql: """
                    UPDATE rawBatch SET syncedAt = ?
                    WHERE batchId = ? AND deviceId = ? AND lineage = ? AND cursorEpoch = ?
                    """,
                arguments: [at, batchId, deviceId, lineage, cursorEpoch]
            )
        }
    }
}

extension WhoopStore {
    /// Prune raw outbox rows. Returns the number of rawBatch rows deleted.
    ///
    /// **Policy 1:** Delete SYNCED batches whose `syncedAt` timestamp is older than
    /// `now - keepWindowSeconds`. Synced raw is safe to drop because the decoded streams
    /// are persisted separately.
    ///
    /// **Policy 2 (size eviction, #27):** Cap the total on-disk raw footprint at
    /// `maxUnsyncedBytes`. Walk the surviving batches newest-first (`capturedAt DESC`),
    /// summing `byteSize`, and DELETE every row once the running total exceeds the cap —
    /// i.e. drop the OLDEST raw. Raw is transient working data, not an archive: the decoded
    /// streams are persisted BEFORE the raw batch is enqueued (Collector E2 invariant), so
    /// dropping the oldest raw never loses a decoded metric. Without this an experimental
    /// capture toggle could grow local storage without bound (a 5/MG user saw 19 GB).
    ///
    /// - Parameters:
    ///   - now: Current unix-second timestamp used to compute the synced-aging cutoff.
    ///   - keepWindowSeconds: Synced batches older than `now - keepWindowSeconds` are removed.
    ///   - maxUnsyncedBytes: Total raw-footprint cap; oldest batches beyond it are evicted.
    @discardableResult
    public func pruneRaw(now: Int, keepWindowSeconds: Int, maxUnsyncedBytes: Int) async throws -> Int {
        try syncWrite { db in
            var pruned = 0
            // Policy 1: aged synced batches.
            let cutoff = now - keepWindowSeconds
            try db.execute(sql: """
                DELETE FROM rawBatch AS raw
                WHERE raw.syncedAt IS NOT NULL AND raw.syncedAt < ?
                  AND NOT EXISTS (
                      SELECT 1 FROM historicalDataCommitJournal AS receipt
                      WHERE receipt.rawStatus = 'materializationRequired'
                        AND receipt.rawBatchId = raw.batchId
                        AND receipt.deviceId = raw.deviceId
                        AND receipt.lineage = raw.lineage
                        AND receipt.cursorEpoch = raw.cursorEpoch
                        AND NOT EXISTS (
                            SELECT 1 FROM historicalMaterializationJob AS job
                            WHERE job.receiptId = receipt.receiptId
                              AND job.state = 'completed'
                        )
                  )
                """, arguments: [cutoff])
            pruned += db.changesCount

            // Policy 2 (#27): size-based eviction of the OLDEST raw beyond the cap. Sum byteSize
            // newest-first; once the cumulative total exceeds maxUnsyncedBytes, the remaining (older)
            // rows are over budget and get dropped. rowid keeps the cutoff stable regardless of ties
            // on capturedAt. A materialization-required receipt protects its packed record until a later
            // worker has created the normalized representation.
            let rows = try Row.fetchAll(db, sql: """
                SELECT raw.rowid, raw.byteSize,
                       EXISTS (
                           SELECT 1 FROM historicalDataCommitJournal AS receipt
                           WHERE receipt.rawStatus = 'materializationRequired'
                             AND receipt.rawBatchId = raw.batchId
                             AND receipt.deviceId = raw.deviceId
                             AND receipt.lineage = raw.lineage
                             AND receipt.cursorEpoch = raw.cursorEpoch
                             AND NOT EXISTS (
                                 SELECT 1 FROM historicalMaterializationJob AS job
                                 WHERE job.receiptId = receipt.receiptId
                                   AND job.state = 'completed'
                             )
                       ) AS protected
                FROM rawBatch AS raw
                ORDER BY raw.capturedAt DESC, raw.rowid DESC
                """)
            var cumulative = 0
            var evict: [Int64] = []
            for row in rows {
                let size: Int = row["byteSize"]
                let rowid: Int64 = row["rowid"]
                let protected: Bool = row["protected"]
                if protected { continue }
                cumulative += size
                if cumulative > maxUnsyncedBytes {
                    evict.append(rowid)
                }
            }
            if !evict.isEmpty {
                let placeholders = evict.map { _ in "?" }.joined(separator: ",")
                try db.execute(
                    sql: "DELETE FROM rawBatch WHERE rowid IN (\(placeholders))",
                    arguments: StatementArguments(evict))
                pruned += db.changesCount
            }
            return pruned
        }
    }

    // MARK: - Test helper
    public func allBatchIdsForTest() async throws -> [String] {
        try syncRead { db in
            try String.fetchAll(db, sql: "SELECT batchId FROM rawBatch ORDER BY capturedAt ASC")
        }
    }
}

// MARK: - PR #28 root-fix support for WhoopStore
extension WhoopStore {
    static func zlibDecompressWithLengthStrict(
            _ input: Data,
            expectedUncompressedLength: Int,
            maximumUncompressedLength: Int = 256 * 1_024 * 1_024
        ) throws -> Data {
            guard input.count >= 4 else { throw RawOutboxIntegrityError.truncatedCompressedLength }
            let actualLength = Int(input[input.startIndex])
                | (Int(input[input.startIndex + 1]) << 8)
                | (Int(input[input.startIndex + 2]) << 16)
                | (Int(input[input.startIndex + 3]) << 24)
            guard actualLength >= 0, actualLength <= maximumUncompressedLength else {
                throw RawOutboxIntegrityError.unreasonableUncompressedLength(actualLength)
            }
            guard actualLength == expectedUncompressedLength else {
                throw RawOutboxIntegrityError.uncompressedLengthMismatch(
                    expected: expectedUncompressedLength,
                    actual: actualLength
                )
            }
            let compressed = input.dropFirst(4)
            if actualLength == 0 {
                guard compressed.isEmpty else { throw RawOutboxIntegrityError.trailingBytes(compressed.count) }
                return Data()
            }
            var destination = [UInt8](repeating: 0, count: actualLength)
            let written = compressed.withUnsafeBytes { source -> Int in
                guard let base = source.baseAddress else { return 0 }
                return compression_decode_buffer(
                    &destination,
                    actualLength,
                    base,
                    compressed.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            guard written == actualLength else {
                throw RawOutboxIntegrityError.decompressionFailed(expected: actualLength, actual: written)
            }
            return Data(destination)
        }

    static func unpackFramesStrict(
            _ data: Data,
            expectedFrameCount: Int? = nil,
            expectedFrameBytes: Int? = nil,
            maximumFrameCount: Int = 1_000_000,
            maximumFrameLength: Int = 16 * 1_024 * 1_024
        ) throws -> [[UInt8]] {
            let bytes = [UInt8](data)
            var offset = 0

            func readU32() -> Int? {
                guard offset + 4 <= bytes.count else { return nil }
                let value = Int(bytes[offset])
                    | (Int(bytes[offset + 1]) << 8)
                    | (Int(bytes[offset + 2]) << 16)
                    | (Int(bytes[offset + 3]) << 24)
                offset += 4
                return value
            }

            guard let count = readU32() else { throw RawOutboxIntegrityError.truncatedHeader }
            // Every frame needs at least a four-byte length. Reject impossible counts before reserveCapacity.
            let structuralMaximum = max(0, (bytes.count - 4) / 4)
            guard count <= structuralMaximum, (0...maximumFrameCount).contains(count) else {
                throw RawOutboxIntegrityError.unreasonableFrameCount(count)
            }
            if let expectedFrameCount, expectedFrameCount != count {
                throw RawOutboxIntegrityError.invalidStoredMetadata
            }

            var frames: [[UInt8]] = []
            frames.reserveCapacity(count)
            var totalFrameBytes = 0
            for index in 0..<count {
                guard let length = readU32() else {
                    throw RawOutboxIntegrityError.truncatedFrameLength(index: index)
                }
                guard (0...maximumFrameLength).contains(length) else {
                    throw RawOutboxIntegrityError.unreasonableFrameLength(index: index, length: length)
                }
                let remaining = bytes.count - offset
                guard length <= remaining else {
                    throw RawOutboxIntegrityError.truncatedFrame(
                        index: index,
                        expected: length,
                        remaining: remaining
                    )
                }
                let (nextTotal, overflow) = totalFrameBytes.addingReportingOverflow(length)
                guard !overflow else { throw RawOutboxIntegrityError.invalidStoredMetadata }
                totalFrameBytes = nextTotal
                frames.append(Array(bytes[offset..<(offset + length)]))
                offset += length
            }
            guard offset == bytes.count else {
                throw RawOutboxIntegrityError.trailingBytes(bytes.count - offset)
            }
            if let expectedFrameBytes, expectedFrameBytes != totalFrameBytes {
                throw RawOutboxIntegrityError.invalidStoredMetadata
            }
            return frames
        }

    static func expectedPackedFrameLength(frameCount: Int, byteSize: Int) throws -> Int {
            guard frameCount >= 0, byteSize >= 0 else {
                throw RawOutboxIntegrityError.invalidStoredMetadata
            }
            let (lengthBytes, lengthOverflow) = frameCount.multipliedReportingOverflow(by: 4)
            let (withHeader, headerOverflow) = lengthBytes.addingReportingOverflow(4)
            let (total, totalOverflow) = withHeader.addingReportingOverflow(byteSize)
            guard !lengthOverflow, !headerOverflow, !totalOverflow else {
                throw RawOutboxIntegrityError.invalidStoredMetadata
            }
            return total
        }

    static func enqueueRawBatchV2(_ meta: RawBatchMeta, blob: Data, in db: Database) throws {
            switch try existingRawBatchMatches(meta, blob: blob, in: db) {
            case .some(true):
                return
            case .some(false):
                throw RawOutboxIntegrityError.conflictingBatchIdentity
            case .none:
                try db.execute(sql: """
                    INSERT INTO rawBatch
                        (batchId, deviceId, lineage, cursorEpoch, capturedAt, deviceClockRef, wallClockRef,
                         startTs, endTs, frameCount, byteSize, framesBlob, syncedAt)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                    """, arguments: [
                        meta.batchId, meta.deviceId, meta.lineage, meta.cursorEpoch, meta.capturedAt,
                        meta.clockRef.device, meta.clockRef.wall,
                        meta.startTs, meta.endTs, meta.frameCount, meta.byteSize, blob,
                    ])
            }
        }
}
