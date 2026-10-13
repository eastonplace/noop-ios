import XCTest
import NoopPhase34Core
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

    /// Review R3b #1/#5, R3c 3: a pending reconnect with no hold of its own (a failed connect, a
    /// ladder-timer handoff) must not erase a running CLIENT_HELLO hold. Driven through the pending
    /// reconnect's own setup (everything but the CoreBluetooth connect). Only the series' ends clear it.
    func testAPendingReconnectNeverShortensARunningHandshakeHold() throws {
        let manager = BLEManager(state: LiveState(), collector: nil)
        let held = Date().addingTimeInterval(60)
        manager.beginPendingReconnectForTesting(holdHandshakeUntil: held)
        XCTAssertEqual(manager.whoop5HandshakeHoldForTesting, held)
        manager.armReconnectForTesting(after: 6, secureRecovery: false)
        manager.beginPendingReconnectForTesting(holdHandshakeUntil: nil)
        XCTAssertEqual(manager.whoop5HandshakeHoldForTesting, held, "a reconnect with no hold keeps the running one")
        XCTAssertFalse(manager.reconnectArmedForTesting, "the pending connect replaces the armed timer")
        manager.beginPendingReconnectForTesting(holdHandshakeUntil: Date().addingTimeInterval(10))
        XCTAssertEqual(manager.whoop5HandshakeHoldForTesting, held, "a shorter hold does not cut it short")
        let longer = Date().addingTimeInterval(90)
        manager.beginPendingReconnectForTesting(holdHandshakeUntil: longer)
        XCTAssertEqual(manager.whoop5HandshakeHoldForTesting, longer)

        manager.disconnect()
        XCTAssertNil(manager.whoop5HandshakeHoldForTesting, "a user disconnect ends the series")
        manager.beginPendingReconnectForTesting(holdHandshakeUntil: held)
        manager.connect()
        XCTAssertNil(manager.whoop5HandshakeHoldForTesting, "a user Connect starts a fresh series")
    }

    /// Review R3b #2/#7, R3c 3: a drop while the attempt's CLIENT_HELLO is still held never reached the
    /// secure handshake, so it must not climb the secure series toward its sticky pause. Driven through the
    /// same classification didDisconnect uses, with a real held attempt.
    func testADropWhileTheHelloIsHeldIsNotASecureFailure() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.connect(model: .whoop5mg)   // selects the 5/MG family; the simulator's Bluetooth is off
        let held = Whoop5SecureSessionID(peripheralID: UUID(), connectGeneration: 1, attemptEpoch: 1)
        let other = Whoop5SecureSessionID(peripheralID: UUID(), connectGeneration: 1, attemptEpoch: 2)
        XCTAssertTrue(manager.disconnectCountsAsSecureFailure(sessionID: held, state: .standardOnly),
                      "before the hold, a pre-proof drop counts")
        manager.holdWhoop5ClientHelloForTesting(held, until: Date().addingTimeInterval(30))

        XCTAssertFalse(manager.disconnectCountsAsSecureFailure(sessionID: held, state: .standardOnly),
                       "the held attempt's drop is not a secure failure")
        XCTAssertTrue(manager.disconnectCountsAsSecureFailure(sessionID: other, state: .standardOnly),
                      "another attempt's pre-proof drop still counts")
        manager.disconnect()
    }

    /// Review R3b #3: the background-cap pause means "too many background attempts with no healthy link",
    /// so a healthy link lifts it; an unhealthy one does not.
    func testAHealthyLinkLiftsTheBackgroundCapPause() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        manager.pauseAutoReconnectForBackgroundCapForTesting()
        manager.recordLinkEnded(upSeconds: 20, acknowledgedHistory: false)
        XCTAssertTrue(manager.autoReconnectPausedForBackgroundCapForTesting, "a 20 s link without an ACK is not healthy")
        manager.recordLinkEnded(upSeconds: 61, acknowledgedHistory: false)
        XCTAssertFalse(manager.autoReconnectPausedForBackgroundCapForTesting)

        manager.pauseAutoReconnectForBackgroundCapForTesting()
        manager.recordLinkEnded(upSeconds: 5, acknowledgedHistory: true)
        XCTAssertFalse(manager.autoReconnectPausedForBackgroundCapForTesting, "a history ACK proves the link healthy")
    }

    /// Review R3b #3: every automatic path respects the pause, Bluetooth power-on included
    /// (connectFromSystem), until the app comes to the foreground.
    func testSystemReconnectsRespectTheBackgroundCapPauseUntilForeground() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        let wasWhoop5 = manager.isWhoop5
        manager.pauseAutoReconnectForBackgroundCapForTesting()
        manager.connectFromSystem(model: wasWhoop5 ? .whoop4 : .whoop5mg)
        XCTAssertEqual(manager.isWhoop5, wasWhoop5, "a paused system reconnect never reaches the connect path")
        manager.resumeAutoReconnectInForeground()
        XCTAssertFalse(manager.autoReconnectPausedForBackgroundCapForTesting)
    }

    /// Review R3b #4/#6: a suspended app runs no timer and a quiet strap sends no notification, so a
    /// CLIENT_HELLO hold takes a background task for its length, and the task ends with the hold.
    func testAHoldKeepsTheAppRunningUntilTheSeriesEnds() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        let session = Whoop5SecureSessionID(peripheralID: UUID(), connectGeneration: 1, attemptEpoch: 1)
        manager.holdWhoop5ClientHelloForTesting(session, until: Date().addingTimeInterval(30))
        XCTAssertEqual(manager.whoop5HeldClientHelloForTesting, session)
        XCTAssertTrue(manager.whoop5HoldTimerArmedForTesting)
        XCTAssertTrue(manager.whoop5HoldBackgroundTaskActiveForTesting, "a background task covers the hold")
        manager.disconnect()
        XCTAssertNil(manager.whoop5HeldClientHelloForTesting)
        XCTAssertFalse(manager.whoop5HoldTimerArmedForTesting)
        XCTAssertFalse(manager.whoop5HoldBackgroundTaskActiveForTesting, "the task ends with the hold")
    }

    func testTheHoldDeadlineEndsTheBackgroundTask() async throws {
        let manager = BLEManager(state: LiveState(), collector: nil)
        let session = Whoop5SecureSessionID(peripheralID: UUID(), connectGeneration: 1, attemptEpoch: 1)
        manager.holdWhoop5ClientHelloForTesting(session, until: Date().addingTimeInterval(0.2))
        XCTAssertTrue(manager.whoop5HoldBackgroundTaskActiveForTesting)
        for _ in 0..<50 where manager.whoop5HoldBackgroundTaskActiveForTesting {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(manager.whoop5HeldClientHelloForTesting, "the deadline released the hold")
        XCTAssertNil(manager.whoop5HandshakeHoldForTesting, "a deadline that has passed is cleared")
        XCTAssertFalse(manager.whoop5HoldTimerArmedForTesting)
        XCTAssertFalse(manager.whoop5HoldBackgroundTaskActiveForTesting, "the app is free to suspend once the hold ends")
    }

    /// Review R3c 1: the background time iOS grants (~30 s) ends before the 60 s rung. While the strap is
    /// still notifying, the expiry ends only the background task; the hold, its deadline and the release
    /// timer stay, so the next notification after the deadline sends the hello on time.
    func testBackgroundExpiryKeepsTheHoldWhileTheStrapIsNotifying() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        let session = Whoop5SecureSessionID(peripheralID: UUID(), connectGeneration: 1, attemptEpoch: 1)
        let deadline = Date().addingTimeInterval(60)
        manager.holdWhoop5ClientHelloForTesting(session, until: deadline)
        let expiry = Date().addingTimeInterval(30)
        manager.noteInboundStrapDataForTesting(at: expiry.addingTimeInterval(-1))

        manager.whoop5HoldBackgroundTimeExpiring(now: expiry)

        XCTAssertEqual(manager.whoop5HeldClientHelloForTesting, session, "the hello is still held")
        XCTAssertEqual(manager.whoop5HandshakeHoldForTesting, deadline, "the real deadline stands")
        XCTAssertTrue(manager.whoop5HoldTimerArmedForTesting)
        XCTAssertFalse(manager.whoop5HoldBackgroundTaskActiveForTesting, "only the background task ends")
        manager.disconnect()
    }

    /// Review R3c 1: on a quiet link nothing would wake the app at the deadline, so the expiry releases
    /// the hello. With no live link to send on (as here), an unexpired deadline stands for the reconnect.
    func testBackgroundExpiryOnAQuietLinkReleasesTheHello() {
        let manager = BLEManager(state: LiveState(), collector: nil)
        let session = Whoop5SecureSessionID(peripheralID: UUID(), connectGeneration: 1, attemptEpoch: 1)
        let deadline = Date().addingTimeInterval(60)
        manager.holdWhoop5ClientHelloForTesting(session, until: deadline)
        let expiry = Date().addingTimeInterval(30)
        manager.noteInboundStrapDataForTesting(at: expiry.addingTimeInterval(-25))

        manager.whoop5HoldBackgroundTimeExpiring(now: expiry)

        XCTAssertNil(manager.whoop5HeldClientHelloForTesting, "the hold is released")
        XCTAssertFalse(manager.whoop5HoldTimerArmedForTesting)
        XCTAssertFalse(manager.whoop5HoldBackgroundTaskActiveForTesting)
        XCTAssertEqual(manager.whoop5HandshakeHoldForTesting, deadline,
                       "nothing was sent, so the unexpired deadline still covers the next attempt")
        manager.disconnect()
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
