import XCTest
@testable import NOOP
import WhoopProtocol
import WhoopStore

@MainActor
final class BLEHistoricalRetirementPublicationTests: XCTestCase {
    private func committedContext(in store: WhoopStore) async throws -> HistoricalCommitContext {
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: "strap-a", brand: "WHOOP", model: "WHOOP 4.0", peripheralId: "peripheral-a",
            sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        let scope = try registry.historicalCursorScope(for: "strap-a")
        var context: HistoricalCommitContext?
        let backfiller = Backfiller(
            store: store, deviceId: "strap-a", ackTrim: { _, _, _ in true },
            onHistoricalCommitContext: { context = $0 },
            extract: { _, _, _, _, _, _ in Streams(hr: [HRSample(ts: 1_781_557_000, bpm: 60)]) })
        let hex = "aa5a008e2f18000000000000f153650000000000003f0152030000000000000000dc053075"
            + "000000cdcc4c3dcdcccc3d5a657e3f00000040cdcc4c3dcdcccc3d5a657e3f504668428403"
            + "200364006400b80bb80b000000000000c25c1a88"
        let record = stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        func le32(_ value: UInt32) -> [UInt8] {
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        XCTAssertTrue(backfiller.begin(family: .whoop4, historicalCursorScope: scope))
        await backfiller.ingest(record)
        await backfiller.ingest(frameFromPayload(
            le32(1_781_557_001) + [0, 0] + le32(0) + le32(321), type: 49, seq: 0, cmd: 2))
        return try XCTUnwrap(context)
    }

    func testLateOriginalReceiptPublishesWithoutChangingReplacementSourceOrPassProgress() async throws {
        let store = try await WhoopStore.inMemory()
        let context = try await committedContext(in: store)
        let live = LiveState()
        let manager = BLEManager(state: live, collector: nil, receiveBluetoothCallbacks: false)
        manager.setHistoricalMaterializationStoreForTesting(store)
        let notify = manager.makeRetiredHistoricalCommitHandler(for: store)
        let replacement = LiveHeartRateSource(
            deviceId: "strap-b", peripheralID: UUID(), connectionGeneration: 2, providerSessionID: UUID())
        let observedAt = Date()
        live.activateHeartRateProviderSource(replacement, at: observedAt.timeIntervalSince1970)
        live.receiveHeartRate(bpm: 112, observedAt: observedAt, source: replacement, transport: .standard, now: observedAt)
        let replacementReceipt = live.latestHeartRateReceipt
        let progress = HistoricalSyncPassProgress(
            rowsPersisted: 12, passNumber: 2, latestFrontierUnix: nil, publishedAt: 123)
        live.publishHistoricalSyncProgress(progress)
        let lastSyncedAt = live.lastSyncedAt

        await notify(context)

        XCTAssertEqual(live.finalizedHistoricalDataCommitWatermark, HistoricalReceiptWatermark(receipt: context.receipt))
        XCTAssertEqual(live.currentHeartRateSource, replacement)
        XCTAssertEqual(live.latestHeartRateReceipt, replacementReceipt)
        XCTAssertEqual(live.heartRate, 112)
        XCTAssertEqual(live.historicalSyncPassProgress, progress, "late A work must not clear B's active pass")
        XCTAssertEqual(live.lastSyncedAt, lastSyncedAt)
    }

    func testReplacedDatabaseRejectsRetiredReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        let replacement = try await WhoopStore.inMemory()
        let context = try await committedContext(in: store)
        let live = LiveState()
        let manager = BLEManager(state: live, collector: nil, receiveBluetoothCallbacks: false)
        manager.setHistoricalMaterializationStoreForTesting(store)
        let notify = manager.makeRetiredHistoricalCommitHandler(for: store)
        manager.setHistoricalMaterializationStoreForTesting(replacement)

        await notify(context)

        XCTAssertNil(live.finalizedHistoricalBurst)
    }

    func testSameStoreHandleWithANewerGenerationRejectsRetiredReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        let context = try await committedContext(in: store)
        let live = LiveState()
        let manager = BLEManager(state: live, collector: nil, receiveBluetoothCallbacks: false)
        manager.setHistoricalMaterializationStoreForTesting(store)
        let notify = manager.makeRetiredHistoricalCommitHandler(for: store)
        manager.setHistoricalMaterializationStoreForTesting(store)

        await notify(context)

        XCTAssertNil(live.finalizedHistoricalBurst)
    }

    func testRestoreQuiescenceRejectsRetiredReceipt() async throws {
        let store = try await WhoopStore.inMemory()
        let context = try await committedContext(in: store)
        let live = LiveState()
        let manager = BLEManager(state: live, collector: nil, receiveBluetoothCallbacks: false)
        manager.setHistoricalMaterializationStoreForTesting(store)
        let notify = manager.makeRetiredHistoricalCommitHandler(for: store)
        try await manager.quiesceStoreForRestore()

        await notify(context)

        XCTAssertNil(live.finalizedHistoricalBurst)
    }

    func testReceiptFromAnotherDatabaseCannotUseTheCurrentStoreHandler() async throws {
        let currentStore = try await WhoopStore.inMemory()
        let otherStore = try await WhoopStore.inMemory()
        let context = try await committedContext(in: otherStore)
        let live = LiveState()
        let manager = BLEManager(state: live, collector: nil, receiveBluetoothCallbacks: false)
        manager.setHistoricalMaterializationStoreForTesting(currentStore)
        let notify = manager.makeRetiredHistoricalCommitHandler(for: currentStore)

        await notify(context)

        XCTAssertNil(live.finalizedHistoricalBurst)
    }
}
