import XCTest
import WhoopProtocol
@testable import WhoopStore

final class HistoricalRawMaterializationTests: XCTestCase {
    private let deviceId = "materialization-device"
    private var scope: HistoricalCursorScope {
        HistoricalCursorScope(deviceId: deviceId, lineage: "device:\(deviceId)")
    }

    private func putU32(_ frame: inout [UInt8], _ offset: Int, _ value: UInt32) {
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
        frame[5] = 0x00
        frame[8] = 0x2F
        frame[9] = 20
        frame[10] = 0x81
        putU32(&frame, 15, unix)
        frame[Whoop5RawOptical.blockStart] = 25
        // Preserve a non-zero byte in unused slot capacity. The exact materialized frame must retain it.
        frame[Whoop5RawOptical.blockStart + Whoop5RawOptical.headerLength + 49 * 4] = 0x7F
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame[6] = UInt8(headerCRC & 0xFF)
        frame[7] = UInt8((headerCRC >> 8) & 0xFF)
        let payloadEnd = frame.count - 4
        let payloadCRC = crc32(Array(frame[8..<payloadEnd]))
        putU32(&frame, payloadEnd, payloadCRC)
        return frame
    }

    private func ordinary(unix: UInt32) -> [UInt8] {
        var frame = frameFromPayload([], type: 50)
        // Console frames have no unix and are valid complete frames. This is unrelated mixed-chunk data.
        XCTAssertTrue(verifyFrame(frame).ok)
        frame[5] = UInt8(unix & 0xFF) // distinct bytes; rebuild CRCs below
        frame[3] = crc8(Array(frame[1...2]))
        let inner = Array(frame[4..<(frame.count - 4)])
        let payloadCRC = crc32(inner)
        putU32(&frame, frame.count - 4, payloadCRC)
        return frame
    }

    private func commitMapped(
        store: WhoopStore,
        trim: Int = 77,
        mappedFrame: [UInt8],
        completeFrames: [[UInt8]],
        mappedIndex: Int
    ) async throws -> HistoricalDataCommitReceipt {
        let input = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: completeFrames,
            protocolMetadata: Data([0x01]),
            historyEndFrame: Data([0x02]),
            minReceivedTs: Int(UInt32(mappedFrame[15])
                | (UInt32(mappedFrame[16]) << 8)
                | (UInt32(mappedFrame[17]) << 16)
                | (UInt32(mappedFrame[18]) << 24)),
            maxReceivedTs: Int(UInt32(mappedFrame[15])
                | (UInt32(mappedFrame[16]) << 8)
                | (UInt32(mappedFrame[17]) << 16)
                | (UInt32(mappedFrame[18]) << 24))
        )
        let ts = input.maxReceivedTs!
        let raw = HistoricalRawBatch(
            meta: RawBatchMeta(
                batchId: "mapped-\(trim)",
                deviceId: deviceId,
                clockRef: ClockRef(device: ts, wall: ts),
                capturedAt: ts,
                startTs: ts,
                endTs: ts,
                frameCount: 1,
                byteSize: mappedFrame.count,
                lineage: scope.lineage,
                cursorEpoch: scope.cursorEpoch
            ),
            frames: [mappedFrame],
            originalFrameIndexes: [mappedIndex],
            protocolMetadata: input.protocolMetadata,
            historyEndFrame: input.historyEndFrame
        )
        return try await store.commitHistoricalChunk(
            streams: Streams(),
            deviceId: deviceId,
            trim: trim,
            chunkEndUnix: ts,
            rawBatch: raw,
            committedAt: ts + 1,
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

    func testSelectiveProtectedRetentionMaterializesExactFrameAtOriginalIndex() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let mapped = v20(unix: 1_781_557_123)
        let unrelated = ordinary(unix: 1)
        let receipt = try await commitMapped(
            store: store,
            mappedFrame: mapped,
            completeFrames: [unrelated, mapped, unrelated],
            mappedIndex: 1
        )

        let retained = try await store.rawFrames(
            batchId: "mapped-77",
            deviceId: deviceId,
            lineage: scope.lineage,
            cursorEpoch: scope.cursorEpoch)
        let pendingState = try await store.historicalMaterializationJobStateForTest(
            receiptId: receipt.receiptId)
        XCTAssertEqual(retained, [mapped])
        XCTAssertEqual(pendingState, .pending)

        let run = try await store.materializePendingHistoricalRaw(limit: 1, now: 1_781_557_200)

        XCTAssertEqual(run, HistoricalMaterializationRunSummary(claimed: 1, completed: 1))
        let completedState = try await store.historicalMaterializationJobStateForTest(
            receiptId: receipt.receiptId)
        let indexes = try await store.historicalMaterializedFrameIndexesForTest(
            receiptId: receipt.receiptId)
        let materialized = try await store.historicalMaterializedFramesForTest(
            receiptId: receipt.receiptId)
        XCTAssertEqual(completedState, .completed)
        XCTAssertEqual(indexes, [1])
        XCTAssertEqual(materialized, [Data(mapped)])
    }

    func testMappedRawAdvancesDurableFrontierWithoutNormalizedRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let mapped = v20(unix: 1_781_557_456)
        _ = try await commitMapped(
            store: store,
            mappedFrame: mapped,
            completeFrames: [mapped],
            mappedIndex: 0
        )

        let frontier = try await store.latestHistoricalDurableFrontier(deviceId: deviceId)
        XCTAssertNil(frontier.normalizedMaxTs)
        XCTAssertEqual(frontier.mappedRawMaxTs, 1_781_557_456)
        XCTAssertEqual(frontier.maxTs, 1_781_557_456)
    }

    func testProtectedByteCeilingRejectsAdditionalMandatoryRetention() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let mapped = v20(unix: 1_781_557_789)
        _ = try await commitMapped(
            store: store,
            mappedFrame: mapped,
            completeFrames: [mapped],
            mappedIndex: 0
        )

        do {
            try await store.assertHistoricalProtectedRawCapacityForTest(
                incomingBytes: 1,
                limit: mapped.count
            )
            XCTFail("protected ceiling must reject the next byte")
        } catch let error as HistoricalDataCommitJournalError {
            XCTAssertEqual(
                error,
                .protectedRawByteCeilingExceeded(limit: mapped.count, attempted: mapped.count + 1)
            )
        }
    }

    func testCompletedJobReleasesRawBatchForNormalPruning() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let mapped = v20(unix: 1_781_558_000)
        let receipt = try await commitMapped(
            store: store,
            mappedFrame: mapped,
            completeFrames: [mapped],
            mappedIndex: 0
        )
        _ = try await store.materializePendingHistoricalRaw(limit: 1, now: 1_781_558_010)
        try await store.markRawBatchSynced(
            batchId: "mapped-77",
            deviceId: deviceId,
            lineage: scope.lineage,
            cursorEpoch: scope.cursorEpoch,
            at: 1
        )

        let pruned = try await store.pruneRaw(
            now: 1_781_558_100,
            keepWindowSeconds: 1,
            maxUnsyncedBytes: 0
        )

        XCTAssertEqual(pruned, 1)
        let completedState = try await store.historicalMaterializationJobStateForTest(
            receiptId: receipt.receiptId)
        let materialized = try await store.historicalMaterializedFramesForTest(
            receiptId: receipt.receiptId)
        XCTAssertEqual(completedState, .completed)
        XCTAssertEqual(materialized, [Data(mapped)])
    }

    func testPendingJobIsClaimedBeforeOlderRetryableFailure() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let oldMapped = v20(unix: 1_781_558_100)
        let newMapped = v20(unix: 1_781_558_200)
        let oldReceipt = try await commitMapped(
            store: store,
            trim: 77,
            mappedFrame: oldMapped,
            completeFrames: [oldMapped],
            mappedIndex: 0
        )
        let newReceipt = try await commitMapped(
            store: store,
            trim: 78,
            mappedFrame: newMapped,
            completeFrames: [newMapped],
            mappedIndex: 0
        )
        try await store.setHistoricalMaterializationJobStateForTest(
            receiptId: oldReceipt.receiptId,
            state: .retryable,
            updatedAt: 1_781_558_300
        )

        let run = try await store.materializePendingHistoricalRaw(limit: 1, now: 1_781_558_400)

        XCTAssertEqual(run, HistoricalMaterializationRunSummary(claimed: 1, completed: 1))
        let oldState = try await store.historicalMaterializationJobStateForTest(
            receiptId: oldReceipt.receiptId)
        let newState = try await store.historicalMaterializationJobStateForTest(
            receiptId: newReceipt.receiptId)
        XCTAssertEqual(oldState, .retryable)
        XCTAssertEqual(newState, .completed)
    }
}
