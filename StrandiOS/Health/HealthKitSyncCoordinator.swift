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

/// Converts one committed HealthKit civil-time window into IntelligenceEngine's forward dependency closure.
/// A historical HRV/RHR/sleep edit is not day-local: it can change later personal baselines, Recovery,
/// sleep-debt, and carry-dependent results. Recompute from the earliest changed civil day through today rather
/// than rescoring only the changed slice and leaving newer outputs stale. Calendar arithmetic (not seconds /
/// 86,400) keeps spring/fall DST windows exact; the range remains bounded to the engine's 10,000-day ceiling.
struct HealthKitAnalysisRange: Equatable, Sendable {
    static let maximumWindowDays = 10_000

    let maxDays: Int
    let startOffset: Int

    init(window: HealthKitSyncWindow, now: Date = Date(), calendar input: Calendar = .current) {
        let calendar = input
        let today = calendar.startOfDay(for: now)
        let changedStart = calendar.startOfDay(for: window.start)
        let earliestAffected = min(changedStart, today)
        let forwardSpan = max(
            1,
            (calendar.dateComponents([.day], from: earliestAffected, to: today).day ?? 0) + 1)

        startOffset = 0
        maxDays = min(forwardSpan, Self.maximumWindowDays)
    }

    var publicationDays: Int {
        min(Self.maximumWindowDays, max(120, maxDays))
    }

    func reconciledDays(now: Date = Date(), calendar input: Calendar = .current) -> ClosedRange<String> {
        let calendar = input
        let newest = calendar.startOfDay(for: now)
        let oldest = calendar.date(byAdding: .day, value: -(maxDays - 1), to: newest) ?? newest
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: oldest)...formatter.string(from: newest)
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
///
/// This coordinator owns two related fences:
/// 1. an import/scoring lease, so a newer HealthKit writer cannot commit between analysis and publication;
/// 2. the shared Repository publication barrier, so an unrelated BLE/foreground refresh cannot expose fresh
///    HRV/RHR before the matching Recovery generation is durable.
///
/// The Repository barrier is acquired before any HealthKit import operation and remains closed while a durable
/// scoring journal exists—even if the process is suspended or scoring fails. It opens only after the journal is
/// successfully cleared following coherent Repository/widget publication.
@MainActor
final class HealthKitScoringCoordinator: NSObject {
    typealias Operation = @MainActor (HealthKitSyncWindow) async -> Bool
    typealias Analysis = @MainActor (HealthKitSyncWindow) async -> Bool
    typealias Publication = @MainActor (HealthKitSyncWindow) async -> Bool

    static let shared = HealthKitScoringCoordinator(
        persistence: HealthKitPendingWindowDefaultsStore(key: "healthKit.pendingScoringWindow.v1"))

    private enum PipelineLease: Equatable {
        case importing
        case scoring
    }

    private struct LeaseWaiter {
        let kind: PipelineLease
        let continuation: CheckedContinuation<Void, Never>
    }

    private let persistence: any HealthKitPendingWindowPersisting
    private let notificationCenter: NotificationCenter
    private let publicationBarrier: RepositoryPublicationBarrier
    private(set) var pending: HealthKitSyncWindow?
    private(set) var isRunning = false
    private var revision: UInt64 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var activeLease: PipelineLease?
    private var leaseWaiters: [LeaseWaiter] = []
    private var publicationBarrierHeld = false

    init(
        persistence: any HealthKitPendingWindowPersisting,
        notificationCenter: NotificationCenter = .default,
        publicationBarrier: RepositoryPublicationBarrier = .shared
    ) {
        self.persistence = persistence
        self.notificationCenter = notificationCenter
        self.publicationBarrier = publicationBarrier
        pending = persistence.load()
        super.init()

        // StrandiOSApp constructs the production singleton before AppModel. A restored scoring journal can
        // therefore close publication synchronously before launch's first Repository refresh is scheduled.
        if pending != nil {
            publicationBarrierHeld = publicationBarrier.acquireRestoredExclusiveIfIdle()
        }
    }

    /// Compatibility helper for focused tests and callers that have no competing producer. Production uses
    /// the coordinator-owned `runAndWait(analyze:publish:)`, which validates the scoring revision between
    /// analysis and publication and holds both fences throughout those phases.
    static func runAnalysisThenPublish(
        analyze: @escaping @MainActor () async -> Bool,
        publish: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        guard await analyze() else { return false }
        return await publish()
    }

    /// Durably widen the scoring dependency. This method is async because a direct caller must first close the
    /// shared Repository fence. Production import calls already hold it, so the await is a no-op there.
    func offer(_ window: HealthKitSyncWindow) async throws {
        let hadPending = pending != nil
        await ensurePublicationBarrierHeld()
        let widened = pending.map { $0.union(window) } ?? window
        do {
            try persistence.save(widened)
        } catch {
            if !hadPending { releasePublicationBarrierIfIdle() }
            throw error
        }
        pending = widened
        revision &+= 1
        notificationCenter.post(
            name: HealthKitSyncPublication.name,
            object: self,
            userInfo: [HealthKitSyncPublication.windowKey: widened])
    }

    /// Run one importer while excluding scoring publication and every typed Repository refresh. A second
    /// import request can still widen the import coordinator's durable window while the operation awaits; it is
    /// replayed before this lease transfers. The scoring notification may arrive immediately, but its drain
    /// waits on the same pipeline lease and inherits the still-closed Repository fence.
    func withImportLease<T>(_ operation: @MainActor () async -> T) async -> T {
        await acquireLease(.importing)
        await ensurePublicationBarrierHeld()
        defer {
            releaseLease(.importing)
            releasePublicationBarrierIfIdle()
        }
        return await operation()
    }

    /// Drain the durable scoring union. The revision check occurs after analysis and before publication, so a
    /// widened window never publishes the older analyzed generation. The source pipeline and every unrelated
    /// typed Repository refresh remain fenced through the final Repository/widget publication.
    func runAndWait(
        analyze: @escaping Analysis,
        publish: @escaping Publication
    ) async {
        if isRunning {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isRunning = true
        await acquireLease(.scoring)
        await ensurePublicationBarrierHeld()
        defer {
            releaseLease(.scoring)
            releasePublicationBarrierIfIdle()
            isRunning = false
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
        }

        while let snapshot = pending {
            let snapshotRevision = revision
            guard await analyze(snapshot) else { return }
            guard revision == snapshotRevision else { continue }

            guard await publish(snapshot) else { return }
            // Production offers cannot occur while the scoring lease is held. Keep the second check as a
            // defensive/test guard for any direct future caller that widens the journal during publication.
            guard revision == snapshotRevision else { continue }

            do {
                try persistence.save(nil)
                pending = nil
            } catch {
                // Publication may already be correct, but retaining the journal AND Repository fence is
                // conservative: the next mount repeats the idempotent analysis rather than losing the handoff.
                return
            }
        }
    }

    /// Backward-compatible operation-only seam used by existing coordinator tests. It receives all revision
    /// and fence guarantees; it simply has no separate publication phase.
    func runAndWait(operation: @escaping Operation) async {
        await runAndWait(analyze: operation, publish: { _ in true })
    }

    private func ensurePublicationBarrierHeld() async {
        guard !publicationBarrierHeld else { return }
        await publicationBarrier.acquireExclusive()
        publicationBarrierHeld = true
    }

    private func releasePublicationBarrierIfIdle() {
        guard publicationBarrierHeld, pending == nil, activeLease == nil else { return }
        publicationBarrierHeld = false
        publicationBarrier.releaseExclusive()
    }

    private func acquireLease(_ kind: PipelineLease) async {
        guard activeLease != nil else {
            activeLease = kind
            return
        }
        await withCheckedContinuation { continuation in
            leaseWaiters.append(LeaseWaiter(kind: kind, continuation: continuation))
        }
    }

    private func releaseLease(_ kind: PipelineLease) {
        precondition(activeLease == kind, "HealthKit pipeline lease released by non-owner")
        guard !leaseWaiters.isEmpty else {
            activeLease = nil
            return
        }
        let next = leaseWaiters.removeFirst()
        activeLease = next.kind
        next.continuation.resume()
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

        await scoringCoordinator.withImportLease {
            while let snapshot = pending {
                let snapshotRevision = revision
                do {
                    // Journal the scoring dependency BEFORE any import/write-back awaits. If local rows commit
                    // and a later outbound HealthKit write fails—or the process is suspended—the score request
                    // already survives. Scoring itself cannot begin until this import lease is released.
                    try await scoringCoordinator.offer(snapshot)
                } catch {
                    return
                }

                guard await operation(snapshot) else {
                    // Import work remains pending for retry, while the durable scoring journal may safely
                    // reconcile either unchanged rows or a partially committed transaction.
                    return
                }

                // An overlapping wake widened/replaced the pending interval while the operation awaited. Keep
                // the import lease and process the union before any scoring publication can begin.
                guard revision == snapshotRevision else { continue }
                do {
                    try persistence.save(nil)
                    pending = nil
                } catch {
                    // Clearing failure is conservative: repeat the idempotent import on the next wake. The
                    // scoring dependency is already durable and will run after this lease is released.
                    return
                }
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
        anchor: HKQueryAnchor?,
        handlePage: PageHandler? = nil
    ) async throws -> HealthKitAnchorScanResult {
        var cursor = anchor
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
            wasInitialScan: anchor == nil
        )
    }
}
#endif
