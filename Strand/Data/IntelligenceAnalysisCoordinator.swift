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
    /// Exact historical work pins both its reference instant and its Gregorian time zone. It cannot merge
    /// with a similarly shaped live request because equal offsets can denote different civil days.
    let committedAnalysisExecutionContext: CommittedAnalysisExecutionContext?
    /// Publication-sensitive source pipelines may require a durable postcondition before their caller is
    /// released. Keep that semantic in the request identity so such work can never coalesce into an otherwise
    /// identical best-effort batch and silently lose its verifier closure.
    let requiresDurableRecoveryReceipt: Bool

    init(
        maxDays: Int,
        startOffset: Int,
        force: Bool,
        refreshRepository: Bool,
        requiresDurableRecoveryReceipt: Bool = false,
        committedAnalysisExecutionContext: CommittedAnalysisExecutionContext? = nil
    ) {
        let boundedStart = min(max(0, startOffset), Self.maximumWindowDays - 1)
        let remaining = max(1, Self.maximumWindowDays - boundedStart)
        self.startOffset = boundedStart
        self.maxDays = min(max(1, maxDays), remaining)
        self.force = force
        self.refreshRepository = refreshRepository
        self.requiresDurableRecoveryReceipt = requiresDurableRecoveryReceipt
        self.committedAnalysisExecutionContext = committedAnalysisExecutionContext
    }

    var endOffsetExclusive: Int { startOffset + maxDays }

    /// Merge only requests with identical publication semantics whose day ranges overlap or touch. Keeping a
    /// recent `refreshRepository:false` post-backfill request separate from a deep migration prevents an
    /// unrelated historical refresh from publishing before today's exact pass has completed. Durable-receipt
    /// work also stays separate from a best-effort batch so its postcondition cannot be dropped by coalescing.
    func canCoalesce(with other: Self) -> Bool {
        refreshRepository == other.refreshRepository
            && requiresDurableRecoveryReceipt == other.requiresDurableRecoveryReceipt
            && committedAnalysisExecutionContext == other.committedAnalysisExecutionContext
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
            requiresDurableRecoveryReceipt: requiresDurableRecoveryReceipt,
            committedAnalysisExecutionContext: committedAnalysisExecutionContext)
    }
}

extension IntelligenceAnalysisRequest {
    /// DL-03: the forward dependency closure of edited days. An edit to an older night changes that day and
    /// every later baseline, carry and sleep-debt value, so the window runs from the earliest edited day
    /// through today. Future timestamps clamp to today. Nil when nothing was edited.
    static func editedDays(
        containingTimestamps timestamps: some Collection<Int>,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Self? {
        guard let earliest = timestamps.min() else { return nil }
        let today = calendar.startOfDay(for: now)
        let editedDay = min(calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(earliest))), today)
        let span = (calendar.dateComponents([.day], from: editedDay, to: today).day ?? 0) + 1
        return Self(maxDays: max(1, span), startOffset: 0, force: true, refreshRepository: true)
    }

    /// One drain step over `editedDays`: its oldest `chunkDays` days at most, plus a timestamp inside the first
    /// day after the chunk when the range continues (nil once the chunk reaches today). Oldest first, because
    /// each pass reads the baselines, carry and sleep debt the previous one wrote. Nil when nothing was edited.
    static func editedDayChunk(
        containingTimestamps timestamps: some Collection<Int>,
        chunkDays: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (request: Self, remainderTimestamp: Int?)? {
        guard let range = editedDays(containingTimestamps: timestamps, now: now, calendar: calendar) else {
            return nil
        }
        let chunk = max(1, chunkDays)
        guard range.maxDays > chunk else { return (range, nil) }
        let uncoveredOffset = range.maxDays - chunk - 1
        guard let firstUncovered = calendar.date(byAdding: .day, value: -uncoveredOffset,
                                                 to: calendar.startOfDay(for: now)),
              let midday = calendar.date(byAdding: .hour, value: 12, to: firstUncovered) else {
            return (range, nil)
        }
        let request = Self(maxDays: chunk, startOffset: range.maxDays - chunk, force: true,
                           refreshRepository: range.refreshRepository)
        return (request, Int(midday.timeIntervalSince1970))
    }
}

/// DL-03: timestamps of sleeps and workouts the user edited, waiting for a rescore from their day through
/// today. The edit flows only ask for the one-day `analyzeRecent()`, so editing any night but last night never
/// rescored that day. Repository's mutators enqueue here. `analyzeRecent()` runs its usual one-day pass, so the
/// editor returns once that is saved, and then starts a background drain of this queue.
///
/// The drain rescores the oldest chunk first, at most `chunkDays` per pass, so each pass reads the carry the
/// previous one wrote and a long range never runs as one uncancellable forced batch. It stops between chunks
/// when cancelled (BG expiry) or once the app is in the background. A chunk that doesn't complete leaves the
/// whole taken range queued, and edits that arrive mid-chunk stay queued for the next step.
@MainActor
final class EditedDayRescoreQueue {
    static let shared = EditedDayRescoreQueue()
    static let chunkDays = 30

    typealias Analyze = @MainActor (IntelligenceAnalysisRequest) async -> Bool

    private(set) var timestamps: Set<Int> = []
    private let now: @MainActor () -> Date
    private let calendar: @MainActor () -> Calendar
    private let isBackgrounded: @MainActor () -> Bool
    private weak var analyzer: AnyObject?
    private var analyze: Analyze?
    private var drainTask: Task<Void, Never>?
    private var lastDrain: Task<Void, Never>?
    private var drainGeneration: UInt64 = 0

    init(now: @escaping @MainActor () -> Date = { Date() },
         calendar: @escaping @MainActor () -> Calendar = { .current },
         isBackgrounded: @escaping @MainActor () -> Bool = { RescoreBackgroundPolicy.isBackgrounded }) {
        self.now = now
        self.calendar = calendar
        self.isBackgrounded = isBackgrounded
    }

    var isDraining: Bool { drainTask != nil }

    func enqueue(_ edited: [Int]) {
        timestamps.formUnion(edited.filter { $0 > 0 })
    }

    /// Removes and returns everything queued and stops any drain. Tests reset the shared queue with it.
    func take() -> Set<Int> {
        cancel()
        defer { timestamps.removeAll() }
        return timestamps
    }

    /// The engine that rescores drained chunks, held weakly through `owner`.
    func register(_ owner: AnyObject, analyze: @escaping Analyze) {
        guard analyzer !== owner || self.analyze == nil else { return }
        analyzer = owner
        self.analyze = analyze
    }

    /// Starts a drain after `delay` unless one is already pending or running.
    func scheduleDrain(after delay: Duration = .zero) {
        guard drainTask == nil, !timestamps.isEmpty, analyze != nil else { return }
        drainGeneration &+= 1
        let generation = drainGeneration
        drainTask = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard let self else { return }
            await self.drain(generation: generation)
            if self.drainGeneration == generation { self.drainTask = nil }
        }
        lastDrain = drainTask
    }

    /// Stops the drain at its next chunk boundary. The unfinished range stays queued.
    func cancel() {
        drainGeneration &+= 1
        drainTask?.cancel()
        drainTask = nil
    }

    /// Test/diagnostic: waits for the most recent drain to stop, including one that was just cancelled.
    func waitForDrain() async {
        await lastDrain?.value
    }

    private func drain(generation: UInt64) async {
        while generation == drainGeneration, !timestamps.isEmpty, let analyze, analyzer != nil {
            if Task.isCancelled || isBackgrounded() { return }
            let taken = timestamps
            guard let chunk = IntelligenceAnalysisRequest.editedDayChunk(
                containingTimestamps: taken, chunkDays: Self.chunkDays, now: now(), calendar: calendar()) else {
                timestamps.subtract(taken)
                continue
            }
            guard await analyze(chunk.request) else { return }
            timestamps.subtract(taken)
            if let next = chunk.remainderTimestamp { timestamps.insert(next) }
        }
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
        var retryCount: Int
        let run: Execute
    }

    private struct QueueState {
        var pending: [PendingBatch] = []
    }

    private var queues: [ObjectIdentifier: QueueState] = [:]
    /// The unstructured runner per owner. Callers' cancellation never reaches it, by design, so background
    /// expiry cancels it through `cancelRunningWork()`.
    private var runners: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let retryDelay: TimeInterval
    private let maximumRetryCount: Int

    init(retryDelay: TimeInterval = 1.0, maximumRetryCount: Int = 2) {
        self.retryDelay = max(0, retryDelay)
        self.maximumRetryCount = max(0, maximumRetryCount)
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
                retryCount: 0,
                run: run))
            normalizePendingBatches(&state.pending)
            queues[key] = state

            if shouldStartRunner {
                // The runner retains the coordinator until every queued batch has either executed or been
                // coalesced. Individual submitters remain suspended only on their own batch continuation.
                runners[key] = Task { @MainActor in
                    await self.drain(ownerKey: key)
                }
            }
        }
    }

    /// CC-2 / CORE-08 cancellation token for background expiry. Forced work ignores caller cancellation, so
    /// a cancelled BG task used to leave a multi-day rescore burning CPU after its grant ended. This cancels
    /// every runner: IntelligenceEngine stops at its next per-day checkpoint, nothing is retried, and every
    /// queued caller resumes with `false`. Durable sources (HealthKit journal, historical work rows) keep
    /// their own record of the work, so nothing is lost.
    func cancelRunningWork() {
        runners.values.forEach { $0.cancel() }
        EditedDayRescoreQueue.shared.cancel()
    }

    private func drain(ownerKey key: ObjectIdentifier) async {
        while true {
            if Task.isCancelled {
                abandonQueue(ownerKey: key)
                return
            }
            guard var state = queues[key],
                  let index = nextBatchIndex(in: state.pending) else {
                queues.removeValue(forKey: key)
                runners.removeValue(forKey: key)
                return
            }

            var batch = state.pending.remove(at: index)
            queues[key] = state // existence continues to mark this owner as actively running
            let completed: Bool
            do {
                let disposition: RepositoryRefreshContext.Disposition =
                    batch.request.refreshRepository ? .allow : .suppress
                try await RepositoryRefreshContext.$disposition.withValue(disposition) {
                    try await batch.run(batch.request)
                }
                completed = true
            } catch IntelligenceAnalysisCoordinatorError.analysisDidNotComplete
                where batch.request.force && batch.retryCount < maximumRetryCount && !Task.isCancelled {
                // The source-change request is durable. Re-read the live queue before appending it: other
                // callers may have arrived while `run` was suspended, and restoring the pre-run local state
                // would silently erase those requests. Compatible work can coalesce with this retry and every
                // original waiter stays attached until one real analysis pass completes.
                batch.retryCount += 1
                var latest = queues[key] ?? QueueState()
                latest.pending.append(batch)
                normalizePendingBatches(&latest.pending)
                queues[key] = latest
                await waitBeforeRetry(attempt: batch.retryCount)
                continue
            } catch {
                completed = false
            }
            batch.waiters.forEach { $0.resume(returning: completed) }
        }
    }

    private func abandonQueue(ownerKey key: ObjectIdentifier) {
        let abandoned = queues.removeValue(forKey: key)?.pending ?? []
        runners.removeValue(forKey: key)
        abandoned.forEach { batch in batch.waiters.forEach { $0.resume(returning: false) } }
    }

    private func waitBeforeRetry(attempt: Int) async {
        let multiplier = pow(2.0, Double(max(0, attempt - 1)))
        let delay = min(30, retryDelay * multiplier)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
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
                    // A genuinely new compatible request supplies fresh evidence that retrying the widened
                    // source window is worthwhile; keep the less-exhausted budget without ever becoming an
                    // unbounded hot loop.
                    batches[lhs].retryCount = min(batches[lhs].retryCount, batches[rhs].retryCount)
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
        durableRecoveryPostcondition: DurableRecoveryPostcondition? = nil,
        committedAnalysisExecutionContext: CommittedAnalysisExecutionContext? = nil
    ) async -> Bool {
        let request = IntelligenceAnalysisRequest(
            maxDays: maxDays,
            startOffset: startOffset,
            force: force,
            refreshRepository: refreshRepository,
            requiresDurableRecoveryReceipt: durableRecoveryPostcondition != nil,
            committedAnalysisExecutionContext: committedAnalysisExecutionContext)

        return await IntelligenceAnalysisCoordinator.shared.submit(owner: self, request: request) { [weak self] queued in
            guard let self else { throw IntelligenceAnalysisCoordinatorError.ownerReleased }

            // Normal production calls are serialized here. A direct legacy/full-signature call or an old
            // in-engine re-arm task may nevertheless already own `computing`; forced work waits instead of
            // disappearing, while a disposable cadence tick still drops. Once forced work is queued it ignores
            // caller-task cancellation—the durable source change still needs to be scored and published.
            // Only `cancelRunningWork()` (background expiry) cancels this runner task.
            while self.computing {
                guard queued.force else { throw IntelligenceAnalysisCoordinatorError.deferred }
                try Task.checkCancellation()
                await Self.waitForAnalysisPoll()
            }
            guard queued.force || !Task.isCancelled else { throw IntelligenceAnalysisCoordinatorError.deferred }

            let analysisCalendar: Calendar
            if let context = queued.committedAnalysisExecutionContext {
                analysisCalendar = try context.gregorianCalendar()
            } else {
                analysisCalendar = .current
            }

            guard await self.analyzeRecent(
                maxDays: queued.maxDays,
                startOffset: queued.startOffset,
                force: queued.force,
                refreshRepository: queued.refreshRepository,
                analysisReference: queued.committedAnalysisExecutionContext?.reference,
                analysisCalendar: analysisCalendar)
            else { throw IntelligenceAnalysisCoordinatorError.analysisDidNotComplete }

            if let durableRecoveryPostcondition,
               !(await durableRecoveryPostcondition(self.results)) {
                throw IntelligenceAnalysisCoordinatorError.analysisDidNotComplete
            }
        }
    }

    // Define every proper subset of the original four labels. Swift prefers these exact signatures over the
    // original method's default arguments, so every production shorthand call is serialized. The fully-spelled
    // four-label call remains the private bypass used only by `submitSerializedAnalysis` above.
    /// The one-day pass the UI asks for after an edit or a manual re-run. The editor awaits it, so it stays one
    /// day; the days the user edited (DL-03) then drain in the background, so an older night's Rest, Charge
    /// and Strain are rescored from that day forward without holding the editor on "Saving…".
    func analyzeRecent() async {
        await submitSerializedAnalysis(maxDays: 1, startOffset: 0, force: true, refreshRepository: true)
        EditedDayRescoreQueue.shared.register(self) { [weak self] request in
            await self?.rescoreEditedDays(request) ?? false
        }
        EditedDayRescoreQueue.shared.scheduleDrain()
    }

    /// One drained chunk of edited days, serialized with every other pass.
    private func rescoreEditedDays(_ request: IntelligenceAnalysisRequest) async -> Bool {
        await submitSerializedAnalysis(maxDays: request.maxDays, startOffset: request.startOffset, force: true,
                                       refreshRepository: request.refreshRepository)
    }

    func analyzeRecent(maxDays: Int) async {
        await submitSerializedAnalysis(maxDays: maxDays, startOffset: 0, force: true, refreshRepository: true)
    }

    func analyzeRecent(startOffset: Int) async {
        await submitSerializedAnalysis(maxDays: 1, startOffset: startOffset, force: true, refreshRepository: true)
    }

    func analyzeRecent(force: Bool) async {
        await submitSerializedAnalysis(maxDays: 1, startOffset: 0, force: force, refreshRepository: true)
    }

    @discardableResult
    func analyzeRecent(refreshRepository: Bool) async -> Bool {
        await submitSerializedAnalysis(
            maxDays: 1, startOffset: 0, force: true, refreshRepository: refreshRepository)
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
        await submitSerializedAnalysis(maxDays: 1, startOffset: startOffset, force: force,
                                       refreshRepository: true)
    }

    func analyzeRecent(startOffset: Int, refreshRepository: Bool) async {
        await submitSerializedAnalysis(maxDays: 1, startOffset: startOffset, force: true,
                                       refreshRepository: refreshRepository)
    }

    func analyzeRecent(force: Bool, refreshRepository: Bool) async {
        await submitSerializedAnalysis(maxDays: 1, startOffset: 0, force: force,
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
    /// as a retryable forced failure, so the source journal remains intact for the caller's bounded retry.
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
        await submitSerializedAnalysis(maxDays: 1, startOffset: startOffset, force: force,
                                       refreshRepository: refreshRepository)
    }
}
