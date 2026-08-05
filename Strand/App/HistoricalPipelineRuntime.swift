// Add to Strand/App. This is the single runtime owner for receipt admission and durable pipeline draining.

import Foundation
import NoopPhase34Core
import WhoopStore

struct HistoricalPipelineRuntimeDependencies: Sendable {
    /// Rearm only environmental blocked work before admission and coordinator drain.
    /// Structural repair rows stay quarantined.
    let rearmEnvironmental: (@Sendable () async throws -> Void)?
    /// Return every currently valid source scope. Old scopes must first be retired transactionally through
    /// `retireHistoricalReceiptScope`; they are not left as invisible pending work.
    let admissionContexts: @Sendable () async throws -> [HistoricalReceiptAdmissionContext]
    let admit: @Sendable (HistoricalReceiptAdmissionContext) async throws -> HistoricalReceiptAdmissionResult
    let coordinator: HistoricalPipelineCoordinator
    let pendingWorkCount: @Sendable () async throws -> Int
    let classifyAdmissionError: @Sendable (any Error) -> PipelineFailureClassification
    let onAdmissionFailure: @Sendable (PipelineFailureClassification) async -> Void
    let report: @Sendable (String) -> Void

    init(
        rearmEnvironmental: (@Sendable () async throws -> Void)? = nil,
        admissionContexts: @escaping @Sendable () async throws -> [HistoricalReceiptAdmissionContext],
        admit: @escaping @Sendable (HistoricalReceiptAdmissionContext) async throws -> HistoricalReceiptAdmissionResult,
        coordinator: HistoricalPipelineCoordinator,
        pendingWorkCount: @escaping @Sendable () async throws -> Int,
        classifyAdmissionError: @escaping @Sendable (any Error) -> PipelineFailureClassification,
        onAdmissionFailure: @escaping @Sendable (PipelineFailureClassification) async -> Void,
        report: @escaping @Sendable (String) -> Void
    ) {
        self.rearmEnvironmental = rearmEnvironmental
        self.admissionContexts = admissionContexts
        self.admit = admit
        self.coordinator = coordinator
        self.pendingWorkCount = pendingWorkCount
        self.classifyAdmissionError = classifyAdmissionError
        self.onAdmissionFailure = onAdmissionFailure
        self.report = report
    }
}

struct HistoricalPipelineRuntimeResult: Equatable, Sendable {
    let admittedReceipts: Int
    let completedWork: Int
    let deferredWork: Int
    /// Nil means the count read failed. Never report an infrastructure failure as zero pending work.
    let pendingWork: Int?
    let alreadyRunning: Bool
}

enum HistoricalPipelineRuntimeError: Error {
    case storeUnavailable
    case snapshotUnavailable
}

/// Coalesces launch, foreground, protected-data, CoreBluetooth restoration, and burst-finalization signals.
/// The durable journal remains the source of truth; a missed in-memory signal is repaired by the next call.
actor HistoricalPipelineRuntime {
    private let dependencies: HistoricalPipelineRuntimeDependencies
    private let quiescence = PipelineQuiescence()
    private var running = false
    private var rerunRequested = false
    private var activeSignalTask: Task<HistoricalPipelineRuntimeResult, Never>?
    private var coordinatorEpochByRuntimeEpoch: [UInt64: UInt64] = [:]

    init(dependencies: HistoricalPipelineRuntimeDependencies) {
        self.dependencies = dependencies
    }

    func quiesce() async throws -> UInt64 {
        activeSignalTask?.cancel()

        // The runtime can be suspended while it is awaiting the coordinator. Quiesce the coordinator first so
        // that cancellation reaches the actual lease owner instead of waiting only on this wrapper task.
        let coordinatorEpoch = try await dependencies.coordinator.quiesce()
        let runtimeEpoch = try await quiescence.quiesce(cancelOwners: { })
        coordinatorEpochByRuntimeEpoch[runtimeEpoch] = coordinatorEpoch
        return runtimeEpoch
    }

    func resume(expectedEpoch: UInt64) async throws {
        guard let coordinatorEpoch = coordinatorEpochByRuntimeEpoch.removeValue(forKey: expectedEpoch) else {
            throw PipelineQuiescenceError.superseded
        }
        try await quiescence.resume(expectedEpoch: expectedEpoch)
        try await dependencies.coordinator.resume(expectedEpoch: coordinatorEpoch)
    }

    func signal() async -> HistoricalPipelineRuntimeResult {
        guard !running else {
            rerunRequested = true
            return HistoricalPipelineRuntimeResult(
                admittedReceipts: 0,
                completedWork: 0,
                deferredWork: 0,
                pendingWork: await readPendingWorkCount(),
                alreadyRunning: true
            )
        }
        running = true
        let task = Task { [weak self] in
            await self?.drain() ?? HistoricalPipelineRuntimeResult(
                admittedReceipts: 0,
                completedWork: 0,
                deferredWork: 1,
                pendingWork: nil,
                alreadyRunning: false
            )
        }
        activeSignalTask = task
        let result = await task.value
        activeSignalTask = nil
        running = false
        return result
    }

    private func drain() async -> HistoricalPipelineRuntimeResult {
        let token: PipelineEpochToken
        do {
            token = try await quiescence.begin()
        } catch {
            return HistoricalPipelineRuntimeResult(
                admittedReceipts: 0,
                completedWork: 0,
                deferredWork: 1,
                pendingWork: await readPendingWorkCount(),
                alreadyRunning: false
            )
        }
        defer { Task { await quiescence.end(token) } }

        var admitted = 0
        var completed = 0
        var deferred = 0
        repeat {
            rerunRequested = false
            do { try await quiescence.validate(token) }
            catch { deferred += 1; break }
            if let rearmEnvironmental = dependencies.rearmEnvironmental {
                do {
                    try await rearmEnvironmental()
                } catch {
                    dependencies.report("historical_blocked_rearm_failed: \(error)")
                }
            }
            let contexts: [HistoricalReceiptAdmissionContext]
            do {
                contexts = try await dependencies.admissionContexts()
            } catch {
                let failure = dependencies.classifyAdmissionError(error)
                await dependencies.onAdmissionFailure(failure)
                dependencies.report("historical_admission_contexts_failed: \(error)")
                contexts = []
                deferred += 1
            }

            for context in contexts where !Task.isCancelled {
                do {
                    try await quiescence.validate(token)
                    var hasMoreReceipts = true
                    while hasMoreReceipts && !Task.isCancelled {
                        let result = try await dependencies.admit(context)
                        try await quiescence.validate(token)
                        admitted += result.admittedReceiptCount
                        hasMoreReceipts = result.hasMoreReceipts
                    }
                } catch {
                    let failure = dependencies.classifyAdmissionError(error)
                    await dependencies.onAdmissionFailure(failure)
                    dependencies.report("historical_receipt_admission_failed: \(error)")
                    deferred += 1
                }
            }

            try? await quiescence.validate(token)
            guard !Task.isCancelled else { break }
            let drain = await dependencies.coordinator.signal()
            guard !Task.isCancelled else { break }
            do { try await quiescence.validate(token) }
            catch { deferred += 1; break }
            completed += drain.completedWorkCount
            deferred += drain.deferredWorkCount
        } while rerunRequested && !Task.isCancelled

        return HistoricalPipelineRuntimeResult(
            admittedReceipts: admitted,
            completedWork: completed,
            deferredWork: deferred,
            pendingWork: await readPendingWorkCount(),
            alreadyRunning: false
        )
    }

    private func readPendingWorkCount() async -> Int? {
        do {
            return try await dependencies.pendingWorkCount()
        } catch {
            dependencies.report("historical_pending_work_count_failed: \(error)")
            return nil
        }
    }
}

/*
AppModel wiring:

- Remove `historicalReceiptAnalysisConsumer` and its checkpoint callbacks.
- Add one lazy `HistoricalPipelineRuntime`.
- Build `HistoricalPipelineCoordinator` dependencies from:
    WhoopStore.leaseNextHistoricalAnalysisWork
    WhoopStore.applyHistoricalAnalysisWorkEvent
    IntelligenceEngine exact-day analysis plus `recordAnalysisMutation`
    Repository.verifyAndCommitHistoricalSnapshot
    Repository.publishVerifiedExactDays
    WhoopStore.enqueueExternalPublications
- `admissionContexts` returns all currently valid device/source scopes. Source transitions retire the old scope
  before returning only the new scope.
- Call `signal()` from:
    app launch after store open,
    finalized receipt watermark,
    foreground entry,
    protected data available,
    CoreBluetooth state restoration,
    eligible BGProcessing task.
- Background expiration cancels the task only. Durable leases expire and recover; do not mark completion.
*/
