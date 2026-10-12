import XCTest
import WhoopProtocol

/// BLE-7 + BLE-9 + CC-7: one reconnect ladder for every involuntary link loss, generation-checked
/// reconnect timers, and interrupted offloads that resume instead of being counted as empty.
final class ReconnectPolicyTests: XCTestCase {

    // MARK: Reconnect ladder (BLE-9)

    func testLadderClimbsThreeToSixtyAndHolds() {
        var policy = ReconnectPolicy()
        let delays = (0..<8).map { _ in policy.nextDelay() }
        XCTAssertEqual(delays, [3, 6, 12, 24, 48, 60, 60, 60])
    }

    /// The old disconnect path retried a flat 3 s forever. A link that connects and drops quickly now
    /// climbs the same ladder as a failed connect.
    func testQuickDropsKeepClimbing() {
        var policy = ReconnectPolicy()
        var delays: [TimeInterval] = []
        for _ in 0..<4 {
            policy.linkEnded(upSeconds: 2, acknowledgedHistory: false)
            delays.append(policy.nextDelay())
        }
        XCTAssertEqual(delays, [3, 6, 12, 24])
    }

    func testOnlyAHealthyLinkResetsTheLadder() {
        var policy = ReconnectPolicy()
        _ = policy.nextDelay(); _ = policy.nextDelay(); _ = policy.nextDelay()
        policy.linkEnded(upSeconds: 59, acknowledgedHistory: false)
        XCTAssertEqual(policy.nextDelay(), 24, "a 59 s link is not yet proven healthy")
        policy.linkEnded(upSeconds: 60, acknowledgedHistory: false)
        XCTAssertEqual(policy.nextDelay(), 3, "a link that stayed up 60 s resets the ladder")
        _ = policy.nextDelay()
        policy.linkEnded(upSeconds: 5, acknowledgedHistory: true)
        XCTAssertEqual(policy.nextDelay(), 3, "an acknowledged history chunk proves the link healthy")
        _ = policy.nextDelay()
        policy.linkEnded(upSeconds: nil, acknowledgedHistory: false)
        XCTAssertEqual(policy.nextDelay(), 12, "a failed connect (no link) never resets")
    }

    func testExplicitResetStartsOver() {
        var policy = ReconnectPolicy()
        _ = policy.nextDelay(); _ = policy.nextDelay()
        policy.reset()
        XCTAssertEqual(policy.nextDelay(), 3)
    }

    // MARK: Stale reconnect timers (CC-7)

    func testTimerFiresOnlyForItsOwnGenerationWhileTheLinkIsDown() {
        XCTAssertTrue(ReconnectPolicy.shouldFire(scheduledGeneration: 4, currentGeneration: 4, state: .disconnected))
        XCTAssertTrue(ReconnectPolicy.shouldFire(scheduledGeneration: 4, currentGeneration: 4, state: .none))
        XCTAssertFalse(ReconnectPolicy.shouldFire(scheduledGeneration: 4, currentGeneration: 5, state: .disconnected),
                       "a newer connection happened since the timer was armed")
        XCTAssertFalse(ReconnectPolicy.shouldFire(scheduledGeneration: 4, currentGeneration: 4, state: .connected),
                       "re-entering connect on a live link resets reassembly mid-stream")
        XCTAssertFalse(ReconnectPolicy.shouldFire(scheduledGeneration: 4, currentGeneration: 4, state: .connecting))
    }

    // MARK: Interrupted offloads (BLE-7)

    /// The finding's scenario: the link drops 20 s into an offload and comes back at 30 s. The interrupted
    /// session is not an "empty" one, and the post-bond `.connect` pass runs instead of waiting out the
    /// 90 s anti-flap floor measured from the failed start.
    func testDropAtTwentySecondsReconnectAtThirtyRunsConnect() {
        var tracker = HistoricalEmptyBackoffTracker()
        tracker.recordDisconnect(inFlight: true, freshProgress: false)
        XCTAssertEqual(tracker.consecutiveEmpty, 0, "a transport failure is not an empty attempt")
        XCTAssertEqual(tracker.interruptedSessions, 1)

        let start = 10_000.0
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .connect, now: start + 31.5, lastBackfillAt: start,
                                               emptyStreak: tracker.consecutiveEmpty,
                                               interruptedSessions: tracker.interruptedSessions))
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .connect, now: start + 31.5, lastBackfillAt: start),
                       "without the interruption the 90 s floor still applies")
        // The empty backoff did not move: the next periodic pass is still on the 15-minute floor.
        XCTAssertEqual(BackfillPolicy.periodicFloorSeconds(powerSaving: false,
                                                           emptyStreak: tracker.consecutiveEmpty), 900)
    }

    func testResumeLadderIsBoundedThenFallsBackToThePeriodicFloor() {
        XCTAssertEqual(BackfillPolicy.interruptedResumeLadderSeconds, [20, 60, 180])
        XCTAssertNil(BackfillPolicy.interruptedResumeFloorSeconds(interruptedSessions: 0, powerSaving: false,
                                                                 emptyStreak: 0))
        let floors = (1...4).map {
            BackfillPolicy.interruptedResumeFloorSeconds(interruptedSessions: $0, powerSaving: false, emptyStreak: 0)
        }
        XCTAssertEqual(floors, [20, 60, 180, 900])

        var tracker = HistoricalEmptyBackoffTracker()
        for _ in 0..<10 { tracker.recordDisconnect(inFlight: true, freshProgress: false) }
        XCTAssertEqual(tracker.interruptedSessions, 4, "the counter saturates one past the ladder")
        XCTAssertFalse(BackfillPolicy.shouldRun(trigger: .connect, now: 10_000 + 899, lastBackfillAt: 10_000,
                                                interruptedSessions: tracker.interruptedSessions))
        XCTAssertTrue(BackfillPolicy.shouldRun(trigger: .connect, now: 10_000 + 900, lastBackfillAt: 10_000,
                                               interruptedSessions: tracker.interruptedSessions))
    }

    func testFreshProgressAndCleanSessionEndsResetTheInterruptionLadder() {
        var tracker = HistoricalEmptyBackoffTracker()
        tracker.record(freshProgress: false)
        tracker.recordDisconnect(inFlight: true, freshProgress: false)
        tracker.recordDisconnect(inFlight: true, freshProgress: false)
        XCTAssertEqual(tracker.interruptedSessions, 2)
        XCTAssertEqual(tracker.consecutiveEmpty, 1)

        tracker.recordDisconnect(inFlight: true, freshProgress: true)
        XCTAssertEqual(tracker.interruptedSessions, 1, "a productive interruption restarts at the first rung")
        XCTAssertEqual(tracker.consecutiveEmpty, 0)

        tracker.record(freshProgress: false)
        XCTAssertEqual(tracker.interruptedSessions, 0, "a session that reached its own end clears it")

        tracker.recordDisconnect(inFlight: false, freshProgress: false)
        XCTAssertEqual(tracker.interruptedSessions, 0, "an idle disconnect is not an interrupted session")
    }
}
