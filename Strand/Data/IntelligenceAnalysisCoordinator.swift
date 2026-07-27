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

    init(maxDays: Int, startOffset: Int, force: Bool, refreshRepository: Bool) {
        let boundedStart = min(max(0, startOffset), Self.maximumWindowDays - 1)
        let remaining = max(1, Self.maximumWindowDays - boundedStart)
        self.startOffset = boundedStart
        self.maxDays = min(max(1, maxDays), remaining)
        self.force = force
        self.refreshRepository = refreshRepository
    }

    var endOffsetExclusive: Int { startOffset + maxDays }

    /// Merge only requests with identical publication semantics whose day ranges overlap or touch. Keeping a
    /// recent `refreshRepository:false` post-backfill request separate from a deep migration prevents an
    /// unrelated historical refresh from publishing before today's exact pass has completed.
    func canCoalesce(with other: Self) -> Bool {
        refreshRepository == other.refreshRepository
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
            refreshRepository: refreshRepository)
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

/// Serial, completion-aware coordinator for the heavy intelligence pipeline.
///
/// - A non-forced cadence tick is disposable while another pass runs.
/// - A forced source-change request suspends until its own exact request, or a compatible superset, completes.
/// - Pending recent-day work is selected before deeper historical chunks, creating a current-day fast lane.
/// - Overlapping compatible pending windows coalesce; disjoint or differently-published work stays separate.
///
/// One shared coordinator partitions queues by engine identity. MainActor isolation makes both queue mutation
/// and the engine callback race-free.
@MainActor
final class IntelligenceAnalysisCoordinator {
    static let shared = IntelligenceAnalysisCoordinator()

    typealias Execute = @MainActor (IntelligenceAnalysisRequest) async -> Void

    private struct PendingBatch {
        var request: IntelligenceAnalysisRequest
        var waiters: [CheckedContinuation<Void, Never>]
    }

    private struct QueueState {
        var pending: [PendingBatch] = []
    }

    private var queues: [ObjectIdentifier: QueueState] = [:]

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

    func submit(
        owner: AnyObject,
        request: IntelligenceAnalysisRequest,
        run: @escaping Execute
    ) async {
        let key = ObjectIdentifier(owner)

        if queues[key] != nil {
            guard request.force else { return }
            await withCheckedContinuation { continuation in
                var state = queues[key] ?? QueueState()
                state.pending.append(PendingBatch(request: request, waiters: [continuation]))
                normalizePendingBatches(&state.pending)
                queues[key] = state
            }
            return
        }

        queues[key] = QueueState()
        var current = request
        var completionWaiters: [CheckedContinuation<Void, Never>] = []

        while true {
            await run(current)
            completionWaiters.forEach { $0.resume() }
            completionWaiters.removeAll(keepingCapacity: true)

            guard var state = queues[key] else { return }
            guard let index = nextBatchIndex(in: state.pending) else {
                queues.removeValue(forKey: key)
                return
            }

            let batch = state.pending.remove(at: index)
            queues[key] = state
            current = batch.request
            completionWaiters = batch.waiters
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
            if a.refreshRepository != b.refreshRepository { return !a.refreshRepository }
            return a.maxDays < b.maxDays
        }
    }
}

// MARK: - Production admission surface

@MainActor
extension IntelligenceEngine {
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
    private func submitSerializedAnalysis(
        maxDays: Int,
        startOffset: Int,
        force: Bool,
        refreshRepository: Bool
    ) async {
        let request = IntelligenceAnalysisRequest(
            maxDays: maxDays,
            startOffset: startOffset,
            force: force,
            refreshRepository: refreshRepository)

        await IntelligenceAnalysisCoordinator.shared.submit(owner: self, request: request) { [weak self] queued in
            guard let self else { return }

            // Normal production calls are serialized here. A direct legacy/full-signature call or an old
            // in-engine re-arm task may nevertheless already own `computing`; forced work waits instead of
            // disappearing, while a disposable cadence tick still drops. Once forced work is queued it ignores
            // caller-task cancellation—the durable source change still needs to be scored and published.
            while self.computing {
                guard queued.force else { return }
                await Self.waitForAnalysisPoll()
            }
            guard queued.force || !Task.isCancelled else { return }

            await self.analyzeRecent(
                maxDays: queued.maxDays,
                startOffset: queued.startOffset,
                force: queued.force,
                refreshRepository: queued.refreshRepository)
        }
    }

    /// AppModel's post-backfill path intentionally asks analysis not to publish Repository itself; it performs
    /// one explicit cache publication immediately after this call. Hold the call until one exact current-day
    /// pass begins and ends with the same quiescent durable-data generation. If a reconnect or periodic burst
    /// advances data during analysis, rerun before returning. Forced source work survives caller cancellation.
    private func submitStablePostBackfillAnalysis() async {
        guard let live = AppModel.shared?.live else {
            await submitSerializedAnalysis(
                maxDays: 21, startOffset: 0, force: true, refreshRepository: false)
            return
        }

        while true {
            let before = BackfillAnalysisSnapshot(
                dataAvailableAt: live.backfillDataAvailableAt,
                backfilling: live.backfilling)
            if before.backfilling {
                await Self.waitForAnalysisPoll()
                continue
            }

            await submitSerializedAnalysis(
                maxDays: 21, startOffset: 0, force: true, refreshRepository: false)

            let after = BackfillAnalysisSnapshot(
                dataAvailableAt: live.backfillDataAvailableAt,
                backfilling: live.backfilling)
            if after.isSettledAndUnchanged(since: before) { return }
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

    func analyzeRecent(refreshRepository: Bool) async {
        if refreshRepository {
            await submitSerializedAnalysis(
                maxDays: 21, startOffset: 0, force: true, refreshRepository: true)
        } else {
            await submitStablePostBackfillAnalysis()
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

    func analyzeRecent(maxDays: Int, startOffset: Int, refreshRepository: Bool) async {
        await submitSerializedAnalysis(maxDays: maxDays, startOffset: startOffset, force: true,
                                       refreshRepository: refreshRepository)
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
