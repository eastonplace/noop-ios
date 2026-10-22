import XCTest
import WhoopProtocol
@testable import NOOP

final class Whoop4RestoredCommandNotifyTests: XCTestCase {
    private func adopts(
        family: DeviceFamily = .whoop4,
        connected: Bool = true,
        currentPeripheral: Bool = true,
        currentCommandCharacteristic: Bool = true,
        notifying: Bool = true
    ) -> Bool {
        BLEManager.shouldAdoptRestoredCommandNotification(
            family: family, isConnected: connected,
            isCurrentPeripheral: currentPeripheral,
            isCurrentCommandCharacteristic: currentCommandCharacteristic,
            isNotifying: notifying)
    }

    func testRestoredLiveWhoop4CommandChannelSatisfiesNotificationHalfOfConnectSettled() {
        XCTAssertTrue(adopts(), "Already-active restored command notifications must not wait for a callback that will never arrive")
    }

    func testWhoop5StillRequiresItsFreshProtectedNotificationProof() {
        XCTAssertFalse(adopts(family: .whoop5))
    }

    func testDisconnectedLinkCannotAdoptNotificationState() {
        XCTAssertFalse(adopts(connected: false))
    }

    func testStalePeripheralCannotSupplyNotificationProofForCurrentConnection() {
        XCTAssertFalse(adopts(currentPeripheral: false))
    }

    func testStaleOrOtherCharacteristicCannotSupplyCommandChannelProof() {
        XCTAssertFalse(adopts(currentCommandCharacteristic: false))
    }

    func testUnsubscribedCommandChannelStillWaitsForRealNotificationCallback() {
        XCTAssertFalse(adopts(notifying: false))
    }
}
