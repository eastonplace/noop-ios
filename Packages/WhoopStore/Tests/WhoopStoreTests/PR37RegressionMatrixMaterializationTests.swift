import Foundation
import GRDB
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class PR37RegressionMatrixMaterializationTests: XCTestCase {
    private let deviceId = "pr37-matrix-device"

    private var scope: HistoricalCursorScope {
        HistoricalCursorScope(deviceId: deviceId, lineage: "device:\(deviceId)")
    }

    private func putU32(_ frame: inout [UInt8], at offset: Int, value: UInt32) {
        frame[offset] = UInt8(value & 0xFF)
        frame[offset + 1] = UInt8((value >> 8) & 0xFF)
        frame[offset + 2] = UInt8((value >> 16) & 0xFF)
        frame[offset + 3] = UInt8((value >> 24) & 0xFF)
    }

    private func v20(unix: UInt32) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: Whoop5RawOptical.bufferLength)
        frame[0] = 0xAA
        frame[1] = 0x01
        let declared = frame.count - 8
        frame[2] = UInt8(declared & 0xFF)
        frame[3] = UInt8((declared >> 8) & 0xFF)
        frame[4] = 0x01
        frame[8] = 0x2F
        frame[9] = 20
        frame[10] = 0x81
        putU32(&frame, at: 15, value: unix)
        frame[Whoop5RawOptical.blockStart] = 25
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame[6] = UInt8(headerCRC & 0xFF)
        frame[7] = UInt8((headerCRC >> 8) & 0xFF)
        let payloadEnd = frame.count - 4
        putU32(&frame, at: payloadEnd, value: crc32(Array(frame[8..<payloadEnd])))
        return frame
    }

    private func commitMapped(
        to store: WhoopStore,
        trim: Int,
        unix: UInt32
    ) async throws -> HistoricalDataCommitReceipt {
        let frame = v20(unix: unix)
        let input = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: [frame],
            protocolMetadata: Data([0x01]),
            historyEndFrame: Data([0x02]),
            minReceivedTs: Int(unix),
            maxReceivedTs: Int(unix)
        )
        let raw = HistoricalRawBatch(
            meta: RawBatchMeta(
                batchId: "pr37-matrix-\(trim)",
                deviceId: deviceId,
                clockRef: ClockRef(device: Int(unix), wall: Int(unix)),
                capturedAt: Int(unix),
                startTs: Int(unix),
                endTs: Int(unix),
                frameCount: 1,
                byteSize: frame.count,
                lineage: scope.lineage,
                cursorEpoch: scope.cursorEpoch
            ),
            frames: [frame],
            originalFrameIndexes: [0],
            protocolMetadata: input.protocolMetadata,
            historyEndFrame: input.historyEndFrame,
            trustedMappedProgressRange: Int(unix)...Int(unix)
        )
        return try await store.commitHistoricalChunk(
            streams: Streams(),
            deviceId: deviceId,
            trim: trim,
            chunkEndUnix: Int(unix),
            rawBatch: raw,
            committedAt: Int(unix) + 1,
            scope: scope,
            fingerprint: try WhoopStore.historicalReceivedFrameFingerprint(
                input: input,
                scope: scope,
                trim: trim
            ),
            fingerprintInput: input,
            rawCaptureStatus: .materializationRequired(batchId: raw.meta.batchId)
        )
    }

    private func jobRow(
        store: WhoopStore,
        receiptId: String
    ) async throws -> (state: String, attempts: Int, nextAttemptAt: Int?, leaseOwner: String?, leaseExpiresAt: Int?, lastErrorCode: String?) {
        let writer = store.registryWriter
        return try await writer.read { db in
            let row = try XCTUnwrap(Row.fetchOne(
                db,
                sql: """
                    SELECT state, attemptCount, nextAttemptAt, leaseOwner, leaseExpiresAt, lastErrorCode
                    FROM historicalMaterializationJob
                    WHERE receiptId = ?
                    """,
                arguments: [receiptId]
            ))
            return (
                state: row["state"],
                attempts: row["attemptCount"],
                nextAttemptAt: row["nextAttemptAt"],
                leaseOwner: row["leaseOwner"],
                leaseExpiresAt: row["leaseExpiresAt"],
                lastErrorCode: row["lastErrorCode"]
            )
        }
    }

    func testLeaseDeadlineReclaimsExpiredJobButNotLiveLease() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let expired = try await commitMapped(to: store, trim: 101, unix: 1_781_600_101)
        let live = try await commitMapped(to: store, trim: 102, unix: 1_781_600_102)
        let now = 1_781_600_500

        try await store.registryWriter.write { db in
            try db.execute(sql: """
                UPDATE historicalMaterializationJob
                SET state = 'running', leaseOwner = 'dead-worker', leaseExpiresAt = ?
                WHERE receiptId = ?
                """, arguments: [now, expired.receiptId])
            try db.execute(sql: """
                UPDATE historicalMaterializationJob
                SET state = 'running', leaseOwner = 'live-worker', leaseExpiresAt = ?
                WHERE receiptId = ?
                """, arguments: [now + 1, live.receiptId])
        }

        let run = try await store.materializePendingHistoricalRaw(limit: 2, now: now)

        XCTAssertEqual(run, HistoricalMaterializationRunSummary(claimed: 1, completed: 1))
        let expiredRow = try await jobRow(store: store, receiptId: expired.receiptId)
        let liveRow = try await jobRow(store: store, receiptId: live.receiptId)
        XCTAssertEqual(expiredRow.state, HistoricalMaterializationJobState.completed.rawValue)
        XCTAssertEqual(expiredRow.attempts, 1)
        XCTAssertNil(expiredRow.leaseOwner)
        XCTAssertNil(expiredRow.leaseExpiresAt)
        XCTAssertEqual(liveRow.state, HistoricalMaterializationJobState.running.rawValue)
        XCTAssertEqual(liveRow.attempts, 0)
        XCTAssertEqual(liveRow.leaseOwner, "live-worker")
        XCTAssertEqual(liveRow.leaseExpiresAt, now + 1)
    }

    func testTransientRawDecodeFailureUsesCappedBackoff() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let receipt = try await commitMapped(to: store, trim: 201, unix: 1_781_600_201)

        try await store.registryWriter.write { db in
            try db.execute(
                sql: "UPDATE rawBatch SET framesBlob = ? WHERE batchId = ?",
                arguments: [Data([0x00]), "pr37-matrix-201"]
            )
        }

        let first = try await store.materializePendingHistoricalRaw(limit: 1, now: 1_781_600_300)
        let tooEarly = try await store.materializePendingHistoricalRaw(limit: 1, now: 1_781_600_301)
        let second = try await store.materializePendingHistoricalRaw(limit: 1, now: 1_781_600_330)

        XCTAssertEqual(first, HistoricalMaterializationRunSummary(claimed: 1, retryable: 1))
        XCTAssertEqual(tooEarly, HistoricalMaterializationRunSummary())
        XCTAssertEqual(second, HistoricalMaterializationRunSummary(claimed: 1, retryable: 1))
        let row = try await jobRow(store: store, receiptId: receipt.receiptId)
        XCTAssertEqual(row.state, HistoricalMaterializationJobState.retryable.rawValue)
        XCTAssertEqual(row.attempts, 2)
        XCTAssertEqual(row.nextAttemptAt, 1_781_600_390)
        XCTAssertNil(row.leaseOwner)
        XCTAssertNil(row.leaseExpiresAt)
    }

    func testDurableInvalidEnvelopeIsQuarantinedAndRemainsProtectedFromPruning() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let receipt = try await commitMapped(to: store, trim: 301, unix: 1_781_600_301)
        var corrupt = v20(unix: 1_781_600_301)
        corrupt[100] ^= 0x01
        let corruptBlob = try WhoopStore.zlibCompressWithLength(WhoopStore.packFrames([corrupt]))

        try await store.registryWriter.write { db in
            try db.execute(
                sql: "UPDATE rawBatch SET framesBlob = ? WHERE batchId = ?",
                arguments: [corruptBlob, "pr37-matrix-301"]
            )
        }

        let run = try await store.materializePendingHistoricalRaw(limit: 1, now: 1_781_600_400)
        XCTAssertEqual(run, HistoricalMaterializationRunSummary(claimed: 1, quarantined: 1))
        let row = try await jobRow(store: store, receiptId: receipt.receiptId)
        XCTAssertEqual(row.state, HistoricalMaterializationJobState.quarantined.rawValue)
        XCTAssertEqual(row.attempts, 1)

        try await store.markRawBatchSynced(
            batchId: "pr37-matrix-301",
            deviceId: deviceId,
            lineage: scope.lineage,
            cursorEpoch: scope.cursorEpoch,
            at: 1
        )
        let pruned = try await store.pruneRaw(
            now: 1_781_700_000,
            keepWindowSeconds: 1,
            maxUnsyncedBytes: 0
        )

        XCTAssertEqual(pruned, 0)
        let retained = try await store.rawFrames(
            batchId: "pr37-matrix-301",
            deviceId: deviceId,
            lineage: scope.lineage,
            cursorEpoch: scope.cursorEpoch
        )
        XCTAssertEqual(retained, [corrupt])
    }

    func testMalformedIndexJSONIsQuarantinedWithoutBlockingAnotherJob() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let receipt = try await commitMapped(to: store, trim: 401, unix: 1_781_600_401)

        try await store.registryWriter.write { db in
            try db.execute(
                sql: "UPDATE historicalMaterializationJob SET originalFrameIndexesJSON = ? WHERE receiptId = ?",
                arguments: [Data("not-json".utf8), receipt.receiptId]
            )
        }

        let healthy = try await commitMapped(to: store, trim: 402, unix: 1_781_600_402)
        let run = try await store.materializePendingHistoricalRaw(limit: 2, now: 1_781_600_500)
        let malformedRow = try await jobRow(store: store, receiptId: receipt.receiptId)
        let healthyRow = try await jobRow(store: store, receiptId: healthy.receiptId)
        XCTAssertEqual(run, HistoricalMaterializationRunSummary(claimed: 1, completed: 1))
        XCTAssertEqual(malformedRow.state, HistoricalMaterializationJobState.quarantined.rawValue)
        XCTAssertEqual(malformedRow.attempts, 0)
        XCTAssertEqual(malformedRow.lastErrorCode, "invalidIndexes")
        XCTAssertEqual(healthyRow.state, HistoricalMaterializationJobState.completed.rawValue)
    }

    func testV54ClaimAndMappedTimestampQueriesUseTheirIndexes() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = store.registryWriter

        try await writer.read { db in
            func details(sql: String, arguments: StatementArguments = StatementArguments()) throws -> String {
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
                    .compactMap { $0["detail"] as String? }
                    .joined(separator: "\n")
            }

            let claim = try details(
                sql: """
                    SELECT receiptId
                    FROM historicalMaterializationJob
                    WHERE state = 'pending'
                       OR (state = 'retryable' AND COALESCE(nextAttemptAt, 0) <= ?)
                       OR (state = 'running' AND COALESCE(leaseExpiresAt, 0) <= ?)
                    ORDER BY CASE WHEN state = 'pending' THEN 0 ELSE 1 END, createdAt, receiptId
                    LIMIT ?
                    """,
                arguments: [1_781_600_500, 1_781_600_500,
                            HistoricalRawMaterializationPolicy.defaultJobLimit]
            )
            let mapped = try details(
                sql: """
                    SELECT receiptId, originalFrameIndex
                    FROM historicalMappedRawFrame
                    WHERE databaseInstanceId = ? AND deviceId = ? AND lineage = ?
                      AND cursorEpoch = ? AND trimScope = ? AND unix >= ?
                    ORDER BY unix, receiptId
                    """,
                arguments: ["db", self.deviceId, self.scope.lineage, self.scope.cursorEpoch,
                            self.scope.trimScope, 1_781_600_000]
            )

            XCTAssertTrue(claim.contains("idx_historicalMaterializationJob_claim"), claim)
            XCTAssertTrue(mapped.contains("idx_historicalMappedRawFrame_source_frontier"), mapped)
            XCTAssertFalse(mapped.contains("SCAN historicalMappedRawFrame"), mapped)
        }
    }
}
