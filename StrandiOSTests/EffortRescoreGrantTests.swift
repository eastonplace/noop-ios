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

    /// Waits for an effect of the grant's `.background`-priority task. `Task.yield` alone is not enough: with only a
    /// background-priority job pending, the runtime hands the main actor straight back to the (higher-priority) test
    /// without running it, so the test has to suspend for real. Polls, so a slow machine only makes it wait longer.
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
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
        let grant = EffortRescoreGrant()
        let probe = Probe()
        probe.background = false
        start(grant, probe) { _, _ in }
        await settle()
        XCTAssertEqual(probe.runs, 0, "Control Center / the app switcher is not the background")
        XCTAssertFalse(grant.isActive)
    }

    func testTheOtherGatesStopAGrantFromStarting() async {
        let grant = EffortRescoreGrant()
        let probe = Probe()
        probe.background = true
        probe.mayRun = false
        start(grant, probe) { _, _ in }
        await settle()
        XCTAssertEqual(probe.runs, 0, "an import, a backfill, a workout or no first paint blocks the grant")
        XCTAssertFalse(grant.isActive)
    }

    func testABackgroundEdgeStartsOneUnpausedGrantAndItClears() async {
        let grant = EffortRescoreGrant()
        let probe = Probe()
        probe.background = true
        start(grant, probe) { _, _ in }
        await waitUntil { probe.runs == 1 && !grant.isActive }
        XCTAssertEqual(probe.runs, 1)
        XCTAssertEqual(probe.pausedWhenStarted, false)
        XCTAssertFalse(grant.isActive, "a finished grant frees the next edge to start one")
    }

    func testLeavingTheBackgroundPausesTheGrantBeforeItsNextChunk() async {
        let grant = EffortRescoreGrant()
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
        let grant = EffortRescoreGrant()
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
        let grant = EffortRescoreGrant()
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
        let grant = EffortRescoreGrant()
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
        let grant = EffortRescoreGrant()
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
        let grant = EffortRescoreGrant()
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
}
