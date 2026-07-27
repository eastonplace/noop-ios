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

/// Serial, completion-aware coordinator for the heavy intelligence pipeline.
///
/// - A non-forced cadence tick is disposable while another pass runs.
/// - A forced source-change request suspends until its own exact request, or a compatible superset, completes.
/// - Pending recent-day work is selected before deeper historical chunks, creating a current-day fast lane.
/// - Overlapping compatible pending windows coalesce; disjoint or differently-published work stays separate.
///
/// The coordinator is MainActor-isolated because the engine itself is MainActor-isolated. Its execute closure
/// is supplied by `IntelligenceEngine+AnalysisAdmission.swift`, which is the only place allowed to invoke the
/// raw four-argument implementation.
@MainActor
final class IntelligenceAnalysisCoordinator {
    typealias Execute = @MainActor (IntelligenceAnalysisRequest) async -> Void

    private struct PendingBatch {
        var request: IntelligenceAnalysisRequest
        var waiters: [CheckedContinuation<Void, Never>]
    }

    private(set) var isRunning = false
    private(set) var completedPasses = 0
    private var pending: [PendingBatch] = []

    var pendingBatchCount: Int { pending.count }
    var waitingForcedCallers: Int { pending.reduce(0) { $0 + $1.waiters.count } }

    func submit(_ request: IntelligenceAnalysisRequest, execute: @escaping Execute) async {
        if isRunning {
            guard request.force else { return }
            await withCheckedContinuation { continuation in
                enqueue(request, waiter: continuation)
            }
            return
        }

        isRunning = true
        var current = request
        var waitersAfterCurrent: [CheckedContinuation<Void, Never>] = []
        defer {
            waitersAfterCurrent.forEach { $0.resume() }
            isRunning = false
        }

        while true {
            await execute(current)
            completedPasses += 1
            waitersAfterCurrent.forEach { $0.resume() }
            waitersAfterCurrent.removeAll(keepingCapacity: true)

            guard let index = nextBatchIndex() else { return }
            let batch = pending.remove(at: index)
            current = batch.request
            waitersAfterCurrent = batch.waiters
        }
    }

    private func enqueue(
        _ request: IntelligenceAnalysisRequest,
        waiter: CheckedContinuation<Void, Never>
    ) {
        pending.append(PendingBatch(request: request, waiters: [waiter]))
        normalizePendingBatches()
    }

    /// Coalesce transitively: a newly-arrived bridge can join two previously-disjoint overlapping batches.
    private func normalizePendingBatches() {
        var changed = true
        while changed {
            changed = false
            outer: for lhs in pending.indices {
                for rhs in pending.indices where rhs > lhs {
                    guard pending[lhs].request.canCoalesce(with: pending[rhs].request) else { continue }
                    pending[lhs].request = pending[lhs].request.coalesced(with: pending[rhs].request)
                    pending[lhs].waiters.append(contentsOf: pending[rhs].waiters)
                    pending.remove(at: rhs)
                    changed = true
                    break outer
                }
            }
        }
    }

    /// Lowest offset first. A post-sync current-day request (`startOffset == 0`) therefore runs before the
    /// next queued 30-day migration chunk instead of waiting for the entire historical migration to finish.
    private func nextBatchIndex() -> Int? {
        pending.indices.min { lhs, rhs in
            let a = pending[lhs].request
            let b = pending[rhs].request
            if a.startOffset != b.startOffset { return a.startOffset < b.startOffset }
            if a.refreshRepository != b.refreshRepository { return !a.refreshRepository }
            return a.maxDays < b.maxDays
        }
    }
}
