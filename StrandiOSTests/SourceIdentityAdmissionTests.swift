import Combine
import XCTest
import WhoopStore
@testable import NOOP

@MainActor
final class SourceIdentityAdmissionTests: XCTestCase {
    private struct Harness {
        let coordinator: SourceCoordinator
        let registry: DeviceRegistry
        let fence: SourceTransitionFence
        let live: LiveState
    }

    private func makeHarness() async throws -> Harness {
        let store = try await WhoopStore.inMemory()
        let registryStore = DeviceRegistryStore(dbQueue: store.registryWriter)
        for (id, status) in [("my-whoop", DeviceStatus.active), ("second-whoop", .paired)] {
            try registryStore.add(PairedDevice(
                id: id, brand: "WHOOP", model: "WHOOP 4.0", sourceKind: .liveBLE,
                capabilities: [.hr, .hrv, .sleep], status: status, addedAt: 0, lastSeenAt: 0))
        }
        let registry = DeviceRegistry(store: registryStore)
        try registry.reload()
        let fence = SourceTransitionFence()
        let live = LiveState()
        let coordinator = SourceCoordinator(
            registry: registry, live: live, storeHandle: { store },
            startWhoop: {}, stopWhoop: {}, setWhoopPreferredPeripheral: { _ in },
            setWhoopActiveDeviceId: { _ in },
            connectedPeripheralUUID: Empty<String?, Never>().eraseToAnyPublisher(),
            transitionFence: fence)
        coordinator.start()
        return Harness(coordinator: coordinator, registry: registry, fence: fence, live: live)
    }

    func testCallbackQueuedDuringSelectionCannotAdoptOldStrapIntoNewSource() async throws {
        let harness = try await makeHarness()
        let pending = try await harness.fence.runThrowing {
            let pending = harness.coordinator.connectedPeripheralChanged(to: "strap-a")
            try harness.registry.setActive("second-whoop")
            return pending
        }
        await pending.value

        XCTAssertNil(harness.registry.devices.first { $0.id == "second-whoop" }?.peripheralId)
        await harness.coordinator.connectedPeripheralChanged(to: "strap-b").value
        XCTAssertEqual(harness.registry.devices.first { $0.id == "second-whoop" }?.peripheralId, "strap-b")
    }

    func testRetiringAndReactivatingSameSourceInvalidatesQueuedIdentity() async throws {
        let harness = try await makeHarness()
        let pending = harness.coordinator.connectedPeripheralChanged(to: "retired-strap")
        harness.coordinator.stopForTransition()
        harness.coordinator.activeDeviceChanged(to: "my-whoop")
        await pending.value

        XCTAssertNil(harness.registry.devices.first { $0.id == "my-whoop" }?.peripheralId)
    }

    func testLatestPhysicalObservationWinsBeforeAdmission() async throws {
        let harness = try await makeHarness()
        let retired = harness.coordinator.connectedPeripheralChanged(to: "retired-strap")
        let current = harness.coordinator.connectedPeripheralChanged(to: "current-strap")
        await retired.value
        await current.value

        XCTAssertEqual(harness.registry.devices.first { $0.id == "my-whoop" }?.peripheralId, "current-strap")
    }

    func testPreBondCallbackCannotBorrowLaterBondProof() async throws {
        let harness = try await makeHarness()
        try harness.registry.setPeripheralId("my-whoop", peripheralId: "pinned-strap")
        let pending = harness.coordinator.connectedPeripheralChanged(to: "unverified-strap")
        harness.live.encryptedBond = true
        await pending.value

        XCTAssertEqual(harness.registry.devices.first { $0.id == "my-whoop" }?.peripheralId, "pinned-strap")
        await harness.coordinator.connectedPeripheralChanged(to: "verified-strap").value
        XCTAssertEqual(harness.registry.devices.first { $0.id == "my-whoop" }?.peripheralId, "verified-strap")
    }
}
