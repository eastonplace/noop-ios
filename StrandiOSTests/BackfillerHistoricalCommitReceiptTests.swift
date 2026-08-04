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
        struct CommitDetails: Sendable {
            let scope: HistoricalCursorScope
            let fingerprint: String
            let fingerprintInput: HistoricalReceivedFrameFingerprintInput
            let rawCaptureStatus: HistoricalRawCaptureStatus?
            let rawRange: HistoricalRawRangeEvidence?
        }

        private var committedDeviceIds: [String] = []
        private var lastCommitDetails: CommitDetails?

        func commitHistoricalChunk(
            streams: Streams,
            deviceId: String,
            trim: Int,
            chunkEndUnix: Int,
            rawBatch: HistoricalRawBatch?,
            committedAt: Int,
            scope: HistoricalCursorScope,
            fingerprint: String,
            fingerprintInput: HistoricalReceivedFrameFingerprintInput,
            rawCaptureStatus: HistoricalRawCaptureStatus?,
            rawRange: HistoricalRawRangeEvidence?,
            burst: HistoricalDataCommitBurst?,
            timestampHeal: HistoricalTimestampHeal?,
            isFinal: Bool
        ) async throws -> HistoricalDataCommitReceipt {
            committedDeviceIds.append(deviceId)
            lastCommitDetails = CommitDetails(
                scope: scope,
                fingerprint: fingerprint,
                fingerprintInput: fingerprintInput,
                rawCaptureStatus: rawCaptureStatus,
                rawRange: rawRange)
            return HistoricalDataCommitReceipt(
                receiptId: "source-\(trim)",
                generation: Int64(trim),
                databaseInstanceId: "test-db",
                deviceId: deviceId,
                trim: trim,
                chunkEndUnix: chunkEndUnix,
                committedAt: committedAt,
                rawBatchId: rawBatch?.meta.batchId,
                insertedRows: HistoricalStreamInsertCounts(hr: 1),
                fingerprint: fingerprint,
                lineage: scope.lineage,
                cursorEpoch: scope.cursorEpoch,
                trimScope: scope.trimScope,
                rawStatus: rawCaptureStatus,
                rawRange: rawRange ?? fingerprintInput.rawRangeEvidence,
                burst: burst,
                timestampHeal: timestampHeal,
                isFinal: isFinal
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

        func commitDetails() -> CommitDetails? { lastCommitDetails }
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
            committedAt: Int,
            scope: HistoricalCursorScope,
            fingerprint: String,
            fingerprintInput: HistoricalReceivedFrameFingerprintInput,
            rawCaptureStatus: HistoricalRawCaptureStatus?,
            rawRange: HistoricalRawRangeEvidence?,
            burst: HistoricalDataCommitBurst?,
            timestampHeal: HistoricalTimestampHeal?,
            isFinal: Bool
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
                ),
                fingerprint: fingerprint,
                lineage: scope.lineage,
                cursorEpoch: scope.cursorEpoch,
                trimScope: scope.trimScope,
                rawStatus: rawCaptureStatus,
                rawRange: rawRange ?? fingerprintInput.rawRangeEvidence,
                burst: burst,
                timestampHeal: timestampHeal,
                isFinal: isFinal
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
    private func commitDetails(enableRawCapture: Bool) async -> SourceCaptureStore.CommitDetails? {
        let store = SourceCaptureStore()
        let source = HistoricalReceiptWatermark.SourceIdentity(
            deviceId: "strap-a", lineage: "ble:A", epoch: 7)
        let scope = HistoricalCursorScope(
            deviceId: "strap-a", lineage: "registry-lineage", cursorEpoch: 19,
            trimScope: "historical")
        let backfiller = Backfiller(
            store: store,
            deviceId: source.deviceId,
            ackTrim: { _, _, _ in true },
            enableRawCapture: enableRawCapture,
            sourceIdentity: source,
            extract: { _, _, _, _, _ in Streams() })
        backfiller.begin(
            family: .whoop4,
            sourceIdentity: source,
            historicalCursorScope: scope)

        await backfiller.ingest(frameFromPayload([], type: 49, seq: 0, cmd: 1))
        await backfiller.ingest(frameFromPayload([0x01, 0x02, 0x03], type: 47))
        await backfiller.ingest(historyEndFrame(trim: 123))
        return await store.commitDetails()
    }

    @MainActor
    func testSuccessfulCommitPrecedesHistoricalAck() async {
        let ledger = EventLedger()
        let backfiller = Backfiller(
            store: CommitSpy(ledger: ledger),
            deviceId: "strap-a",
            ackTrim: { _, _, _ in ledger.append("ack"); return true },
            onHistoricalCommit: { _ in ledger.append("receipt") }
        )
        backfiller.begin(
            family: .whoop4,
            historicalCursorScope: HistoricalCursorScope(deviceId: "strap-a", lineage: "test-lineage"))

        await backfiller.ingest(historyEndFrame(trim: 41))

        XCTAssertEqual(ledger.events, ["commit", "receipt", "ack"])
    }

    @MainActor
    func testFailedCommitHoldsHistoricalAck() async {
        let ledger = EventLedger()
        let backfiller = Backfiller(
            store: CommitSpy(ledger: ledger, failuresRemaining: 1),
            deviceId: "strap-a",
            ackTrim: { _, _, _ in ledger.append("ack"); return true },
            onHistoricalCommit: { _ in ledger.append("receipt") }
        )
        backfiller.begin(
            family: .whoop4,
            historicalCursorScope: HistoricalCursorScope(deviceId: "strap-a", lineage: "test-lineage"))

        await backfiller.ingest(historyEndFrame(trim: 42))

        XCTAssertEqual(ledger.events, ["commit"])
        XCTAssertTrue(backfiller.persistStalled)
    }

    @MainActor
    func testUnconfirmedHistoricalAckStallsTheDurableFrontier() async {
        let ledger = EventLedger()
        var requestedScopes: [HistoricalCursorScope] = []
        let scope = HistoricalCursorScope(deviceId: "strap-a", lineage: "test-lineage")
        let backfiller = Backfiller(
            store: CommitSpy(ledger: ledger),
            deviceId: "strap-a",
            ackTrim: { receivedScope, _, _ in
                requestedScopes.append(receivedScope)
                ledger.append("ack")
                return false
            },
            onHistoricalCommit: { _ in ledger.append("receipt") }
        )
        backfiller.begin(family: .whoop4, historicalCursorScope: scope)

        await backfiller.ingest(historyEndFrame(trim: 43))
        await backfiller.ingest(historyEndFrame(trim: 44))

        XCTAssertEqual(requestedScopes, [scope])
        XCTAssertEqual(ledger.events, ["commit", "receipt", "ack"])
        XCTAssertTrue(backfiller.persistStalled)
        XCTAssertNil(backfiller.lastAckedTrim)
    }

    @MainActor
    func testPersistStallPreventsLaterCursorReceiptAndAck() async {
        let ledger = EventLedger()
        let backfiller = Backfiller(
            store: CommitSpy(ledger: ledger, failuresRemaining: 1),
            deviceId: "strap-a",
            ackTrim: { _, _, _ in ledger.append("ack"); return true },
            onHistoricalCommit: { _ in ledger.append("receipt") }
        )
        backfiller.begin(
            family: .whoop4,
            historicalCursorScope: HistoricalCursorScope(deviceId: "strap-a", lineage: "test-lineage"))

        await backfiller.ingest(historyEndFrame(trim: 41))
        await backfiller.ingest(historyEndFrame(trim: 42))

        XCTAssertEqual(ledger.events, ["commit"])
        XCTAssertTrue(backfiller.persistStalled)
    }

    @MainActor
    func testRawDisabledCommitUsesExactReceivedFrameIdentityAndRange() async throws {
        let store = SourceCaptureStore()
        let source = HistoricalReceiptWatermark.SourceIdentity(
            deviceId: "strap-a", lineage: "ble:A", epoch: 7)
        let scope = HistoricalCursorScope(
            deviceId: "strap-a", lineage: "registry-lineage", cursorEpoch: 19,
            trimScope: "historical")
        let backfiller = Backfiller(
            store: store,
            deviceId: source.deviceId,
            ackTrim: { _, _, _ in true },
            sourceIdentity: source,
            extract: { _, _, _, _, _ in Streams() })
        backfiller.begin(
            family: .whoop4,
            sourceIdentity: source,
            historicalCursorScope: scope)

        let startFrame = frameFromPayload([], type: 49, seq: 0, cmd: 1)
        let receivedFrame = frameFromPayload([0x01, 0x02, 0x03], type: 47)
        let endFrame = historyEndFrame(trim: 123)
        await backfiller.ingest(startFrame)
        await backfiller.ingest(receivedFrame)
        await backfiller.ingest(endFrame)

        guard let details = await store.commitDetails() else {
            XCTFail("the raw-disabled chunk must produce a commit")
            return
        }
        XCTAssertEqual(details.scope, scope)
        XCTAssertEqual(details.fingerprintInput.orderedFrames, [receivedFrame])
        XCTAssertEqual(details.fingerprintInput.protocolMetadata, Data(startFrame))
        XCTAssertEqual(details.fingerprintInput.historyEndFrame, Data(endFrame))
        XCTAssertEqual(details.rawCaptureStatus, .disabled)
        XCTAssertEqual(details.rawRange, details.fingerprintInput.rawRangeEvidence)
        XCTAssertEqual(details.rawRange?.source, .receivedFrames)
        XCTAssertEqual(details.rawRange?.frameCount, 1)
        XCTAssertEqual(details.rawRange?.byteCount, receivedFrame.count)
        XCTAssertEqual(
            details.fingerprint,
            try WhoopStore.historicalReceivedFrameFingerprint(
                input: details.fingerprintInput,
                deviceId: "strap-a",
                trim: 123,
                chunkEndUnix: 1_700_000_000))
    }

    @MainActor
    func testRawCaptureTogglePreservesFingerprintForTimestamplessFrames() async throws {
        let rawDisabledDetails = await commitDetails(enableRawCapture: false)
        let rawEnabledDetails = await commitDetails(enableRawCapture: true)
        let rawDisabled = try XCTUnwrap(rawDisabledDetails)
        let rawEnabled = try XCTUnwrap(rawEnabledDetails)

        XCTAssertNil(rawDisabled.fingerprintInput.minReceivedTs)
        XCTAssertNil(rawDisabled.fingerprintInput.maxReceivedTs)
        XCTAssertEqual(rawDisabled.rawCaptureStatus, .disabled)
        XCTAssertEqual(rawDisabled.rawRange?.source, .receivedFrames)
        XCTAssertNil(rawDisabled.rawRange?.minReceivedTs)
        XCTAssertNil(rawDisabled.rawRange?.maxReceivedTs)

        XCTAssertNil(rawEnabled.fingerprintInput.minReceivedTs)
        XCTAssertNil(rawEnabled.fingerprintInput.maxReceivedTs)
        XCTAssertEqual(rawEnabled.rawCaptureStatus?.batchId, "hist-strap-a|registry-lineage|19|historical-123")
        XCTAssertEqual(rawEnabled.rawRange?.source, .retainedRawBatch)
        XCTAssertEqual(rawEnabled.rawRange?.minReceivedTs, 1_700_000_000)
        XCTAssertEqual(rawEnabled.rawRange?.maxReceivedTs, 1_700_000_000)

        XCTAssertEqual(rawEnabled.fingerprintInput, rawDisabled.fingerprintInput)
        XCTAssertEqual(rawEnabled.fingerprint, rawDisabled.fingerprint)
    }

    @MainActor
    func testDisplaySourceIdentityCommitsUnderAdmittedRegistryScope() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: "strap-a",
            brand: "WHOOP",
            model: "WHOOP 5.0",
            peripheralId: "peripheral-a",
            sourceKind: .liveBLE,
            capabilities: [.hr],
            status: .paired,
            addedAt: 1,
            lastSeenAt: 1))
        let registryScope = try registry.historicalCursorScope(for: "strap-a")
        let displaySource = HistoricalReceiptWatermark.SourceIdentity(
            deviceId: "strap-a", lineage: "ble:peripheral-a", epoch: 44)
        var ackCount = 0
        let backfiller = Backfiller(
            store: store,
            deviceId: "strap-a",
            ackTrim: { _, _, _ in ackCount += 1; return true },
            sourceIdentity: displaySource,
            extract: { _, _, _, _, _ in Streams() })
        backfiller.begin(
            family: .whoop4,
            sourceIdentity: displaySource,
            historicalCursorScope: registryScope)

        await backfiller.ingest(historyEndFrame(trim: 125))

        XCTAssertEqual(ackCount, 1)
        let receipts = try await store.historicalDataCommitReceipts(deviceId: "strap-a")
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts.first?.lineage, registryScope.lineage)
        XCTAssertEqual(receipts.first?.cursorEpoch, registryScope.cursorEpoch)
        XCTAssertEqual(receipts.first?.trimScope, registryScope.trimScope)
        XCTAssertNotEqual(receipts.first?.lineage, displaySource.lineage)
    }

    @MainActor
    func testStaleLineageAndEpochAreRejectedBeforeHistoricalAck() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: "strap-a",
            brand: "WHOOP",
            model: "WHOOP 5.0",
            peripheralId: "peripheral-a",
            sourceKind: .liveBLE,
            capabilities: [.hr],
            status: .paired,
            addedAt: 1,
            lastSeenAt: 1))
        let initialScope = try registry.historicalCursorScope(for: "strap-a")
        let source = HistoricalReceiptWatermark.SourceIdentity(
            deviceId: "strap-a",
            lineage: "ble:peripheral-a",
            epoch: 44)
        var ackCount = 0
        let backfiller = Backfiller(
            store: store,
            deviceId: source.deviceId,
            ackTrim: { _, _, _ in ackCount += 1; return true },
            sourceIdentity: source)
        backfiller.begin(
            family: .whoop4,
            sourceIdentity: source,
            historicalCursorScope: initialScope)

        try registry.setPeripheralId("strap-a", peripheralId: "peripheral-b")
        await backfiller.ingest(historyEndFrame(trim: 124))

        XCTAssertEqual(ackCount, 0)
        XCTAssertTrue(backfiller.persistStalled)
        let receipts = try await store.historicalDataCommitReceipts(deviceId: "strap-a")
        XCTAssertEqual(receipts, [])
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
            ackTrim: { _, _, _ in true },
            onHistoricalCommitContext: { contexts.append($0) },
            beforeHistoricalCommit: { await gate.wait() },
            sourceIdentity: sourceA,
            extract: { _, _, _, _, _ in Streams() })
        let scopeA = HistoricalCursorScope(
            deviceId: "strap-a", lineage: "registry-A", cursorEpoch: 11)
        backfiller.begin(
            family: .whoop4,
            sourceIdentity: sourceA,
            historicalCursorScope: scopeA)

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
        XCTAssertEqual(
            contexts.first?.sourceIdentity,
            HistoricalReceiptWatermark.SourceIdentity(
                deviceId: "strap-a", lineage: scopeA.lineage, epoch: Int64(scopeA.cursorEpoch),
                trimScope: scopeA.trimScope))
        XCTAssertEqual(contexts.first?.receipt.deviceId, "strap-a")
    }

    @MainActor
    func testSupersededSessionCannotCommitOrAckAfterSuspension() async {
        let gate = AsyncGate()
        let store = SourceCaptureStore()
        var ackedScopes: [HistoricalCursorScope] = []
        let scopeA = HistoricalCursorScope(deviceId: "strap-a", lineage: "registry-A", cursorEpoch: 1)
        let scopeB = HistoricalCursorScope(deviceId: "strap-b", lineage: "registry-B", cursorEpoch: 2)
        let backfiller = Backfiller(
            store: store,
            deviceId: "strap-a",
            ackTrim: { scope, _, _ in
                ackedScopes.append(scope)
                return true
            },
            beforeHistoricalCommit: { await gate.wait() },
            extract: { _, _, _, _, _ in Streams() })
        backfiller.begin(family: .whoop4, historicalCursorScope: scopeA)

        let suspendedChunk = Task { @MainActor in
            await backfiller.ingest(historyEndFrame(trim: 123))
        }
        while !(await gate.waiting) {
            await Task.yield()
        }

        backfiller.begin(family: .whoop4, historicalCursorScope: scopeB)
        await gate.open()
        await suspendedChunk.value

        let committedDeviceIds = await store.deviceIds()
        XCTAssertEqual(committedDeviceIds, [])
        XCTAssertEqual(ackedScopes, [])
        XCTAssertFalse(backfiller.persistStalled)
        XCTAssertNil(backfiller.lastAckedTrim)
    }
}
