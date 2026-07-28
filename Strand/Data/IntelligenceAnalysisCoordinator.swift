import Foundation

/// One bounded request for `IntelligenceEngine.analyzeRecent`.
///
/// The old Boolean re-arm remembered only that “something” arrived while analysis was busy. It lost the
/// caller's exact day window and repository-publication policy, which let a deep historical migration stand in
/// for the current-day post-backfill pass. This value is the complete admission contract.
struct IntelligenceAnalysisRequest: Equatable, Sendable {
    static let maximumWindowDays = 10_000

    let maxDays: Int
    let startOffset: Int
    let force: Bool
    let refreshRepository: Bool
    /// Publication-sensitive source pipelines may require a durable postcondition before their caller is
    /// released. Keep that semantic in the request identity so such work can never coalesce into an otherwise
    /// identical best-effort batch and silently lose its verifier closure.
    let requiresDurableRecoveryReceipt: Bool

    init(
        maxDays: Int,
        startOffset: Int,
        force: Bool,
        refreshRepository: Bool,
        requiresDurableRecoveryReceipt: Bool = false
    ) {
        let boundedStart = min(max(0, startOffset), Self.maximumWindowDays - 1)
        let remaining = max(1, Self.maximumWindowDays - boundedStart)
        self.startOffset = boundedStart
        self.maxDays = min(max(1, maxDays), remaining)
        self.force = force
        self.refreshRepository = refreshRepository
        self.requiresDurableRecoveryReceipt = requiresDurableRecoveryReceipt
    }

    var endOffsetExclusive: Int { startOffset + maxDays }

    /// Merge only requests with identical publication semantics whose day ranges overlap or touch. Keeping a
    /// recent `refreshRepository:false` post-backfill request separate from a deep migration prevents an
    /// unrelated historical refresh from publishing before today's exact pass has completed. Durable-receipt
    /// work also stays separate from a best-effort batch so its postcondition cannot be dropped by coalescing.
    func canCoalesce(with other: Self) -> Bool {
        refreshRepository == other.refreshRepository
            && requiresDurableRecoveryReceipt == other.requiresDurableRecoveryReceipt
            && startOffset <= other.endOffsetExclusive
            && other.startOffset <= endOffsetExclusive
    }

    func coalesced(with other: Self) -> Self {
        precondition(canCoalesce(with: other), "incompatible analysis requests cannot coalesce")
        let lower = min(startOffset, other.startOffset)
        let upper = max(endOffsetExclusive, other.endOffsetExclusive)
        return Self(
            maxDays: upper - lower,
            startOffset: lower,
            force: force || other.force,
            refreshRepository: refreshRepository,
            requiresDurableRecoveryReceipt: requiresDurableRecoveryReceipt)
    }
}

/// Immutable observation around one post-backfill analysis pass. The caller may publish only when the store
/// is still quiescent and the durable-data edge is unchanged after analysis. A reconnect or periodic burst
/// that starts or completes in the middle therefore forces another pass over the newest data instead of
/// allowing an older generation to publish a final-looking blank Recovery state.
struct BackfillAnalysisSnapshot: Equatable, Sendable {
    let dataAvailableAt: TimeInterval?
    let backfilling: Bool

    func isSettledAndUnchanged(since earlier: Self) -> Bool {
        !backfilling && !earlier.backfilling && dataAvailableAt == earlier.dataAvailableAt
    }
}

enum IntelligenceAnalysisCoordinatorError: Error {
    case ownerReleased
    case deferred
    case analysisDidNotComplete
}

/// Serial, completion-aware coordinator for the heavy intelligence pipeline.
///
/// - A non-forced cadence tick is disposable while another pass runs.
/// - A forced source-change request suspends until its own exact request, or a compatible superset, completes.
/// - A retryable forced failure remains queued; transient store protection/open failures cannot advance a
///   timestamp-heal flag or publish an older Home generation as though the requested analysis completed.
/// - Pending recent-day work is selected before deeper historical chunks, creating a current-day fast lane.
/// - Overlapping compatible pending windows coalesce; disjoint or differently-published work stays separate.
/// - Every caller returns when ITS batch completes; the caller that happened to start the runner never waits
///   for unrelated batches queued behind it.
///
/// One shared coordinator partitions queues by engine identity. MainActor isolation makes both queue mutation
/// and the engine callback race-free.
@MainActor
final class IntelligenceAnalysisCoordinator {
    static let shared = IntelligenceAnalysisCoordinator()

    /// A runner must explicitly finish its requested analysis. Returning normally
    /// means that the batch completed; throwing means its callers must *not*
    /// publish the derived Home/Widget generation as though a rescore succeeded.
    typealias Execute = @MainActor (IntelligenceAnalysisRequest) async throws -> Void

    private struct PendingBatch {
        var request: IntelligenceAnalysisRequest
        var waiters: [CheckedContinuation<Bool, Never>]
        let run: Execute
    }

    private struct QueueState {
        var pending: [PendingBatch] = []
    }

    private var queues: [ObjectIdentifier: QueueState] = [:]
    private let retryDelay: TimeInterval

    init(retryDelay: TimeInterval = 1.0) {
        self.retryDelay = max(0, retryDelay)
    }

    /// Test/diagnostic visibility only. These are pure queue counts and do not publish UI state.
    func isRunning(for owner: AnyObject) -> Bool {
        queues[ObjectIdentifier(owner)] != nil
    }

    func pendingBatchCount(for owner: AnyObject) -> Int {
        queues[ObjectIdentifier(owner)]?.pending.count ?? 0
    }

    func waitingForcedCallerCount(for owner: AnyObject) -> Int {
        queues[ObjectIdentifier(owner)]?.pending.reduce(0) { $0 + $1.waiters.count } ?? 0
    }

    @discardableResult
    func submit(
        owner: AnyObject,
        request: IntelligenceAnalysisRequest,
        run: @escaping Execute
    ) async -> Bool {
        let key = ObjectIdentifier(owner)
        if queues[key] != nil, !request.force { return false }

        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let shouldStartRunner = queues[key] == nil
            var state = queues[key] ?? QueueState()
            state.pending.append(PendingBatch(
                request: request,
                waiters: [continuation],
                run: run))
            normalizePendingBatches(&state.pending)
            queues[key] = state

            if shouldStartRunner {
                // The runner retains the coordinator until every queued batch has either executed or been
                // coalesced. Individual submitters remain suspended only on their own batch continuation.
                Task { @MainActor in
                    await self.drain(ownerKey: key)
                }
            }
        }
    }

    private func drain(ownerKey key: ObjectIdentifier) async {
        while true {
            guard var state = queues[key],
                  let index = nextBatchIndex(in: state.pending) else {
                queues.removeValue(forKey: key)
                return
            }

            let batch = state.pending.remove(at: index)
            queues[key] = state // existence continues to mark this owner as actively running
            let completed: Bool
            do {
                try await batch.run(batch.request)
                completed = true
            } catch IntelligenceAnalysisCoordinatorError.analysisDidNotComplete where batch.request.force {
                // The source-change request is durable. Re-read the live queue before appending it: other
                // callers may have arrived while `run` was suspended, and restoring the pre-run local state
                // would silently erase those requests. Compatible work can coalesce with this retry and every
                // original waiter stays attached until one real analysis pass completes.
                var latest = queues[key] ?? QueueState()
                latest.pending.append(batch)
                normalizePendingBatches(&latest.pending)
                queues[key] = latest
                await waitBeforeRetry()
                continue
            } catch {
                completed = false
            }
            batch.waiters.forEach { $0.resume(returning: completed) }
        }
    }

    private func waitBeforeRetry() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) {
                continuation.resume()
            }
        }
    }

    /// Coalesce transitively: a new bridge request can join two previously-disjoint overlapping batches.
    private func normalizePendingBatches(_ batches: inout [PendingBatch]) {
        var changed = true
        while changed {
            changed = false
            outer: for lhs in batches.indices {
                for rhs in batches.indices where rhs > lhs {
                    guard batches[lhs].request.canCoalesce(with: batches[rhs].request) else { continue }
                    batches[lhs].request = batches[lhs].request.coalesced(with: batches[rhs].request)
                    batches[lhs].waiters.append(contentsOf: batches[rhs].waiters)
                    batches.remove(at: rhs)
                    changed = true
                    break outer
                }
            }
        }
    }

    /// Lowest offset first. A post-sync current-day request (`startOffset == 0`) therefore runs before the
    /// next queued 30-day migration chunk instead of waiting for the entire historical migration to finish.
    private func nextBatchIndex(in batches: [PendingBatch]) -> Int? {
        batches.indices.min { lhs, rhs in
            let a = batches[lhs].request
            let b = batches[rhs].request
            if a.startOffset != b.startOffset { return a.startOffset < b.startOffset }
            if a.requiresDurableRecoveryReceipt != b.requiresDurableRecoveryReceipt {
                return a.requiresDurableRecoveryReceipt
            }
            if a.refreshRepository != b.refreshRepository { return !a.refreshRepository }
            return a.maxDays < b.maxDays
        }
    }
}

// MARK: - Production admission surface

@MainActor
extension IntelligenceEngine {
    typealias DurableRecoveryPostcondition = @MainActor ([Computed]) async -> Bool

    /// A queued forced request represents durable source change and must survive cancellation of the UI task
    /// that happened to request it. DispatchQueue's deadline is cancellation-insensitive, unlike Task.sleep;
    /// use it while waiting for the legacy in-engine lock or an active historical writer to clear.
    private static func waitForAnalysisPoll() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(20)) {
                continuation.resume()
            }
        }
    }

    /// The only route from shorthand production calls into the existing full implementation. Supplying all
    /// four labels below deliberately resolves to the class's original method, not to any overload here.
    /// A durable postcondition executes inside the admitted batch, after the engine updates `results` but before
    /// any waiter resumes or the next queued analysis can replace that snapshot.
    @discardableResult
    private func submitSerializedAnalysis(
        maxDays: Int,
        startOffset: Int,
        force: Bool,
        refreshRepository: Bool,
        durableRecoveryPostcondition: DurableRecoveryPostcondition? = nil
    ) async -> Bool {
        let request = IntelligenceAnalysisRequest(
            maxDays: maxDays,
            startOffset: startOffset,
            force: force,
            refreshRepository: refreshRepository,
            requiresDurableRecoveryReceipt: durableRecoveryPostcondition != nil)

        return await IntelligenceAnalysisCoordinator.shared.submit(owner: self, request: request) { [weak self] queued in
            guard let self else { throw IntelligenceAnalysisCoordinatorError.ownerReleased }

            // Normal production calls are serialized here. A direct legacy/full-signature call or an old
            // in-engine re-arm task may nevertheless already own `computing`; forced work waits instead of
            // disappearing, while a disposable cadence tick still drops. Once forced work is queued it ignores
            // caller-task cancellation—the durable source change still needs to be scored and published.
            while self.computing {
                guard queued.force else { throw IntelligenceAnalysisCoordinatorError.deferred }
                await Self.waitForAnalysisPoll()
            }
            guard queued.force || !Task.isCancelled else { throw IntelligenceAnalysisCoordinatorError.deferred }

            guard await self.analyzeRecent(
                maxDays: queued.maxDays,
                startOffset: queued.startOffset,
                force: queued.force,
                refreshRepository: queued.refreshRepository)
            else { throw IntelligenceAnalysisCoordinatorError.analysisDidNotComplete }

            if let durableRecoveryPostcondition,
               !(await durableRecoveryPostcondition(self.results)) {
                throw IntelligenceAnalysisCoordinatorError.analysisDidNotComplete
            }
        }
    }

    /// AppModel's post-backfill path intentionally asks analysis not to publish Repository itself; it performs
    /// one explicit cache publication immediately after this call. Hold the call until one exact current-day
    /// pass begins and ends with the same quiescent durable-data generation. If a reconnect or periodic burst
    /// advances data during analysis, rerun before returning. Forced source work survives caller cancellation.
    private func submitStablePostBackfillAnalysis() async -> Bool {
        guard let live = AppModel.shared?.live else {
            return await submitSerializedAnalysis(
                maxDays: 21, startOffset: 0, force: true, refreshRepository: false)
        }

        while true {
            let before = BackfillAnalysisSnapshot(
                dataAvailableAt: live.backfillDataAvailableAt,
                backfilling: live.backfilling)
            if before.backfilling {
                await Self.waitForAnalysisPoll()
                continue
            }

            guard await submitSerializedAnalysis(
                maxDays: 21, startOffset: 0, force: true, refreshRepository: false)
            else { return false }

            let after = BackfillAnalysisSnapshot(
                dataAvailableAt: live.backfillDataAvailableAt,
                backfilling: live.backfilling)
            if after.isSettledAndUnchanged(since: before) { return true }
        }
    }

    // Define every proper subset of the original four labels. Swift prefers these exact signatures over the
    // original method's default arguments, so every production shorthand call is serialized. The fully-spelled
    // four-label call remains the private bypass used only by `submitSerializedAnalysis` above.
    func analyzeRecent() async {
        await submitSerializedAnalysis(maxDays: 21, startOffset: 0, force: true, refreshRepository: true)
    }

    func analyzeRecent(maxDays: Int) async {
        await submitSerializedAnalysis(maxDays: maxDays, startOffset: 0, force: true, refreshRepository: true)
    }

    func analyzeRecent(startOffset: Int) async {
        await submitSerializedAnalysis(maxDays: 21, startOffset: startOffset, force: true, refreshRepository: true)
    }

    func analyzeRecent(force: Bool) async {
        await submitSerializedAnalysis(maxDays: 21, startOffset: 0, force: force, refreshRepository: true)
    }

    @discardableResult
    func analyzeRecent(refreshRepository: Bool) async -> Bool {
        if refreshRepository {
            return await submitSerializedAnalysis(
                maxDays: 21, startOffset: 0, force: true, refreshRepository: true)
        } else {
            return await submitStablePostBackfillAnalysis()
        }
    }

    func analyzeRecent(maxDays: Int, startOffset: Int) async {
        await submitSerializedAnalysis(maxDays: maxDays, startOffset: startOffset, force: true,
                                       refreshRepository: true)
    }

    func analyzeRecent(maxDays: Int, force: Bool) async {
        await submitSerializedAnalysis(maxDays: maxDays, startOffset: 0, force: force,
                                       refreshRepository: true)
    }

    func analyzeRecent(maxDays: Int, refreshRepository: Bool) async {
        await submitSerializedAnalysis(maxDays: maxDays, startOffset: 0, force: true,
                                       refreshRepository: refreshRepository)
    }

    func analyzeRecent(startOffset: Int, force: Bool) async {
        await submitSerializedAnalysis(maxDays: 21, startOffset: startOffset, force: force,
                                       refreshRepository: true)
    }

    func analyzeRecent(startOffset: Int, refreshRepository: Bool) async {
        await submitSerializedAnalysis(maxDays: 21, startOffset: startOffset, force: true,
                                       refreshRepository: refreshRepository)
    }

    func analyzeRecent(force: Bool, refreshRepository: Bool) async {
        await submitSerializedAnalysis(maxDays: 21, startOffset: 0, force: force,
                                       refreshRepository: refreshRepository)
    }

    func analyzeRecent(maxDays: Int, startOffset: Int, force: Bool) async {
        await submitSerializedAnalysis(maxDays: maxDays, startOffset: startOffset, force: force,
                                       refreshRepository: true)
    }

    /// Publication-sensitive callers need the real coordinator result. Returning `Void` here let call sites
    /// compile only when they ignored success, and made HealthKit's fail-closed publication closure impossible
    /// to type-check. Keep the exact requested window and expose whether its admitted batch actually completed.
    @discardableResult
    func analyzeRecent(maxDays: Int, startOffset: Int, refreshRepository: Bool) async -> Bool {
        await submitSerializedAnalysis(maxDays: maxDays, startOffset: startOffset, force: true,
                                       refreshRepository: refreshRepository)
    }

    /// Stronger publication contract for a durable source handoff. The verifier runs against the exact results
    /// produced by this admitted batch before any queued analysis can replace them. A false receipt is treated
    /// as a retryable forced failure, so the source journal and Repository publication fence remain intact.
    @discardableResult
    func analyzeRecentForPublication(
        maxDays: Int,
        startOffset: Int,
        refreshRepository: Bool,
        verifyDurableRecovery: @escaping DurableRecoveryPostcondition
    ) async -> Bool {
        await submitSerializedAnalysis(
            maxDays: maxDays,
            startOffset: startOffset,
            force: true,
            refreshRepository: refreshRepository,
            durableRecoveryPostcondition: verifyDurableRecovery)
    }

    func analyzeRecent(maxDays: Int, force: Bool, refreshRepository: Bool) async {
        await submitSerializedAnalysis(maxDays: maxDays, startOffset: 0, force: force,
                                       refreshRepository: refreshRepository)
    }

    func analyzeRecent(startOffset: Int, force: Bool, refreshRepository: Bool) async {
        await submitSerializedAnalysis(maxDays: 21, startOffset: startOffset, force: force,
                                       refreshRepository: refreshRepository)
    }
}
