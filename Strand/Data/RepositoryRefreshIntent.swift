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

@MainActor
final class RepositoryRefreshCoordinator {
    typealias Executor = @MainActor (RepositoryRefreshIntent) async -> Bool

    private let executor: Executor
    private let coalescingDelay: Duration
    private var pending: RepositoryRefreshIntent?
    private var worker: Task<Void, Never>?
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    private var queueSucceeded = true

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
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            pending = pending.map { RepositoryRefreshIntent.merged($0, intent) } ?? intent
            startIfNeeded()
        }
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            if coalescingDelay > .zero {
                try? await Task.sleep(for: coalescingDelay)
            } else {
                await Task.yield()
            }
            await drain()
        }
    }

    private func drain() async {
        while let intent = pending {
            pending = nil
            #if DEBUG
            executed.append(intent)
            #endif
            let succeeded = await executor(intent)
            queueSucceeded = queueSucceeded && succeeded
        }
        worker = nil
        let completed = waiters
        waiters.removeAll(keepingCapacity: true)
        let result = queueSucceeded
        queueSucceeded = true
        completed.forEach { $0.resume(returning: result) }
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
}
