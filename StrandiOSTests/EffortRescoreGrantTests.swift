import XCTest
@testable import NOOP

/// Pins when the v3/settle rescore grant may start and that a foreground return stops it. A grant that started on an
/// `.inactive` edge (Control Center, the app switcher) used to keep running flat out in the foreground, holding the
/// analysis lock and the store queue and blocking post-sync scoring, refreshes and edits.
@MainActor
final class EffortRescoreGrantTests: XCTestCase {

    @MainActor
    private final class Probe {
        var background = false
        var mayRun = true
        var runs = 0
        var pausedWhenStarted: Bool?
        var pausedAfterBackgroundEnded: Bool?
        var sawCancellation = false
        var resume: CheckedContinuation<Void, Never>?
    }

    /// A background-execution assertion that records what the grant asks of it.
    @MainActor
    private final class FakeAssertion {
        private(set) var begun = 0
        private(set) var ended: [Int] = []
        private var handlers: [@MainActor () -> Void] = []

        var provider: BackgroundExecutionAssertion {
            BackgroundExecutionAssertion(
                begin: { [self] onExpiry in
                    begun += 1
                    handlers.append(onExpiry)
                    return begun
                },
                end: { [self] id in ended.append(id) })
        }

        /// iOS calling the expiration handler of the `index`th assertion (the newest by default).
        func expire(_ index: Int? = nil) {
            guard let handler = index.map({ handlers[$0] }) ?? handlers.last else { return }
            handler()
        }
    }

    /// Waits for an effect of the grant's `.background`-priority task. `Task.yield` alone is not enough: with only a
    /// background-priority job pending, the runtime hands the main actor straight back to the (higher-priority) test
    /// without running it, so the test has to suspend for real. Polls a bounded number of times rather than until a
    /// wall-clock deadline, so a starved machine only makes it wait longer: the round-2 sim run hit 20 s deadlines on
    /// a host at load 200+ (one test took 575 s) although the grant was fine. A real hang still fails after 4,000
    /// polls (about 20 s on a healthy machine).
    private func waitUntil(_ condition: () -> Bool) async {
        var polls = 0
        while !condition(), polls < 4_000 {
            polls += 1
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// For "nothing happened" checks: lets any job the grant already queued run first.
    private func settle() async {
        await Task(priority: .background) { @MainActor in }.value
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func start(_ grant: EffortRescoreGrant, _ probe: Probe,
                       run: @escaping @MainActor (Probe, () -> Bool) async -> Void) {
        grant.start(
            isBackground: { probe.background },
            mayRun: { probe.mayRun },
            run: { shouldPause in
                probe.runs += 1
                probe.pausedWhenStarted = shouldPause()
                await run(probe, shouldPause)
            })
    }

    func testAnInactiveEdgeStartsNoGrant() async {
        let grant = EffortRescoreGrant(assertion: FakeAssertion().provider)
        let probe = Probe()
        probe.background = false
        start(grant, probe) { _, _ in }
        await settle()
        XCTAssertEqual(probe.runs, 0, "Control Center / the app switcher is not the background")
        XCTAssertFalse(grant.isActive)
    }

    func testTheOtherGatesStopAGrantFromStarting() async {
        let grant = EffortRescoreGrant(assertion: FakeAssertion().provider)
        let probe = Probe()
        probe.background = true
        probe.mayRun = false
        start(grant, probe) { _, _ in }
        await settle()
        XCTAssertEqual(probe.runs, 0, "an import, a backfill, a workout or no first paint blocks the grant")
        XCTAssertFalse(grant.isActive)
    }

    func testABackgroundEdgeStartsOneUnpausedGrantAndItClears() async {
        let grant = EffortRescoreGrant(assertion: FakeAssertion().provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { _, _ in }
        await waitUntil { probe.runs == 1 && !grant.isActive }
        XCTAssertEqual(probe.runs, 1)
        XCTAssertEqual(probe.pausedWhenStarted, false)
        XCTAssertFalse(grant.isActive, "a finished grant frees the next edge to start one")
    }

    func testLeavingTheBackgroundPausesTheGrantBeforeItsNextChunk() async {
        let grant = EffortRescoreGrant(assertion: FakeAssertion().provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, shouldPause in
            // The first await of the migration: the app comes back while the store reads are in flight.
            await withCheckedContinuation { probe.resume = $0 }
            probe.pausedAfterBackgroundEnded = shouldPause()
        }
        await waitUntil { probe.resume != nil }
        XCTAssertEqual(probe.runs, 1)
        probe.background = false
        probe.resume?.resume()
        await waitUntil { probe.pausedAfterBackgroundEnded != nil }
        XCTAssertEqual(probe.pausedAfterBackgroundEnded, true, "the driver sees pause before it starts a chunk")
    }

    func testAForegroundReturnCancelsTheRunningGrant() async {
        let grant = EffortRescoreGrant(assertion: FakeAssertion().provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            do { try await Task.sleep(for: .seconds(60)) } catch { probe.sawCancellation = true }
        }
        await waitUntil { probe.runs == 1 }
        XCTAssertEqual(probe.runs, 1)
        XCTAssertTrue(grant.isActive)
        grant.cancel()
        XCTAssertFalse(grant.isActive)
        await waitUntil { probe.sawCancellation }
        XCTAssertTrue(probe.sawCancellation, "the in-flight chunk is told to stop")
    }

    func testAGrantIsNotStartedTwiceWhileOneIsActive() async {
        let grant = EffortRescoreGrant(assertion: FakeAssertion().provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            await withCheckedContinuation { probe.resume = $0 }
        }
        await waitUntil { probe.resume != nil }
        start(grant, probe) { _, _ in }
        await settle()
        XCTAssertEqual(probe.runs, 1)
        probe.resume?.resume()
        await waitUntil { !grant.isActive }
        XCTAssertFalse(grant.isActive)
    }

    func testAfterACancelTheNextBackgroundEdgeStartsAgain() async {
        let grant = EffortRescoreGrant(assertion: FakeAssertion().provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            do { try await Task.sleep(for: .seconds(60)) } catch { probe.sawCancellation = true }
        }
        await waitUntil { probe.runs == 1 }
        grant.cancel()
        start(grant, probe) { _, _ in }
        await waitUntil { probe.runs == 2 }
        XCTAssertEqual(probe.runs, 2, "a cancelled grant replays from the durable cursor on the next background edge")
    }

    /// The user leaves the app again while the cancelled grant is still inside the engine (waiting for its next
    /// checkpoint, often behind foreground store work). The engine drops a second caller silently while one is
    /// running, so a grant that started at once would do nothing for the whole stay. It waits for the first.
    func testAGrantStartedWhileACancelledOneUnwindsWaitsForItInsteadOfNoOpping() async {
        let grant = EffortRescoreGrant(assertion: FakeAssertion().provider)
        let probe = Probe()
        probe.background = true
        // The first run ignores cancellation until released, like an engine that has not reached a checkpoint.
        start(grant, probe) { probe, _ in
            await withCheckedContinuation { probe.resume = $0 }
        }
        await waitUntil { probe.resume != nil }
        grant.cancel()
        XCTAssertFalse(grant.isActive)
        XCTAssertTrue(grant.isUnwinding)

        start(grant, probe) { _, _ in }
        XCTAssertTrue(grant.isActive)
        await settle()
        XCTAssertEqual(probe.runs, 1, "the new grant has not entered the engine while the old one is in it")

        probe.resume?.resume()
        await waitUntil { probe.runs == 2 && !grant.isActive && !grant.isUnwinding }
        XCTAssertEqual(probe.runs, 2, "then it runs, so the stay does its work")
        XCTAssertFalse(grant.isActive)
        XCTAssertFalse(grant.isUnwinding)
    }

    /// A grant that is cancelled while it waits behind an unwinding one never enters the engine at all.
    func testAGrantCancelledWhileItWaitsBehindAnUnwindingOneNeverRuns() async {
        let grant = EffortRescoreGrant(assertion: FakeAssertion().provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            await withCheckedContinuation { probe.resume = $0 }
        }
        await waitUntil { probe.resume != nil }
        grant.cancel()
        start(grant, probe) { _, _ in }
        grant.cancel()
        XCTAssertFalse(grant.isActive)

        probe.resume?.resume()
        await waitUntil { !grant.isUnwinding }
        await settle()
        XCTAssertEqual(probe.runs, 1)
        XCTAssertFalse(grant.isUnwinding)
    }

    // MARK: - The background-execution assertion

    func testARunningGrantHoldsOneAssertionAndEndsItWhenItFinishes() async {
        let assertion = FakeAssertion()
        let grant = EffortRescoreGrant(assertion: assertion.provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            await withCheckedContinuation { probe.resume = $0 }
        }
        await waitUntil { probe.resume != nil }
        XCTAssertEqual(assertion.begun, 1, "the process is kept alive for the chunk")
        XCTAssertTrue(assertion.ended.isEmpty)
        probe.resume?.resume()
        await waitUntil { !grant.isActive }
        XCTAssertEqual(assertion.ended, [1])
    }

    func testAGrantThatDoesNotRunNeverTakesAnAssertion() async {
        let assertion = FakeAssertion()
        let grant = EffortRescoreGrant(assertion: assertion.provider)
        let probe = Probe()
        probe.background = false
        start(grant, probe) { _, _ in }
        await settle()
        XCTAssertEqual(assertion.begun, 0)
        XCTAssertTrue(assertion.ended.isEmpty)
    }

    func testAForegroundCancelEndsTheAssertionOnceEvenWhileTheChunkUnwinds() async {
        let assertion = FakeAssertion()
        let grant = EffortRescoreGrant(assertion: assertion.provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            await withCheckedContinuation { probe.resume = $0 }
        }
        await waitUntil { probe.resume != nil }
        grant.cancel()
        XCTAssertEqual(assertion.ended, [1], "the foreground needs no background time")
        probe.resume?.resume()
        await waitUntil { !grant.isUnwinding }
        XCTAssertEqual(assertion.ended, [1], "finishing after the cancel does not end it again")
    }

    /// iOS gives a scene-edge assertion about 30 s. Cancelling the grant then threw away a partial scan the paced work
    /// needs several wakes to finish; before the assertion existed the Task froze with the process and resumed on the
    /// next wake. Expiry ends the assertion and leaves the grant running; a foreground return still cancels it.
    func testExpirationEndsTheAssertionOnceAndLeavesTheGrantRunning() async {
        let assertion = FakeAssertion()
        let grant = EffortRescoreGrant(assertion: assertion.provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            do { try await Task.sleep(for: .seconds(60)) } catch { probe.sawCancellation = true }
        }
        await waitUntil { assertion.begun == 1 && probe.runs == 1 }
        assertion.expire()
        XCTAssertEqual(assertion.ended, [1], "ended before the handler returns")
        XCTAssertTrue(grant.isActive, "the grant is still the live one")
        await settle()
        XCTAssertFalse(probe.sawCancellation, "and its chunk was not told to stop")

        grant.cancel()
        XCTAssertEqual(assertion.ended, [1], "the foreground return does not end the spent assertion again")
        await waitUntil { probe.sawCancellation && !grant.isUnwinding }
        XCTAssertTrue(probe.sawCancellation, "a foreground return still cancels the grant")
    }

    func testAGrantThatOutlivesItsAssertionFinishesNormally() async {
        let assertion = FakeAssertion()
        let grant = EffortRescoreGrant(assertion: assertion.provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            await withCheckedContinuation { probe.resume = $0 }
        }
        await waitUntil { probe.resume != nil }
        assertion.expire()
        probe.resume?.resume()           // the next wake: the chunk carries on and finishes
        await waitUntil { !grant.isActive }
        XCTAssertEqual(assertion.ended, [1])
        XCTAssertFalse(probe.sawCancellation)
    }

    func testAnExpirationAfterTheGrantFinishedDoesNotEndTheAssertionAgain() async {
        let assertion = FakeAssertion()
        let grant = EffortRescoreGrant(assertion: assertion.provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { _, _ in }
        await waitUntil { !grant.isActive && probe.runs == 1 }
        XCTAssertEqual(assertion.ended, [1])
        assertion.expire()
        XCTAssertEqual(assertion.ended, [1])
    }

    func testAnEarlierGrantsLateExpirationHandlerDoesNotCancelTheNextGrant() async {
        let assertion = FakeAssertion()
        let grant = EffortRescoreGrant(assertion: assertion.provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { _, _ in }
        await waitUntil { !grant.isActive && probe.runs == 1 }
        start(grant, probe) { probe, _ in
            do { try await Task.sleep(for: .seconds(60)) } catch { probe.sawCancellation = true }
        }
        await waitUntil { assertion.begun == 2 && probe.runs == 2 }
        assertion.expire(0)
        await settle()
        XCTAssertTrue(grant.isActive, "the first grant's handler is spent: it leaves the live grant alone")
        XCTAssertFalse(probe.sawCancellation)
        XCTAssertEqual(assertion.ended, [1])
        grant.cancel()
        XCTAssertEqual(assertion.ended, [1, 2])
    }

    func testCancellingTheWaiterCancelsTheGrant() async {
        let grant = EffortRescoreGrant(assertion: FakeAssertion().provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            do { try await Task.sleep(for: .seconds(60)) } catch { probe.sawCancellation = true }
        }
        await waitUntil { probe.runs == 1 }
        let waiter = Task { @MainActor in await grant.waitUntilIdle() }
        await settle()
        waiter.cancel()
        await waiter.value
        await waitUntil { probe.sawCancellation }
        XCTAssertTrue(probe.sawCancellation, "an expired processing task stops the chunk it was waiting on")
        XCTAssertFalse(grant.isActive)
    }

    // MARK: - A grant that waits behind an unwinding one

    /// A migration chunk past its first write runs to completion after a cancel, and the cancel ended its assertion.
    /// A grant started in that window takes its own assertion before it waits, so that write tail is not left with
    /// nothing keeping the process alive.
    func testAGrantWaitingBehindAnUnwindingOneTakesItsAssertionBeforeWaiting() async {
        let assertion = FakeAssertion()
        let grant = EffortRescoreGrant(assertion: assertion.provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            await withCheckedContinuation { probe.resume = $0 }
        }
        await waitUntil { probe.resume != nil }
        grant.cancel()
        XCTAssertEqual(assertion.ended, [1], "the cancelled grant's own assertion ended at the cancel")

        start(grant, probe) { _, _ in }
        await waitUntil { assertion.begun == 2 }
        XCTAssertEqual(assertion.begun, 2, "the new grant protects the old one's tail while it waits")
        XCTAssertEqual(probe.runs, 1, "and has not entered the engine")
        XCTAssertEqual(assertion.ended, [1])

        probe.resume?.resume()
        await waitUntil { probe.runs == 2 && !grant.isActive && !grant.isUnwinding }
        XCTAssertEqual(probe.runs, 2)
        XCTAssertEqual(assertion.begun, 2, "it does not take a second one to run")
        XCTAssertEqual(assertion.ended, [1, 2], "ended once, when the grant finished")
    }

    func testAWaitingGrantCancelledBeforeItRunsEndsItsAssertionOnce() async {
        let assertion = FakeAssertion()
        let grant = EffortRescoreGrant(assertion: assertion.provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            await withCheckedContinuation { probe.resume = $0 }
        }
        await waitUntil { probe.resume != nil }
        grant.cancel()
        start(grant, probe) { _, _ in }
        await waitUntil { assertion.begun == 2 }
        grant.cancel()
        XCTAssertEqual(assertion.ended, [1, 2])

        probe.resume?.resume()
        await waitUntil { !grant.isUnwinding }
        await settle()
        XCTAssertEqual(probe.runs, 1, "the cancelled waiter never enters the engine")
        XCTAssertEqual(assertion.ended, [1, 2], "and does not end its assertion again")
    }

    func testAWaitingGrantThatMayNoLongerRunEndsItsAssertion() async {
        let assertion = FakeAssertion()
        let grant = EffortRescoreGrant(assertion: assertion.provider)
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            await withCheckedContinuation { probe.resume = $0 }
        }
        await waitUntil { probe.resume != nil }
        grant.cancel()
        start(grant, probe) { _, _ in }
        await waitUntil { assertion.begun == 2 }

        probe.background = false          // the owner is back by the time the old tail has finished
        probe.resume?.resume()
        await waitUntil { !grant.isActive && !grant.isUnwinding }
        XCTAssertEqual(probe.runs, 1, "a grant that is no longer in the background does not run")
        XCTAssertEqual(assertion.ended, [1, 2], "and ends the assertion it took")
    }
}
