#if os(iOS)
import Foundation
import HealthKit

struct HealthKitSyncWindow: Codable, Equatable, Sendable {
    let start: Date
    let end: Date

    init(start: Date, end: Date) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    func union(_ other: HealthKitSyncWindow) -> HealthKitSyncWindow {
        HealthKitSyncWindow(start: min(start, other.start), end: max(end, other.end))
    }
}

/// Converts one committed HealthKit civil-time window into IntelligenceEngine's day-offset contract.
/// Calendar arithmetic (not seconds/86,400) keeps spring/fall DST windows exact. The result is bounded to
/// the same 10,000-day ceiling as IntelligenceAnalysisRequest, so a malformed historical cursor cannot ask
/// the scorer for an unbounded pass.
struct HealthKitAnalysisRange: Equatable, Sendable {
    static let maximumWindowDays = 10_000

    let maxDays: Int
    let startOffset: Int

    init(window: HealthKitSyncWindow, now: Date = Date(), calendar input: Calendar = .current) {
        let calendar = input
        let today = calendar.startOfDay(for: now)
        let rawStart = calendar.startOfDay(for: window.start)
        let rawEnd = calendar.startOfDay(for: window.end)
        let end = min(rawEnd, today)
        let start = min(rawStart, end)

        let rawOffset = max(0, calendar.dateComponents([.day], from: end, to: today).day ?? 0)
        let boundedOffset = min(rawOffset, Self.maximumWindowDays - 1)
        let rawSpan = max(1, (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1)
        let remaining = max(1, Self.maximumWindowDays - boundedOffset)

        startOffset = boundedOffset
        maxDays = min(rawSpan, remaining)
    }

    var publicationDays: Int {
        min(Self.maximumWindowDays, max(120, startOffset + maxDays))
    }
}

enum HealthKitSyncPublication {
    static let name = Notification.Name("noop.healthKitSyncWindowCommitted")
    static let windowKey = "window"

    static func window(from notification: Notification) -> HealthKitSyncWindow? {
        notification.userInfo?[windowKey] as? HealthKitSyncWindow
    }
}

@MainActor
protocol HealthKitPendingWindowPersisting: AnyObject {
    func load() -> HealthKitSyncWindow?
    func save(_ window: HealthKitSyncWindow?) throws
}

@MainActor
final class HealthKitPendingWindowDefaultsStore: HealthKitPendingWindowPersisting {
    enum PersistenceError: Error {
        case flushFailed
        case verificationFailed
    }

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "healthKit.pendingSyncWindow.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> HealthKitSyncWindow? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HealthKitSyncWindow.self, from: data)
    }

    func save(_ window: HealthKitSyncWindow?) throws {
        if let window {
            let data = try JSONEncoder().encode(window)
            defaults.set(data, forKey: key)
            guard defaults.synchronize() else { throw PersistenceError.flushFailed }
            guard defaults.data(forKey: key) == data else { throw PersistenceError.verificationFailed }
        } else {
            defaults.removeObject(forKey: key)
            guard defaults.synchronize() else { throw PersistenceError.flushFailed }
            guard defaults.object(forKey: key) == nil else { throw PersistenceError.verificationFailed }
        }
    }
}

/// Durable handoff from HealthKit ingestion to IntelligenceEngine scoring. The import coordinator writes this
/// journal before it clears its own pending window. If iOS suspends or kills the process before the app-level
/// scoring task runs, the next app mount drains the same union instead of waiting for the 15-minute cadence.
@MainActor
final class HealthKitScoringCoordinator {
    typealias Operation = @MainActor (HealthKitSyncWindow) async -> Bool

    static let shared = HealthKitScoringCoordinator(
        persistence: HealthKitPendingWindowDefaultsStore(key: "healthKit.pendingScoringWindow.v1"))

    private let persistence: any HealthKitPendingWindowPersisting
    private let notificationCenter: NotificationCenter
    private(set) var pending: HealthKitSyncWindow?
    private(set) var isRunning = false
    private var revision: UInt64 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(
        persistence: any HealthKitPendingWindowPersisting,
        notificationCenter: NotificationCenter = .default
    ) {
        self.persistence = persistence
        self.notificationCenter = notificationCenter
        pending = persistence.load()
    }

    func offer(_ window: HealthKitSyncWindow) throws {
        let widened = pending.map { $0.union(window) } ?? window
        try persistence.save(widened)
        pending = widened
        revision &+= 1
        notificationCenter.post(
            name: HealthKitSyncPublication.name,
            object: self,
            userInfo: [HealthKitSyncPublication.windowKey: widened])
    }

    func runAndWait(operation: @escaping Operation) async {
        if isRunning {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isRunning = true
        defer {
            isRunning = false
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
        }

        while let snapshot = pending {
            let snapshotRevision = revision
            guard await operation(snapshot) else { return }
            guard revision == snapshotRevision else { continue }
            do {
                try persistence.save(nil)
                pending = nil
            } catch {
                // The derived publication may already be correct, but retaining the journal is conservative:
                // the next mount repeats the idempotent analysis rather than losing the handoff.
                return
            }
        }
    }
}

/// Serializes every HealthKit aggregation and journals the widest outstanding civil-time window.
/// A wake arriving while an aggregation is suspended widens the durable window; the worker then
/// reruns that union before clearing the journal. A failed aggregation intentionally leaves the
/// journal in place for the next observer wake or foreground catch-up.
@MainActor
final class HealthKitSyncCoordinator {
    typealias Operation = @MainActor (HealthKitSyncWindow) async -> Bool

    private let persistence: any HealthKitPendingWindowPersisting
    private let operation: Operation
    private let scoringCoordinator: HealthKitScoringCoordinator
    private(set) var pending: HealthKitSyncWindow?
    private(set) var isRunning = false
    private var revision: UInt64 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var workerTask: Task<Void, Never>?

    init(
        persistence: any HealthKitPendingWindowPersisting,
        scoringCoordinator: HealthKitScoringCoordinator = .shared,
        operation: @escaping Operation
    ) {
        self.persistence = persistence
        self.scoringCoordinator = scoringCoordinator
        self.operation = operation
        pending = persistence.load()
    }

    /// Durably records work before the caller advances any HealthKit query anchor.
    func offer(_ window: HealthKitSyncWindow) throws {
        let widened = pending.map { $0.union(window) } ?? window
        try persistence.save(widened)
        pending = widened
        revision &+= 1
    }

    /// Starts recovery without making an observer acknowledgement wait for a potentially long import.
    func start() {
        guard workerTask == nil, pending != nil else { return }
        workerTask = Task { [weak self] in
            await self?.runAndWait()
        }
    }

    /// Used by foreground/manual sync, where the caller expects the queued work to finish first.
    func runAndWait() async {
        if isRunning {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isRunning = true
        defer {
            isRunning = false
            workerTask = nil
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
        }

        while let snapshot = pending {
            let snapshotRevision = revision
            guard await operation(snapshot) else { return }

            // An overlapping wake widened/replaced the pending interval while the operation awaited.
            // Keep the union and run it once more; only the exact successfully-processed revision may hand
            // off a scoring journal and clear the durable import window.
            guard revision == snapshotRevision else { continue }
            do {
                // Ordering is the crash-safety contract: the derived-score work is durable before imported
                // work is acknowledged. A kill at any later instruction leaves at least one journal to replay.
                try scoringCoordinator.offer(snapshot)
                try persistence.save(nil)
                pending = nil
            } catch {
                // Clearing/handoff failure is conservative: repeat the idempotent aggregation on next wake.
                return
            }
        }
    }
}

struct HealthKitAnchorPage {
    let samples: [HKSample]
    /// HealthKit supplies only UUIDs for deleted objects. They are resolved through the persisted
    /// source-object index before the observer's aggregation window is chosen.
    let deletedObjectUUIDs: [String]
    let deletedCount: Int
    let newAnchor: HKQueryAnchor?

    init(samples: [HKSample], deletedObjectUUIDs: [String], newAnchor: HKQueryAnchor?) {
        self.samples = samples
        self.deletedObjectUUIDs = deletedObjectUUIDs
        deletedCount = deletedObjectUUIDs.count
        self.newAnchor = newAnchor
    }

    /// Compatibility seam for deterministic pager tests where a synthetic HKDeletedObject is not available.
    init(samples: [HKSample], deletedCount: Int, newAnchor: HKQueryAnchor?) {
        self.samples = samples
        deletedObjectUUIDs = []
        self.deletedCount = deletedCount
        self.newAnchor = newAnchor
    }

    var resultCount: Int { samples.count + deletedCount }
}

@MainActor
protocol HealthKitAnchoredPageLoading: AnyObject {
    func loadPage(
        type: HKSampleType,
        predicate: NSPredicate?,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> HealthKitAnchorPage
}

@MainActor
final class HealthKitAnchoredPageLoader: HealthKitAnchoredPageLoading {
    private let store: HKHealthStore

    init(store: HKHealthStore) {
        self.store = store
    }

    func loadPage(
        type: HKSampleType,
        predicate: NSPredicate?,
        anchor: HKQueryAnchor?,
        limit: Int
    ) async throws -> HealthKitAnchorPage {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: type,
                predicate: predicate,
                anchor: anchor,
                limit: limit
            ) { _, samples, deleted, newAnchor, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: HealthKitAnchorPage(
                        samples: samples ?? [],
                        deletedObjectUUIDs: (deleted ?? []).map { $0.uuid.uuidString },
                        newAnchor: newAnchor
                    ))
                }
            }
            store.execute(query)
        }
    }
}

struct HealthKitAnchorScanResult {
    let oldestSampleDate: Date?
    let newestSampleDate: Date?
    let sampleCount: Int
    let deletedCount: Int
    let pageCount: Int
    let finalAnchor: HKQueryAnchor
    let wasInitialScan: Bool
}

/// Pages anchored deltas in fixed-size batches. The page handler resolves deleted UUIDs while that
/// bounded page is still alive; the pager deliberately retains only counts and date extrema, never a
/// lifetime-sized `[HKSample]` or `[UUID]`.
@MainActor
final class HealthKitAnchorPager {
    enum PagingError: Error {
        case missingAnchor
        case excessivePageCount
    }

    static let defaultPageLimit = 500
    private static let maximumPageCount = 100_000

    private let loader: any HealthKitAnchoredPageLoading
    private let pageLimit: Int
    typealias PageHandler = @MainActor (HealthKitAnchorPage) async throws -> HealthKitSyncWindow?

    init(loader: any HealthKitAnchoredPageLoading, pageLimit: Int = defaultPageLimit) {
        self.loader = loader
        self.pageLimit = max(1, pageLimit)
    }

    func scan(
        type: HKSampleType,
        predicate: NSPredicate?,
        priorAnchor: HKQueryAnchor?,
        handlePage: PageHandler? = nil
    ) async throws -> HealthKitAnchorScanResult {
        var cursor = priorAnchor
        var oldest: Date?
        var newest: Date?
        var sampleCount = 0
        var deletedCount = 0
        var pageCount = 0
        var finalAnchor: HKQueryAnchor?

        repeat {
            guard pageCount < Self.maximumPageCount else { throw PagingError.excessivePageCount }
            let page = try await loader.loadPage(
                type: type,
                predicate: predicate,
                anchor: cursor,
                limit: pageLimit
            )
            guard let nextAnchor = page.newAnchor else { throw PagingError.missingAnchor }
            pageCount += 1
            sampleCount += page.samples.count
            deletedCount += page.deletedCount
            for sample in page.samples {
                oldest = oldest.map { min($0, sample.startDate) } ?? sample.startDate
                newest = newest.map { max($0, sample.endDate) } ?? sample.endDate
            }
            if let handledWindow = try await handlePage?(page) {
                oldest = oldest.map { min($0, handledWindow.start) } ?? handledWindow.start
                newest = newest.map { max($0, handledWindow.end) } ?? handledWindow.end
            }
            finalAnchor = nextAnchor
            cursor = nextAnchor
            if page.resultCount < pageLimit { break }
        } while true

        guard let finalAnchor else { throw PagingError.missingAnchor }
        return HealthKitAnchorScanResult(
            oldestSampleDate: oldest,
            newestSampleDate: newest,
            sampleCount: sampleCount,
            deletedCount: deletedCount,
            pageCount: pageCount,
            finalAnchor: finalAnchor,
            wasInitialScan: priorAnchor == nil
        )
    }
}
#endif
