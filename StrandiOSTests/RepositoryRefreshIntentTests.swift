import XCTest
import WhoopStore
@testable import NOOP

#if os(iOS)
@MainActor
final class RepositoryRefreshIntentTests: XCTestCase {
    func testIntentRangesAndDeterministicEqualRangeMerge() {
        XCTAssertEqual(RepositoryRefreshIntent.currentDay.days, 1)
        XCTAssertEqual(RepositoryRefreshIntent.postBackfill.days, 1)
        XCTAssertEqual(RepositoryRefreshIntent.initialLoad.days, 1)
        XCTAssertEqual(RepositoryRefreshIntent.recentDashboard(days: 120).days, 30)
        XCTAssertEqual(RepositoryRefreshIntent.fullHistoryMigration.days, 30)
        XCTAssertEqual(
            RepositoryRefreshIntent.merged(.currentDay, .postBackfill),
            .postBackfill
        )
    }

    func testTraceNamesAreCompileTimeLiteralsAndStable() {
        XCTAssertEqual(
            String(describing: RepositoryRefreshIntent.currentDay.traceName),
            "repository_refresh_current_day"
        )
        XCTAssertEqual(
            String(describing: RepositoryRefreshIntent.recentDashboard(days: 120).traceName),
            "repository_refresh_recent_dashboard"
        )
        XCTAssertEqual(
            String(describing: RepositoryRefreshIntent.recentDashboard(days: 4_000).traceName),
            "repository_refresh_recent_dashboard"
        )
        XCTAssertEqual(
            String(describing: RepositoryRefreshIntent.postBackfill.traceName),
            "repository_refresh_post_backfill"
        )
        XCTAssertEqual(
            String(describing: RepositoryRefreshIntent.fullHistoryMigration.traceName),
            "repository_refresh_full_history_migration"
        )
    }

    func testInitialLoadPreservesMultiYearHistoryExtent() async throws {
        let store = try await WhoopStore.inMemory()
        let calendar = Calendar.current
        let oldDate = calendar.date(byAdding: .day, value: -730, to: Date())!
        let oldDay = Repository.localDayKey(oldDate)
        try await store.upsertDailyMetrics([
            DailyMetric(day: oldDay, totalSleepMin: 440, efficiency: 0.9, deepMin: 90, remMin: 100,
                        lightMin: 250, disturbances: 3, restingHr: 52, avgHrv: 63, recovery: 78,
                        strain: 64, exerciseCount: 1, strainVersion: 2)
        ], deviceId: Repository.whoopSource + "-noop")
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)

        let didRefresh = await repository.refresh(.initialLoad)

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(repository.historyExtent.earliestDay?.key, oldDay)
    }

    func testOverlappingNarrowRequestsCoalesceToWidestPendingRange() async {
        var executed: [RepositoryRefreshIntent] = []
        var releases: [CheckedContinuation<Void, Never>] = []
        let coordinator = RepositoryRefreshCoordinator { intent in
            executed.append(intent)
            await withCheckedContinuation { releases.append($0) }
            return true
        }
        let first = Task { await coordinator.request(.currentDay) }
        while executed.isEmpty { await Task.yield() }
        let second = Task { await coordinator.request(.recentDashboard(days: 30)) }
        let third = Task { await coordinator.request(.recentDashboard(days: 240)) }
        releases.removeFirst().resume()
        while executed.count < 2 { await Task.yield() }
        releases.removeFirst().resume()
        let firstResult = await first.value
        let secondResult = await second.value
        let thirdResult = await third.value
        XCTAssertTrue(firstResult)
        XCTAssertTrue(secondResult)
        XCTAssertTrue(thirdResult)
        XCTAssertEqual(executed, [.currentDay, .recentDashboard(days: 240)])
    }

    func testBroadPendingRequestAbsorbsNarrowRequestsBeforeExecution() async {
        var executed: [RepositoryRefreshIntent] = []
        var release: CheckedContinuation<Void, Never>?
        let coordinator = RepositoryRefreshCoordinator(coalescingDelay: .milliseconds(30)) { intent in
            executed.append(intent)
            await withCheckedContinuation { release = $0 }
            return true
        }
        let broad = Task { await coordinator.request(.fullHistoryMigration) }
        let narrowA = Task { await coordinator.request(.currentDay) }
        let narrowB = Task { await coordinator.request(.postBackfill) }
        while executed.isEmpty { await Task.yield() }
        release?.resume()
        release = nil
        let broadResult = await broad.value
        let narrowAResult = await narrowA.value
        let narrowBResult = await narrowB.value
        XCTAssertTrue(broadResult)
        XCTAssertTrue(narrowAResult)
        XCTAssertTrue(narrowBResult)
        XCTAssertEqual(executed, [.fullHistoryMigration])
    }

    func testNarrowRequestAfterBroadStartedRunsAgainForNewerMutation() async {
        var executed: [RepositoryRefreshIntent] = []
        var releases: [CheckedContinuation<Void, Never>] = []
        let coordinator = RepositoryRefreshCoordinator(coalescingDelay: .zero) { intent in
            executed.append(intent)
            await withCheckedContinuation { releases.append($0) }
            return true
        }
        let broad = Task { await coordinator.request(.fullHistoryMigration) }
        while executed.isEmpty { await Task.yield() }
        let narrow = Task { await coordinator.request(.currentDay) }
        releases.removeFirst().resume()
        while executed.count < 2 { await Task.yield() }
        releases.removeFirst().resume()
        let broadResult = await broad.value
        let narrowResult = await narrow.value
        XCTAssertTrue(broadResult)
        XCTAssertTrue(narrowResult)
        XCTAssertEqual(executed, [.fullHistoryMigration, .currentDay])
    }

    func testEachExecutedBatchReceivesItsOwnResult() async {
        var executions = 0
        var releases: [CheckedContinuation<Void, Never>] = []
        let coordinator = RepositoryRefreshCoordinator(coalescingDelay: .zero) { _ in
            executions += 1
            let result = executions > 1
            await withCheckedContinuation { releases.append($0) }
            return result
        }

        let first = Task { await coordinator.request(.fullHistoryMigration) }
        while executions == 0 { await Task.yield() }
        let second = Task { await coordinator.request(.currentDay) }
        releases.removeFirst().resume()
        while executions < 2 { await Task.yield() }
        releases.removeFirst().resume()

        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertFalse(firstResult)
        XCTAssertTrue(secondResult)
    }

    func testMigrationSuppressionIsInheritedByChildTask() async {
        let inherited = await RepositoryRefreshContext.$disposition.withValue(.suppress) {
            await Task { RepositoryRefreshContext.disposition }.value
        }
        XCTAssertEqual(inherited, .suppress)
        XCTAssertEqual(RepositoryRefreshContext.disposition, .allow)
    }

    func testAlreadyCancelledRequestDoesNotEnterQueue() async {
        let coordinator = RepositoryRefreshCoordinator { _ in
            XCTFail("Cancelled request must not execute")
            return true
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await coordinator.request(.currentDay)
        }
        let result = await task.value
        XCTAssertFalse(result)
    }

    func testExclusivePublicationWaitsForInFlightRefreshAndStopsNewStarts() async throws {
        let barrier = RepositoryPublicationBarrier()
        XCTAssertTrue(barrier.beginRefreshIfAllowed())

        var acquiredExclusive = false
        let exclusive = Task { @MainActor in
            let ownership = try await barrier.acquireExclusive()
            acquiredExclusive = true
            return ownership
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(acquiredExclusive,
                       "a source import cannot begin while an older Repository snapshot is still reading")
        XCTAssertFalse(barrier.beginRefreshIfAllowed(),
                       "once source publication is pending, no newer refresh may overtake it")

        barrier.endRefresh()
        let ownership = try await exclusive.value
        XCTAssertTrue(acquiredExclusive)
        XCTAssertTrue(barrier.blocksRefreshes)
        XCTAssertFalse(barrier.beginRefreshIfAllowed())

        barrier.releaseExclusive(ownership)
        XCTAssertFalse(barrier.blocksRefreshes)
        XCTAssertTrue(barrier.beginRefreshIfAllowed())
        barrier.endRefresh()
    }

    func testBlockedRefreshesCoalesceToOneWidestReplayPerRepository() async throws {
        let barrier = RepositoryPublicationBarrier()
        let ownership = try await barrier.acquireExclusive()
        let owner = NSObject()
        var replayed: [RepositoryRefreshIntent] = []

        for _ in 0..<100 {
            barrier.performAfterOpen(for: owner, intent: .currentDay) { replayed.append($0) }
        }
        barrier.performAfterOpen(for: owner, intent: .fullHistoryMigration) { replayed.append($0) }
        XCTAssertTrue(replayed.isEmpty)
        XCTAssertEqual(barrier.deferredRequestCount, 101)
        XCTAssertEqual(barrier.deferredRepositoryCount, 1)

        barrier.releaseExclusive(ownership)
        XCTAssertEqual(replayed, [.fullHistoryMigration])
        XCTAssertEqual(barrier.deferredRepositoryCount, 0)
    }

    func testBlockedRefreshesKeepDifferentRepositoriesDistinct() async throws {
        let barrier = RepositoryPublicationBarrier()
        let ownership = try await barrier.acquireExclusive()
        let first = NSObject()
        let second = NSObject()
        var replayed: [RepositoryRefreshIntent] = []

        barrier.performAfterOpen(for: first, intent: .currentDay) { replayed.append($0) }
        barrier.performAfterOpen(for: second, intent: .postImport) { replayed.append($0) }
        XCTAssertEqual(barrier.deferredRepositoryCount, 2)

        barrier.releaseExclusive(ownership)
        XCTAssertEqual(Set(replayed.map(\.description)), Set(["current-day", "post-import"]))
    }

    /// CC-3: a waiter parked on a held fence leaves on cancel. Before the fix the wait ignored cancellation,
    /// so quiesce and BG-task expiry hung for as long as the fence stayed closed.
    func testCancelledFenceWaiterThrowsPromptlyAndLeavesTheHolderInCharge() async throws {
        let barrier = RepositoryPublicationBarrier()
        let holder = try await barrier.acquireExclusive()
        var parked = false
        let waiter = Task { @MainActor in
            parked = true
            try await HistoricalRepositoryPublicationGate.run(barrier: barrier) {
                XCTFail("a cancelled waiter must never run its publication")
            }
        }
        while !parked { await Task.yield() }
        for _ in 0..<5 { await Task.yield() }

        waiter.cancel()
        let result = await waiter.result
        XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(barrier.blocksRefreshes, "the holder still owns the fence")

        barrier.releaseExclusive(holder)
        XCTAssertFalse(barrier.blocksRefreshes)
        XCTAssertTrue(barrier.beginRefreshIfAllowed())
        barrier.endRefresh()
    }

    /// A cancelled waiter that was the only thing closing the fence must replay what it deferred.
    func testCancelledWaiterBehindARefreshReplaysDeferredRefreshes() async throws {
        let barrier = RepositoryPublicationBarrier()
        XCTAssertTrue(barrier.beginRefreshIfAllowed())
        let waiter = Task { @MainActor in try await barrier.acquireExclusive() }
        while !barrier.blocksRefreshes { await Task.yield() }
        var replayed: [RepositoryRefreshIntent] = []
        barrier.performAfterOpen(for: NSObject(), intent: .currentDay) { replayed.append($0) }
        XCTAssertTrue(replayed.isEmpty)

        waiter.cancel()
        _ = await waiter.result
        XCTAssertEqual(replayed, [.currentDay])
        XCTAssertFalse(barrier.blocksRefreshes)
        barrier.endRefresh()
        XCTAssertFalse(barrier.blocksRefreshes)
    }

    /// D4 safety net: a hung owner cannot freeze every typed refresh. The watchdog reclaims the hold, and the
    /// late owner's release is a no-op instead of opening a fence that a newer owner holds.
    func testWatchdogReclaimsAHungHoldAndIgnoresTheLateRelease() async throws {
        let barrier = RepositoryPublicationBarrier(watchdogLimit: .milliseconds(30))
        let hung = try await barrier.acquireExclusive()
        XCTAssertTrue(barrier.blocksRefreshes)

        for _ in 0..<500 where barrier.blocksRefreshes {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertFalse(barrier.blocksRefreshes)
        XCTAssertEqual(barrier.watchdogReleaseCount, 1)

        let next = try await barrier.acquireExclusive()
        barrier.releaseExclusive(hung)
        XCTAssertTrue(barrier.blocksRefreshes, "a stale release must not open the newer owner's fence")
        barrier.releaseExclusive(next)
        XCTAssertFalse(barrier.blocksRefreshes)
    }
}
#endif
