import XCTest
@testable import NOOP
import WhoopProtocol
import WhoopStore

final class BackfillerHistoricalCommitReceiptTests: XCTestCase {
    @MainActor
    private final class EventLedger {
        private(set) var events: [String] = []

        func append(_ event: String) {
            events.append(event)
        }
    }

    private struct CommitFailure: Error, Sendable {}

    private actor AsyncGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var waiting = false

        func wait() async {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
            waiting = false
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private actor SourceCaptureStore: BackfillStoreWriting {
        private var committedDeviceIds: [String] = []

        func commitHistoricalChunk(
            streams: Streams,
            deviceId: String,
            trim: Int,
            chunkEndUnix: Int,
            rawBatch: HistoricalRawBatch?,
            committedAt: Int
        ) async throws -> HistoricalDataCommitReceipt {
            committedDeviceIds.append(deviceId)
            return HistoricalDataCommitReceipt(
                receiptId: "source-\(trim)",
                generation: Int64(trim),
                databaseInstanceId: "test-db",
                deviceId: deviceId,
                trim: trim,
                chunkEndUnix: chunkEndUnix,
                committedAt: committedAt,
                rawBatchId: rawBatch?.meta.batchId,
                insertedRows: HistoricalStreamInsertCounts(hr: 1)
            )
        }

        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }

        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }

        func deviceIds() -> [String] { committedDeviceIds }
    }

    private actor CommitSpy: BackfillStoreWriting {
        private let ledger: EventLedger
        private var failuresRemaining: Int

        init(ledger: EventLedger, failuresRemaining: Int = 0) {
            self.ledger = ledger
            self.failuresRemaining = failuresRemaining
        }

        func commitHistoricalChunk(
            streams: Streams,
            deviceId: String,
            trim: Int,
            chunkEndUnix: Int,
            rawBatch: HistoricalRawBatch?,
            committedAt: Int
        ) async throws -> HistoricalDataCommitReceipt {
            await ledger.append("commit")
            if failuresRemaining > 0 {
                failuresRemaining -= 1
                throw CommitFailure()
            }
            return HistoricalDataCommitReceipt(
                receiptId: "receipt-\(trim)",
                generation: Int64(trim),
                databaseInstanceId: "test-db",
                deviceId: deviceId,
                trim: trim,
                chunkEndUnix: chunkEndUnix,
                committedAt: committedAt,
                rawBatchId: rawBatch?.meta.batchId,
                insertedRows: HistoricalStreamInsertCounts(
                    hr: streams.hr.count,
                    rr: streams.rr.count,
                    events: streams.events.count,
                    battery: streams.battery.count,
                    spo2: streams.spo2.count,
                    skinTemp: streams.skinTemp.count,
                    resp: streams.resp.count,
                    gravity: streams.gravity.count,
                    steps: streams.steps.count,
                    sleepState: streams.sleepState.count,
                    ppgHr: streams.ppgHr.count,
                    ppgWaveform: streams.ppgWaveform.count
                )
            )
        }

        @discardableResult
        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            (0, 0, 0, 0, 0, 0, 0, 0)
        }

        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {}
        func setCursor(_ name: String, _ value: Int) async throws {}
        func cursor(_ name: String) async throws -> Int? { nil }
    }

    private func historyEndFrame(trim: UInt32, unix: UInt32 = 1_700_000_000) -> [UInt8] {
        func le32(_ value: UInt32) -> [UInt8] {
            [
                UInt8(value & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 24) & 0xFF),
            ]
        }
        return frameFromPayload(le32(unix) + [0, 0] + le32(0) + le32(trim), type: 49, seq: 0, cmd: 2)
    }

    @MainActor
    func testSuccessfulCommitPrecedesHistoricalAck() async {
        let ledger = EventLedger()
        let backfiller = Backfiller(
            store: CommitSpy(ledger: ledger),
            deviceId: "strap-a",
            ackTrim: { _, _ in ledger.append("ack") },
            onHistoricalCommit: { _ in ledger.append("receipt") }
        )
        backfiller.begin(family: .whoop4)

        await backfiller.ingest(historyEndFrame(trim: 41))

        XCTAssertEqual(ledger.events, ["commit", "receipt", "ack"])
    }

    @MainActor
    func testFailedCommitHoldsHistoricalAck() async {
        let ledger = EventLedger()
        let backfiller = Backfiller(
            store: CommitSpy(ledger: ledger, failuresRemaining: 1),
            deviceId: "strap-a",
            ackTrim: { _, _ in ledger.append("ack") },
            onHistoricalCommit: { _ in ledger.append("receipt") }
        )
        backfiller.begin(family: .whoop4)

        await backfiller.ingest(historyEndFrame(trim: 42))

        XCTAssertEqual(ledger.events, ["commit"])
        XCTAssertTrue(backfiller.persistStalled)
    }

    @MainActor
    func testPersistStallPreventsLaterCursorReceiptAndAck() async {
        let ledger = EventLedger()
        let backfiller = Backfiller(
            store: CommitSpy(ledger: ledger, failuresRemaining: 1),
            deviceId: "strap-a",
            ackTrim: { _, _ in ledger.append("ack") },
            onHistoricalCommit: { _ in ledger.append("receipt") }
        )
        backfiller.begin(family: .whoop4)

        await backfiller.ingest(historyEndFrame(trim: 41))
        await backfiller.ingest(historyEndFrame(trim: 42))

        XCTAssertEqual(ledger.events, ["commit"])
        XCTAssertTrue(backfiller.persistStalled)
    }

    @MainActor
    func testSourceSwitchWhileDetachedDecodeIsPausedUsesAdmittedSource() async {
        let gate = AsyncGate()
        let store = SourceCaptureStore()
        let sourceA = HistoricalReceiptWatermark.SourceIdentity(
            deviceId: "strap-a", lineage: "ble:A", epoch: 11)
        var contexts: [HistoricalCommitContext] = []
        let backfiller = Backfiller(
            store: store,
            deviceId: "strap-a",
            ackTrim: { _, _ in },
            onHistoricalCommitContext: { contexts.append($0) },
            beforeHistoricalCommit: { await gate.wait() },
            sourceIdentity: sourceA,
            extract: { _, _, _, _, _ in Streams() })
        backfiller.begin(family: .whoop4, sourceIdentity: sourceA)

        let historicalRecord = frameFromPayload([0x01, 0x02, 0x03], type: 47)
        let commitTask = Task { @MainActor in
            await backfiller.ingest(historicalRecord)
            await backfiller.ingest(historyEndFrame(trim: 123))
        }
        while !(await gate.waiting) {
            await Task.yield()
        }

        // Simulate SourceCoordinator changing the mutable current source while detached decode is paused.
        backfiller.deviceId = "strap-b"
        await gate.open()
        await commitTask.value

        let committedDeviceIds = await store.deviceIds()
        XCTAssertEqual(committedDeviceIds, ["strap-a"])
        XCTAssertEqual(contexts.count, 1)
        XCTAssertEqual(contexts.first?.sourceIdentity, sourceA)
        XCTAssertEqual(contexts.first?.receipt.deviceId, "strap-a")
    }
}
