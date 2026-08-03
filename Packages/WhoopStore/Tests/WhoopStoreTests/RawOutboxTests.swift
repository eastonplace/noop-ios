import XCTest
import WhoopProtocol
@testable import WhoopStore

final class RawOutboxTests: XCTestCase {
    private let frames: [[UInt8]] = [
        [0xAA, 0x18, 0x00, 0xFF, 0x28, 0x02, 0x0F, 0x01, 0x02, 0x03],
        [0xAA, 0x0C, 0x00, 0xFC, 0x24, 0x24, 0x03, 0x0A],
        [],                                   // empty frame must survive the round-trip
    ]
    private func meta(
        _ id: String,
        capturedAt: Int = 5000,
        synced: Bool = false,
        deviceId: String = "dev1",
        lineage: String? = nil,
        cursorEpoch: Int = 0,
        frames: [[UInt8]]? = nil
    ) -> RawBatchMeta {
        let frames = frames ?? self.frames
        return RawBatchMeta(batchId: id, deviceId: deviceId,
                     clockRef: ClockRef(device: 31538447, wall: 1736365593),
                     capturedAt: capturedAt, startTs: 1736365593, endTs: 1736365600,
                     frameCount: frames.count, byteSize: frames.reduce(0) { $0 + $1.count },
                     lineage: lineage, cursorEpoch: cursorEpoch)
    }

    func testEnqueueThenRawFramesRoundTrips() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("b1"), frames: frames)
        let got = try await store.rawFrames(batchId: "b1")
        XCTAssertEqual(got, frames)
    }

    func testRawFramesUnknownBatchIsEmpty() async throws {
        let store = try await WhoopStore.inMemory()
        let got = try await store.rawFrames(batchId: "nope")
        XCTAssertEqual(got, [])
    }

    func testPendingExcludesSyncedAndRespectsLimitAndOrder() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.enqueueRawBatch(meta("old", capturedAt: 100), frames: frames)
        try await store.enqueueRawBatch(meta("mid", capturedAt: 200), frames: frames)
        try await store.enqueueRawBatch(meta("new", capturedAt: 300), frames: frames)
        try await store.markRawBatchSynced(batchId: "mid", at: 999)

        let pending = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pending.map { $0.batchId }, ["old", "new"])   // mid synced; oldest first

        let limited = try await store.pendingRawBatches(limit: 1)
        XCTAssertEqual(limited.map { $0.batchId }, ["old"])
    }

    func testMetaRoundTripsThroughPending() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let m = meta("b1")
        try await store.enqueueRawBatch(m, frames: frames)
        let pending = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0], m)
    }

    func testRoundTripLargeBatch() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // 200 frames x 24 bytes → packed >> (byteSize + 256) hint; exercises the truncation path.
        let manyFrames = (0..<200).map { i in [UInt8](repeating: UInt8(i & 0xFF), count: 24) }
        let byteSize = manyFrames.reduce(0) { $0 + $1.count }
        let m = RawBatchMeta(batchId: "big", deviceId: "dev1",
                             clockRef: ClockRef(device: 0, wall: 0),
                             capturedAt: 1, startTs: 0, endTs: 0,
                             frameCount: manyFrames.count, byteSize: byteSize)
        try await store.enqueueRawBatch(m, frames: manyFrames)
        let gotLarge = try await store.rawFrames(batchId: "big")
        XCTAssertEqual(gotLarge, manyFrames)
    }

    func testRoundTripHighlyCompressibleBatch() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        // All-zero frames compress to a tiny blob but decompress LARGE — the worst case for
        // any fixed-size decode buffer heuristic.
        let zeros = (0..<300).map { _ in [UInt8](repeating: 0, count: 64) }
        let byteSize = zeros.reduce(0) { $0 + $1.count }
        let m = RawBatchMeta(batchId: "z", deviceId: "dev1",
                             clockRef: ClockRef(device: 0, wall: 0),
                             capturedAt: 1, startTs: 0, endTs: 0,
                             frameCount: zeros.count, byteSize: byteSize)
        try await store.enqueueRawBatch(m, frames: zeros)
        let gotZeros = try await store.rawFrames(batchId: "z")
        XCTAssertEqual(gotZeros, zeros)
    }

    func testLegacyRawBatchApisFailClosedWhenBatchIdIsAmbiguous() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        let framesA: [[UInt8]] = [[0xA1, 0x01]]
        let framesB: [[UInt8]] = [[0xB2, 0x02]]
        let sharedBatchId = "reused-batch"
        let lineageA = "physical-a"
        let lineageB = "physical-b"

        try await store.enqueueRawBatch(
            meta(sharedBatchId, lineage: lineageA, cursorEpoch: 0, frames: framesA), frames: framesA
        )
        try await store.enqueueRawBatch(
            meta(sharedBatchId, lineage: lineageB, cursorEpoch: 1, frames: framesB), frames: framesB
        )

        // A legacy lookup must not select either physical source.
        let legacyFrames = try await store.rawFrames(batchId: sharedBatchId)
        XCTAssertEqual(legacyFrames, [])

        // A legacy sync must not update either row when the ID is ambiguous.
        try await store.markRawBatchSynced(batchId: sharedBatchId, at: 1_000)
        let pendingAfterLegacySync = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pendingAfterLegacySync.count, 2)
        XCTAssertEqual(Set(pendingAfterLegacySync.map { "\($0.lineage):\($0.cursorEpoch)" }),
                       Set(["\(lineageA):0", "\(lineageB):1"]))

        // Scoped reads and syncs remain identity-specific.
        let scopedFramesA = try await store.rawFrames(
            batchId: sharedBatchId, lineage: lineageA, cursorEpoch: 0
        )
        let scopedFramesB = try await store.rawFrames(
            batchId: sharedBatchId, lineage: lineageB, cursorEpoch: 1
        )
        XCTAssertEqual(scopedFramesA, framesA)
        XCTAssertEqual(scopedFramesB, framesB)

        try await store.markRawBatchSynced(
            batchId: sharedBatchId, lineage: lineageA, cursorEpoch: 0, at: 2_000
        )
        let pendingAfterScopedA = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pendingAfterScopedA.map { "\($0.lineage):\($0.cursorEpoch)" }, ["\(lineageB):1"])

        try await store.markRawBatchSynced(
            batchId: sharedBatchId, lineage: lineageB, cursorEpoch: 1, at: 3_000
        )
        let pendingAfterScopedB = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pendingAfterScopedB, [])
    }

    func testScopedRawBatchApisFailClosedWhenScopeIsAmbiguousAcrossDevices() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceA = "dev-a"
        let deviceB = "dev-b"
        try await store.upsertDevice(id: deviceA, mac: nil, name: nil)
        try await store.upsertDevice(id: deviceB, mac: nil, name: nil)

        let batchId = "same-batch"
        let lineage = "same-lineage"
        let cursorEpoch = 4
        try await store.enqueueRawBatch(
            meta(batchId, deviceId: deviceA, lineage: lineage, cursorEpoch: cursorEpoch,
                 frames: [[0xA1]]),
            frames: [[0xA1]]
        )
        try await store.enqueueRawBatch(
            meta(batchId, deviceId: deviceB, lineage: lineage, cursorEpoch: cursorEpoch,
                 frames: [[0xB2]]),
            frames: [[0xB2]]
        )

        let scopedFrames = try await store.rawFrames(
            batchId: batchId, lineage: lineage, cursorEpoch: cursorEpoch
        )
        XCTAssertEqual(scopedFrames, [])

        try await store.markRawBatchSynced(
            batchId: batchId, lineage: lineage, cursorEpoch: cursorEpoch, at: 4_000
        )
        let pending = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(Set(pending.map(\.deviceId)), Set([deviceA, deviceB]))
    }

    func testDeviceScopedRawBatchApisSelectAndSyncOnlyRequestedDevice() async throws {
        let store = try await WhoopStore.inMemory()
        let deviceA = "dev-a"
        let deviceB = "dev-b"
        try await store.upsertDevice(id: deviceA, mac: nil, name: nil)
        try await store.upsertDevice(id: deviceB, mac: nil, name: nil)

        let batchId = "same-batch"
        let lineage = "same-lineage"
        let cursorEpoch = 4
        let framesA: [[UInt8]] = [[0xA1]]
        let framesB: [[UInt8]] = [[0xB2]]
        try await store.enqueueRawBatch(
            meta(batchId, deviceId: deviceA, lineage: lineage, cursorEpoch: cursorEpoch,
                 frames: framesA),
            frames: framesA
        )
        try await store.enqueueRawBatch(
            meta(batchId, deviceId: deviceB, lineage: lineage, cursorEpoch: cursorEpoch,
                 frames: framesB),
            frames: framesB
        )

        let deviceFramesA = try await store.rawFrames(
            batchId: batchId, deviceId: deviceA, lineage: lineage, cursorEpoch: cursorEpoch
        )
        let deviceFramesB = try await store.rawFrames(
            batchId: batchId, deviceId: deviceB, lineage: lineage, cursorEpoch: cursorEpoch
        )
        XCTAssertEqual(deviceFramesA, framesA)
        XCTAssertEqual(deviceFramesB, framesB)

        try await store.markRawBatchSynced(
            batchId: batchId, deviceId: deviceA, lineage: lineage, cursorEpoch: cursorEpoch, at: 5_000
        )
        let pendingAfterA = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pendingAfterA.map(\.deviceId), [deviceB])

        try await store.markRawBatchSynced(
            batchId: batchId, deviceId: deviceB, lineage: lineage, cursorEpoch: cursorEpoch, at: 6_000
        )
        let pendingAfterB = try await store.pendingRawBatches(limit: 10)
        XCTAssertEqual(pendingAfterB, [])
    }
}
