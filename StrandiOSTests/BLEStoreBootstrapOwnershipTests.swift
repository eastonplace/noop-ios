import NoopPhase34Core
import WhoopProtocol
import WhoopStore
import XCTest
@testable import NOOP

@MainActor
final class BLEStoreBootstrapOwnershipTests: XCTestCase {
    private func makeManager(_ state: LiveState) -> BLEManager {
        let manager = BLEManager(state: state, collector: nil)
        manager.setHistoricalMaterializationSeamsForTesting(
            dueCheck: { _, _ in false },
            run: { _ in HistoricalMaterializationRunSummary() })
        return manager
    }

    func testRegistrySnapshotCannotReparentOwnerAfterLeavingAndReturning() async throws {
        try await assertRegistrySnapshotIsOwned(expectedOwner: "my-whoop") { manager in
            let original = manager.deviceId
            manager.setActiveDeviceId("intermediate-strap")
            manager.setActiveDeviceId(original)
            return "intermediate-strap"
        }
    }

    func testStableRegistrySnapshotStillAdoptsTheSelectedOwner() async throws {
        try await assertRegistrySnapshotIsOwned(expectedOwner: "selected-strap") { _ in
            "selected-strap"
        }
    }

    private func assertRegistrySnapshotIsOwned(
        expectedOwner: String,
        read: @MainActor (BLEManager) -> String?
    ) async throws {
        let defaults = UserDefaults.standard
        let previousReplayStamp = defaults.object(forKey: BLEManager.rejectArchiveReplayKey)
        defaults.set(BLEManager.rejectArchiveReplayStamp(), forKey: BLEManager.rejectArchiveReplayKey)
        defer { defaults.set(previousReplayStamp, forKey: BLEManager.rejectArchiveReplayKey) }
        let store = try await WhoopStore.inMemory()
        let manager = makeManager(LiveState())
        var upsertedOwner: String?

        await manager.bootstrapStore(
            openStore: { _ in store }, readActiveDeviceId: { _ in read(manager) },
            upsertDevice: { _, owner in upsertedOwner = owner },
            readBatterySamples: { _, _, _, _ in [] })

        XCTAssertEqual(manager.deviceId, expectedOwner)
        XCTAssertEqual(upsertedOwner, expectedOwner)
        XCTAssertTrue(manager.hasIngestStoreForTesting,
                      "Discarding a stale registry snapshot must still initialize the explicit current owner")
        manager.disconnect()
        try await manager.quiesceStoreForRestore()
    }

    func testRetiredStoreCannotInstallCollectorsAfterDeviceUpsertResumes() async throws {
        let oldStore = try await WhoopStore.inMemory()
        let replacementStore = try await WhoopStore.inMemory()
        let manager = makeManager(LiveState())

        await manager.bootstrapStore(openStore: { _ in oldStore }, upsertDevice: { store, id in
            try await store.upsertDevice(id: id, mac: nil, name: "WHOOP 4.0")
            manager.setHistoricalMaterializationStoreForTesting(replacementStore)
        })

        XCTAssertFalse(manager.hasIngestStoreForTesting,
                       "A bootstrap whose store generation retired must not resurrect its collector/backfiller")
        manager.disconnect()
        try await manager.quiesceStoreForRestore()
    }

    func testBatteryReadCannotSeedTheNewlySelectedDevice() async throws {
        try await assertBatterySeedIsOwned { manager, state, _ in
            manager.setActiveDeviceId("replacement-strap")
            state.bankBatterySample(22, now: 1_792_600_000)
        }
    }

    func testBatteryReadCannotSeedAfterDatabaseReplacement() async throws {
        try await assertBatterySeedIsOwned { manager, state, replacement in
            manager.setHistoricalMaterializationStoreForTesting(replacement)
            state.bankBatterySample(22, now: 1_792_600_000)
        }
    }

    func testBatteryReadCannotBorrowAnIdenticalIdAfterLeavingAndReturning() async throws {
        try await assertBatterySeedIsOwned { manager, state, _ in
            let original = manager.deviceId
            manager.setActiveDeviceId("another-strap")
            manager.setActiveDeviceId(original)
            state.bankBatterySample(22, now: 1_792_600_000)
        }
    }

    func testCurrentStoreAndSourceStillReceiveTheirBatterySeed() async throws {
        try await assertBatterySeedIsOwned(expectedSamples: [88]) { _, _, _ in }
    }

    func testArchiveInsertRejectsAReplacedSourceBeforeWriting() async throws {
        try await withReplayDue { manager, store, _ in
            var rejected = false
            await manager.bootstrapStore(
                openStore: { _ in store }, readBatterySamples: { _, _, _, _ in [] },
                replayRejectedHistory: { insert in
                    manager.setActiveDeviceId("replacement-strap")
                    do {
                        _ = try await insert(Streams())
                    } catch is CancellationError {
                        rejected = true
                    }
                    return 0
                })
            XCTAssertTrue(rejected, "An archive batch cannot acquire the replacement source's identity")
        }
    }

    func testArchiveCompletionCannotAdvanceReplayGateAfterStoreReplacement() async throws {
        try await withReplayDue { manager, store, replacement in
            await manager.bootstrapStore(
                openStore: { _ in store }, readBatterySamples: { _, _, _, _ in [] },
                replayRejectedHistory: { _ in
                    manager.setHistoricalMaterializationStoreForTesting(replacement)
                    return 1
                })
        }
    }

    private func withReplayDue(
        _ operation: @MainActor (BLEManager, WhoopStore, WhoopStore) async throws -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let keys = [BLEManager.rejectArchiveReplayKey, BLEManager.legacyRejectArchiveReplayKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
        }
        let store = try await WhoopStore.inMemory()
        let replacement = try await WhoopStore.inMemory()
        let manager = makeManager(LiveState())

        try await operation(manager, store, replacement)

        XCTAssertNil(defaults.object(forKey: BLEManager.rejectArchiveReplayKey),
                     "Only completion by the captured store and source may stamp the replay gate")
        manager.disconnect()
        try await manager.quiesceStoreForRestore()
    }

    private func assertBatterySeedIsOwned(
        expectedSamples: [Double] = [22],
        replace: @MainActor (BLEManager, LiveState, WhoopStore) -> Void
    ) async throws {
        let defaults = UserDefaults.standard
        let previousReplayStamp = defaults.object(forKey: BLEManager.rejectArchiveReplayKey)
        defaults.set(BLEManager.rejectArchiveReplayStamp(), forKey: BLEManager.rejectArchiveReplayKey)
        defer { defaults.set(previousReplayStamp, forKey: BLEManager.rejectArchiveReplayKey) }
        let oldStore = try await WhoopStore.inMemory()
        let replacementStore = try await WhoopStore.inMemory()
        let state = LiveState()
        let manager = makeManager(state)
        var readCount = 0

        await manager.bootstrapStore(openStore: { _ in oldStore }, readBatterySamples: { _, _, _, _ in
            readCount += 1
            replace(manager, state, replacementStore)
            return [BatterySample(ts: 1_792_500_000, soc: 88, mv: nil)]
        })

        XCTAssertEqual(readCount, 1, "Exercise the production post-read publication boundary")
        XCTAssertEqual(state.batterySamples.map(\.soc), expectedSamples,
                       "The old read must not mix another source/store's discharge history into the current one")
        manager.disconnect()
        try await manager.quiesceStoreForRestore()
    }
}
