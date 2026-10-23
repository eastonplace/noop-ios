import XCTest
import WhoopProtocol
import WhoopStore
@testable import NOOP

@MainActor
final class CollectorOwnershipTests: XCTestCase {
    private actor Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var observers: [CheckedContinuation<Void, Never>] = []
        private var entered = false
        private var opened = false

        func wait() async {
            guard !opened else { return }
            entered = true
            observers.forEach { $0.resume() }
            observers.removeAll()
            await withCheckedContinuation { waiter = $0 }
        }

        func waitUntilEntered() async {
            guard !entered else { return }
            await withCheckedContinuation { observers.append($0) }
        }

        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    private actor StoreProbe: StoreWriting {
        struct Write: Sendable {
            let owner: String
            let hr: [HRSample]
            let rr: [RRInterval]
        }
        private struct Failure: Error {}
        private let gate: Gate?
        private var failures: Int
        private let failureOnCall: Int?
        private var attempts = 0
        private(set) var writes: [Write] = []
        private(set) var rawOwners: [String] = []
        private(set) var rawClocks: [ClockRef] = []

        init(gate: Gate? = nil, failures: Int = 0, failureOnCall: Int? = nil) {
            self.gate = gate
            self.failures = failures
            self.failureOnCall = failureOnCall
        }

        func insert(_ streams: Streams, deviceId: String) async throws
            -> (hr: Int, rr: Int, events: Int, battery: Int,
                spo2: Int, skinTemp: Int, resp: Int, gravity: Int) {
            attempts += 1
            let call = attempts
            await gate?.wait()
            if call == failureOnCall { throw Failure() }
            if failures > 0 {
                failures -= 1
                throw Failure()
            }
            writes.append(Write(owner: deviceId, hr: streams.hr, rr: streams.rr))
            return (streams.hr.count, streams.rr.count, streams.events.count,
                    streams.battery.count, streams.spo2.count, streams.skinTemp.count,
                    streams.resp.count, streams.gravity.count)
        }

        func enqueueRawBatch(_ meta: RawBatchMeta, frames: [[UInt8]]) async throws {
            rawOwners.append(meta.deviceId)
            rawClocks.append(meta.clockRef)
        }
    }

    private func collector(_ store: StoreProbe, raw: Bool = false) -> Collector {
        let collector = Collector(
            store: store, deviceId: "strap-a",
            policy: CollectorPolicy(maxFrames: 100, maxInterval: 10_000),
            enableRawCapture: raw, monotonic: { 0 })
        collector.clockRef = ClockRef(device: 1_700_000_000, wall: 1_700_000_000)
        return collector
    }

    private var frame: [UInt8] { frameFromPayload([0], type: 40) }

    func testStandardSamplesKeepTheirIntakeOwnerAcrossSourceSwitch() async {
        let store = StoreProbe()
        let collector = collector(store)
        collector.ingestStandardHR(hr: 80, rr: [750], at: 1_700_000_001)
        collector.deviceId = "strap-b"
        collector.ingestStandardHR(hr: 100, rr: [600], at: 1_700_000_002)
        await collector.flushStandardHR()
        let writes = await store.writes
        XCTAssertEqual(writes.map(\.owner), ["strap-a", "strap-b"])
        XCTAssertEqual(writes.map { $0.hr.map(\.bpm) }, [[80], [100]])
        XCTAssertEqual(writes.map { $0.rr.map(\.rrMs) }, [[750], [600]])
    }

    func testFailedStandardBatchRetriesUnderItsOriginalOwner() async {
        let store = StoreProbe(failures: 1)
        let collector = collector(store)
        collector.ingestStandardHR(hr: 80, rr: [750], at: 1_700_000_001)
        await collector.flushStandardHR()
        collector.deviceId = "strap-b"
        collector.ingestStandardHR(hr: 100, rr: [600], at: 1_700_000_002)
        await collector.flushStandardHR()
        await collector.flushStandardHR()
        let writes = await store.writes
        XCTAssertEqual(writes.map(\.owner), ["strap-a", "strap-b"])
        XCTAssertEqual(writes.flatMap(\.hr).count, 2)
        XCTAssertEqual(writes.flatMap(\.rr).count, 2)
    }

    func testRapidReturnToSameSourcePreservesBatchOrder() async {
        let store = StoreProbe()
        let collector = collector(store)
        for (owner, bpm) in [("strap-a", 80), ("strap-b", 100), ("strap-a", 90)] {
            collector.deviceId = owner
            collector.ingestStandardHR(hr: bpm, rr: [], at: 1_700_000_000 + bpm)
        }
        await collector.flushStandardHR()
        let writes = await store.writes
        XCTAssertEqual(writes.map(\.owner), ["strap-a", "strap-b", "strap-a"])
        XCTAssertEqual(writes.flatMap(\.hr).map(\.bpm), [80, 100, 90])
    }

    func testDecodedAndRawWritesKeepOneOwnerWhenInsertSuspends() async {
        let gate = Gate()
        let store = StoreProbe(gate: gate)
        let collector = collector(store, raw: true)
        collector.ingest(frame)
        let flush = Task { await collector.flush() }
        await gate.waitUntilEntered()
        collector.deviceId = "strap-b"
        collector.clockRef = ClockRef(device: 1_800_000_000, wall: 1_800_000_001)
        await gate.open()
        await flush.value
        let writes = await store.writes
        let rawOwners = await store.rawOwners
        let rawClocks = await store.rawClocks
        XCTAssertEqual(writes.map(\.owner), ["strap-a"])
        XCTAssertEqual(rawOwners, ["strap-a"])
        XCTAssertEqual(rawClocks, [ClockRef(device: 1_700_000_000, wall: 1_700_000_000)])
    }

    func testBufferedFramesKeepTheirOriginalOwnerAndClock() async {
        let store = StoreProbe()
        let collector = collector(store, raw: true)
        collector.ingest(frame)
        collector.deviceId = "strap-b"
        collector.clockRef = ClockRef(device: 1_800_000_000, wall: 1_800_000_001)
        collector.ingest(frame)
        await collector.flush()
        let writes = await store.writes
        let rawOwners = await store.rawOwners
        let rawClocks = await store.rawClocks
        XCTAssertEqual(writes.map(\.owner), ["strap-a", "strap-b"])
        XCTAssertEqual(rawOwners, ["strap-a", "strap-b"])
        XCTAssertEqual(rawClocks, [ClockRef(device: 1_700_000_000, wall: 1_700_000_000),
                                 ClockRef(device: 1_800_000_000, wall: 1_800_000_001)])
    }

    func testFailedFrameBatchKeepsItsOwnerOnRetry() async {
        let store = StoreProbe(failures: 1)
        let collector = collector(store, raw: true)
        collector.ingest(frame)
        await collector.flush()
        collector.deviceId = "strap-b"
        collector.clockRef = ClockRef(device: 1_800_000_000, wall: 1_800_000_001)
        collector.ingest(frame)
        await collector.flush()
        await collector.flush()
        let writes = await store.writes
        let rawOwners = await store.rawOwners
        XCTAssertEqual(writes.map(\.owner), ["strap-a", "strap-b"])
        XCTAssertEqual(rawOwners, ["strap-a", "strap-b"])
        XCTAssertEqual(collector.bufferedCount, 0)
    }

    func testLateClockOnlyCorrelatesItsOwnSource() async {
        let store = StoreProbe()
        let collector = collector(store, raw: true)
        collector.clockRef = nil
        collector.ingest(frame)
        collector.deviceId = "strap-b"
        collector.ingest(frame)
        collector.clockRef = ClockRef(device: 1_800_000_000, wall: 1_800_000_001)
        await collector.flush()
        let writes = await store.writes
        XCTAssertEqual(writes.map(\.owner), ["strap-b"])
        XCTAssertEqual(collector.bufferedCount, 1, "uncorrelated old-source bytes remain bounded and unassigned")
    }

    func testNewSourceDoesNotFreezePreviousSourceClockBeforeItsOwnClockArrives() async {
        let store = StoreProbe()
        let collector = collector(store, raw: true)
        collector.deviceId = "strap-b"
        collector.ingest(frame)
        let ownClock = ClockRef(device: 1_800_000_000, wall: 1_800_000_001)
        collector.clockRef = ownClock
        await collector.flush()
        let rawClocks = await store.rawClocks
        let rawOwners = await store.rawOwners
        XCTAssertEqual(rawOwners, ["strap-b"])
        XCTAssertEqual(rawClocks, [ownClock], "A new source must wait for its own clock correlation")
    }

    func testStandardRetryDoesNotReinsertAnAlreadyCommittedOwner() async {
        let store = StoreProbe(failureOnCall: 2)
        let collector = collector(store)
        for (owner, bpm) in [("strap-a", 80), ("strap-b", 100)] {
            collector.deviceId = owner
            collector.ingestStandardHR(hr: bpm, rr: [], at: 1_700_000_000 + bpm)
        }
        await collector.flushStandardHR()
        collector.deviceId = "strap-c"
        collector.ingestStandardHR(hr: 90, rr: [], at: 1_700_000_090)
        await collector.flushStandardHR()
        await collector.flushStandardHR()
        let writes = await store.writes
        XCTAssertEqual(writes.map(\.owner), ["strap-a", "strap-b", "strap-c"])
        XCTAssertEqual(writes.flatMap(\.hr).map(\.bpm), [80, 100, 90])
    }

    func testFrameRetryDoesNotReinsertOrRequeueRawForAnAlreadyCommittedOwner() async {
        let store = StoreProbe(failureOnCall: 2)
        let collector = collector(store, raw: true)
        for owner in ["strap-a", "strap-b"] {
            collector.deviceId = owner
            collector.clockRef = ClockRef(device: 1_700_000_000, wall: 1_700_000_000)
            collector.ingest(frame)
        }
        await collector.flush()
        collector.deviceId = "strap-c"
        collector.clockRef = ClockRef(device: 1_700_000_000, wall: 1_700_000_000)
        collector.ingest(frame)
        await collector.flush()
        await collector.flush()
        let writes = await store.writes
        let rawOwners = await store.rawOwners
        XCTAssertEqual(writes.map(\.owner), ["strap-a", "strap-b", "strap-c"])
        XCTAssertEqual(rawOwners, ["strap-a", "strap-b", "strap-c"])
        XCTAssertEqual(collector.bufferedCount, 0)
    }
}
