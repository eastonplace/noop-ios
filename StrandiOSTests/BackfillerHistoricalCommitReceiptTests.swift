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
            let rawBatch: HistoricalRawBatch?
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
                rawBatch: rawBatch,
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
                    ppgWaveform: streams.ppgWaveform.count),
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

    private func bytes(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }

    private func whoop5V20Frame(unix: UInt32 = 1_781_557_000) -> [UInt8] {
        var frame = [UInt8](repeating: 0, count: Whoop5RawOptical.bufferLength)
        frame[0] = 0xAA; frame[1] = 0x01
        let declared = frame.count - 8
        frame[2] = UInt8(declared & 0xFF); frame[3] = UInt8((declared >> 8) & 0xFF)
        frame[4] = 0x01; frame[5] = 0x00; frame[8] = 0x2F; frame[9] = 20; frame[10] = 0x80
        frame[15] = UInt8(unix & 0xFF); frame[16] = UInt8((unix >> 8) & 0xFF)
        frame[17] = UInt8((unix >> 16) & 0xFF); frame[18] = UInt8((unix >> 24) & 0xFF)
        frame[Whoop5RawOptical.blockStart] = 25
        let headerCRC = crc16Modbus(Array(frame[0..<6]))
        frame[6] = UInt8(headerCRC & 0xFF); frame[7] = UInt8((headerCRC >> 8) & 0xFF)
        let payloadEnd = frame.count - 4
        let payloadCRC = crc32(Array(frame[8..<payloadEnd]))
        frame[payloadEnd] = UInt8(payloadCRC & 0xFF)
        frame[payloadEnd + 1] = UInt8((payloadCRC >> 8) & 0xFF)
        frame[payloadEnd + 2] = UInt8((payloadCRC >> 16) & 0xFF)
        frame[payloadEnd + 3] = UInt8((payloadCRC >> 24) & 0xFF)
        return frame
    }

    private var whoop4V24Frame: [UInt8] {
        bytes(
            "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075" +
            "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403" +
            "200364006400b80bb80b000000000000c25c1a88"
        )
    }

    private var whoop5V18Frame: [UInt8] {
        bytes(
            "aa01740001003fb12f1280733d8401b69f266a66460066025a0265020000000000007b0a8d" +
            "656463ff0012163cf6a439bf2924fd3ed763fe3e3200aa000000000000000000f7000901f1" +
            "0b0007010c020c00000000000000000000000000000000000000000000000100656f1e1e00" +
            "00009d61a7c00000003e862817"
        )
    }

    private var whoop5HistoryEndFrame: [UInt8] {
        bytes("aa011c00010023d1316a0284a3266a0a373d00000041b601001000000000000044d21e3d")
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
                scope: scope,
                trim: 123))
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
        XCTAssertEqual(
            rawEnabled.rawCaptureStatus?.batchId,
            "hist-strap-a|registry-lineage|19|historical-123-\(rawEnabled.fingerprint.prefix(16))"
        )
        XCTAssertEqual(rawEnabled.rawRange?.source, .retainedRawBatch)
        XCTAssertEqual(rawEnabled.rawRange?.minReceivedTs, 1_700_000_000)
        XCTAssertEqual(rawEnabled.rawRange?.maxReceivedTs, 1_700_000_000)

        XCTAssertEqual(rawEnabled.fingerprintInput, rawDisabled.fingerprintInput)
        XCTAssertEqual(rawEnabled.fingerprint, rawDisabled.fingerprint)
    }

    @MainActor
    func testMappedV20IsRetainedWithoutRejectedArchiveOrRowExpansion() async throws {
        let store = SourceCaptureStore()
        var rejectedArchiveCalls = 0
        var ackCount = 0
        var decodedChunks = 0
        let before = puffinCommandFrame(cmd: 0, seq: 1, payload: [0x01], type: 50)
        let frame = whoop5V20Frame()
        let after = puffinCommandFrame(cmd: 0, seq: 2, payload: [0x02], type: 50)
        let backfiller = Backfiller(
            store: store,
            deviceId: "strap-a",
            ackTrim: { _, _, _ in ackCount += 1; return true },
            rejectedSink: { _, _, _ in rejectedArchiveCalls += 1; return true },
            onChunk: { decoded, _ in if decoded { decodedChunks += 1 } })
        backfiller.begin(
            family: .whoop5,
            historicalCursorScope: HistoricalCursorScope(deviceId: "strap-a", lineage: "test-lineage"))

        await backfiller.ingest(before)
        await backfiller.ingest(frame)
        await backfiller.ingest(after)
        await backfiller.ingest(whoop5HistoryEndFrame)

        let committedDetails = await store.commitDetails()
        let details = try XCTUnwrap(committedDetails)
        XCTAssertEqual(rejectedArchiveCalls, 0)
        XCTAssertEqual(ackCount, 1)
        XCTAssertEqual(decodedChunks, 1)
        XCTAssertEqual(backfiller.sessionRowsPersisted, 0)
        XCTAssertEqual(backfiller.sessionMappedRawRecords, 1)
        XCTAssertEqual(details.fingerprintInput.orderedFrames, [before, frame, after])
        XCTAssertEqual(details.rawBatch?.frames, [frame])
        XCTAssertEqual(details.rawBatch?.originalFrameIndexes, [1])
        guard case .materializationRequired(let batchId) = details.rawCaptureStatus else {
            return XCTFail("mapped V20 must commit as durable materialization-required raw")
        }
        XCTAssertEqual(batchId, details.rawBatch?.meta.batchId)
    }

    @MainActor
    func testCorruptHistoricalEnvelopesArchiveButNeverCommitOrAck() async {
        let valid = whoop5V18Frame
        var badHeader = valid
        badHeader[4] ^= 0x01
        var badPayload = valid
        badPayload[20] ^= 0x01
        let missingPayloadCRC = Array(valid.dropLast(4))
        var declaredLengthMismatch = valid
        let declared = Int(declaredLengthMismatch[2]) | (Int(declaredLengthMismatch[3]) << 8)
        declaredLengthMismatch[2] = UInt8((declared + 1) & 0xFF)
        declaredLengthMismatch[3] = UInt8(((declared + 1) >> 8) & 0xFF)
        let repairedHeaderCRC = crc16Modbus(declaredLengthMismatch, 0, 6)
        declaredLengthMismatch[6] = UInt8(repairedHeaderCRC & 0xFF)
        declaredLengthMismatch[7] = UInt8(repairedHeaderCRC >> 8)
        let trailingBytes = valid + [0x99]

        let variants: [(String, [UInt8])] = [
            ("header CRC", badHeader),
            ("payload CRC", badPayload),
            ("missing payload CRC", missingPayloadCRC),
            ("declared length", declaredLengthMismatch),
            ("trailing bytes", trailingBytes),
        ]
        for (label, corrupt) in variants {
            let store = SourceCaptureStore()
            var ackCount = 0
            var archived: [[[UInt8]]] = []
            var failures: [BackfillFailure] = []
            let backfiller = Backfiller(
                store: store,
                deviceId: "strap-a",
                ackTrim: { _, _, _ in ackCount += 1; return true },
                rejectedSink: { frames, _, _ in archived.append(frames); return true },
                onFailure: { failures.append($0) })
            backfiller.begin(
                family: .whoop5,
                historicalCursorScope: HistoricalCursorScope(
                    deviceId: "strap-a", lineage: "test-lineage"))

            await backfiller.ingest(corrupt)
            await backfiller.ingest(whoop5HistoryEndFrame)

            let committedDeviceIds = await store.deviceIds()
            XCTAssertEqual(committedDeviceIds, [], "\(label) must not commit")
            XCTAssertEqual(ackCount, 0, "\(label) must not ACK")
            XCTAssertEqual(archived, [[corrupt]], "\(label) should be retained only as diagnostics")
            XCTAssertEqual(failures, [.integrity(trim: 112_193)], "\(label) must fail closed")
            XCTAssertTrue(backfiller.persistStalled, "\(label) must hold the durable frontier")
        }
    }

    @MainActor
    func testCorruptMetadataEnvelopeCannotBeWashedAwayByValidEnd() async {
        let store = SourceCaptureStore()
        var ackCount = 0
        var rejectedArchiveCalls = 0
        var failures: [BackfillFailure] = []
        var corruptStart = frameFromPayload([], type: 49, seq: 0, cmd: 1)
        corruptStart[3] ^= 0x01
        let backfiller = Backfiller(
            store: store,
            deviceId: "strap-a",
            ackTrim: { _, _, _ in ackCount += 1; return true },
            rejectedSink: { _, _, _ in rejectedArchiveCalls += 1; return true },
            onFailure: { failures.append($0) })
        backfiller.begin(
            family: .whoop4,
            historicalCursorScope: HistoricalCursorScope(
                deviceId: "strap-a", lineage: "test-lineage"))

        await backfiller.ingest(corruptStart)
        await backfiller.ingest(whoop4V24Frame)
        await backfiller.ingest(historyEndFrame(trim: 126))

        let committedDeviceIds = await store.deviceIds()
        XCTAssertEqual(committedDeviceIds, [])
        XCTAssertEqual(ackCount, 0)
        XCTAssertEqual(rejectedArchiveCalls, 0, "metadata is not a rejected sensor record")
        XCTAssertEqual(failures, [.integrity(trim: 126)])
        XCTAssertTrue(backfiller.persistStalled)
    }

    @MainActor
    func testExactReplayAcksWithoutPublishingOrCountingFreshProgress() async throws {
        let store = try await WhoopStore.inMemory()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: "strap-a",
            brand: "WHOOP",
            model: "WHOOP 4.0",
            peripheralId: "peripheral-a",
            sourceKind: .liveBLE,
            capabilities: [.hr],
            status: .paired,
            addedAt: 1,
            lastSeenAt: 1))
        let scope = try registry.historicalCursorScope(for: "strap-a")
        var ackCount = 0
        var publishedReceipts: [String] = []
        var acknowledgedOutcomes: [HistoricalCommitOutcome] = []
        let backfiller = Backfiller(
            store: store,
            deviceId: "strap-a",
            ackTrim: { _, _, _ in ackCount += 1; return true },
            onHistoricalCommit: { publishedReceipts.append($0.receiptId) },
            onHistoricalAcknowledged: { _, outcome in acknowledgedOutcomes.append(outcome) },
            extract: { _, _, _, _, _ in
                Streams(hr: [HRSample(ts: 1_781_557_000, bpm: 60)])
            })
        let record = whoop4V24Frame
        let end = historyEndFrame(trim: 321, unix: 1_781_557_001)

        backfiller.begin(family: .whoop4, historicalCursorScope: scope)
        await backfiller.ingest(record)
        await backfiller.ingest(end)
        XCTAssertEqual(backfiller.sessionRowsPersisted, 1)
        XCTAssertEqual(backfiller.sessionDurableMaxTs, 1_781_557_000)

        backfiller.begin(family: .whoop4, historicalCursorScope: scope)
        await backfiller.ingest(record)
        await backfiller.ingest(end)

        XCTAssertEqual(ackCount, 2, "an exact lost-ACK replay remains safe to ACK")
        XCTAssertEqual(publishedReceipts.count, 1, "replay must not trigger analysis or UI publication")
        XCTAssertEqual(acknowledgedOutcomes, [.inserted, .replayed])
        XCTAssertEqual(backfiller.sessionRowsPersisted, 0)
        XCTAssertEqual(backfiller.sessionMappedRawRecords, 0)
        XCTAssertNil(backfiller.sessionDurableMaxTs)
        let receipts = try await store.historicalDataCommitReceipts(deviceId: "strap-a")
        XCTAssertEqual(receipts.count, 1)
    }

    @MainActor
    func testHistoricalChunkParsesEachFrameExactlyOnce() async {
        final class ParseCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let counter = ParseCounter()
        let backfiller = Backfiller(
            store: SourceCaptureStore(),
            deviceId: "strap-a",
            ackTrim: { _, _, _ in true },
            parse: { bytes, family in
                counter.increment()
                return parseFrame(bytes, family: family)
            })
        backfiller.begin(
            family: .whoop5,
            historicalCursorScope: HistoricalCursorScope(deviceId: "strap-a", lineage: "test-lineage"))
        let records = [whoop5V20Frame(unix: 1_781_557_000), whoop5V20Frame(unix: 1_781_557_001)]

        for frame in records { await backfiller.ingest(frame) }
        await backfiller.ingest(whoop5HistoryEndFrame)

        XCTAssertEqual(counter.count, records.count, "reject classification must reuse parsed frames")
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
