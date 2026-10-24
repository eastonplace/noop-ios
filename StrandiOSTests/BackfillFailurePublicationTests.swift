import Combine
import XCTest
@testable import NOOP
import WhoopProtocol
import WhoopStore

@MainActor
final class BackfillFailurePublicationTests: XCTestCase {
    private let sampleTimestamp = 1_781_557_000

    private func preserveDefaults() {
        let defaults = UserDefaults.standard
        let keys = [BLEManager.historicalBacklogRemainsKey, "sync.lastWriteStalledAt"]
        let previous = keys.map { ($0, defaults.object(forKey: $0)) }
        defaults.removeObject(forKey: BLEManager.historicalBacklogRemainsKey)
        addTeardownBlock {
            for (key, value) in previous {
                if let value { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
    }

    private func scope(in store: WhoopStore) throws -> HistoricalCursorScope {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: "strap-a", brand: "WHOOP", model: "WHOOP 4.0", peripheralId: "peripheral-a",
            sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        return try registry.historicalCursorScope(for: "strap-a")
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

    private func end(trim: UInt32) -> [UInt8] {
        func le32(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        return frameFromPayload(le32(UInt32(sampleTimestamp + 1)) + [0, 0] + le32(0) + le32(trim),
                                type: 49, seq: 0, cmd: 2)
    }

    func testCommittedChunkPublishesWhenItsAckFailsWithoutClaimingCompletion() async throws {
        preserveDefaults()
        let store = try await WhoopStore.inMemory()
        let scope = try scope(in: store)
        let live = LiveState()
        let lastSyncedAt = live.lastSyncedAt
        weak var target: BLEManager?
        let backfiller = Backfiller(
            store: store, deviceId: "strap-a", ackTrim: { _, _, _ in false },
            onHistoricalCommitContext: { target?.recordHistoricalCommit($0) },
            onFailure: { target?.handleBackfillFailure($0) },
            extract: { [sampleTimestamp] _, _, _, _, _, _ in
                Streams(hr: [HRSample(ts: sampleTimestamp, bpm: 60)])
            })
        XCTAssertTrue(backfiller.begin(family: .whoop4, historicalCursorScope: scope))
        let manager = BLEManager(state: live, deviceId: "strap-a", collector: nil,
                                 backfiller: backfiller, receiveBluetoothCallbacks: false)
        target = manager
        var finalizations = 0
        let subscription = live.$backfillDataAvailableAt.dropFirst().sink { _ in finalizations += 1 }

        await backfiller.ingest(record)
        await backfiller.ingest(end(trim: 321))

        let receipts = try await store.historicalDataCommitReceipts(deviceId: "strap-a")
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipts.count, 1, "the chunk is durable before the failed ACK")
        XCTAssertEqual(backfiller.sessionRowsPersisted, 0, "ACK-confirmed tallies intentionally remain zero")
        XCTAssertTrue(backfiller.persistStalled)
        XCTAssertEqual(live.finalizedHistoricalDataCommitWatermark, HistoricalReceiptWatermark(receipt: receipt))
        XCTAssertEqual(finalizations, 1, "durable scoring must not wait for another successful radio session")
        XCTAssertEqual(live.historicalSyncSessionState, .failed)
        XCTAssertEqual(live.lastSyncedAt, lastSyncedAt, "a failed ACK is not HISTORY_COMPLETE")
        let snapshot = manager.historicalSyncBackgroundSnapshot()
        XCTAssertFalse(snapshot.syncActive)
        XCTAssertTrue(snapshot.backlogRemains, "the strap retains the unconfirmed chunk for a safe replay")
        XCTAssertEqual(snapshot.emptyStreak, 0, "a committed productive chunk is not an empty attempt")
        withExtendedLifetime(subscription) {}
    }

    func testLaterIntegrityFailurePublishesEarlierReceiptAndKeepsTheFailedChunkOnTheStrap() async throws {
        preserveDefaults()
        let store = try await WhoopStore.inMemory()
        let scope = try scope(in: store)
        let live = LiveState()
        let lastSyncedAt = live.lastSyncedAt
        var ackedTrims: [UInt32] = []
        weak var target: BLEManager?
        let backfiller = Backfiller(
            store: store, deviceId: "strap-a",
            ackTrim: { _, trim, _ in ackedTrims.append(trim); return true },
            onHistoricalCommitContext: { target?.recordHistoricalCommit($0) },
            onFailure: { target?.handleBackfillFailure($0) },
            extract: { [sampleTimestamp] _, _, _, _, _, _ in
                Streams(hr: [HRSample(ts: sampleTimestamp, bpm: 60)])
            })
        XCTAssertTrue(backfiller.begin(family: .whoop4, historicalCursorScope: scope))
        let manager = BLEManager(state: live, deviceId: "strap-a", collector: nil,
                                 backfiller: backfiller, receiveBluetoothCallbacks: false)
        target = manager

        await backfiller.ingest(record)
        await backfiller.ingest(end(trim: 321))
        XCTAssertNil(live.backfillDataAvailableAt, "normal productive chunks still coalesce within the burst")
        await backfiller.ingest(record)
        backfiller.noteInvalidInboundFrame()
        await backfiller.ingest(end(trim: 322))

        let receipts = try await store.historicalDataCommitReceipts(deviceId: "strap-a")
        let receipt = try XCTUnwrap(receipts.first)
        XCTAssertEqual(receipts.count, 1, "the incomplete second chunk must not commit")
        XCTAssertEqual(ackedTrims, [321], "the incomplete chunk must not be trimmed")
        XCTAssertEqual(live.finalizedHistoricalDataCommitWatermark, HistoricalReceiptWatermark(receipt: receipt))
        XCTAssertNotNil(live.backfillDataAvailableAt)
        XCTAssertEqual(live.historicalSyncSessionState, .failed)
        XCTAssertEqual(live.lastSyncedAt, lastSyncedAt)
        XCTAssertTrue(manager.historicalSyncBackgroundSnapshot().backlogRemains)
    }

    func testFailureBeforeAnyDurableReceiptDoesNotPublishOrInventBacklog() async throws {
        preserveDefaults()
        let store = try await WhoopStore.inMemory()
        let scope = try scope(in: store)
        let live = LiveState()
        weak var target: BLEManager?
        let backfiller = Backfiller(
            store: store, deviceId: "strap-a", ackTrim: { _, _, _ in XCTFail("invalid chunk cannot ACK"); return false },
            onHistoricalCommitContext: { target?.recordHistoricalCommit($0) },
            onFailure: { target?.handleBackfillFailure($0) })
        XCTAssertTrue(backfiller.begin(family: .whoop4, historicalCursorScope: scope))
        let manager = BLEManager(state: live, deviceId: "strap-a", collector: nil,
                                 backfiller: backfiller, receiveBluetoothCallbacks: false)
        target = manager

        await backfiller.ingest(record)
        backfiller.noteInvalidInboundFrame()
        await backfiller.ingest(end(trim: 321))

        let receipts = try await store.historicalDataCommitReceipts(deviceId: "strap-a")
        XCTAssertTrue(receipts.isEmpty)
        XCTAssertNil(live.backfillDataAvailableAt)
        XCTAssertNil(live.finalizedHistoricalDataCommitWatermark)
        XCTAssertEqual(live.historicalSyncSessionState, .failed)
        XCTAssertFalse(manager.historicalSyncBackgroundSnapshot().backlogRemains)
        XCTAssertEqual(manager.historicalSyncBackgroundSnapshot().emptyStreak, 1)
    }
}
