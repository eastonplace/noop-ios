import Foundation
import NoopPhase34Core

enum RepositoryRefreshDataset: Hashable, Sendable {
    case dashboard
}

/// Explicit refresh purposes. Exact historical publication uses its committed civil-day set. These
/// compatibility intents remain narrow and never widen a missing-day publication into a history sweep.
enum RepositoryRefreshIntent: Equatable, Sendable, CustomStringConvertible {
    case currentDay
    case recentDashboard(days: Int)
    case postBackfill
    case initialLoad
    /// A sleep or workout edit. It goes through the publication fence like every other typed refresh (DL-09).
    case userEdit
    case activeDeviceChanged
    case postImport
    case fullHistoryMigration

    var days: Int {
        switch self {
        case .currentDay, .postBackfill, .initialLoad:
            return 1
        case .recentDashboard(let days):
            return min(30, max(1, days))
        case .userEdit, .activeDeviceChanged, .postImport, .fullHistoryMigration:
            return 30
        }
    }

    var datasets: Set<RepositoryRefreshDataset> { [.dashboard] }

    var description: String {
        switch self {
        case .currentDay: return "current-day"
        case .recentDashboard: return "recent-\(days)"
        case .postBackfill: return "post-backfill"
        case .initialLoad: return "initial-load"
        case .userEdit: return "user-edit"
        case .activeDeviceChanged: return "active-device-changed"
        case .postImport: return "post-import"
        case .fullHistoryMigration: return "full-history-migration"
        }
    }

    /// `PerformanceTrace.begin` deliberately accepts `StaticString`, so every trace name must be a literal.
    /// Keeping this mapping next to the intent prevents runtime interpolation from becoming a compile failure.
    var traceName: StaticString {
        switch self {
        case .currentDay: return "repository_refresh_current_day"
        case .recentDashboard: return "repository_refresh_recent_dashboard"
        case .postBackfill: return "repository_refresh_post_backfill"
        case .initialLoad: return "repository_refresh_initial_load"
        case .userEdit: return "repository_refresh_user_edit"
        case .activeDeviceChanged: return "repository_refresh_active_device_changed"
        case .postImport: return "repository_refresh_post_import"
        case .fullHistoryMigration: return "repository_refresh_full_history_migration"
        }
    }

    func absorbs(_ other: Self) -> Bool {
        days >= other.days && datasets.isSuperset(of: other.datasets)
    }

    static func merged(_ lhs: Self, _ rhs: Self) -> Self {
        if case .recentDashboard(let leftDays) = lhs,
           case .recentDashboard(let rightDays) = rhs {
            return .recentDashboard(days: max(leftDays, rightDays))
        }
        if lhs.days > rhs.days { return lhs }
        if rhs.days > lhs.days { return rhs }
        return rank(lhs) >= rank(rhs) ? lhs : rhs
    }

    private static func rank(_ intent: Self) -> Int {
        switch intent {
        case .currentDay: return 0
        case .recentDashboard: return 1
        case .postBackfill: return 2
        case .initialLoad: return 3
        case .userEdit: return 4
        case .activeDeviceChanged: return 5
        case .postImport: return 6
        case .fullHistoryMigration: return 7
        }
    }

    /// One compatibility adapter. Production execution is typed by `RepositoryRefreshRequest`.
    var request: RepositoryRefreshRequest {
        switch self {
        case .currentDay: return .currentDayRequest
        case .recentDashboard(let days): return .recentDashboardRequest(days: days)
        case .postBackfill: return .currentDayRequest
        case .initialLoad: return .initialLoadRequest
        case .userEdit: return .recentDashboardRequest(days: 30)
        case .activeDeviceChanged: return .activeDeviceChangedRequest
        case .postImport: return .postImportRequest
        case .fullHistoryMigration:
            return RepositoryRefreshRequest(
                recentDashboardDays: 30,
                includeHistoryExtent: true,
                fullHistory: true,
                reasons: [.fullHistoryMigration])
        }
    }
}

/// Dynamic refresh policy inherited by child `Task` values. Historical migration analysis sets `.suppress`
/// while running a chunk. If `IntelligenceEngine` re-arms a forced pass in an unstructured child task, that
/// child inherits the suppression and cannot accidentally restore a broad repository refresh.
enum RepositoryRefreshContext {
    enum Disposition: Equatable, Sendable {
        case allow
        case suppress
    }

    @TaskLocal static var disposition: Disposition = .allow
}

/// Central publication fence for source pipelines whose imported rows and derived scores must become visible
/// as one generation. A HealthKit import, for example, may persist fresh HRV/RHR before Recovery is recomputed.
/// Without this fence an unrelated foreground/BLE refresh can publish those new vitals with the previous or
/// blank Recovery in the middle of the transaction.
///
/// - An exclusive source pipeline waits for a typed Repository refresh already in flight.
/// - Once exclusive acquisition is pending, no new typed refresh may start.
/// - A blocked refresh returns `false` immediately (so analysis cannot deadlock waiting on its own publication)
///   and is re-requested after the fence opens; the normal refresh coordinator coalesces those retries.
/// - The source owner performs its one coherent final refresh directly while holding the fence.
/// - The fence is held only while a source run is active (CC-1). Durable journals keep failed work for retry;
///   they never keep the fence closed across a failed run or a relaunch.
/// - Waiting for the fence honours Task cancellation (CC-3), so quiesce and BG-task expiry can stop a parked
///   owner. A watchdog reclaims a hold that outlives `watchdogLimit` and logs it.
///
/// MainActor isolation makes the handoff deterministic without locks. The class is injectable so tests and
/// previews do not share production fence state.
@MainActor
final class RepositoryPublicationBarrier {
    static let shared = RepositoryPublicationBarrier()

    /// Proof of one exclusive grant. Releasing with a grant the watchdog already reclaimed is a logged no-op,
    /// so a late owner can never open a fence that now belongs to someone else.
    struct Ownership: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    private var exclusive = false
    private var activeRefreshes = 0
    private let exclusiveWaiters = CancellableWaiterQueue<Void>()
    private var ownerGeneration: UInt64 = 0
    private let watchdogLimit: Duration
    private let watchdogTick: Duration
    private let watchdogSlack: Duration
    private let watchdogClock: @MainActor () -> ContinuousClock.Instant
    private let watchdogSleep: @Sendable (Duration) async throws -> Void
    private var watchdog: Task<Void, Never>?
    private struct DeferredRefresh {
        var intent: RepositoryRefreshIntent
        let operation: @MainActor (RepositoryRefreshIntent) -> Void
    }
    private var afterOpen: [ObjectIdentifier: DeferredRefresh] = [:]

    #if DEBUG
    private(set) var deferredRequestCount = 0
    private(set) var watchdogReleaseCount = 0
    var deferredRepositoryCount: Int { afterOpen.count }
    #endif

    /// Ten minutes is far beyond one HealthKit import batch or scoring generation, so the watchdog only fires
    /// for a hung owner. It is a safety net, not a scheduler.
    ///
    /// The limit is running time, accumulated from short ticks. Every clock Swift offers keeps running while
    /// iOS suspends the process, so neither one long sleep nor a count of wake-ups measures it: a ten-minute
    /// sleep fired on the first wake after a long suspension, and sixty short BLE wakes counted sixty full
    /// ticks. Each tick is credited with its measured elapsed time, and a tick that took longer than
    /// `watchdogTick + watchdogSlack` spanned a suspension and is credited nothing.
    init(watchdogLimit: Duration = .seconds(600),
         watchdogTick: Duration = .seconds(1),
         watchdogSlack: Duration = .milliseconds(500),
         watchdogClock: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
         watchdogSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.watchdogLimit = watchdogLimit
        self.watchdogTick = max(.nanoseconds(1), min(watchdogTick, watchdogLimit))
        self.watchdogSlack = max(.zero, watchdogSlack)
        self.watchdogClock = watchdogClock
        self.watchdogSleep = watchdogSleep
    }

    var blocksRefreshes: Bool {
        exclusive || !exclusiveWaiters.isEmpty
    }

    /// Acquire the source-publication fence. New refreshes stop immediately; an already-running typed refresh
    /// is allowed to finish before the source begins writing, so it cannot publish a snapshot taken mid-import.
    /// - Throws: `CancellationError` if the calling task is cancelled before it owns the fence. A waiter that
    ///   is cancelled just after ownership reached it releases the fence before throwing.
    @discardableResult
    func acquireExclusive() async throws -> Ownership {
        try Task.checkCancellation()
        if !exclusive, activeRefreshes == 0, exclusiveWaiters.isEmpty {
            return grant()
        }
        do {
            try await exclusiveWaiters.wait(())
        } catch {
            // The cancelled waiter has left the queue. If it was the only thing closing the fence, replay the
            // refreshes it deferred.
            openIfIdle()
            throw error
        }
        // `handOff()` granted this generation in the same main-actor turn that resumed this waiter.
        let ownership = Ownership(generation: ownerGeneration)
        if Task.isCancelled {
            releaseExclusive(ownership)
            throw CancellationError()
        }
        return ownership
    }

    func releaseExclusive(_ ownership: Ownership) {
        guard exclusive, ownership.generation == ownerGeneration else {
            NSLog("RepositoryPublicationBarrier: ignored a stale release (grant %llu, current %llu)",
                  ownership.generation, ownerGeneration)
            return
        }
        handOff()
    }

    /// Called by the typed refresh executor immediately before it reads Repository's SQLite projection.
    /// Returns false instead of suspending when a source fence is requested; suspending here could deadlock an
    /// in-flight Intelligence pass whose completion is required by the exclusive scorer.
    func beginRefreshIfAllowed() -> Bool {
        guard !exclusive, exclusiveWaiters.isEmpty else { return false }
        activeRefreshes += 1
        return true
    }

    func endRefresh() {
        precondition(activeRefreshes > 0, "Repository refresh fence count underflow")
        activeRefreshes -= 1
        guard activeRefreshes == 0, !exclusive else { return }
        if exclusiveWaiters.resumeNext() != nil {
            _ = grant()
        } else {
            openIfIdle()
        }
    }

    /// Retain at most one replay per Repository until all exclusive source generations have completed.
    /// A long-lived source fence can receive hundreds of foreground/BLE/UI refresh attempts; retaining one
    /// callback per attempt caused an unbounded burst when the fence opened. Merge their typed intents here,
    /// before any tasks are created, so one Repository produces exactly one widest replay.
    func performAfterOpen(
        for owner: AnyObject,
        intent: RepositoryRefreshIntent,
        operation: @escaping @MainActor (RepositoryRefreshIntent) -> Void
    ) {
        guard blocksRefreshes else {
            operation(intent)
            return
        }
        #if DEBUG
        deferredRequestCount += 1
        #endif
        let key = ObjectIdentifier(owner)
        if var deferred = afterOpen[key] {
            deferred.intent = RepositoryRefreshIntent.merged(deferred.intent, intent)
            afterOpen[key] = deferred
        } else {
            afterOpen[key] = DeferredRefresh(intent: intent, operation: operation)
        }
    }

    private func grant() -> Ownership {
        exclusive = true
        ownerGeneration &+= 1
        let generation = ownerGeneration
        watchdog?.cancel()
        watchdog = Task { @MainActor [weak self, watchdogLimit, watchdogTick, watchdogSlack, watchdogClock,
                                      watchdogSleep] in
            var running = Duration.zero
            while running < watchdogLimit {
                let start = watchdogClock()
                do {
                    try await watchdogSleep(watchdogTick)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                let elapsed = watchdogClock() - start
                if elapsed <= watchdogTick + watchdogSlack { running += elapsed }
            }
            self?.watchdogExpired(generation)
        }
        return Ownership(generation: generation)
    }

    /// Transfer ownership to the next waiter without opening a publication gap, or open the fence.
    private func handOff() {
        watchdog?.cancel()
        watchdog = nil
        if exclusiveWaiters.resumeNext() != nil {
            _ = grant()
            return
        }
        exclusive = false
        openIfIdle()
    }

    private func openIfIdle() {
        guard !exclusive, exclusiveWaiters.isEmpty, !afterOpen.isEmpty else { return }
        let callbacks = Array(afterOpen.values)
        afterOpen.removeAll(keepingCapacity: true)
        callbacks.forEach { $0.operation($0.intent) }
    }

    private func watchdogExpired(_ generation: UInt64) {
        guard exclusive, generation == ownerGeneration else { return }
        NSLog("RepositoryPublicationBarrier: exclusive hold %llu exceeded the watchdog limit; releasing it",
              generation)
        #if DEBUG
        watchdogReleaseCount += 1
        #endif
        handOff()
    }
}

/// Serializes historical exact-day publication with other source-owned Repository generations. Historical
/// analysis may finish while HealthKit is publishing the same shared projection; waiting on the same fence
/// prevents either publisher from invalidating the other's in-flight Repository refresh generation.
/// The wait is cancellable (CC-3): a quiesced drain unwinds into its `cancelOwnedLease` path instead of
/// holding the pipeline's quiescence token until the fence opens.
@MainActor
enum HistoricalRepositoryPublicationGate {
    static func run<T>(
        barrier: RepositoryPublicationBarrier = .shared,
        operation: @MainActor () async throws -> T
    ) async throws -> T {
        let ownership = try await barrier.acquireExclusive()
        defer { barrier.releaseExclusive(ownership) }
        return try await operation()
    }
}

/// Main-actor single-flight queue because `Repository` itself is MainActor-isolated. Requests that arrive
/// before an operation starts merge into one pending batch. Requests arriving after a refresh starts queue a
/// later pass because they may represent data committed after the running query took its SQLite snapshot.
@MainActor
final class RepositoryRefreshCoordinator {
    typealias Executor = @MainActor (RepositoryRefreshIntent) async -> Bool

    private struct PendingBatch {
        var intent: RepositoryRefreshIntent
        var waiters: [CheckedContinuation<Bool, Never>]
    }

    private let executor: Executor
    private let coalescingDelay: Duration
    private var pending: PendingBatch?
    private var worker: Task<Void, Never>?

    #if DEBUG
    private(set) var executed: [RepositoryRefreshIntent] = []
    #endif

    init(
        coalescingDelay: Duration = .milliseconds(20),
        executor: @escaping Executor
    ) {
        self.coalescingDelay = max(.zero, coalescingDelay)
        self.executor = executor
    }

    func request(_ intent: RepositoryRefreshIntent) async -> Bool {
        if Task.isCancelled { return false }
        return await withCheckedContinuation { continuation in
            if var batch = pending {
                batch.intent = RepositoryRefreshIntent.merged(batch.intent, intent)
                batch.waiters.append(continuation)
                pending = batch
            } else {
                pending = PendingBatch(intent: intent, waiters: [continuation])
            }
            startIfNeeded()
        }
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            if coalescingDelay > .zero {
                do {
                    try await Task.sleep(for: coalescingDelay)
                } catch {
                    // The coordinator owns the worker. A cancelled caller must not strand other waiters;
                    // proceed to drain the already-accepted batch and deliver a deterministic result.
                }
            } else {
                await Task.yield()
            }
            await drain()
        }
    }

    private func drain() async {
        while let batch = pending {
            pending = nil
            #if DEBUG
            executed.append(batch.intent)
            #endif
            let succeeded = await executor(batch.intent)
            batch.waiters.forEach { $0.resume(returning: succeeded) }
        }
        worker = nil
        if pending != nil { startIfNeeded() }
    }
}

@MainActor
private enum RepositoryRefreshRegistry {
    private final class Entry {
        weak var repository: Repository?
        let coordinator: RepositoryRefreshCoordinator

        init(repository: Repository, coordinator: RepositoryRefreshCoordinator) {
            self.repository = repository
            self.coordinator = coordinator
        }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    static func coordinator(for repository: Repository) -> RepositoryRefreshCoordinator {
        entries = entries.filter { $0.value.repository != nil }
        let key = ObjectIdentifier(repository)
        if let existing = entries[key]?.coordinator { return existing }
        let coordinator = RepositoryRefreshCoordinator { [weak repository] intent in
            guard let repository, await repository.storeHandle() != nil else { return false }
            let barrier = RepositoryPublicationBarrier.shared
            guard barrier.beginRefreshIfAllowed() else {
                barrier.performAfterOpen(for: repository, intent: intent) { [weak repository] replayIntent in
                    guard let repository else { return }
                    Task { @MainActor in
                        _ = await repository.refresh(replayIntent)
                    }
                }
                return false
            }
            defer { barrier.endRefresh() }

            let trace = PerformanceTrace.begin(intent.traceName)
            defer { PerformanceTrace.end(trace) }
            return (await repository.executeRefresh(intent.request)).succeeded
        }
        entries[key] = Entry(repository: repository, coordinator: coordinator)
        return coordinator
    }
}

extension Repository {
    /// Execute the typed refresh request after the caller owns the publication barrier. This is the single
    /// production backend for both legacy intent adapters and new exact/recent callers.
    @discardableResult
    func executeRefresh(_ request: RepositoryRefreshRequest) async -> RepositoryRefreshExecutionStatus {
        // Exact publication must use an already verified generation. A bounded refresh is not evidence that
        // the requested historical days were published.
        if !request.exactDays.isEmpty,
           !request.reasons.contains(.currentDay) {
            guard let projection = verifiedHealthProjection,
                  Set(projection.metrics.values.map(\.metricDay)).isSuperset(of: request.exactDays) else {
                return .failed(code: "verified_projection_missing_exact_days")
            }
            do {
                let outcome = try await publishVerifiedExactDays(
                    request.exactDays,
                    recordedTimeZoneIdentifier: TimeZone.autoupdatingCurrent.identifier,
                    projection: projection
                )
                guard outcome.authoritativeDataPublished else {
                    return .failed(code: "exact_repository_publication_failed")
                }
                if request.includeHistoryExtent {
                    await refreshHistoryExtent()
                }
                return .published(outcome)
            } catch {
                return .failed(code: "exact_repository_publication_failed")
            }
        }

        // Full history is a maintenance lane. It updates extent metadata only and never hydrates the
        // dashboard cache with an unbounded read.
        if request.fullHistory {
            if request.includeHistoryExtent {
                await refreshHistoryExtent()
            }
            return .deferred
        }

        let requestedRecentDays = request.recentDashboardDays
            ?? 30
        let boundedRecentDays = min(30, max(1, requestedRecentDays))
        let didPublish = await refresh(days: boundedRecentDays)
        guard didPublish else {
            return .failed(code: "repository_refresh_failed")
        }
        if request.includeHistoryExtent {
            await refreshHistoryExtent()
        }
        return .published(RepositoryRefreshOutcome(
            authoritativeDataPublished: true,
            changedDays: [],
            snapshotStatus: .persisted
        ))
    }

    /// Typed refresh entry point. A source publication fence returns `.deferred`; it never reports a blocked
    /// request as an authoritative failure.
    @discardableResult
    func refresh(_ request: RepositoryRefreshRequest) async -> RepositoryRefreshExecutionStatus {
        switch RepositoryRefreshContext.disposition {
        case .suppress:
            return .deferred
        case .allow:
            let barrier = RepositoryPublicationBarrier.shared
            guard barrier.beginRefreshIfAllowed() else { return .deferred }
            defer { barrier.endRefresh() }
            return await executeRefresh(request)
        }
    }

    @discardableResult
    func refresh(_ intent: RepositoryRefreshIntent) async -> Bool {
        switch RepositoryRefreshContext.disposition {
        case .allow:
            return await RepositoryRefreshRegistry.coordinator(for: self).request(intent)
        case .suppress:
            return false
        }
    }
}
