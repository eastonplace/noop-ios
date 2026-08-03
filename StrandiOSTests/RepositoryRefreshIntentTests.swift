import XCTest
import WhoopStore
@testable import NOOP

#if os(iOS)
@MainActor
final class RepositoryRefreshIntentTests: XCTestCase {
    func testIntentRangesAndDeterministicEqualRangeMerge() {
        XCTAssertEqual(RepositoryRefreshIntent.currentDay.days, 4_000)
        XCTAssertEqual(RepositoryRefreshIntent.postBackfill.days, 4_000)
        XCTAssertEqual(RepositoryRefreshIntent.initialLoad.days, 4_000)
        XCTAssertEqual(RepositoryRefreshIntent.recentDashboard(days: 1).days, 120)
        XCTAssertEqual(RepositoryRefreshIntent.fullHistoryMigration.days, 4_000)
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

    func testInitialLoadPreservesMultiYearHistoryWindow() async throws {
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
        XCTAssertEqual(repository.freshness.earliestDay, oldDay)
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

    func testExclusivePublicationWaitsForInFlightRefreshAndStopsNewStarts() async {
        let barrier = RepositoryPublicationBarrier()
        XCTAssertTrue(barrier.beginRefreshIfAllowed())

        var acquiredExclusive = false
        let exclusive = Task { @MainActor in
            await barrier.acquireExclusive()
            acquiredExclusive = true
        }
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(acquiredExclusive,
                       "a source import cannot begin while an older Repository snapshot is still reading")
        XCTAssertFalse(barrier.beginRefreshIfAllowed(),
                       "once source publication is pending, no newer refresh may overtake it")

        barrier.endRefresh()
        await exclusive.value
        XCTAssertTrue(acquiredExclusive)
        XCTAssertTrue(barrier.blocksRefreshes)
        XCTAssertFalse(barrier.beginRefreshIfAllowed())

        barrier.releaseExclusive()
        XCTAssertFalse(barrier.blocksRefreshes)
        XCTAssertTrue(barrier.beginRefreshIfAllowed())
        barrier.endRefresh()
    }

    func testBlockedRefreshesCoalesceToOneWidestReplayPerRepository() async {
        let barrier = RepositoryPublicationBarrier()
        await barrier.acquireExclusive()
        let owner = NSObject()
        var replayed: [RepositoryRefreshIntent] = []

        for _ in 0..<100 {
            barrier.performAfterOpen(for: owner, intent: .currentDay) { replayed.append($0) }
        }
        barrier.performAfterOpen(for: owner, intent: .fullHistoryMigration) { replayed.append($0) }
        XCTAssertTrue(replayed.isEmpty)
        XCTAssertEqual(barrier.deferredRequestCount, 101)
        XCTAssertEqual(barrier.deferredRepositoryCount, 1)

        barrier.releaseExclusive()
        XCTAssertEqual(replayed, [.fullHistoryMigration])
        XCTAssertEqual(barrier.deferredRepositoryCount, 0)
    }

    func testBlockedRefreshesKeepDifferentRepositoriesDistinct() async {
        let barrier = RepositoryPublicationBarrier()
        await barrier.acquireExclusive()
        let first = NSObject()
        let second = NSObject()
        var replayed: [RepositoryRefreshIntent] = []

        barrier.performAfterOpen(for: first, intent: .currentDay) { replayed.append($0) }
        barrier.performAfterOpen(for: second, intent: .postImport) { replayed.append($0) }
        XCTAssertEqual(barrier.deferredRepositoryCount, 2)

        barrier.releaseExclusive()
        XCTAssertEqual(Set(replayed.map(\.description)), Set(["current-day", "post-import"]))
    }

    func testRestoredJournalCanFenceSynchronouslyBeforeLaunchRefresh() {
        let barrier = RepositoryPublicationBarrier()

        XCTAssertTrue(barrier.acquireRestoredExclusiveIfIdle())
        XCTAssertTrue(barrier.blocksRefreshes)
        XCTAssertFalse(barrier.acquireRestoredExclusiveIfIdle(),
                       "one durable scoring journal owns one fence")

        barrier.releaseExclusive()
        XCTAssertFalse(barrier.blocksRefreshes)
    }
}
#endif
