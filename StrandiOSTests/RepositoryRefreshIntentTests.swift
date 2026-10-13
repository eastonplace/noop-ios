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

    /// Review finding (lost wake-up): the waiter used to join the queue only after hopping off the main actor,
    /// so a refresh ending in that gap found no waiter and opened the fence. The waiter then sat in the queue
    /// with nobody left to grant it, `blocksRefreshes` stayed true and every later refresh was deferred.
    func testARefreshEndingRightBehindTheWaiterStillGrantsTheFence() async throws {
        for iteration in 0..<50 {
            let barrier = RepositoryPublicationBarrier()
            XCTAssertTrue(barrier.beginRefreshIfAllowed())
            var granted: RepositoryPublicationBarrier.Ownership?
            let owner = Task { @MainActor in granted = try await barrier.acquireExclusive() }
            let ender = Task { @MainActor in barrier.endRefresh() }
            await ender.value
            for _ in 0..<1_000 where granted == nil { try await Task.sleep(nanoseconds: 1_000_000) }
            guard let ownership = granted else {
                XCTFail("iteration \(iteration): the refresh ended before the waiter queued; the fence is stuck")
                owner.cancel()
                _ = await owner.result
                return
            }
            barrier.releaseExclusive(ownership)
            XCTAssertFalse(barrier.blocksRefreshes)
        }
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

    /// Review findings (watchdog clock): one long sleep fired on the first wake after a long suspension, and
    /// counting wake-ups let sixty short BLE wakes reclaim the fence from a live owner. Each tick is now
    /// credited with its measured time, and a tick that spanned a suspension is credited nothing.
    func testSuspensionsBurnNoWatchdogBudgetButAHungForegroundOwnerIsReclaimedAfterTheLimit() async throws {
        let clock = ManualWatchdogClock()
        let barrier = RepositoryPublicationBarrier(
            watchdogLimit: .seconds(600), watchdogTick: .seconds(10), watchdogSlack: .milliseconds(500),
            watchdogClock: { clock.now },
            watchdogSleep: { [clock] in await clock.sleep($0) })
        let ownership = try await barrier.acquireExclusive()

        // A fifteen-minute suspension, then 100 short BLE wakes at least 11 s apart: each tick spanned a
        // suspension, so none of them is running time.
        try await clock.waitForSleeper()
        clock.advance(by: .seconds(900))
        clock.wakeOne()
        for wake in 1...100 {
            try await clock.waitForSleeper()
            XCTAssertTrue(barrier.blocksRefreshes, "wake \(wake): a suspended owner lost the fence")
            clock.advance(by: .seconds(11))
            clock.wakeOne()
        }
        // A hung owner in the foreground: 60 on-time ticks of 10 s are 600 s of running time.
        for tick in 1...60 {
            try await clock.waitForSleeper()
            XCTAssertTrue(barrier.blocksRefreshes, "tick \(tick): the hold was reclaimed early")
            XCTAssertEqual(barrier.watchdogReleaseCount, 0)
            clock.advance(by: .seconds(10))
            clock.wakeOne()
        }
        for _ in 0..<1_000 where barrier.watchdogReleaseCount == 0 { await Task.yield() }
        XCTAssertEqual(barrier.watchdogReleaseCount, 1, "600 s of running time reaches the limit")
        XCTAssertFalse(barrier.blocksRefreshes)
        barrier.releaseExclusive(ownership)
        XCTAssertFalse(barrier.blocksRefreshes)
    }

    private func seedComputedDays(_ count: Int, into store: WhoopStore, strain: Double = 64) async throws -> [String] {
        let now = Date()
        let keys = (0..<count).map {
            Repository.localDayKey(Repository.dateByAddingCalendarDays(-$0, to: now))
        }
        try await store.upsertDailyMetrics(keys.map { key in
            DailyMetric(day: key, totalSleepMin: 440, efficiency: 0.9, deepMin: 90, remMin: 100,
                        lightMin: 250, disturbances: 3, restingHr: 52, avgHrv: 63, recovery: 78,
                        strain: strain, exerciseCount: 1, strainVersion: 2)
        }, deviceId: Repository.whoopSource + "-noop")
        return keys.sorted()
    }

    /// DL-01: a current-day refresh used to replace every 30-day cache with its own 2-day window, so Trends,
    /// the step sparkline and the baselines collapsed to about 3 days after every sync or HealthKit wake.
    func testCurrentDayRefreshSplicesIntoTheThirtyDayDashboard() async throws {
        let store = try await WhoopStore.inMemory()
        let keys = try await seedComputedDays(30, into: store)
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)

        let loaded = await repository.refresh(days: 30)
        XCTAssertTrue(loaded)
        XCTAssertEqual(repository.days.count, 30)
        XCTAssertEqual(repository.days.first?.day, keys.first)
        XCTAssertEqual(repository.freshness.computedDays, 30)

        // New data lands for today only; the narrow refresh must publish it without dropping history.
        // Stored strain is on the 0...100 scale; an out-of-range value can't be saved in the Today snapshot.
        try await store.upsertDailyMetrics([
            DailyMetric(day: keys.last!, totalSleepMin: 440, efficiency: 0.9, deepMin: 90, remMin: 100,
                        lightMin: 250, disturbances: 3, restingHr: 52, avgHrv: 63, recovery: 78,
                        strain: 90, exerciseCount: 1, strainVersion: 2)
        ], deviceId: Repository.whoopSource + "-noop")
        let narrow = await repository.refresh(days: 2)
        XCTAssertTrue(narrow)
        XCTAssertEqual(repository.days.count, 30, "a narrow refresh never shrinks the dashboard caches")
        XCTAssertEqual(repository.days.first?.day, keys.first)
        XCTAssertEqual(repository.days.last?.strain, 90, "the refreshed window still publishes")
        XCTAssertEqual(repository.freshness.computedDays, 30)
        XCTAssertEqual(repository.vitalRows.count, 30)
    }

    /// DL-01: the typed `.currentDay` path (analysis tail, 15-minute tick, BLE sync) keeps the 30-day window.
    func testTypedCurrentDayRefreshKeepsDayCountAndEarliestDay() async throws {
        let store = try await WhoopStore.inMemory()
        let keys = try await seedComputedDays(30, into: store)
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        _ = await repository.refresh(days: 30)
        XCTAssertEqual(repository.days.count, 30)

        _ = await repository.refresh(.currentDay)
        XCTAssertEqual(repository.days.count, 30)
        XCTAssertEqual(repository.days.first?.day, keys.first)
    }

    /// DL-09: a sleep edit publishes through the typed refresh, so while a source owns the publication fence
    /// it is deferred and replayed when the fence opens, instead of tearing that source's generation.
    func testSleepEditWhileTheFenceIsHeldIsDeferredUntilItOpens() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await seedComputedDays(3, into: store)
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        _ = await repository.refresh(days: 30)
        XCTAssertTrue(repository.sleeps.isEmpty)

        let barrier = RepositoryPublicationBarrier.shared
        let ownership = try await barrier.acquireExclusive()
        let end = Int(Date().timeIntervalSince1970) - 3_600
        await repository.addManualNap(startTs: end - 2_700, endTs: end)
        XCTAssertTrue(repository.sleeps.isEmpty, "the edit's refresh waits behind the held fence")

        barrier.releaseExclusive(ownership)
        for _ in 0..<500 where repository.sleeps.isEmpty {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(repository.sleeps.map(\.endTs), [end], "the deferred refresh replays once the fence opens")
    }
}
/// Hands out watchdog ticks one at a time on a clock the test moves, the way a suspended process wakes its one
/// pending sleep however long it was suspended.
@MainActor
private final class ManualWatchdogClock {
    private var sleepers: [CheckedContinuation<Void, Never>] = []
    private(set) var requested: [Duration] = []
    private(set) var now = ContinuousClock.now

    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
    }

    func sleep(_ duration: Duration) async {
        requested.append(duration)
        await withCheckedContinuation { sleepers.append($0) }
    }

    func waitForSleeper() async throws {
        for _ in 0..<1_000 where sleepers.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(sleepers.isEmpty, "the watchdog stopped ticking")
    }

    func wakeOne() {
        guard !sleepers.isEmpty else { return }
        sleepers.removeFirst().resume()
    }
}
#endif
