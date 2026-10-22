import Combine
import XCTest
import WhoopStore
@testable import NOOP

/// Exercises the actual coordinator with a real isolated registry. The closures are
/// the production boundary to BLEManager; no physical Bluetooth device is needed.
@MainActor
final class SourceCoordinatorTransitionRegressionTests: XCTestCase {
    private final class Effects {
        var starts = 0
        var stops = 0
        var writeTarget = "my-whoop"
    }

    private func makeHarness() async throws -> (SourceCoordinator, Effects) {
        let store = try await WhoopStore.inMemory()
        let registryStore = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registryStore.add(PairedDevice(
            id: "my-whoop", brand: "WHOOP", model: "WHOOP 4.0",
            sourceKind: .liveBLE, capabilities: [.hr, .hrv, .sleep],
            status: .active, addedAt: 0, lastSeenAt: 0))
        try registryStore.add(PairedDevice(
            id: "second-whoop", brand: "WHOOP", model: "WHOOP 4.0",
            sourceKind: .liveBLE, capabilities: [.hr, .hrv, .sleep],
            status: .paired, addedAt: 1, lastSeenAt: 1))
        let registry = DeviceRegistry(store: registryStore)
        try registry.reload()
        let effects = Effects()
        let coordinator = SourceCoordinator(
            registry: registry,
            live: LiveState(),
            storeHandle: { store },
            startWhoop: { effects.starts += 1 },
            stopWhoop: { effects.stops += 1 },
            setWhoopPreferredPeripheral: { _ in },
            setWhoopActiveDeviceId: { effects.writeTarget = $0 },
            connectedPeripheralUUID: Empty<String?, Never>().eraseToAnyPublisher())
        return (coordinator, effects)
    }

    func testInitialLegacyActivationPreservesRestoredConnection() async throws {
        let (coordinator, effects) = try await makeHarness()
        coordinator.activeDeviceChanged(to: "my-whoop")
        coordinator.activeDeviceChanged(to: "my-whoop")
        XCTAssertEqual(effects.starts, 0)
        XCTAssertEqual(effects.stops, 0)
        XCTAssertEqual(effects.writeTarget, "my-whoop")
    }

    func testCommittedTargetRestartsAfterDurableTransitionStop() async throws {
        let (coordinator, effects) = try await makeHarness()
        coordinator.activeDeviceChanged(to: "my-whoop")
        coordinator.stopForTransition()
        XCTAssertEqual(effects.stops, 1)
        coordinator.activeDeviceChanged(to: "second-whoop")
        XCTAssertEqual(effects.starts, 1)
        XCTAssertEqual(effects.writeTarget, "second-whoop")
        coordinator.activeDeviceChanged(to: "second-whoop")
        XCTAssertEqual(effects.starts, 1, "Duplicate publication must not reconnect again")
    }

    func testSelectingLegacyWhoopRestoresItsPersistenceIdentity() async throws {
        let (coordinator, effects) = try await makeHarness()
        coordinator.activeDeviceChanged(to: "my-whoop")
        coordinator.activeDeviceChanged(to: "second-whoop")
        XCTAssertEqual(effects.writeTarget, "second-whoop")
        coordinator.activeDeviceChanged(to: "my-whoop")
        XCTAssertEqual(effects.writeTarget, "my-whoop")
    }

    func testRollbackRestartsPreviousWhoopAfterTransitionStop() async throws {
        let (coordinator, effects) = try await makeHarness()
        coordinator.activeDeviceChanged(to: "my-whoop")
        coordinator.stopForTransition()
        // The recovery coordinator invokes the same activation when a mutation fails.
        coordinator.activeDeviceChanged(to: "my-whoop")
        XCTAssertEqual(effects.starts, 1)
        XCTAssertEqual(effects.writeTarget, "my-whoop")
    }
}
