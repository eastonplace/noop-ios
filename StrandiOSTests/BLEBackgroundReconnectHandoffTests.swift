import XCTest
import WhoopProtocol
@testable import NOOP

/// F1 round 3 (finding #1): a reconnect timer armed in the foreground never fires once iOS suspends the
/// app, and nothing would be pending to wake it. When the app leaves the foreground, BLEManager hands the
/// armed retry to an OS-managed pending connect, carrying a WHOOP 5/MG secure-recovery delay over to the
/// secure handshake. These drive a real manager's timer and flags; only the CoreBluetooth target is
/// supplied, because the simulator has no powered-on central to retrieve a strap from.
@MainActor
final class BLEBackgroundReconnectHandoffTests: XCTestCase {

    func testAnArmedSecureRecoveryTimerIsHandedOffWithItsDeadlineAsTheHandshakeHold() throws {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.armReconnectForTesting(after: 24, secureRecovery: true)
        let due = try XCTUnwrap(manager.reconnectDueAtForTesting)

        var issued: [Date?] = []
        XCTAssertTrue(manager.handOffArmedReconnect(targetState: .disconnected) { issued.append($0) })

        XCTAssertFalse(manager.reconnectArmedForTesting, "the dead timer is cancelled")
        XCTAssertNil(manager.reconnectDueAtForTesting)
        XCTAssertEqual(issued.count, 1, "exactly one pending connect is issued")
        let hold = try XCTUnwrap(issued.first.flatMap { $0 })
        XCTAssertEqual(hold.timeIntervalSince1970, due.timeIntervalSince1970, accuracy: 0.001,
                       "the secure handshake waits out the delay the timer would have")
    }

    func testAnArmedLadderTimerIsHandedOffWithNoHold() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.armReconnectForTesting(after: 12, secureRecovery: false)

        var issued: [Date?] = []
        XCTAssertTrue(manager.handOffArmedReconnect(targetState: .disconnecting) { issued.append($0) })

        XCTAssertFalse(manager.reconnectArmedForTesting)
        XCTAssertEqual(issued.count, 1)
        XCTAssertNil(issued.first.flatMap { $0 }, "a ladder retry has no secure delay to carry over")
    }

    func testNothingIsHandedOffWithoutAnArmedTimer() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        var issued = 0
        XCTAssertFalse(manager.handOffArmedReconnect(targetState: .disconnected) { _ in issued += 1 })
        XCTAssertEqual(issued, 0)
    }

    func testALiveOrConnectingStrapKeepsItsTimer() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.armReconnectForTesting(after: 6, secureRecovery: false)
        var issued = 0
        XCTAssertFalse(manager.handOffArmedReconnect(targetState: .connecting) { _ in issued += 1 })
        XCTAssertFalse(manager.handOffArmedReconnect(targetState: .connected) { _ in issued += 1 })
        XCTAssertEqual(issued, 0)
        XCTAssertTrue(manager.reconnectArmedForTesting, "the stale-timer guard handles a link that came up")
    }

    func testAUserDisconnectIsNeverReconnectedInTheBackground() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.disconnect()
        manager.armReconnectForTesting(after: 6, secureRecovery: false)
        var issued = 0
        XCTAssertFalse(manager.handOffArmedReconnect(targetState: .disconnected) { _ in issued += 1 })
        XCTAssertEqual(issued, 0)
    }

    /// Review R3b #1/#5: a reconnect with no hold of its own (a failed pending connect, a ladder-timer
    /// handoff) must not erase a running CLIENT_HELLO hold. Only the series' real ends clear it.
    func testARunningHandshakeHoldIsNeverShortenedAndOnlyTheSeriesEndsClearIt() throws {
        let manager = BLEManager(state: LiveState(), collector: nil)
        let held = Date().addingTimeInterval(60)
        manager.applyWhoop5HandshakeHoldForTesting(held)
        manager.applyWhoop5HandshakeHoldForTesting(nil)
        XCTAssertEqual(manager.whoop5HandshakeHoldForTesting, held)
        manager.applyWhoop5HandshakeHoldForTesting(Date().addingTimeInterval(10))
        XCTAssertEqual(manager.whoop5HandshakeHoldForTesting, held)
        let longer = Date().addingTimeInterval(90)
        manager.applyWhoop5HandshakeHoldForTesting(longer)
        XCTAssertEqual(manager.whoop5HandshakeHoldForTesting, longer)

        manager.disconnect()
        XCTAssertNil(manager.whoop5HandshakeHoldForTesting, "a user disconnect ends the series")
        manager.applyWhoop5HandshakeHoldForTesting(held)
        manager.connect()
        XCTAssertNil(manager.whoop5HandshakeHoldForTesting, "a user Connect starts a fresh series")
    }

    /// End to end through the real target lookup: with no powered-on central (the simulator) there is no
    /// strap to hand off to, so the timer stays armed for when the app comes back.
    func testWithNoReachableStrapTheBackgroundTransitionKeepsTheTimer() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.armReconnectForTesting(after: 30, secureRecovery: false)
        manager.handOffArmedReconnectForBackground()
        XCTAssertTrue(manager.reconnectArmedForTesting)
    }
}
