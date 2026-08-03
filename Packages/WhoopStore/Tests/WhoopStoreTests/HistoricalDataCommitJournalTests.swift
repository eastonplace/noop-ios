import XCTest
import WhoopProtocol
@testable import WhoopStore

final class HistoricalDataCommitJournalTests: XCTestCase {
    private let deviceId = "strap-a"
    private let frames: [[UInt8]] = [
        [0xAA, 0x18, 0x00, 0xFF, 0x28, 0x02],
        [0xAA, 0x0C, 0x00, 0xFC, 0x24, 0x24],
    ]
    private let protocolMetadata = Data([0x49, 0x01, 0x02, 0x03])
    private let historyEndFrame = Data([0xAA, 0x02, 0x00, 0x00, 0x00, 0x00])

    private var streams: Streams {
        Streams(
            hr: [HRSample(ts: 1_000, bpm: 60)],
            gravity: [GravitySample(ts: 1_001, x: 0.1, y: 0.2, z: 0.9)],
            steps: [StepSample(ts: 1_002, counter: 42)],
            sleepState: [SleepStateSample(ts: 1_003, state: 2)],
            ppgHr: [PpgHrSample(ts: 1_004, bpm: 61, conf: 0.8)],
            ppgWaveform: [PpgWaveformSample(ts: 1_005, samples: [7, -8])]
        )
    }

    private func rawBatch(
        deviceId: String,
        trim: Int,
        batchId: String? = nil
    ) -> HistoricalRawBatch {
        HistoricalRawBatch(
            meta: RawBatchMeta(
                batchId: batchId ?? "hist-\(deviceId)-\(trim)",
                deviceId: deviceId,
                clockRef: ClockRef(device: 100, wall: 1_700_000_000),
                capturedAt: 1_700_000_001,
                startTs: 1_700_000_000,
                endTs: 1_700_000_005,
                frameCount: frames.count,
                byteSize: frames.reduce(0) { $0 + $1.count }
            ),
            frames: frames,
            protocolMetadata: protocolMetadata,
            historyEndFrame: historyEndFrame
        )
    }

    private func fingerprint(
        deviceId: String? = nil,
        trim: Int,
        chunkEndUnix: Int,
        frames: [[UInt8]]? = nil
    ) throws -> String {
        try WhoopStore.historicalReceivedFrameFingerprint(
            input: HistoricalReceivedFrameFingerprintInput(
                orderedFrames: frames ?? self.frames,
                protocolMetadata: protocolMetadata,
                historyEndFrame: historyEndFrame,
                minReceivedTs: 1_700_000_000,
                maxReceivedTs: 1_700_000_005
            ),
            deviceId: deviceId ?? self.deviceId,
            trim: trim,
            chunkEndUnix: chunkEndUnix
        )
    }

    private func receivedInput(
        frames: [[UInt8]]? = nil,
        minReceivedTs: Int? = 1_700_000_000,
        maxReceivedTs: Int? = 1_700_000_005
    ) -> HistoricalReceivedFrameFingerprintInput {
        HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames ?? self.frames,
            protocolMetadata: protocolMetadata,
            historyEndFrame: historyEndFrame,
            minReceivedTs: minReceivedTs,
            maxReceivedTs: maxReceivedTs
        )
    }

    private func assertJournalError(
        _ expected: HistoricalDataCommitJournalError,
        operation: () async throws -> Void
    ) async throws {
        do {
            try await operation()
            XCTFail("expected (expected)")
        } catch let error as HistoricalDataCommitJournalError {
            XCTAssertEqual(error, expected)
        }
    }

    func testReceivedFrameFingerprintPreservesOrderAndProtocolMetadata() throws {
        let first = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames,
            protocolMetadata: protocolMetadata,
            historyEndFrame: historyEndFrame
        )
        let reordered = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames.reversed(),
            protocolMetadata: protocolMetadata,
            historyEndFrame: historyEndFrame
        )
        let changedMetadata = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames,
            protocolMetadata: Data([0x49, 0x01, 0x02, 0x04]),
            historyEndFrame: historyEndFrame
        )
        let changedRange = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames,
            protocolMetadata: protocolMetadata,
            historyEndFrame: historyEndFrame,
            minReceivedTs: 10,
            maxReceivedTs: 20
        )

        let firstFingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
            input: first, deviceId: deviceId, trim: 1, chunkEndUnix: 2
        )
        let reorderedFingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
            input: reordered, deviceId: deviceId, trim: 1, chunkEndUnix: 2
        )
        let changedMetadataFingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
            input: changedMetadata, deviceId: deviceId, trim: 1, chunkEndUnix: 2
        )
        let changedRangeFingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
            input: changedRange, deviceId: deviceId, trim: 1, chunkEndUnix: 2
        )

        XCTAssertNotEqual(firstFingerprint, reorderedFingerprint)
        XCTAssertNotEqual(firstFingerprint, changedMetadataFingerprint)
        XCTAssertNotEqual(firstFingerprint, changedRangeFingerprint)
    }

    func testCommitDurablyJoinsRowsRawCursorAndReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)

        let receipt = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 77,
            chunkEndUnix: 1_700_000_005,
            rawBatch: rawBatch(deviceId: deviceId, trim: 77),
            committedAt: 1_700_000_010,
            fingerprint: try fingerprint(trim: 77, chunkEndUnix: 1_700_000_005),
            fingerprintInput: try XCTUnwrap(rawBatch(deviceId: deviceId, trim: 77).fingerprintInput)
        )
        let databaseInstanceId = try await store.databaseInstanceId()
        let snapshotDatabaseInstanceId = try await store.todayHealthSnapshotDatabaseInstanceId()
        let scope = try await store.historicalCursorScope(deviceId: deviceId)
        let cursor = try await store.cursor(scope)
        let rawFrames = try await store.rawFrames(batchId: "hist-strap-a-77")
        let hr = try await store.hrSamples(deviceId: deviceId, from: 0, to: 2_000, limit: 10)
        let receipts = try await store.historicalDataCommitReceipts(deviceId: deviceId)
        let receiptsAfter = try await store.historicalDataCommitReceipts(
            deviceId: deviceId,
            afterGeneration: receipt.generation
        )

        XCTAssertGreaterThan(receipt.generation, 0)
        XCTAssertEqual(receipt.databaseInstanceId, databaseInstanceId)
        XCTAssertEqual(receipt.databaseInstanceId, snapshotDatabaseInstanceId)
        XCTAssertEqual(receipt.deviceId, deviceId)
        XCTAssertEqual(receipt.trim, 77)
        XCTAssertEqual(receipt.rawBatchId, "hist-strap-a-77")
        XCTAssertEqual(receipt.rawStatus, .captured(batchId: "hist-strap-a-77"))
        XCTAssertEqual(receipt.rawRange.source, .retainedRawBatch)
        XCTAssertEqual(receipt.rawRange.minReceivedTs, 1_700_000_000)
        XCTAssertEqual(receipt.rawRange.maxReceivedTs, 1_700_000_005)
        XCTAssertEqual(receipt.rawRange.frameCount, frames.count)
        XCTAssertTrue(receipt.rawRange.hasHistoryEnd)
        XCTAssertFalse(receipt.fingerprint.isEmpty)
        XCTAssertEqual(receipt.lineage, scope.lineage)
        XCTAssertEqual(receipt.cursorEpoch, scope.cursorEpoch)
        XCTAssertEqual(receipt.trimScope, scope.trimScope)
        XCTAssertEqual(receipt.minDecodedTimestamp, 1_000)
        XCTAssertEqual(receipt.maxDecodedTimestamp, 1_005)
        XCTAssertEqual(receipt.touchedDays, ["1970-01-01"])
        XCTAssertEqual(receipt.decodedRows.total, 6)
        XCTAssertEqual(receipt.insertedRows.hr, 1)
        XCTAssertEqual(receipt.insertedRows.gravity, 1)
        XCTAssertEqual(receipt.insertedRows.steps, 1)
        XCTAssertEqual(receipt.insertedRows.sleepState, 1)
        XCTAssertEqual(receipt.insertedRows.ppgHr, 1)
        XCTAssertEqual(receipt.insertedRows.ppgWaveform, 1)
        XCTAssertEqual(receipt.insertedRows.total, 6)

        XCTAssertEqual(cursor, 77)
        XCTAssertEqual(rawFrames, frames)
        XCTAssertEqual(hr, [HRSample(ts: 1_000, bpm: 60), HRSample(ts: 1_004, bpm: 61)])
        XCTAssertEqual(receipts, [receipt])
        XCTAssertEqual(receiptsAfter, [])
    }

    func testReplayReturnsOriginalReceiptWithoutReinsertingRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let raw = rawBatch(deviceId: deviceId, trim: 88)

        let first = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 88,
            chunkEndUnix: 1_700_000_005,
            rawBatch: raw,
            committedAt: 1_700_000_010,
            fingerprint: try fingerprint(trim: 88, chunkEndUnix: 1_700_000_005),
            fingerprintInput: try XCTUnwrap(raw.fingerprintInput)
        )
        let replay = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 88,
            chunkEndUnix: 1_700_000_005,
            rawBatch: raw,
            committedAt: 1_700_000_999,
            fingerprint: try fingerprint(trim: 88, chunkEndUnix: 1_700_000_005),
            fingerprintInput: try XCTUnwrap(raw.fingerprintInput)
        )
        let hr = try await store.hrSamples(deviceId: deviceId, from: 0, to: 2_000, limit: 10)
        let receipts = try await store.historicalDataCommitReceipts(deviceId: deviceId)

        XCTAssertEqual(replay, first)
        XCTAssertEqual(hr.count, 2)
        XCTAssertEqual(receipts, [first])
    }

    func testReplayWithDifferentRawCaptureSettingReturnsOriginalReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let first = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 99,
            chunkEndUnix: 1_700_000_005,
            rawBatch: nil,
            committedAt: 1_700_000_010,
            fingerprint: try fingerprint(trim: 99, chunkEndUnix: 1_700_000_005),
            fingerprintInput: HistoricalReceivedFrameFingerprintInput(
                orderedFrames: frames,
                protocolMetadata: protocolMetadata,
                historyEndFrame: historyEndFrame,
                minReceivedTs: 1_700_000_000,
                maxReceivedTs: 1_700_000_005
            )
        )

        let replay = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 99,
            chunkEndUnix: 1_700_000_005,
            rawBatch: rawBatch(deviceId: deviceId, trim: 99),
            committedAt: 1_700_000_011,
            fingerprint: try fingerprint(trim: 99, chunkEndUnix: 1_700_000_005),
            fingerprintInput: try XCTUnwrap(rawBatch(deviceId: deviceId, trim: 99).fingerprintInput)
        )
        let receipts = try await store.historicalDataCommitReceipts(deviceId: deviceId)
        let rawFrames = try await store.rawFrames(batchId: "hist-strap-a-99")

        XCTAssertEqual(replay, first)
        XCTAssertEqual(receipts, [first])
        XCTAssertEqual(rawFrames, [])
        XCTAssertEqual(first.rawStatus, .disabled)
    }

    func testUnavailableRawCaptureAndReceivedRangeAreDurable() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let input = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames,
            protocolMetadata: protocolMetadata,
            historyEndFrame: historyEndFrame,
            minReceivedTs: 1_700_000_000,
            maxReceivedTs: 1_700_000_005
        )
        let receipt = try await store.commitHistoricalChunk(
            streams: Streams(),
            deviceId: deviceId,
            trim: 1000,
            chunkEndUnix: 1_700_000_005,
            rawBatch: nil,
            committedAt: 1_700_000_010,
            fingerprint: try WhoopStore.historicalReceivedFrameFingerprint(
                input: input, deviceId: deviceId, trim: 1000, chunkEndUnix: 1_700_000_005
            ),
            fingerprintInput: input,
            rawCaptureStatus: .unavailable,
            burst: HistoricalDataCommitBurst(id: "burst-1", sequence: 2, isFinal: true),
            timestampHeal: HistoricalTimestampHeal(
                droppedRecordCount: 2,
                rawRowsDeleted: 3,
                computedRowsDeleted: 4
            )
        )
        let readback = try await store.historicalDataCommitReceipts(deviceId: deviceId)

        XCTAssertEqual(receipt.rawStatus, .unavailable)
        XCTAssertNil(receipt.rawBatchId)
        XCTAssertEqual(receipt.rawRange.source, .receivedFrames)
        XCTAssertEqual(receipt.rawRange.minReceivedTs, 1_700_000_000)
        XCTAssertEqual(receipt.rawRange.maxReceivedTs, 1_700_000_005)
        XCTAssertEqual(receipt.rawRange.frameCount, frames.count)
        XCTAssertEqual(receipt.burst, HistoricalDataCommitBurst(id: "burst-1", sequence: 2, isFinal: true))
        XCTAssertEqual(receipt.timestampHeal.totalRowsDeleted, 7)
        XCTAssertTrue(receipt.timestampHeal.requiresAnalysis)
        XCTAssertEqual(readback, [receipt])
    }

    func testReplayWithDifferentReceivedFingerprintFailsClosed() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        _ = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 1001,
            chunkEndUnix: 1_700_000_005,
            rawBatch: nil,
            committedAt: 1_700_000_010,
            fingerprint: try fingerprint(trim: 1001, chunkEndUnix: 1_700_000_005),
            fingerprintInput: HistoricalReceivedFrameFingerprintInput(
                orderedFrames: frames,
                protocolMetadata: protocolMetadata,
                historyEndFrame: historyEndFrame,
                minReceivedTs: 1_700_000_000,
                maxReceivedTs: 1_700_000_005
            )
        )

        do {
            _ = try await store.commitHistoricalChunk(
                streams: Streams(hr: [HRSample(ts: 1_000, bpm: 61)]),
                deviceId: deviceId,
                trim: 1001,
                chunkEndUnix: 1_700_000_005,
                rawBatch: nil,
                committedAt: 1_700_000_011,
                fingerprint: try fingerprint(
                    trim: 1001,
                    chunkEndUnix: 1_700_000_005,
                    frames: [[0xDE, 0xAD], frames[1]]
                ),
                fingerprintInput: HistoricalReceivedFrameFingerprintInput(
                    orderedFrames: [[0xDE, 0xAD], frames[1]],
                    protocolMetadata: protocolMetadata,
                    historyEndFrame: historyEndFrame,
                    minReceivedTs: 1_700_000_000,
                    maxReceivedTs: 1_700_000_005
                )
            )
            XCTFail("different received-frame content must not replay the old receipt")
        } catch let error as HistoricalDataCommitJournalError {
            XCTAssertEqual(error, .conflictingFingerprintReplay)
        }
    }

    func testReplayUsesReceivedFingerprintWhenDecodedRowsVary() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let input = HistoricalReceivedFrameFingerprintInput(
            orderedFrames: frames,
            protocolMetadata: protocolMetadata,
            historyEndFrame: historyEndFrame
        )
        let receivedFingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
            input: input, deviceId: deviceId, trim: 1002, chunkEndUnix: 1_700_000_005
        )
        let first = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 1002,
            chunkEndUnix: 1_700_000_005,
            rawBatch: nil,
            committedAt: 1_700_000_010,
            fingerprint: receivedFingerprint,
            fingerprintInput: input
        )
        let replay = try await store.commitHistoricalChunk(
            streams: Streams(hr: [HRSample(ts: 1_000, bpm: 61)]),
            deviceId: deviceId,
            trim: 1002,
            chunkEndUnix: 1_700_000_005,
            rawBatch: nil,
            committedAt: 1_700_000_011,
            fingerprint: receivedFingerprint,
            fingerprintInput: input
        )

        XCTAssertEqual(replay, first)
    }

    func testRawBatchIdCollisionFailsBeforeRowsCursorAndReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        try await store.upsertDevice(id: "strap-b", mac: nil, name: nil)
        let sharedBatchId = "shared-history-batch"
        let existing = rawBatch(deviceId: "strap-b", trim: 100, batchId: sharedBatchId)
        try await store.enqueueRawBatch(existing.meta, frames: existing.frames)

        do {
            _ = try await store.commitHistoricalChunk(
                streams: streams,
                deviceId: deviceId,
                trim: 100,
                chunkEndUnix: 1_700_000_005,
                rawBatch: rawBatch(deviceId: deviceId, trim: 100, batchId: sharedBatchId),
                committedAt: 1_700_000_010,
                fingerprint: try fingerprint(trim: 100, chunkEndUnix: 1_700_000_005),
                fingerprintInput: try XCTUnwrap(
                    rawBatch(deviceId: deviceId, trim: 100, batchId: sharedBatchId).fingerprintInput
                )
            )
            XCTFail("an existing raw batch id for another device must fail closed")
        } catch let error as HistoricalDataCommitJournalError {
            XCTAssertEqual(error, .conflictingRawCaptureReplay)
        }

        let scope = try await store.historicalCursorScope(deviceId: deviceId)
        let cursor = try await store.cursor(scope)
        let receipts = try await store.historicalDataCommitReceipts(deviceId: deviceId)
        let hr = try await store.hrSamples(deviceId: deviceId, from: 0, to: 2_000, limit: 10)
        let rawFrames = try await store.rawFrames(batchId: sharedBatchId)

        XCTAssertNil(cursor)
        XCTAssertEqual(receipts, [])
        XCTAssertEqual(hr, [])
        XCTAssertEqual(rawFrames, frames)
    }

    func testExistingMatchingRawBatchCanGainItsReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let raw = rawBatch(deviceId: deviceId, trim: 111)
        try await store.enqueueRawBatch(raw.meta, frames: raw.frames)

        let receipt = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 111,
            chunkEndUnix: 1_700_000_005,
            rawBatch: raw,
            committedAt: 1_700_000_010,
            fingerprint: try fingerprint(trim: 111, chunkEndUnix: 1_700_000_005),
            fingerprintInput: try XCTUnwrap(raw.fingerprintInput)
        )
        let pending = try await store.pendingRawBatches(limit: 10)
        let rawFrames = try await store.rawFrames(batchId: raw.meta.batchId)

        XCTAssertEqual(receipt.rawBatchId, raw.meta.batchId)
        XCTAssertEqual(receipt.insertedRows.total, 6)
        XCTAssertEqual(pending, [raw.meta])
        XCTAssertEqual(rawFrames, frames)
    }

    func testSameTrimForAnotherDeviceGetsAnIndependentReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        try await store.upsertDevice(id: "strap-b", mac: nil, name: nil)

        let a = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 123,
            chunkEndUnix: 1_700_000_005,
            rawBatch: nil,
            committedAt: 1_700_000_010,
            fingerprint: try fingerprint(trim: 123, chunkEndUnix: 1_700_000_005),
            fingerprintInput: HistoricalReceivedFrameFingerprintInput(
                orderedFrames: frames,
                protocolMetadata: protocolMetadata,
                historyEndFrame: historyEndFrame,
                minReceivedTs: 1_700_000_000,
                maxReceivedTs: 1_700_000_005
            )
        )
        let b = try await store.commitHistoricalChunk(
            streams: Streams(hr: [HRSample(ts: 2_000, bpm: 70)]),
            deviceId: "strap-b",
            trim: 123,
            chunkEndUnix: 1_700_000_100,
            rawBatch: nil,
            committedAt: 1_700_000_020,
            fingerprint: try fingerprint(
                deviceId: "strap-b", trim: 123, chunkEndUnix: 1_700_000_100
            ),
            fingerprintInput: HistoricalReceivedFrameFingerprintInput(
                orderedFrames: frames,
                protocolMetadata: protocolMetadata,
                historyEndFrame: historyEndFrame,
                minReceivedTs: 1_700_000_000,
                maxReceivedTs: 1_700_000_005
            )
        )
        let receiptsA = try await store.historicalDataCommitReceipts(deviceId: deviceId)
        let receiptsB = try await store.historicalDataCommitReceipts(deviceId: "strap-b")

        XCTAssertNotEqual(a.receiptId, b.receiptId)
        XCTAssertLessThan(a.generation, b.generation)
        XCTAssertEqual(receiptsA, [a])
        XCTAssertEqual(receiptsB, [b])
    }

    func testInvalidTrimWritesNothing() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)

        do {
            _ = try await store.commitHistoricalChunk(
                streams: streams,
                deviceId: deviceId,
                trim: -1,
                chunkEndUnix: 1_700_000_005,
                rawBatch: nil,
                committedAt: 1_700_000_010,
                fingerprint: String(repeating: "0", count: 64),
                fingerprintInput: try XCTUnwrap(rawBatch(deviceId: deviceId, trim: 0).fingerprintInput)
            )
            XCTFail("negative trim must be rejected before any write")
        } catch let error as HistoricalDataCommitJournalError {
            XCTAssertEqual(error, .invalidTrim)
        }
        let scope = try await store.historicalCursorScope(deviceId: deviceId)
        let cursor = try await store.cursor(scope)
        let receipts = try await store.historicalDataCommitReceipts(deviceId: deviceId)
        let hr = try await store.hrSamples(deviceId: deviceId, from: 0, to: 2_000, limit: 10)

        XCTAssertNil(cursor)
        XCTAssertEqual(receipts, [])
        XCTAssertEqual(hr, [])
    }

    func testCursorScopeSeparatesLineageEpochAndTrimProtocol() async throws {
        let store = try await WhoopStore.inMemory()
        let firstScope = HistoricalCursorScope(deviceId: deviceId, lineage: "lineage-a", cursorEpoch: 0, trimScope: "history")
        let secondScope = HistoricalCursorScope(deviceId: deviceId, lineage: "lineage-b", cursorEpoch: 0, trimScope: "history")
        let nextEpoch = HistoricalCursorScope(deviceId: deviceId, lineage: "lineage-a", cursorEpoch: 1, trimScope: "history")
        let otherProtocol = HistoricalCursorScope(deviceId: deviceId, lineage: "lineage-a", cursorEpoch: 0, trimScope: "other")

        _ = try await store.commitHistoricalChunk(
            streams: Streams(hr: [HRSample(ts: 10, bpm: 60)]), deviceId: deviceId, trim: 10,
            chunkEndUnix: 10, rawBatch: nil, committedAt: 10, scope: firstScope,
            fingerprint: try fingerprint(trim: 10, chunkEndUnix: 10), fingerprintInput: receivedInput())
        _ = try await store.commitHistoricalChunk(
            streams: Streams(hr: [HRSample(ts: 20, bpm: 61)]), deviceId: deviceId, trim: 20,
            chunkEndUnix: 20, rawBatch: nil, committedAt: 20, scope: secondScope,
            fingerprint: try fingerprint(trim: 20, chunkEndUnix: 20), fingerprintInput: receivedInput())
        _ = try await store.commitHistoricalChunk(
            streams: Streams(hr: [HRSample(ts: 30, bpm: 62)]), deviceId: deviceId, trim: 30,
            chunkEndUnix: 30, rawBatch: nil, committedAt: 30, scope: nextEpoch,
            fingerprint: try fingerprint(trim: 30, chunkEndUnix: 30), fingerprintInput: receivedInput())
        _ = try await store.commitHistoricalChunk(
            streams: Streams(hr: [HRSample(ts: 40, bpm: 63)]), deviceId: deviceId, trim: 40,
            chunkEndUnix: 40, rawBatch: nil, committedAt: 40, scope: otherProtocol,
            fingerprint: try fingerprint(trim: 40, chunkEndUnix: 40), fingerprintInput: receivedInput())

        let firstCursor = try await store.cursor(firstScope)
        let secondCursor = try await store.cursor(secondScope)
        let epochCursor = try await store.cursor(nextEpoch)
        let protocolCursor = try await store.cursor(otherProtocol)
        let firstReceipts = try await store.historicalDataCommitReceipts(
            deviceId: deviceId, lineage: firstScope.lineage, cursorEpoch: firstScope.cursorEpoch,
            trimScope: firstScope.trimScope)

        XCTAssertEqual(firstCursor, 10)
        XCTAssertEqual(secondCursor, 20)
        XCTAssertEqual(epochCursor, 30)
        XCTAssertEqual(protocolCursor, 40)
        XCTAssertEqual(firstReceipts.count, 1)
    }

    func testFinalReceiptIsDurableDrainWatermark() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let receipt = try await store.commitHistoricalChunk(
            streams: Streams(), deviceId: deviceId, trim: Int(UInt32.max),
            chunkEndUnix: 1_700_000_005, rawBatch: nil, committedAt: 1_700_000_010,
            fingerprint: try fingerprint(trim: Int(UInt32.max), chunkEndUnix: 1_700_000_005),
            fingerprintInput: receivedInput())

        XCTAssertTrue(receipt.isFinal)
        XCTAssertEqual(receipt.durableWatermark, receipt.watermark)
        let durable = try await store.historicalDataCommitWatermark(deviceId: deviceId)
        XCTAssertEqual(durable, receipt.durableWatermark)
        let drained = try await store.historicalDataCommitReceipts(
            deviceId: deviceId, after: durable)
        XCTAssertEqual(drained, [])
    }

    func testRawStatusAndRangeMustMatchRawBatchAvailability() async throws {
        let store = try await WhoopStore.inMemory()
        let input = receivedInput()
        let commitFingerprint = try WhoopStore.historicalReceivedFrameFingerprint(
            input: input, deviceId: deviceId, trim: 2_000, chunkEndUnix: 1_700_000_005
        )

        try await assertJournalError(.invalidReceipt) {
            _ = try await store.commitHistoricalChunk(
                streams: Streams(), deviceId: deviceId, trim: 2_000,
                chunkEndUnix: 1_700_000_005, rawBatch: nil, committedAt: 1_700_000_010,
                fingerprint: commitFingerprint, fingerprintInput: input,
                rawCaptureStatus: .captured(batchId: "not-retained")
            )
        }
        try await assertJournalError(.invalidReceipt) {
            _ = try await store.commitHistoricalChunk(
                streams: Streams(), deviceId: deviceId, trim: 2_001,
                chunkEndUnix: 1_700_000_005, rawBatch: nil, committedAt: 1_700_000_010,
                fingerprint: try self.fingerprint(trim: 2_001, chunkEndUnix: 1_700_000_005),
                fingerprintInput: input,
                rawRange: HistoricalRawRangeEvidence(source: .retainedRawBatch)
            )
        }

        let raw = rawBatch(deviceId: deviceId, trim: 2_002)
        let rawInput = try XCTUnwrap(raw.fingerprintInput)
        try await assertJournalError(.invalidReceipt) {
            _ = try await store.commitHistoricalChunk(
                streams: Streams(), deviceId: deviceId, trim: 2_002,
                chunkEndUnix: 1_700_000_005, rawBatch: raw, committedAt: 1_700_000_010,
                fingerprint: try self.fingerprint(trim: 2_002, chunkEndUnix: 1_700_000_005),
                fingerprintInput: rawInput, rawCaptureStatus: .disabled
            )
        }
        try await assertJournalError(.invalidReceipt) {
            _ = try await store.commitHistoricalChunk(
                streams: Streams(), deviceId: deviceId, trim: 2_003,
                chunkEndUnix: 1_700_000_005, rawBatch: raw, committedAt: 1_700_000_010,
                fingerprint: try self.fingerprint(trim: 2_003, chunkEndUnix: 1_700_000_005),
                fingerprintInput: rawInput,
                rawRange: rawInput.rawRangeEvidence
            )
        }

        let receipts = try await store.historicalDataCommitReceipts(deviceId: deviceId)
        XCTAssertEqual(receipts, [])
    }

    func testRegisteredDeviceRejectsStaleExplicitLineageAndEpoch() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: deviceId, brand: "WHOOP", model: "WHOOP 5.0", peripheralId: "peripheral-a",
            sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1
        ))
        let initialScope = try await store.historicalCursorScope(deviceId: deviceId)
        let input = receivedInput()
        _ = try await store.commitHistoricalChunk(
            streams: Streams(), deviceId: deviceId, trim: 2_100,
            chunkEndUnix: 1_700_000_005, rawBatch: nil, committedAt: 1_700_000_010,
            fingerprint: try fingerprint(trim: 2_100, chunkEndUnix: 1_700_000_005),
            fingerprintInput: input, lineage: initialScope.lineage,
            cursorEpoch: initialScope.cursorEpoch
        )

        try registry.setPeripheralId(deviceId, peripheralId: "peripheral-b")
        let currentScope = try await store.historicalCursorScope(deviceId: deviceId)
        XCTAssertNotEqual(currentScope.lineage, initialScope.lineage)
        XCTAssertEqual(currentScope.cursorEpoch, initialScope.cursorEpoch + 1)

        try await assertJournalError(.invalidCursorScope) {
            _ = try await store.commitHistoricalChunk(
                streams: Streams(), deviceId: deviceId, trim: 2_101,
                chunkEndUnix: 1_700_000_005, rawBatch: nil, committedAt: 1_700_000_010,
                fingerprint: try fingerprint(trim: 2_101, chunkEndUnix: 1_700_000_005),
                fingerprintInput: input, lineage: initialScope.lineage,
                cursorEpoch: initialScope.cursorEpoch
            )
        }
        try await assertJournalError(.invalidCursorScope) {
            _ = try await store.commitHistoricalChunk(
                streams: Streams(), deviceId: deviceId, trim: 2_102,
                chunkEndUnix: 1_700_000_005, rawBatch: nil, committedAt: 1_700_000_010,
                fingerprint: try fingerprint(trim: 2_102, chunkEndUnix: 1_700_000_005),
                fingerprintInput: input, lineage: currentScope.lineage,
                cursorEpoch: initialScope.cursorEpoch
            )
        }
    }

    func testRawBatchReuseIsScopedByLineageAndEpoch() async throws {
        let store = try await WhoopStore.inMemory()
        let scopeA = HistoricalCursorScope(deviceId: deviceId, lineage: "physical-a", cursorEpoch: 0)
        let scopeB = HistoricalCursorScope(deviceId: deviceId, lineage: "physical-b", cursorEpoch: 1)
        let raw = rawBatch(deviceId: deviceId, trim: 2_200, batchId: "reused-batch")
        let input = try XCTUnwrap(raw.fingerprintInput)

        let first = try await store.commitHistoricalChunk(
            streams: Streams(), deviceId: deviceId, trim: 2_200,
            chunkEndUnix: 1_700_000_005, rawBatch: raw, committedAt: 1_700_000_010,
            scope: scopeA,
            fingerprint: try fingerprint(trim: 2_200, chunkEndUnix: 1_700_000_005),
            fingerprintInput: input
        )
        let second = try await store.commitHistoricalChunk(
            streams: Streams(), deviceId: deviceId, trim: 2_200,
            chunkEndUnix: 1_700_000_005, rawBatch: raw, committedAt: 1_700_000_011,
            scope: scopeB,
            fingerprint: try fingerprint(trim: 2_200, chunkEndUnix: 1_700_000_005),
            fingerprintInput: input
        )

        XCTAssertNotEqual(first.receiptId, second.receiptId)
        let framesA = try await store.rawFrames(
            batchId: raw.meta.batchId, lineage: scopeA.lineage, cursorEpoch: scopeA.cursorEpoch
        )
        let framesB = try await store.rawFrames(
            batchId: raw.meta.batchId, lineage: scopeB.lineage, cursorEpoch: scopeB.cursorEpoch
        )
        XCTAssertEqual(framesA, frames)
        XCTAssertEqual(framesB, frames)
        let pending = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(Set(pending.map(\.lineage)), Set([scopeA.lineage, scopeB.lineage]))
    }

    func testWatermarkCarriesDatabaseInstanceAndCannotDrainAnotherDatabase() async throws {
        let firstStore = try await WhoopStore.inMemory()
        let first = try await firstStore.commitHistoricalChunk(
            streams: Streams(), deviceId: deviceId, trim: 2_300,
            chunkEndUnix: 1_700_000_005, rawBatch: nil, committedAt: 1_700_000_010,
            fingerprint: try fingerprint(trim: 2_300, chunkEndUnix: 1_700_000_005),
            fingerprintInput: receivedInput()
        )
        let watermark = first.durableWatermark
        XCTAssertEqual(watermark.databaseInstanceId, first.databaseInstanceId)

        let replacementStore = try await WhoopStore.inMemory()
        let replacement = try await replacementStore.commitHistoricalChunk(
            streams: Streams(), deviceId: deviceId, trim: 2_300,
            chunkEndUnix: 1_700_000_005, rawBatch: nil, committedAt: 1_700_000_011,
            fingerprint: try fingerprint(trim: 2_300, chunkEndUnix: 1_700_000_005),
            fingerprintInput: receivedInput()
        )
        XCTAssertNotEqual(replacement.databaseInstanceId, watermark.databaseInstanceId)
        let drained = try await replacementStore.historicalDataCommitReceipts(
            deviceId: deviceId, after: watermark
        )
        XCTAssertEqual(drained, [])
    }
}
