#if os(iOS)
import Foundation
import HealthKit
import NoopPhase34Core
import UIKit
import WhoopStore

struct HealthKitSyncWindow: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
    /// Durable exact-object evidence considered for workout retraction. Daily aggregates retain
    /// missing/hidden query values because a tombstone does not prove complete contributor visibility.
    let projectionDeletions: [HealthKitProjectionDeletion]

    init(start: Date, end: Date, projectionDeletions: [HealthKitProjectionDeletion] = []) {
        self.start = min(start, end)
        self.end = max(start, end)
        self.projectionDeletions = projectionDeletions
    }

    private enum CodingKeys: String, CodingKey { case start, end, projectionDeletions }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(start: try values.decode(Date.self, forKey: .start),
                  end: try values.decode(Date.self, forKey: .end),
                  projectionDeletions: try values.decodeIfPresent(
                    [HealthKitProjectionDeletion].self, forKey: .projectionDeletions) ?? [])
    }

    func union(_ other: HealthKitSyncWindow) -> HealthKitSyncWindow {
        let evidence = Array(Set(projectionDeletions + other.projectionDeletions)).sorted {
            if $0.sampleType != $1.sampleType { return $0.sampleType < $1.sampleType }
            if $0.fromTimestamp != $1.fromTimestamp { return $0.fromTimestamp < $1.fromTimestamp }
            if $0.toTimestamp != $1.toTimestamp { return $0.toTimestamp < $1.toTimestamp }
            if $0.fromDay != $1.fromDay { return $0.fromDay < $1.fromDay }
            return $0.toDay < $1.toDay
        }
        return HealthKitSyncWindow(start: min(start, other.start), end: max(end, other.end),
                                   projectionDeletions: evidence)
    }
}

/// Makes NOOP-authored HealthKit deletions replay-safe. HealthKit reports only UUIDs for deleted
/// objects, so their ownership and original time windows must be durable before the delete occurs.
/// Journal writes stay below the store's SQLite parameter headroom and a journal failure prevents
/// the destructive HealthKit operation.
@MainActor
enum HealthKitExportDeletionCommit {
    static let maximumIdentityBatchSize = 400

    static func commit(
        sampleType: HKSampleType,
        loadSamples: () async throws -> [HKSample],
        recordIdentities: ([HealthKitObjectIdentity]) async throws -> Void,
        delete: () async throws -> Int
    ) async throws -> Int {
        let samples = try await loadSamples()
        let identities = samples.map {
            HealthKitObjectIdentity(
                sampleType: sampleType.identifier,
                objectUUID: $0.uuid.uuidString,
                startTs: Int($0.startDate.timeIntervalSince1970),
                endTs: Int($0.endDate.timeIntervalSince1970)
            )
        }
        for start in stride(from: 0, to: identities.count, by: maximumIdentityBatchSize) {
            let end = min(start + maximumIdentityBatchSize, identities.count)
            try await recordIdentities(Array(identities[start..<end]))
        }
        return try await delete()
    }
}

/// Commit each bounded observer page before forgetting ownership of its deletion notifications.
/// Exported Health samples never contribute to the inbound Apple Health projection.
@MainActor
enum HealthKitObserverPageCommit {
    static let exportIdentityNamespace = "noop-healthkit-export"

    static func commit(
        page: HealthKitAnchorPage,
        exportedObjectUUIDs: Set<String>,
        importedIdentities: [HealthKitObjectIdentity],
        initialScan: Bool,
        now: Date,
        sampleTypeIdentifier: String? = nil,
        earliestLocalDate: () async throws -> Date?,
        offer: (HealthKitSyncWindow) throws -> Void,
        saveAnchor: (HKQueryAnchor) throws -> Void,
        retireExports: ([String]) async throws -> Void
    ) async throws -> HealthKitSyncWindow? {
        guard let anchor = page.newAnchor else { throw HealthKitAnchorPager.PagingError.missingAnchor }
        let externalDeleted = page.deletedObjectUUIDs.filter { !exportedObjectUUIDs.contains($0) }
        let inboundObjectUUIDs = Set(page.samples.map { $0.uuid.uuidString })
            .union(externalDeleted)
        let inboundIdentities = importedIdentities.filter {
            inboundObjectUUIDs.contains($0.objectUUID)
        }
        var window: HealthKitSyncWindow?
        if !page.samples.isEmpty || !externalDeleted.isEmpty {
            let known = Set(inboundIdentities.map(\.objectUUID))
            let unknownDeletion = !Set(externalDeleted).isSubset(of: known)
            let dates = page.samples.flatMap { [$0.startDate, $0.endDate] }
                + inboundIdentities.flatMap {
                    [Date(timeIntervalSince1970: TimeInterval($0.startTs)),
                     Date(timeIntervalSince1970: TimeInterval($0.endTs))]
                }
            let fallback = Calendar.current.date(byAdding: .day, value: -31, to: now) ?? now
            var start = dates.min() ?? fallback
            if unknownDeletion, let earliest = try await earliestLocalDate() {
                start = min(start, earliest)
            }
            if initialScan && !unknownDeletion { start = max(start, fallback) }
            let changeStart = Calendar.current.startOfDay(for: start)
            let changeEnd = max(now, dates.max() ?? now)
            var deletions: [HealthKitProjectionDeletion] = []
            if let sampleTypeIdentifier,
               sampleTypeIdentifier == HKObjectType.workoutType().identifier,
               !externalDeleted.isEmpty {
                let calendar = Calendar.current
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd"
                let deletedIDs = Set(externalDeleted)
                let knownDeleted = inboundIdentities.filter {
                    deletedIDs.contains($0.objectUUID) && $0.sampleType == sampleTypeIdentifier
                }
                let bounds: [(Date, Date)] = knownDeleted.map {
                    (Date(timeIntervalSince1970: TimeInterval($0.startTs)),
                     Date(timeIntervalSince1970: TimeInterval($0.endTs)))
                }
                // An unknown UUID still triggers the conservative historical requery above. It
                // cannot authorize clearing banked projections without an indexed contribution window.
                deletions = bounds.map { lower, upper in
                    // Daily aggregates have no complete contributor/value provenance. Keep their
                    // missing values; only a workout's exact indexed row can be considered for removal.
                    return HealthKitProjectionDeletion(sampleType: sampleTypeIdentifier,
                        fromDay: formatter.string(from: lower), toDay: formatter.string(from: upper),
                        fromTimestamp: Int(lower.timeIntervalSince1970),
                        toTimestamp: Int(upper.timeIntervalSince1970))
                }
            }
            let changed = HealthKitSyncWindow(start: changeStart, end: changeEnd,
                                              projectionDeletions: deletions)
            try offer(changed)
            window = changed
        }
        // A failed journal write keeps the old anchor. A failed anchor write keeps the export identities
        // for replay. Only this acknowledged page's identities are retired, so memory stays page-bounded.
        try saveAnchor(anchor)
        let consumedExports = page.deletedObjectUUIDs.filter { exportedObjectUUIDs.contains($0) }
        if !consumedExports.isEmpty { try await retireExports(consumedExports) }
        return window
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

/// Bounded retry for a failed HealthKit scoring run (CC-1). A failure keeps the durable journal but never the
/// Repository fence. Each failure waits out its backoff before the next automatic attempt; after
/// `maximumAttempts` consecutive failures the journal parks until the next foreground or HealthKit import.
struct HealthKitScoringRetryPolicy: Equatable, Sendable {
    var maximumAttempts: Int
    /// Wait after the first, second, … failure. The last entry repeats. `.zero` means no automatic retry:
    /// the next trigger runs at once.
    var backoff: [Duration]

    static let standard = Self(maximumAttempts: 3, backoff: [.seconds(30), .seconds(120)])

    func delay(afterFailure failure: Int) -> Duration {
        guard let last = backoff.last else { return .zero }
        let index = failure - 1
        return backoff.indices.contains(index) ? backoff[index] : last
    }
}

/// Durable handoff from HealthKit ingestion to IntelligenceEngine scoring. The import coordinator writes this
/// journal before it clears its own pending window. If iOS suspends or kills the process before the app-level
/// scoring task runs, the next app mount drains the same union instead of waiting for the 15-minute cadence.
///
/// This coordinator owns two related fences:
/// 1. an import/scoring lease, so a newer HealthKit writer cannot commit between analysis and publication;
/// 2. the shared Repository publication barrier, so an unrelated BLE/foreground refresh cannot expose fresh
///    HRV/RHR in the middle of an import or a scoring generation.
///
/// The Repository barrier is held only while an import or scoring run is active, and every run releases it
/// on exit (CC-1, D4). A failed run keeps the durable journal for a bounded retry, never the fence, and a
/// relaunch never closes the fence from `init`. Both waits honour Task cancellation (CC-3).
@MainActor
final class HealthKitScoringCoordinator: NSObject {
    typealias Operation = @MainActor (HealthKitSyncWindow) async -> Bool
    typealias Analysis = @MainActor (HealthKitSyncWindow) async -> Bool
    typealias Publication = @MainActor (HealthKitSyncWindow) async -> Bool

    static let shared = HealthKitScoringCoordinator(
        persistence: HealthKitPendingWindowDefaultsStore(key: "healthKit.pendingScoringWindow.v1"))

    private enum PipelineLease: Equatable, Sendable {
        case importing
        case scoring
    }

    private enum RunOutcome {
        case cleared
        case cancelled
        case failed(String)
    }

    private let persistence: any HealthKitPendingWindowPersisting
    private let notificationCenter: NotificationCenter
    private let publicationBarrier: RepositoryPublicationBarrier
    private let retryPolicy: HealthKitScoringRetryPolicy
    private(set) var pending: HealthKitSyncWindow?
    private(set) var isRunning = false
    private var revision: UInt64 = 0
    private let runWaiters = CancellableWaiterQueue<Void>()
    private var activeLease: PipelineLease?
    private let leaseWaiters = CancellableWaiterQueue<PipelineLease>()
    private(set) var consecutiveFailures = 0
    private(set) var isParked = false
    private var retryNotBefore: ContinuousClock.Instant?
    private var retryTask: Task<Void, Never>?

    #if DEBUG
    private(set) var diagnosticPhase = "idle"
    #endif

    init(
        persistence: any HealthKitPendingWindowPersisting,
        notificationCenter: NotificationCenter = .default,
        publicationBarrier: RepositoryPublicationBarrier = .shared,
        retryPolicy: HealthKitScoringRetryPolicy = .standard
    ) {
        self.persistence = persistence
        self.notificationCenter = notificationCenter
        self.publicationBarrier = publicationBarrier
        self.retryPolicy = retryPolicy
        pending = persistence.load()
        super.init()
        // A restored journal no longer closes the Repository fence here (D4). The launch drain takes the fence
        // when it actually runs, so `.initialLoad` and first paint never wait on a scoring receipt.
        notificationCenter.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetRetryBudget() }
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

    /// Durably widen the scoring dependency. Production offers arrive inside an import lease, which already
    /// holds the Repository fence; a direct offer never takes the fence on its own. New import data is fresh
    /// evidence, so it also restores a parked journal's retry budget.
    func offer(_ window: HealthKitSyncWindow) async throws {
        let widened = pending.map { $0.union(window) } ?? window
        try persistence.save(widened)
        pending = widened
        revision &+= 1
        resetRetryBudget()
        postJournalEdge(widened)
    }

    /// Run one importer while excluding scoring publication and every typed Repository refresh. A second
    /// import request can still widen the import coordinator's durable window while the operation awaits; it is
    /// retained for the next import lease. The scoring notification may arrive immediately; its drain waits on
    /// the same pipeline lease and takes the fence again when it runs.
    /// - Throws: `CancellationError` when the caller is cancelled while waiting for the lease or the fence.
    func withImportLease<T>(_ operation: @MainActor () async -> T) async throws -> T {
        try await acquireLease(.importing)
        defer { releaseLease(.importing) }
        let ownership = try await publicationBarrier.acquireExclusive()
        defer { publicationBarrier.releaseExclusive(ownership) }
        return await operation()
    }

    /// Drain the durable scoring union. The revision check occurs after analysis and before publication, so a
    /// widened window never publishes the older analyzed generation. The source pipeline and every unrelated
    /// typed Repository refresh remain fenced through the final Repository/widget publication, and the fence
    /// opens when the run ends, whether or not the journal cleared.
    func runAndWait(
        analyze: @escaping Analysis,
        publish: @escaping Publication
    ) async {
        if isRunning {
            // Coalesce onto the active run. A cancelled caller stops waiting without disturbing that run.
            try? await runWaiters.wait(())
            return
        }
        guard pending != nil, admitsAttempt() else { return }
        isRunning = true
        defer {
            isRunning = false
            runWaiters.resumeAll()
        }
        #if DEBUG
        diagnosticPhase = "waiting_for_scoring_lease"
        #endif
        do {
            try await acquireLease(.scoring)
        } catch {
            #if DEBUG
            diagnosticPhase = "cancelled_waiting_for_scoring_lease"
            #endif
            return
        }
        defer { releaseLease(.scoring) }
        let ownership: RepositoryPublicationBarrier.Ownership
        do {
            ownership = try await publicationBarrier.acquireExclusive()
        } catch {
            #if DEBUG
            diagnosticPhase = "cancelled_waiting_for_publication_fence"
            #endif
            return
        }
        // CC-1: the fence covers this run only. It always opens here, so a failure can never freeze every
        // typed refresh for the session, or, through the journal, for every later launch.
        defer { publicationBarrier.releaseExclusive(ownership) }

        recordOutcome(await drainJournal(analyze: analyze, publish: publish))
    }

    /// Backward-compatible operation-only seam used by existing coordinator tests. It receives all revision
    /// and fence guarantees; it simply has no separate publication phase.
    func runAndWait(operation: @escaping Operation) async {
        await runAndWait(analyze: operation, publish: { _ in true })
    }

    /// The next foreground or HealthKit import retries a parked or backing-off journal at once, with a fresh
    /// attempt budget.
    func resetRetryBudget() {
        consecutiveFailures = 0
        isParked = false
        retryNotBefore = nil
        retryTask?.cancel()
        retryTask = nil
    }

    private func drainJournal(analyze: Analysis, publish: Publication) async -> RunOutcome {
        while let snapshot = pending {
            guard !Task.isCancelled else {
                #if DEBUG
                diagnosticPhase = "cancelled_before_analysis"
                #endif
                return .cancelled
            }
            let snapshotRevision = revision
            #if DEBUG
            diagnosticPhase = "analyzing"
            NSLog("Health scoring: analyze %@ to %@", snapshot.start.description, snapshot.end.description)
            #endif
            guard await analyze(snapshot) else {
                if Task.isCancelled { return .cancelled }
                #if DEBUG
                diagnosticPhase = "analysis_or_receipt_failed"
                NSLog("Health scoring: analysis or receipt did not complete")
                #endif
                return .failed("analysis_or_receipt_failed")
            }
            guard !Task.isCancelled else {
                #if DEBUG
                diagnosticPhase = "cancelled_after_analysis"
                #endif
                return .cancelled
            }
            guard revision == snapshotRevision else { continue }

            #if DEBUG
            diagnosticPhase = "publishing"
            #endif
            guard await publish(snapshot) else {
                if Task.isCancelled { return .cancelled }
                #if DEBUG
                diagnosticPhase = "publication_failed"
                #endif
                return .failed("publication_failed")
            }
            guard !Task.isCancelled else {
                #if DEBUG
                diagnosticPhase = "cancelled_after_publication"
                #endif
                return .cancelled
            }
            // Production offers cannot occur while the scoring lease is held. Keep the second check as a
            // defensive/test guard for any direct future caller that widens the journal during publication.
            guard revision == snapshotRevision else { continue }

            do {
                try persistence.save(nil)
                pending = nil
                #if DEBUG
                diagnosticPhase = "complete"
                NSLog("Health scoring: published and cleared journal")
                #endif
            } catch {
                // Publication may already be correct. Keeping the journal repeats the idempotent analysis on
                // the next attempt rather than losing the handoff; the fence still opens with this run.
                return .failed("journal_clear_failed")
            }
        }
        return .cleared
    }

    private func admitsAttempt() -> Bool {
        if isParked {
            #if DEBUG
            diagnosticPhase = "parked"
            #endif
            return false
        }
        if let retryNotBefore, ContinuousClock.now < retryNotBefore {
            #if DEBUG
            diagnosticPhase = "backing_off"
            #endif
            return false
        }
        return true
    }

    private func recordOutcome(_ outcome: RunOutcome) {
        switch outcome {
        case .cleared:
            resetRetryBudget()
        case .cancelled:
            // Cancellation (BG expiry, quiesce) is not a failed attempt.
            break
        case .failed(let code):
            consecutiveFailures += 1
            guard consecutiveFailures < retryPolicy.maximumAttempts else {
                isParked = true
                retryNotBefore = nil
                retryTask?.cancel()
                retryTask = nil
                #if DEBUG
                diagnosticPhase = "parked"
                #endif
                NSLog("Health scoring: parked the journal after %ld failed attempts (%@); "
                      + "the next foreground or HealthKit import retries it", consecutiveFailures, code)
                return
            }
            let delay = retryPolicy.delay(afterFailure: consecutiveFailures)
            NSLog("Health scoring: attempt %ld failed (%@); retrying in %@",
                  consecutiveFailures, code, String(describing: delay))
            scheduleRetry(after: delay)
        }
    }

    private func scheduleRetry(after delay: Duration) {
        retryTask?.cancel()
        retryTask = nil
        guard delay > .zero else {
            retryNotBefore = nil
            return
        }
        retryNotBefore = ContinuousClock.now.advanced(by: delay)
        retryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !self.isParked, let pending = self.pending else { return }
            self.retryNotBefore = nil
            self.retryTask = nil
            // The app's scoring drain observes this edge, exactly as it does for a new import.
            self.postJournalEdge(pending)
        }
    }

    private func postJournalEdge(_ window: HealthKitSyncWindow) {
        notificationCenter.post(
            name: HealthKitSyncPublication.name,
            object: self,
            userInfo: [HealthKitSyncPublication.windowKey: window])
    }

    private func acquireLease(_ kind: PipelineLease) async throws {
        try Task.checkCancellation()
        guard activeLease != nil else {
            activeLease = kind
            return
        }
        try await leaseWaiters.wait(kind)
        // `releaseLease` recorded this waiter as the owner in the turn that resumed it.
        if Task.isCancelled {
            releaseLease(kind)
            throw CancellationError()
        }
    }

    private func releaseLease(_ kind: PipelineLease) {
        precondition(activeLease == kind, "HealthKit pipeline lease released by non-owner")
        activeLease = leaseWaiters.resumeNext()
    }
}

/// Serializes every HealthKit aggregation and journals the widest outstanding civil-time window.
/// A wake arriving while an aggregation is suspended widens the durable window. After the snapshot
/// commits, the worker imports only those follow-up wakes before clearing the journal. A failed aggregation intentionally leaves the
/// journal in place for the next observer wake or foreground catch-up.
@MainActor
final class HealthKitSyncCoordinator {
    typealias Operation = @MainActor (HealthKitSyncWindow) async -> Bool
    typealias ScheduleRetry = @MainActor () -> Void

    private let persistence: any HealthKitPendingWindowPersisting
    private let operation: Operation
    private let scoringCoordinator: HealthKitScoringCoordinator
    private let scheduleRetry: ScheduleRetry
    private(set) var pending: HealthKitSyncWindow?
    private(set) var isRunning = false
    private var importInFlight = false
    private var followUp: HealthKitSyncWindow?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var workerTask: Task<Void, Never>?

    init(
        persistence: any HealthKitPendingWindowPersisting,
        scoringCoordinator: HealthKitScoringCoordinator = .shared,
        scheduleRetry: @escaping ScheduleRetry = {},
        operation: @escaping Operation
    ) {
        self.persistence = persistence
        self.scoringCoordinator = scoringCoordinator
        self.scheduleRetry = scheduleRetry
        self.operation = operation
        pending = persistence.load()
    }

    /// Durably records work before the caller advances any HealthKit query anchor.
    func offer(_ window: HealthKitSyncWindow) throws {
        let widened = pending.map { $0.union(window) } ?? window
        try persistence.save(widened)
        pending = widened
        if importInFlight {
            followUp = followUp.map { $0.union(window) } ?? window
        }
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
            importInFlight = false
            followUp = nil
            workerTask = nil
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
        }

        while pending != nil {
            // Release after each committed batch so continuous observers cannot starve scoring.
            let committed: Bool
            do {
                committed = try await scoringCoordinator.withImportLease { () async -> Bool in
                    // Offers can arrive while this worker waits for scoring to release the lease.
                    guard let snapshot = pending else { return true }
                    followUp = nil
                    importInFlight = true
                    do {
                        // Journal the scoring dependency BEFORE any import/write-back awaits. If local rows commit
                        // and a later outbound HealthKit write fails—or the process is suspended—the score request
                        // already survives. Scoring itself cannot begin until this import lease is released.
                        try await scoringCoordinator.offer(snapshot)
                    } catch {
                        return false
                    }

                    guard await operation(snapshot) else {
                        // Import work remains pending for retry, while the durable scoring journal may safely
                        // reconcile either unchanged rows or a partially committed transaction.
                        return false
                    }

                    // The snapshot committed. Keep only wakes received during that import; replaying the
                    // full durable union can restart a decade of history on every live observer wake.
                    // Until this save succeeds the original union remains durable for crash recovery.
                    do {
                        try persistence.save(followUp)
                        pending = followUp
                        importInFlight = false
                    } catch {
                        // Clearing failure is conservative: repeat the idempotent import on the next wake. The
                        // scoring dependency is already durable and will run after this lease is released.
                        return false
                    }
                    return true
                }
            } catch {
                // Cancelled while waiting for the lease or the Repository fence. The import journal is still
                // durable, so the next observer wake, foreground or BG task replays it.
                return
            }
            guard committed else {
                // The import journal is still durable, but an observer acknowledgement or app launch is
                // not guaranteed after a locked-device HealthKit failure. Arm the shared recovery task so
                // iOS can retry the exact same window after protected health data becomes available.
                scheduleRetry()
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
