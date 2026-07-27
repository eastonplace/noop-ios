import Foundation

/// One serialized request for `IntelligenceEngine.analyzeRecent`.
///
/// Forced update paths may arrive while a long history pass is already running. The request retains the
/// caller's exact day window and publication policy so concurrent work can be merged without silently
/// substituting the in-flight pass's unrelated window. The 10,000-day ceiling is above every production
/// caller (the full-history migration is 4,000 days) and keeps hostile/overflowing inputs bounded.
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

    /// Union two queued windows and preserve the strongest requested semantics. A batch therefore runs once
    /// over every requested day; a current-day post-backfill request can never be replaced by the historical
    /// migration window that happened to be active when it arrived.
    func merged(with other: Self) -> Self {
        let lower = min(startOffset, other.startOffset)
        let upper = max(endOffsetExclusive, other.endOffsetExclusive)
        return Self(
            maxDays: upper - lower,
            startOffset: lower,
            force: force || other.force,
            refreshRepository: refreshRepository || other.refreshRepository)
    }
}

/// Main-actor admission queue shared by every production shorthand overload below.
///
/// `IntelligenceEngine` already has one full four-argument implementation. Historically its internal Boolean
/// re-arm dropped the incoming request's window and returned to the caller before the replacement pass ran.
/// This coordinator sits in front of that implementation: one request runs, forced arrivals merge into one
/// pending batch and suspend, and those callers resume only after their batch actually completes. Non-forced
/// cadence ticks remain expendable while real update work is running.
@MainActor
final class IntelligenceAnalysisCoordinator {
    static let shared = IntelligenceAnalysisCoordinator()

    private struct QueueState {
        var pending: IntelligenceAnalysisRequest?
        var pendingWaiters: [CheckedContinuation<Void, Never>] = []
    }

    private var queues: [ObjectIdentifier: QueueState] = [:]

    func submit(
        owner: AnyObject,
        request: IntelligenceAnalysisRequest,
        run: @escaping @MainActor (IntelligenceAnalysisRequest) async -> Void
    ) async {
        let key = ObjectIdentifier(owner)

        if queues[key] != nil {
            guard request.force else { return }
            await withCheckedContinuation { continuation in
                var state = queues[key] ?? QueueState()
                state.pending = state.pending.map { $0.merged(with: request) } ?? request
                state.pendingWaiters.append(continuation)
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

            guard var state = queues[key] else { return }
            guard let next = state.pending else {
                queues.removeValue(forKey: key)
                return
            }

            current = next
            completionWaiters = state.pendingWaiters
            state.pending = nil
            state.pendingWaiters.removeAll(keepingCapacity: true)
            queues[key] = state
        }
    }
}

// MARK: - Production admission surface

@MainActor
extension IntelligenceEngine {
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
            await self.analyzeRecent(
                maxDays: queued.maxDays,
                startOffset: queued.startOffset,
                force: queued.force,
                refreshRepository: queued.refreshRepository)
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
        await submitSerializedAnalysis(maxDays: 21, startOffset: 0, force: true,
                                       refreshRepository: refreshRepository)
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
