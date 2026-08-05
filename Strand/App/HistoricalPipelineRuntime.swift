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
    private var running = false
    private var rerunRequested = false

    init(dependencies: HistoricalPipelineRuntimeDependencies) {
        self.dependencies = dependencies
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
        defer { running = false }

        var admitted = 0
        var completed = 0
        var deferred = 0
        repeat {
            rerunRequested = false
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
                    var hasMoreReceipts = true
                    while hasMoreReceipts && !Task.isCancelled {
                        let result = try await dependencies.admit(context)
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

            let drain = await dependencies.coordinator.signal()
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
