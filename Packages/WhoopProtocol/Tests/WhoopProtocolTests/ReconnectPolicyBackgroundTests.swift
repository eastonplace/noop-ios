import XCTest
import WhoopProtocol

/// F1: a backgrounded app is suspended ~10 s after a BLE event, so a 12–60 s reconnect timer never fires
/// and nothing is left pending to wake it when the strap returns. Drops of a known strap must re-issue
/// an OS-managed pending connect at once; the ladder only paces retries that a timer can actually run.
final class ReconnectPolicyBackgroundTests: XCTestCase {

    /// The finding's scenario: a link at the edge of range flaps every < 60 s with no history ACK. With
    /// the old wiring the third and fourth drops armed 12 s and 24 s timers (dead in the background).
    func testFlappingDropsOfAKnownStrapNeverWaitOnATimer() {
        var policy = ReconnectPolicy()
        for _ in 0..<6 {
            XCTAssertEqual(policy.actionAfterDrop(knownTarget: true, forcedDelay: nil), .connectNow)
            policy.linkEnded(upSeconds: 20, acknowledgedHistory: false)
        }
        XCTAssertEqual(policy.attempts, 0, "a pending connect does not climb the ladder")
    }

    func testDeliberateSecureRecoveryDelayIsHonoured() {
        var policy = ReconnectPolicy()
        XCTAssertEqual(policy.actionAfterDrop(knownTarget: true, forcedDelay: 8), .retry(after: 8))
        XCTAssertEqual(policy.attempts, 0)
    }

    func testADropWithNoKnownStrapFallsBackToTheLadder() {
        var policy = ReconnectPolicy()
        XCTAssertEqual(policy.actionAfterDrop(knownTarget: false, forcedDelay: nil), .retry(after: 3))
        XCTAssertEqual(policy.actionAfterDrop(knownTarget: false, forcedDelay: nil), .retry(after: 6))
    }

    func testFailedConnectsClimbTheLadderInTheForeground() {
        var policy = ReconnectPolicy()
        let delays = (0..<4).map { _ in policy.actionAfterFailedConnect(knownTarget: true, appActive: true) }
        XCTAssertEqual(delays, [.retry(after: 3), .retry(after: 6), .retry(after: 12), .retry(after: 24)])
    }

    func testFailedConnectInTheBackgroundReissuesAPendingConnect() {
        var policy = ReconnectPolicy()
        _ = policy.actionAfterFailedConnect(knownTarget: true, appActive: true)
        _ = policy.actionAfterFailedConnect(knownTarget: true, appActive: true)
        XCTAssertEqual(policy.actionAfterFailedConnect(knownTarget: true, appActive: false), .connectNow)
        XCTAssertEqual(policy.actionAfterFailedConnect(knownTarget: false, appActive: false), .retry(after: 12),
                       "with nothing to connect to, only a timer is left")
    }
}
