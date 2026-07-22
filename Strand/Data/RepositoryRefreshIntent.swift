import Foundation

enum RepositoryRefreshDataset: Hashable, Sendable {
    case dashboard
}

/// Explicit refresh purposes. Each case maps to the narrowest safe replacement window for the coherent
/// dashboard cache; small UI events can no longer accidentally request 4,000 days by default.
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
        case .currentDay, .postBackfill: return 120
        case .recentDashboard(let days): return min(4_000, max(120, days))
        case .initialLoad, .activeDeviceChanged, .postImport, .fullHistoryMigration: return 4_000
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

    func absorbs(_ other: Self) -> Bool {
        days >= other.days && datasets.isSuperset(of: other.datasets)
    }

    static func merged(_ lhs: Self, _ rhs: Self) -> Self {
        if case .recentDashboard(let leftDays) = lhs,
            case .recentDashboard(let rightDays) = rhs
        {
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
/// child inherits the suppression and cannot accidentally restore the legacy 4,000-day repository refresh.
enum RepositoryRefreshContext {
    enum Disposition: Equatable, Sendable {
        case legacyDefault
        case suppress
        case intent(RepositoryRefreshIntent)
    }

    @TaskLocal static var disposition: Disposition = .legacyDefault
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
            let trace = PerformanceTrace.begin("repository_refresh_\(intent.description)")
            defer { PerformanceTrace.end(trace) }
            await repository.refresh(days: intent.days)
            return true
        }
        entries[key] = Entry(repository: repository, coordinator: coordinator)
        return coordinator
    }
}

extension Repository {
    @discardableResult
    func refresh(_ intent: RepositoryRefreshIntent) async -> Bool {
        await RepositoryRefreshRegistry.coordinator(for: self).request(intent)
    }

    /// Compatibility overload for call sites that have not yet been explicitly classified. Normal callers
    /// retain the historical 4,000-day behavior. Narrow or suppressed refreshes are supplied deliberately via
    /// `RepositoryRefreshContext`, so launch hydration can never be accidentally truncated by unrelated state.
    func refresh() async {
        switch RepositoryRefreshContext.disposition {
        case .legacyDefault:
            await refresh(days: 4_000)
        case .suppress:
            return
        case .intent(let intent):
            _ = await refresh(intent)
        }
    }
}
