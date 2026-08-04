// Replace RawOutbox's permissive decompressor/frame decoder and silent insert-conflict behavior.

import Compression
import Foundation
import GRDB

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
    /// Decode the four-byte uncompressed-length prefix before allocating memory. The row's frameCount and
    /// byteSize determine the exact packed length: 4-byte count + one 4-byte length per frame + frame bytes.
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

    /// Exact-idempotent insert. A reused identity with different metadata or payload is an error rather
    /// than a silent `ON CONFLICT DO NOTHING` success.
    static func enqueueRawBatchV2(_ meta: RawBatchMeta, blob: Data, in db: Database) throws {
        switch try existingRawBatchMatches(meta, blob: blob, in: db) {
        case true:
            return
        case false:
            throw RawOutboxIntegrityError.conflictingBatchIdentity
        case nil:
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

/*
Mechanical integration in RawOutbox.swift:

- Replace `zlibDecompressWithLength` on read with `zlibDecompressWithLengthStrict`.
- Every load query must select `frameCount`, `byteSize`, and `framesBlob`.
- Compute `expectedPackedFrameLength(frameCount:byteSize:)`, decompress with that exact expected length,
  then call `unpackFramesStrict(expectedFrameCount:expectedFrameBytes:)`.
- Never return a successfully decoded prefix of a corrupt blob.
- Replace the internal enqueue helper with `enqueueRawBatchV2`; remove `ON CONFLICT DO NOTHING`.
- Keep `existingRawBatchMatches` as the single semantic replay comparison.
- Add tests for a malicious length prefix, impossible frame count, truncated frame, trailing bytes,
  metadata mismatch, decompression mismatch, and conflicting batch identity.
*/
