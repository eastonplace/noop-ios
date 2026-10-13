import XCTest
import WhoopProtocol

/// F1: a backgrounded app is suspended ~10 s after a BLE event, so a reconnect timer never fires and
/// nothing is left pending to wake it when the strap returns. In the foreground the ladder still paces
/// every retry (BLE-9's churn guard); in the background a known strap gets an OS-managed pending connect,
/// bounded by `backgroundRetryCap`, and a WHOOP 5/MG secure-recovery delay moves to the handshake.
final class ReconnectPolicyBackgroundTests: XCTestCase {

    private typealias Action = ReconnectPolicy.Action

    // MARK: Every cell of (appActive × event × knownTarget × forcedDelay × count past cap)

    private struct Cell: CustomStringConvertible {
        let appActive: Bool
        let event: ReconnectPolicy.Event
        let knownTarget: Bool
        let forcedDelay: TimeInterval?
        let pastCap: Bool
        var description: String {
            "appActive=\(appActive) event=\(event) knownTarget=\(knownTarget) "
                + "forcedDelay=\(forcedDelay.map { "\($0)" } ?? "nil") pastCap=\(pastCap)"
        }
    }

    /// The expected answer for one cell, starting from a fresh ladder (next rung = 3 s).
    private func expected(_ cell: Cell) -> Action {
        if cell.appActive || !cell.knownTarget {
            // A timer can run (foreground), or it is all that is left (no strap to connect to).
            return .retry(after: cell.forcedDelay ?? 3)
        }
        if cell.pastCap { return .pause }
        if let delay = cell.forcedDelay { return .connectNowHoldingHandshake(for: delay) }
        return .connectNow
    }

    func testEveryCellOfThePolicyMatrix() {
        var cells: [Cell] = []
        for appActive in [true, false] {
            for event in [ReconnectPolicy.Event.drop, .failedConnect] {
                for knownTarget in [true, false] {
                    for forcedDelay in [nil, 12] as [TimeInterval?] {
                        for pastCap in [false, true] {
                            cells.append(Cell(appActive: appActive, event: event, knownTarget: knownTarget,
                                              forcedDelay: forcedDelay, pastCap: pastCap))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(cells.count, 32)
        for cell in cells {
            var policy = ReconnectPolicy()
            if cell.pastCap {
                for _ in 0..<ReconnectPolicy.backgroundRetryCap {
                    _ = policy.action(after: .drop, appActive: false, knownTarget: true, forcedDelay: nil)
                }
                XCTAssertEqual(policy.backgroundRetries, ReconnectPolicy.backgroundRetryCap, "\(cell)")
                XCTAssertEqual(policy.attempts, 0, "background attempts never climb the ladder: \(cell)")
            }
            let action = policy.action(after: cell.event, appActive: cell.appActive,
                                       knownTarget: cell.knownTarget, forcedDelay: cell.forcedDelay)
            XCTAssertEqual(action, expected(cell), "\(cell)")
        }
    }

    // MARK: Foreground pacing (BLE-7 / BLE-9)

    /// The BLE-9 churn: a known strap that connects and drops quickly in the foreground must climb the
    /// ladder, not re-kick at link speed.
    func testQuickForegroundDropsOfAKnownStrapClimbTheLadder() {
        var policy = ReconnectPolicy()
        var actions: [Action] = []
        for _ in 0..<5 {
            policy.linkEnded(upSeconds: 2, acknowledgedHistory: false)
            actions.append(policy.action(after: .drop, appActive: true, knownTarget: true, forcedDelay: nil))
        }
        XCTAssertEqual(actions, [.retry(after: 3), .retry(after: 6), .retry(after: 12),
                                 .retry(after: 24), .retry(after: 48)])
        XCTAssertEqual(policy.backgroundRetries, 0)
    }

    func testFailedConnectsClimbTheLadderInTheForeground() {
        var policy = ReconnectPolicy()
        let actions = (0..<4).map { _ in
            policy.action(after: .failedConnect, appActive: true, knownTarget: true, forcedDelay: nil)
        }
        XCTAssertEqual(actions, [.retry(after: 3), .retry(after: 6), .retry(after: 12), .retry(after: 24)])
    }

    /// A deliberate 5/MG secure-recovery delay in the foreground stays a timer and does not use a rung.
    func testForegroundSecureRecoveryDelayStaysATimer() {
        var policy = ReconnectPolicy()
        for delay in [3, 6, 12, 24, 60] as [TimeInterval] {
            XCTAssertEqual(policy.action(after: .drop, appActive: true, knownTarget: true, forcedDelay: delay),
                           .retry(after: delay))
        }
        XCTAssertEqual(policy.attempts, 0)
        XCTAssertEqual(policy.action(after: .drop, appActive: true, knownTarget: true, forcedDelay: 0),
                       .retry(after: 0), "an explicit physical reset reconnects at once")
    }

    // MARK: Background

    /// The F1 scenario: a link at the edge of range flaps every < 60 s overnight. Each drop re-issues a
    /// pending connect at once, and the ladder is untouched for when the app comes back.
    func testBackgroundDropsReissueAPendingConnectWithoutClimbingTheLadder() {
        var policy = ReconnectPolicy()
        for _ in 0..<ReconnectPolicy.backgroundRetryCap {
            policy.linkEnded(upSeconds: 20, acknowledgedHistory: false)
            XCTAssertEqual(policy.action(after: .drop, appActive: false, knownTarget: true, forcedDelay: nil),
                           .connectNow)
        }
        XCTAssertEqual(policy.attempts, 0)
    }

    /// Findings #2/#8: 12, 24 and 60 s secure-recovery delays used to go on timers that never fire in the
    /// background. They now reconnect at once and hold the secure handshake instead.
    func testBackgroundSecureRecoveryDelaysMoveToTheHandshake() {
        var policy = ReconnectPolicy()
        for delay in [12, 24, 60] as [TimeInterval] {
            XCTAssertEqual(policy.action(after: .drop, appActive: false, knownTarget: true, forcedDelay: delay),
                           .connectNowHoldingHandshake(for: delay))
        }
        XCTAssertEqual(policy.action(after: .drop, appActive: false, knownTarget: true, forcedDelay: 0),
                       .connectNow, "a zero delay holds nothing")
    }

    /// Finding #3: instant background failures used to loop as fast as the callbacks arrived. The cap
    /// pauses auto-reconnect on the first event past it, whatever mix of drops and failures got there.
    func testConsecutiveBackgroundFailuresPausePastTheCap() {
        var policy = ReconnectPolicy()
        for i in 0..<ReconnectPolicy.backgroundRetryCap {
            let event: ReconnectPolicy.Event = i.isMultiple(of: 2) ? .failedConnect : .drop
            policy.linkEnded(upSeconds: i.isMultiple(of: 2) ? nil : 3, acknowledgedHistory: false)
            XCTAssertEqual(policy.action(after: event, appActive: false, knownTarget: true, forcedDelay: nil),
                           .connectNow, "attempt \(i + 1)")
        }
        XCTAssertEqual(policy.action(after: .failedConnect, appActive: false, knownTarget: true, forcedDelay: nil),
                       .pause)
    }

    func testAHealthyLinkResetsTheBackgroundCount() {
        var policy = ReconnectPolicy()
        for _ in 0..<ReconnectPolicy.backgroundRetryCap {
            _ = policy.action(after: .failedConnect, appActive: false, knownTarget: true, forcedDelay: nil)
        }
        policy.linkEnded(upSeconds: 59, acknowledgedHistory: false)
        XCTAssertEqual(policy.backgroundRetries, ReconnectPolicy.backgroundRetryCap, "59 s is not yet healthy")
        policy.linkEnded(upSeconds: 8, acknowledgedHistory: true)
        XCTAssertEqual(policy.backgroundRetries, 0, "an acknowledged history chunk proves the link healthy")
        XCTAssertEqual(policy.action(after: .drop, appActive: false, knownTarget: true, forcedDelay: nil), .connectNow)

        for _ in 0..<ReconnectPolicy.backgroundRetryCap {
            _ = policy.action(after: .drop, appActive: false, knownTarget: true, forcedDelay: nil)
        }
        policy.linkEnded(upSeconds: 60, acknowledgedHistory: false)
        XCTAssertEqual(policy.backgroundRetries, 0, "a link that stayed up 60 s resets the count")
    }

    /// Review R3b #3: the manager lifts a background-cap pause when a link proves healthy, so linkEnded
    /// reports it.
    func testLinkEndedReportsWhetherTheLinkProvedHealthy() {
        var policy = ReconnectPolicy()
        XCTAssertFalse(policy.linkEnded(upSeconds: 59, acknowledgedHistory: false))
        XCTAssertFalse(policy.linkEnded(upSeconds: nil, acknowledgedHistory: false))
        XCTAssertTrue(policy.linkEnded(upSeconds: 60, acknowledgedHistory: false))
        XCTAssertTrue(policy.linkEnded(upSeconds: 3, acknowledgedHistory: true))
    }

    func testForegroundAndUserConnectResetTheBackgroundCount() {
        var policy = ReconnectPolicy()
        for _ in 0...ReconnectPolicy.backgroundRetryCap {
            _ = policy.action(after: .drop, appActive: false, knownTarget: true, forcedDelay: nil)
        }
        policy.enteredForeground()
        XCTAssertEqual(policy.backgroundRetries, 0)
        XCTAssertEqual(policy.action(after: .drop, appActive: false, knownTarget: true, forcedDelay: nil), .connectNow)

        for _ in 0...ReconnectPolicy.backgroundRetryCap {
            _ = policy.action(after: .drop, appActive: false, knownTarget: true, forcedDelay: nil)
        }
        policy.reset()
        XCTAssertEqual(policy.backgroundRetries, 0)
        XCTAssertEqual(policy.attempts, 0)
    }

    /// With nothing to connect to (Bluetooth off, the pinned strap not retrievable) only the timer is
    /// left, in either state, and it neither counts nor pauses.
    func testNoKnownStrapFallsBackToTheLadderAndIsNotCounted() {
        var policy = ReconnectPolicy()
        XCTAssertEqual(policy.action(after: .drop, appActive: false, knownTarget: false, forcedDelay: nil),
                       .retry(after: 3))
        XCTAssertEqual(policy.action(after: .failedConnect, appActive: false, knownTarget: false, forcedDelay: nil),
                       .retry(after: 6))
        XCTAssertEqual(policy.backgroundRetries, 0)
    }

    // MARK: The secure-handshake hold is never shortened (review R3b #1/#5)

    /// A failed pending connect (no delay of its own) or a ladder-timer handoff used to overwrite a running
    /// hold with nil, so CLIENT_HELLO went out before the secure-recovery deadline.
    func testARunningHandshakeHoldIsNeverShortened() {
        let now = Date(timeIntervalSince1970: 1_000)
        let held = now.addingTimeInterval(60)
        XCTAssertEqual(ReconnectPolicy.laterHandshakeHold(existing: held, new: nil, now: now), held,
                       "a reconnect with no hold of its own keeps the running one")
        XCTAssertEqual(ReconnectPolicy.laterHandshakeHold(existing: held, new: now.addingTimeInterval(10), now: now),
                       held, "a shorter hold does not cut it short")
        XCTAssertEqual(ReconnectPolicy.laterHandshakeHold(existing: held, new: now.addingTimeInterval(90), now: now),
                       now.addingTimeInterval(90), "a longer hold extends it")
        XCTAssertNil(ReconnectPolicy.laterHandshakeHold(existing: now.addingTimeInterval(-1), new: nil, now: now),
                     "an expired hold is gone")
        XCTAssertEqual(ReconnectPolicy.laterHandshakeHold(existing: now.addingTimeInterval(-1),
                                                          new: now.addingTimeInterval(5), now: now),
                       now.addingTimeInterval(5))
        XCTAssertNil(ReconnectPolicy.laterHandshakeHold(existing: nil, new: nil, now: now))
    }

    /// Review R3c 1: iOS ends a hold's background time (~30 s) before the 60 s rung. Only a quiet link
    /// sends the hello early; a strap still notifying releases it at the real deadline.
    func testOnlyAQuietLinkSendsTheHeldHandshakeWhenBackgroundTimeEnds() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(ReconnectPolicy.shouldSendHeldHandshakeOnBackgroundExpiry(
            lastInboundAt: now.addingTimeInterval(-1), now: now), "standard HR about once a second")
        XCTAssertFalse(ReconnectPolicy.shouldSendHeldHandshakeOnBackgroundExpiry(
            lastInboundAt: now.addingTimeInterval(-ReconnectPolicy.quietLinkSeconds), now: now))
        XCTAssertTrue(ReconnectPolicy.shouldSendHeldHandshakeOnBackgroundExpiry(
            lastInboundAt: now.addingTimeInterval(-25), now: now), "nothing since the reconnect")
        XCTAssertTrue(ReconnectPolicy.shouldSendHeldHandshakeOnBackgroundExpiry(lastInboundAt: nil, now: now),
                      "no notification on this link at all")
    }

    // MARK: Background handoff of an armed timer (finding #1)

    func testAnArmedRetryIsHandedOffWhenTheAppLeavesTheForeground() {
        for state in [ReconnectPolicy.LinkState.none, .disconnected, .disconnecting] {
            XCTAssertTrue(ReconnectPolicy.shouldHandOffArmedRetryOnBackground(
                timerArmed: true, intentionalDisconnect: false, autoReconnectPaused: false, target: state), "\(state)")
        }
    }

    func testTheHandoffIsSkippedWhenThereIsNothingToHandOff() {
        XCTAssertFalse(ReconnectPolicy.shouldHandOffArmedRetryOnBackground(
            timerArmed: false, intentionalDisconnect: false, autoReconnectPaused: false, target: .disconnected),
                       "no timer armed")
        XCTAssertFalse(ReconnectPolicy.shouldHandOffArmedRetryOnBackground(
            timerArmed: true, intentionalDisconnect: true, autoReconnectPaused: false, target: .disconnected),
                       "the user tore the link down")
        XCTAssertFalse(ReconnectPolicy.shouldHandOffArmedRetryOnBackground(
            timerArmed: true, intentionalDisconnect: false, autoReconnectPaused: true, target: .disconnected),
                       "auto-reconnect is paused")
        XCTAssertFalse(ReconnectPolicy.shouldHandOffArmedRetryOnBackground(
            timerArmed: true, intentionalDisconnect: false, autoReconnectPaused: false, target: nil),
                       "no known strap")
        XCTAssertFalse(ReconnectPolicy.shouldHandOffArmedRetryOnBackground(
            timerArmed: true, intentionalDisconnect: false, autoReconnectPaused: false, target: .connected))
        XCTAssertFalse(ReconnectPolicy.shouldHandOffArmedRetryOnBackground(
            timerArmed: true, intentionalDisconnect: false, autoReconnectPaused: false, target: .connecting))
    }
}
