import Foundation

enum RepositoryRefreshDataset: Hashable, Sendable {
    case dashboard
}

/// Explicit refresh purposes. The current cache is a full-history replacement model, so Phase 1 keeps its
/// historic 4,000-day extent until Phase 2 introduces a separate recent dashboard projection.
enum RepositoryRefreshIntent: Equatable, Sendable, CustomStringConvertible {
    case currentDay
    case recentDashboard(days: Int)
    case postBackfill
    case initialLoad
    case activeDeviceChanged
    case postImport
    case fullHistoryMigration

    var days: Int {
        switch self {
        case .currentDay, .postBackfill, .initialLoad:
            return 4_000
        case .recentDashboard(let days):
            return min(4_000, max(120, days))
        case .activeDeviceChanged, .postImport, .fullHistoryMigration:
            return 4_000
        }
    }

    var datasets: Set<RepositoryRefreshDataset> { [.dashboard] }

    var description: String {
        switch self {
        case .currentDay: return "current-day"
        case .recentDashboard: return "recent-\(days)"
        case .postBackfill: return "post-backfill"
        case .initialLoad: return "initial-load"
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
        case .activeDeviceChanged: return 4
        case .postImport: return 5
        case .fullHistoryMigration: return 6
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
///
/// MainActor isolation makes the handoff deterministic without locks. The class is injectable so tests and
/// previews do not share production fence state.
@MainActor
final class RepositoryPublicationBarrier {
    static let shared = RepositoryPublicationBarrier()

    private var exclusive = false
    private var activeRefreshes = 0
    private var exclusiveWaiters: [CheckedContinuation<Void, Never>] = []
    private struct DeferredRefresh {
        var intent: RepositoryRefreshIntent
        let operation: @MainActor (RepositoryRefreshIntent) -> Void
    }
    private var afterOpen: [ObjectIdentifier: DeferredRefresh] = [:]

    #if DEBUG
    private(set) var deferredRequestCount = 0
    var deferredRepositoryCount: Int { afterOpen.count }
    #endif

    var blocksRefreshes: Bool {
        exclusive || !exclusiveWaiters.isEmpty
    }

    /// Acquire the source-publication fence. New refreshes stop immediately; an already-running typed refresh
    /// is allowed to finish before the source begins writing, so it cannot publish a snapshot taken mid-import.
    func acquireExclusive() async {
        if !exclusive, activeRefreshes == 0, exclusiveWaiters.isEmpty {
            exclusive = true
            return
        }
        await withCheckedContinuation { continuation in
            exclusiveWaiters.append(continuation)
        }
    }

    /// Best-effort synchronous bootstrap for a scoring journal restored before AppModel launch. The iOS app
    /// initializes the HealthKit coordinator before constructing AppModel, so production reaches this with no
    /// active refresh. If a test or future host initializes late, the normal async acquisition still closes it.
    func acquireRestoredExclusiveIfIdle() -> Bool {
        guard !exclusive, activeRefreshes == 0, exclusiveWaiters.isEmpty else { return false }
        exclusive = true
        return true
    }

    func releaseExclusive() {
        precondition(exclusive, "Repository publication fence released by non-owner")
        if !exclusiveWaiters.isEmpty {
            // Transfer ownership without opening a publication gap between two source transactions.
            let next = exclusiveWaiters.removeFirst()
            next.resume()
            return
        }

        exclusive = false
        let callbacks = Array(afterOpen.values)
        afterOpen.removeAll(keepingCapacity: true)
        callbacks.forEach { $0.operation($0.intent) }
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
        guard activeRefreshes == 0, !exclusive, !exclusiveWaiters.isEmpty else { return }
        exclusive = true
        exclusiveWaiters.removeFirst().resume()
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
            return await repository.refresh(days: intent.days)
        }
        entries[key] = Entry(repository: repository, coordinator: coordinator)
        return coordinator
    }
}

extension Repository {
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
