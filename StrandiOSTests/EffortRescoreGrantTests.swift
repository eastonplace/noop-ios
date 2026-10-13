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

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
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
        await settle()
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
        await settle()
        XCTAssertEqual(probe.runs, 1)
        probe.background = false
        probe.resume?.resume()
        await settle()
        XCTAssertEqual(probe.pausedAfterBackgroundEnded, true, "the driver sees pause before it starts a chunk")
    }

    func testAForegroundReturnCancelsTheRunningGrant() async {
        let grant = EffortRescoreGrant()
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            do { try await Task.sleep(for: .seconds(60)) } catch { probe.sawCancellation = true }
        }
        await settle()
        XCTAssertEqual(probe.runs, 1)
        XCTAssertTrue(grant.isActive)
        grant.cancel()
        XCTAssertFalse(grant.isActive)
        await settle()
        XCTAssertTrue(probe.sawCancellation, "the in-flight chunk is told to stop")
    }

    func testAGrantIsNotStartedTwiceWhileOneIsActive() async {
        let grant = EffortRescoreGrant()
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            await withCheckedContinuation { probe.resume = $0 }
        }
        await settle()
        start(grant, probe) { _, _ in }
        await settle()
        XCTAssertEqual(probe.runs, 1)
        probe.resume?.resume()
        await settle()
        XCTAssertFalse(grant.isActive)
    }

    func testAfterACancelTheNextBackgroundEdgeStartsAgain() async {
        let grant = EffortRescoreGrant()
        let probe = Probe()
        probe.background = true
        start(grant, probe) { probe, _ in
            do { try await Task.sleep(for: .seconds(60)) } catch { probe.sawCancellation = true }
        }
        await settle()
        grant.cancel()
        await settle()
        start(grant, probe) { _, _ in }
        await settle()
        XCTAssertEqual(probe.runs, 2, "a cancelled grant replays from the durable cursor on the next background edge")
    }
}
