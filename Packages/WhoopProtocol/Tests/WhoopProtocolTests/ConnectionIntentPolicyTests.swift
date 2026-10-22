import Foundation
import XCTest
import WhoopProtocol

final class ConnectionIntentPolicyTests: XCTestCase {
    private let strapA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let strapB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!

    func testInitialSystemConnectIsAllowedButAnExplicitStopIsPreserved() {
        XCTAssertTrue(ConnectionIntentPolicy.allowsSystemReconnect(intentionalDisconnect: false))
        XCTAssertFalse(ConnectionIntentPolicy.allowsSystemReconnect(intentionalDisconnect: true))
    }

    func testRequestedConnectionIsAdmittedWithOrWithoutAPin() {
        for pin in [nil, strapA] {
            XCTAssertTrue(ConnectionIntentPolicy.acceptsConnectedPeripheral(
                callbackPeripheralID: strapA,
                requestedPeripheralID: strapA,
                preferredPeripheralID: pin,
                intentionalDisconnect: false))
        }
    }

    func testLateConnectionFromPreviousStrapCannotReplaceTheRequestedStrap() {
        XCTAssertFalse(ConnectionIntentPolicy.acceptsConnectedPeripheral(
            callbackPeripheralID: strapA,
            requestedPeripheralID: strapB,
            preferredPeripheralID: strapB,
            intentionalDisconnect: false))
        XCTAssertFalse(ConnectionIntentPolicy.acceptsConnectedPeripheral(
            callbackPeripheralID: strapA,
            requestedPeripheralID: strapB,
            preferredPeripheralID: nil,
            intentionalDisconnect: false), "the requested target still owns completion without a saved pin")
    }

    func testPinChangeInvalidatesAnEarlierPendingConnectionBeforeRetargetingFinishes() {
        XCTAssertFalse(ConnectionIntentPolicy.acceptsConnectedPeripheral(
            callbackPeripheralID: strapA,
            requestedPeripheralID: strapA,
            preferredPeripheralID: strapB,
            intentionalDisconnect: false))
    }

    func testLateConnectionAfterDisconnectOrForgetCannotBeAdmitted() {
        XCTAssertFalse(ConnectionIntentPolicy.acceptsConnectedPeripheral(
            callbackPeripheralID: strapA,
            requestedPeripheralID: strapA,
            preferredPeripheralID: strapA,
            intentionalDisconnect: true))
        XCTAssertFalse(ConnectionIntentPolicy.acceptsConnectedPeripheral(
            callbackPeripheralID: strapA,
            requestedPeripheralID: nil,
            preferredPeripheralID: nil,
            intentionalDisconnect: false), "a forgotten peripheral no longer has a requested owner")
    }

    func testCurrentFailedAttemptCanEnterTheReconnectPolicy() {
        XCTAssertTrue(ConnectionIntentPolicy.acceptsFailedConnection(
            callbackPeripheralID: strapA,
            requestedPeripheralID: strapA,
            preferredPeripheralID: strapA,
            intentionalDisconnect: false,
            requestedLinkState: .disconnected))
    }

    func testOldStrapFailureCannotAdvanceAnotherStrapsBackoff() {
        XCTAssertFalse(ConnectionIntentPolicy.acceptsFailedConnection(
            callbackPeripheralID: strapA,
            requestedPeripheralID: strapB,
            preferredPeripheralID: strapB,
            intentionalDisconnect: false,
            requestedLinkState: .disconnected))
    }

    func testLateFailureCannotRestartALiveOrNewPendingConnectionToTheSameStrap() {
        for state: ReconnectPolicy.LinkState in [.connected, .connecting, .disconnecting, .none] {
            XCTAssertFalse(ConnectionIntentPolicy.acceptsFailedConnection(
                callbackPeripheralID: strapA,
                requestedPeripheralID: strapA,
                preferredPeripheralID: strapA,
                intentionalDisconnect: false,
                requestedLinkState: state))
        }
    }

    func testFailureAfterAnExplicitStopCannotRestartRecovery() {
        XCTAssertFalse(ConnectionIntentPolicy.acceptsFailedConnection(
            callbackPeripheralID: strapA,
            requestedPeripheralID: strapA,
            preferredPeripheralID: strapA,
            intentionalDisconnect: true,
            requestedLinkState: .disconnected))
    }

    func testRemovingAnInactiveStrapDoesNotStopTheCurrentTarget() {
        XCTAssertFalse(ConnectionIntentPolicy.removalAffectsConnection(
            removedPeripheralID: strapB,
            currentPeripheralID: strapA,
            preferredPeripheralID: strapA,
            isActiveDevice: false))
    }

    func testRemovingAnInactiveRowWithoutAPeripheralDoesNotMeanForgetEverything() {
        XCTAssertFalse(ConnectionIntentPolicy.removalAffectsConnection(
            removedPeripheralID: nil,
            currentPeripheralID: strapA,
            preferredPeripheralID: strapA,
            isActiveDevice: false))
    }

    func testRemovingTheActiveRowReleasesItsConnectionEvenBeforeItsPeripheralIsKnown() {
        XCTAssertTrue(ConnectionIntentPolicy.removalAffectsConnection(
            removedPeripheralID: nil,
            currentPeripheralID: nil,
            preferredPeripheralID: nil,
            isActiveDevice: true))
    }

    func testRemovingThePhysicalCurrentOrPendingTargetAlwaysReleasesIt() {
        XCTAssertTrue(ConnectionIntentPolicy.removalAffectsConnection(
            removedPeripheralID: strapA,
            currentPeripheralID: strapA,
            preferredPeripheralID: nil,
            isActiveDevice: false))
        XCTAssertTrue(ConnectionIntentPolicy.removalAffectsConnection(
            removedPeripheralID: strapA,
            currentPeripheralID: nil,
            preferredPeripheralID: strapA,
            isActiveDevice: false))
    }
}
