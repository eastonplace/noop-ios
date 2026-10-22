import XCTest
import WhoopProtocol
@testable import NOOP

@MainActor
final class BLEConnectionIntentTests: XCTestCase {
    func testSystemReconnectDoesNotUndoAnExplicitDisconnect() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.connect(model: .whoop4)
        manager.disconnect()

        manager.connectFromSystem(model: .whoop5mg)

        XCTAssertTrue(manager.isWhoop4, "a system event must not enter connectCore after Disconnect")
        manager.armReconnectForTesting(after: 30, secureRecovery: false)
        var reconnected = false
        XCTAssertFalse(manager.handOffArmedReconnect(targetState: .disconnected) { _ in
            reconnected = true
        })
        XCTAssertFalse(reconnected, "the stop request must survive the system event")
        manager.disconnect()
    }

    func testSystemReconnectDoesNotUndoForgetDevice() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.connect(model: .whoop5mg)
        manager.forgetDevice(nil, isActiveDevice: true)

        manager.connectFromSystem(model: .whoop4)

        XCTAssertTrue(manager.isWhoop5, "a forgotten strap stays released until an explicit Connect")
        manager.disconnect()
    }

    func testRemovingAnInactiveStrapPreservesTheActiveReconnectTimerAndIntent() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        let activeID = UUID()
        manager.setPreferredPeripheral(activeID.uuidString)
        manager.armReconnectForTesting(after: 30, secureRecovery: false)

        manager.forgetDevice(UUID().uuidString, isActiveDevice: false)

        XCTAssertTrue(manager.reconnectArmedForTesting)
        var reconnected = false
        XCTAssertTrue(manager.handOffArmedReconnect(targetState: .disconnected) { _ in
            reconnected = true
        })
        XCTAssertTrue(reconnected, "removing another device must not stop collection from the active strap")
        manager.disconnect()
    }

    func testRemovingAnInactiveRowWithoutAPeripheralDoesNotReleaseTheActiveStrap() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.setPreferredPeripheral(UUID().uuidString)
        manager.armReconnectForTesting(after: 30, secureRecovery: false)

        manager.forgetDevice(nil, isActiveDevice: false)

        XCTAssertTrue(manager.handOffArmedReconnect(targetState: .disconnected) { _ in })
        manager.disconnect()
    }

    func testRemovingTheSelectedStrapStillStopsItsAutomaticRecovery() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        let selectedID = UUID()
        manager.setPreferredPeripheral(selectedID.uuidString)
        manager.armReconnectForTesting(after: 30, secureRecovery: false)

        manager.forgetDevice(selectedID.uuidString, isActiveDevice: true)

        XCTAssertFalse(manager.reconnectArmedForTesting)
        XCTAssertFalse(manager.handOffArmedReconnect(targetState: .disconnected) { _ in })
    }

    func testPoweredOnDoesNotReconnectOrRediscoverARestoredStrapAfterDisconnect() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.disconnect()
        var actions: [String] = []

        for isConnected in [false, true] {
            manager.handleBluetoothPoweredOn(
                restored: (UUID(), isConnected),
                reconnect: { actions.append("reconnect") },
                resumeDiscovery: { actions.append("discover") })
        }

        XCTAssertTrue(actions.isEmpty, "both restored power-on branches must respect the stop request")
    }

    func testExplicitConnectRearmsAutomaticRecoveryAfterDisconnect() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.connect(model: .whoop4)
        manager.disconnect()

        manager.connect(model: .whoop5mg)
        XCTAssertTrue(manager.isWhoop5)
        manager.armReconnectForTesting(after: 30, secureRecovery: false)
        var reconnected = false
        XCTAssertTrue(manager.handOffArmedReconnect(targetState: .disconnected) { _ in
            reconnected = true
        })
        XCTAssertTrue(reconnected, "explicit Connect must restore normal automatic recovery")
        manager.disconnect()
    }

    func testColdLaunchCanStillConnectFromSystem() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        let target: WhoopModel = manager.isWhoop5 ? .whoop4 : .whoop5mg

        manager.connectFromSystem(model: target)

        XCTAssertEqual(manager.isWhoop5, target == .whoop5mg)
        manager.disconnect()
    }

    func testColdRestoreStillReconnectsOrResumesDiscovery() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        var actions: [String] = []

        manager.handleBluetoothPoweredOn(
            restored: (UUID(), false),
            reconnect: { actions.append("reconnect") },
            resumeDiscovery: { actions.append("discover") })
        manager.handleBluetoothPoweredOn(
            restored: (UUID(), true),
            reconnect: { actions.append("reconnect") },
            resumeDiscovery: { actions.append("discover") })

        XCTAssertEqual(actions, ["reconnect", "discover"])
        manager.disconnect()
    }
}
