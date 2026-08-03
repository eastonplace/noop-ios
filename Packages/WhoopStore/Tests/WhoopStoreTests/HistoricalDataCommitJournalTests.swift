import XCTest
import WhoopProtocol
@testable import WhoopStore

final class HistoricalDataCommitJournalTests: XCTestCase {
    private let deviceId = "strap-a"
    private let frames: [[UInt8]] = [
        [0xAA, 0x18, 0x00, 0xFF, 0x28, 0x02],
        [0xAA, 0x0C, 0x00, 0xFC, 0x24, 0x24],
    ]

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
            frames: frames
        )
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
            committedAt: 1_700_000_010
        )
        let databaseInstanceId = try await store.databaseInstanceId()
        let snapshotDatabaseInstanceId = try await store.todayHealthSnapshotDatabaseInstanceId()
        let cursor = try await store.cursor("strap_trim")
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
            committedAt: 1_700_000_010
        )
        let replay = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 88,
            chunkEndUnix: 1_700_000_005,
            rawBatch: raw,
            committedAt: 1_700_000_999
        )
        let hr = try await store.hrSamples(deviceId: deviceId, from: 0, to: 2_000, limit: 10)
        let receipts = try await store.historicalDataCommitReceipts(deviceId: deviceId)

        XCTAssertEqual(replay, first)
        XCTAssertEqual(hr.count, 2)
        XCTAssertEqual(receipts, [first])
    }

    func testReplayWithDifferentRawCaptureFailsClosed() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: deviceId, mac: nil, name: nil)
        let first = try await store.commitHistoricalChunk(
            streams: streams,
            deviceId: deviceId,
            trim: 99,
            chunkEndUnix: 1_700_000_005,
            rawBatch: nil,
            committedAt: 1_700_000_010
        )

        do {
            _ = try await store.commitHistoricalChunk(
                streams: streams,
                deviceId: deviceId,
                trim: 99,
                chunkEndUnix: 1_700_000_005,
                rawBatch: rawBatch(deviceId: deviceId, trim: 99),
                committedAt: 1_700_000_011
            )
            XCTFail("raw-capture mismatch must not silently reuse a receipt")
        } catch let error as HistoricalDataCommitJournalError {
            XCTAssertEqual(error, .conflictingRawCaptureReplay)
        }
        let receipts = try await store.historicalDataCommitReceipts(deviceId: deviceId)
        let rawFrames = try await store.rawFrames(batchId: "hist-strap-a-99")

        XCTAssertEqual(receipts, [first])
        XCTAssertEqual(rawFrames, [])
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
                committedAt: 1_700_000_010
            )
            XCTFail("an existing raw batch id for another device must fail closed")
        } catch let error as HistoricalDataCommitJournalError {
            XCTAssertEqual(error, .conflictingRawCaptureReplay)
        }

        let cursor = try await store.cursor("strap_trim")
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
            committedAt: 1_700_000_010
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
            committedAt: 1_700_000_010
        )
        let b = try await store.commitHistoricalChunk(
            streams: Streams(hr: [HRSample(ts: 2_000, bpm: 70)]),
            deviceId: "strap-b",
            trim: 123,
            chunkEndUnix: 1_700_000_100,
            rawBatch: nil,
            committedAt: 1_700_000_020
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
                committedAt: 1_700_000_010
            )
            XCTFail("negative trim must be rejected before any write")
        } catch let error as HistoricalDataCommitJournalError {
            XCTAssertEqual(error, .invalidTrim)
        }
        let cursor = try await store.cursor("strap_trim")
        let receipts = try await store.historicalDataCommitReceipts(deviceId: deviceId)
        let hr = try await store.hrSamples(deviceId: deviceId, from: 0, to: 2_000, limit: 10)

        XCTAssertNil(cursor)
        XCTAssertEqual(receipts, [])
        XCTAssertEqual(hr, [])
    }
}
