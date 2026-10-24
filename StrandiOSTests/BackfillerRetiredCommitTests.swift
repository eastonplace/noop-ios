import XCTest
@testable import NOOP
import WhoopProtocol
import WhoopStore

@MainActor
final class BackfillerRetiredCommitTests: XCTestCase {
    private actor Gate {
        private(set) var waiting = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
            waiting = false
        }
        func open() { continuation?.resume(); continuation = nil }
    }

    /// Pause only after the real SQLite transaction returns its actual durable receipt.
    private actor PausedCommitStore: BackfillStoreWriting {
        let store: WhoopStore
        let gate: Gate
        private var paused = false
        init(store: WhoopStore, gate: Gate) { self.store = store; self.gate = gate }

        func commitHistoricalChunk(
            streams: Streams, deviceId: String, trim: Int, chunkEndUnix: Int,
            rawBatch: HistoricalRawBatch?, committedAt: Int, scope: HistoricalCursorScope,
            fingerprint: String, fingerprintInput: HistoricalReceivedFrameFingerprintInput,
            rawCaptureStatus: HistoricalRawCaptureStatus?, rawRange: HistoricalRawRangeEvidence?,
            burst: HistoricalDataCommitBurst?, timestampHeal: HistoricalTimestampHeal?, isFinal: Bool
        ) async throws -> HistoricalDataCommitReceipt {
            try await commitHistoricalChunkResult(
                streams: streams, deviceId: deviceId, trim: trim, chunkEndUnix: chunkEndUnix,
                rawBatch: rawBatch, committedAt: committedAt, scope: scope, fingerprint: fingerprint,
                fingerprintInput: fingerprintInput, rawCaptureStatus: rawCaptureStatus, rawRange: rawRange,
                burst: burst, timestampHeal: timestampHeal, isFinal: isFinal).receipt
        }

        func commitHistoricalChunkResult(
            streams: Streams, deviceId: String, trim: Int, chunkEndUnix: Int,
            rawBatch: HistoricalRawBatch?, committedAt: Int, scope: HistoricalCursorScope,
            fingerprint: String, fingerprintInput: HistoricalReceivedFrameFingerprintInput,
            rawCaptureStatus: HistoricalRawCaptureStatus?, rawRange: HistoricalRawRangeEvidence?,
            burst: HistoricalDataCommitBurst?, timestampHeal: HistoricalTimestampHeal?, isFinal: Bool
        ) async throws -> HistoricalCommitResult {
            let result = try await store.commitHistoricalChunkResult(
                streams: streams, deviceId: deviceId, trim: trim, chunkEndUnix: chunkEndUnix,
                rawBatch: rawBatch, committedAt: committedAt, scope: scope, fingerprint: fingerprint,
                fingerprintInput: fingerprintInput, rawCaptureStatus: rawCaptureStatus, rawRange: rawRange,
                burst: burst, timestampHeal: timestampHeal, isFinal: isFinal)
            if result.outcome == .inserted, !paused {
                paused = true
                await gate.wait()
            }
            return result
        }

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int, spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            try await store.insert(streams, deviceId: deviceId)
        }
        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            try await store.enqueueRawBatch(meta, frames: frames)
        }
        func setCursor(_ name: String, _ value: Int) async throws { try await store.setCursor(name, value) }
        func cursor(_ name: String) async throws -> Int? { try await store.cursor(name) }
    }

    private func source(in store: WhoopStore, id: String = "strap-a") throws -> HistoricalCursorScope {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: id, brand: "WHOOP", model: "WHOOP 4.0", peripheralId: "peripheral-\(id)",
            sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        return try registry.historicalCursorScope(for: id)
    }

    private var record: [UInt8] {
        let hex = "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075"
            + "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403"
            + "200364006400b80bb80b000000000000c25c1a88"
        return stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    private var end: [UInt8] {
        func le32(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        return frameFromPayload(le32(1_781_557_001) + [0, 0] + le32(0) + le32(321), type: 49, seq: 0, cmd: 2)
    }

    func testDurableCommitReturningAfterRetirementNotifiesItsOriginalScopeWithoutAckOrProgress() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = try source(in: store)
        let gate = Gate()
        let paused = PausedCommitStore(store: store, gate: gate)
        var retired: [HistoricalCommitContext] = []
        var current: [HistoricalCommitContext] = []
        var ackCount = 0
        let backfiller = Backfiller(
            store: paused, deviceId: "strap-a", ackTrim: { _, _, _ in ackCount += 1; return true },
            onHistoricalCommitContext: { current.append($0) },
            onRetiredHistoricalCommitContext: { retired.append($0) },
            extract: { _, _, _, _, _, _ in Streams(hr: [HRSample(ts: 1_781_557_000, bpm: 60)]) })
        XCTAssertTrue(backfiller.begin(family: .whoop4, historicalCursorScope: scope))
        let transfer = Task { await backfiller.ingest(record); await backfiller.ingest(end) }
        while !(await gate.waiting) { await Task.yield() }
        let receiptsBeforeRetirement = try await store.historicalDataCommitReceipts(deviceId: "strap-a")
        XCTAssertEqual(receiptsBeforeRetirement.count, 1, "the real SQLite commit already completed")

        backfiller.timeoutFired() // The operation used by BLEManager.retireConnectionState.
        await gate.open()
        await transfer.value

        XCTAssertEqual(retired.count, 1, "retirement must not strand a committed receipt without a durable-work signal")
        XCTAssertEqual(retired.first?.receipt, receiptsBeforeRetirement.first)
        XCTAssertEqual(retired.first?.sourceIdentity.deviceId, "strap-a")
        XCTAssertEqual(retired.first?.sourceIdentity.lineage, scope.lineage)
        XCTAssertTrue(current.isEmpty, "retired work is not current-session progress")
        XCTAssertEqual(ackCount, 0, "retirement cannot authorize a trim")
        XCTAssertEqual(backfiller.sessionRowsPersisted, 0)
        XCTAssertNil(backfiller.sessionDurableMaxTs)
        XCTAssertNil(backfiller.lastAckedTrim)

        XCTAssertTrue(backfiller.begin(family: .whoop4, historicalCursorScope: scope))
        await backfiller.ingest(record)
        await backfiller.ingest(end)
        XCTAssertEqual(retired.count, 1, "an exact replay cannot duplicate the inserted receipt notification")
        XCTAssertTrue(current.isEmpty)
        XCTAssertEqual(ackCount, 1, "only the later admitted replay may ACK")
    }

    func testReplacementSessionCannotRelabelLateReceiptOrReceiveItsProgress() async throws {
        let store = try await WhoopStore.inMemory()
        let scopeA = try source(in: store)
        let scopeB = try source(in: store, id: "strap-b")
        let gate = Gate()
        var retired: [HistoricalCommitContext] = []
        var ackCount = 0
        let backfiller = Backfiller(
            store: PausedCommitStore(store: store, gate: gate), deviceId: "strap-a",
            ackTrim: { _, _, _ in ackCount += 1; return true },
            onRetiredHistoricalCommitContext: { retired.append($0) },
            extract: { _, _, _, _, _, _ in Streams(hr: [HRSample(ts: 1_781_557_000, bpm: 60)]) })
        XCTAssertTrue(backfiller.begin(family: .whoop4, historicalCursorScope: scopeA))
        let transfer = Task { await backfiller.ingest(record); await backfiller.ingest(end) }
        while !(await gate.waiting) { await Task.yield() }
        backfiller.timeoutFired()
        backfiller.deviceId = "strap-b"
        XCTAssertTrue(backfiller.begin(family: .whoop4, historicalCursorScope: scopeB))
        await gate.open()
        await transfer.value

        XCTAssertEqual(retired.count, 1)
        XCTAssertEqual(retired.first?.receipt.deviceId, "strap-a")
        XCTAssertEqual(retired.first?.sourceIdentity.lineage, scopeA.lineage)
        XCTAssertEqual(backfiller.historicalCursorScope, scopeB)
        XCTAssertTrue(backfiller.isBackfilling)
        XCTAssertEqual(backfiller.sessionRowsPersisted, 0)
        XCTAssertNil(backfiller.sessionDurableMaxTs)
        XCTAssertNil(backfiller.lastAckedTrim)
        XCTAssertEqual(ackCount, 0)
        let replacementReceipts = try await store.historicalDataCommitReceipts(deviceId: "strap-b")
        XCTAssertTrue(replacementReceipts.isEmpty)
    }

    func testRetirementBeforeCommitCannotCreateAReceiptNotificationOrAck() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = try source(in: store)
        let gate = Gate()
        var retired: [HistoricalCommitContext] = []
        var ackCount = 0
        let backfiller = Backfiller(
            store: store, deviceId: "strap-a", ackTrim: { _, _, _ in ackCount += 1; return true },
            onRetiredHistoricalCommitContext: { retired.append($0) },
            beforeHistoricalCommit: { await gate.wait() },
            extract: { _, _, _, _, _, _ in Streams(hr: [HRSample(ts: 1_781_557_000, bpm: 60)]) })
        XCTAssertTrue(backfiller.begin(family: .whoop4, historicalCursorScope: scope))
        let transfer = Task { await backfiller.ingest(record); await backfiller.ingest(end) }
        while !(await gate.waiting) { await Task.yield() }
        backfiller.timeoutFired()
        await gate.open()
        await transfer.value

        let receipts = try await store.historicalDataCommitReceipts(deviceId: "strap-a")
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertTrue(retired.isEmpty)
        XCTAssertEqual(ackCount, 0)
    }

    func testCurrentCommitUsesOnlyItsExistingCallbackAndProgress() async throws {
        let store = try await WhoopStore.inMemory()
        let scope = try source(in: store)
        var retired: [HistoricalCommitContext] = []
        var current: [HistoricalCommitContext] = []
        var ackCount = 0
        let backfiller = Backfiller(
            store: store, deviceId: "strap-a", ackTrim: { _, _, _ in ackCount += 1; return true },
            onHistoricalCommitContext: { current.append($0) },
            onRetiredHistoricalCommitContext: { retired.append($0) },
            extract: { _, _, _, _, _, _ in Streams(hr: [HRSample(ts: 1_781_557_000, bpm: 60)]) })
        XCTAssertTrue(backfiller.begin(family: .whoop4, historicalCursorScope: scope))
        await backfiller.ingest(record)
        await backfiller.ingest(end)

        XCTAssertEqual(current.count, 1)
        XCTAssertTrue(retired.isEmpty)
        XCTAssertEqual(ackCount, 1)
        XCTAssertEqual(backfiller.sessionRowsPersisted, 1)
        XCTAssertEqual(backfiller.sessionDurableMaxTs, 1_781_557_000)
    }
}
