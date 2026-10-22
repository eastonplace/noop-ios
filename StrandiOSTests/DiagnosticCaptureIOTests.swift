import XCTest
import CoreBluetooth
import WhoopProtocol
@testable import NOOP

final class DiagnosticCaptureIOTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DiagnosticIO-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testRecorderStreamingJSONMatchesExistingWholeEncoderAndRetriesFailedWrites() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("captures")
        try Data("block directory creation".utf8).write(to: blocked)
        let store = PuffinCaptureFileStore(directory: blocked)
        let frames = [
            PuffinCapturedFrame(frame: DeviceFamily.whoop5ClientHello, characteristic: "fd4b0003", timestampMs: 7, heartRate: 61),
            PuffinCapturedFrame(frame: [0xAA, 0x01, 0x00], characteristic: "quote\"/é\n", timestampMs: 8, heartRate: nil),
        ]
        do {
            _ = try await store.persist(frames)
            XCTFail("a file cannot be used as the capture directory")
        } catch {}
        try FileManager.default.removeItem(at: blocked)
        let firstResult = try await store.persist([])
        let first = try XCTUnwrap(firstResult)
        let expected = PuffinCapture()
        for frame in frames {
            expected.record(frame: frame.frame, char: frame.characteristic, tsMs: frame.timestampMs, hr: frame.heartRate)
        }
        XCTAssertEqual(try Data(contentsOf: first), try expected.encodedJSON())
        let extra = PuffinCapturedFrame(frame: [], characteristic: "fd4b0005", timestampMs: 9, heartRate: 0)
        let secondResult = try await store.persist([extra])
        let second = try XCTUnwrap(secondResult)
        expected.record(frame: extra.frame, char: extra.characteristic, tsMs: extra.timestampMs, hr: extra.heartRate)
        XCTAssertEqual(first, second, "one complete file per recorder lifetime")
        XCTAssertEqual(try Data(contentsOf: second), try expected.encodedJSON())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: blocked.path), [second.lastPathComponent])
    }

    @MainActor
    func testExplicitFlushRetriesWithoutWaitingForAnotherFrame() async throws {
        let live = LiveState()
        let probe = CaptureBatchProbe()
        await probe.releaseFirstBatch()
        let recorder = PuffinFrameRecorder(state: live, enabled: { true }, persist: { await probe.persist($0) })
        recorder.capture(frame: [0xAA], char: CBUUID(string: "FD4B0003"))
        await recorder.flushAndWait()
        await recorder.flushAndWait()
        let batches = await probe.recordedBatches()
        XCTAssertEqual(batches.count, 2, "an explicit retry waits for a new write attempt even without new content")
        XCTAssertEqual(batches.map(\.count), [1, 0])
    }

    @MainActor
    func testRecorderFlushBarrierIncludesFramesAcceptedDuringAnEarlierWrite() async throws {
        let live = LiveState()
        let probe = CaptureBatchProbe()
        let recorder = PuffinFrameRecorder(state: live, enabled: { true }, persist: { await probe.persist($0) })
        for _ in 0..<25 { recorder.capture(frame: [0xAA], char: CBUUID(string: "FD4B0003")) }
        await probe.waitForFirstBatch()
        recorder.capture(frame: [0xBB], char: CBUUID(string: "FD4B0005"))
        XCTAssertEqual(live.puffinCaptureCount, 26, "capture publication remains immediate while IO is suspended")
        let barrier = Task { await recorder.flushAndWait() }
        await Task.yield()
        await probe.releaseFirstBatch()
        await barrier.value
        let batches = await probe.recordedBatches()
        XCTAssertEqual(batches.flatMap { $0 }.map(\.frame), Array(repeating: [0xAA], count: 25) + [[0xBB]])
        XCTAssertEqual(live.puffinCaptureURL?.lastPathComponent, "capture.json")
    }

    func testScheduledDropStreamsRawCompanionWithExactScrubAndKeepsBestEffortLog() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("capture.jsonl")
        let body = String(repeating: "{\"peer\":\"AA:BB:CC:DD:EE:FF\",\"hex\":\"424235415030353339383532\"}\n", count: 3_000)
        try Data(body.utf8).write(to: source)
        let header = ["diagnostic fixture"]
        let expectedLog = LiveState.scheduledExportText(extraHeaderLines: header)
        let log = try await FileExport.saveScheduledExport(to: root, stamp: "fixture", extraHeaderLines: header, captureURL: source)
        XCTAssertEqual(try String(contentsOf: log, encoding: .utf8), expectedLog)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("noop-raw-capture-fixture.json")), Data(LiveState.redactPii(body).utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data(body.utf8))
        let missingLog = try await FileExport.saveScheduledExport(to: root, stamp: "missing", extraHeaderLines: header,
                                                                 captureURL: root.appendingPathComponent("missing.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingLog.path), "a missing optional capture must not discard the log")
    }

    func testTextExportStagesExactBytesWithIndependentOwnership() async throws {
        let text = "NOOP strap log\nUnicode é😴\nA safe line\n"
        let first = try await FileExport.stagedText(text, suggestedName: "same-log.txt")
        let second = try await FileExport.stagedText(text + "next", suggestedName: "same-log.txt")
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        XCTAssertEqual(first.lastPathComponent, "same-log.txt")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), Data(text.utf8))
        XCTAssertEqual(try Data(contentsOf: second), Data((text + "next").utf8))
    }

    func testCancelledScheduledDropDoesNotAcknowledgeOrReplaceExistingLog() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("noop-strap-log-cancelled.txt")
        try Data("keep prior export".utf8).write(to: existing)
        let gate = CaptureBatchProbe()
        let operation = Task {
            await gate.waitForFirstBatch()
            return try await FileExport.saveScheduledExport(to: root, stamp: "cancelled", extraHeaderLines: [], captureURL: nil)
        }
        operation.cancel()
        await gate.releaseFirstBatch()
        do { _ = try await operation.value; XCTFail("cancelled export must not succeed") }
        catch is CancellationError {}
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep prior export")
    }
}

private actor CaptureBatchProbe {
    private var batches: [[PuffinCapturedFrame]] = []
    private var firstStarted = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func persist(_ frames: [PuffinCapturedFrame]) async -> URL? {
        batches.append(frames)
        if batches.count == 1 {
            firstStarted = true
            startedWaiters.forEach { $0.resume() }
            startedWaiters.removeAll()
            if !released { await withCheckedContinuation { releaseWaiter = $0 } }
        }
        return URL(fileURLWithPath: "/tmp/capture.json")
    }
    func waitForFirstBatch() async {
        if firstStarted || released { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }
    func releaseFirstBatch() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
    }
    func recordedBatches() -> [[PuffinCapturedFrame]] { batches }
}
