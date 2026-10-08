#if os(iOS)
import Foundation
@preconcurrency import BackgroundTasks

private final class HistoricalScoringBackgroundCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @Sendable (Bool) -> Void

    init(completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    func complete(success: Bool) {
        lock.lock()
        let accepted = !completed
        completed = true
        lock.unlock()
        if accepted { completion(success) }
    }
}

/// Gives NOOP's existing durable HealthKit and receipt pipelines one discretionary processing wake when a
/// locked device or Bluetooth wake cannot finish recovery scoring. The registrar never creates a second
/// debt record: the persisted import/scoring windows and SQLite receipt state remain authoritative.
@MainActor
enum HistoricalScoringBackgroundTaskRegistrar {
    enum CompletionDisposition: Equatable, Sendable {
        case complete
        case retry
    }

    static let identifier = (Bundle.main.bundleIdentifier ?? "com.eastonplace.noop") + ".rescore"

    typealias DrainHealthImport = @MainActor @Sendable () async -> Bool
    typealias DrainHealthScoring = @MainActor @Sendable () async -> Bool
    typealias HealthImportPending = @MainActor @Sendable () -> Bool
    typealias HealthScoringPending = @MainActor @Sendable () -> Bool
    typealias Run = @MainActor @Sendable () async -> HistoricalPipelineRuntimeResult?
    typealias Cancel = @MainActor @Sendable () async -> Void

    private static var drainHealthImport: DrainHealthImport?
    private static var drainHealthScoring: DrainHealthScoring?
    private static var healthImportPending: HealthImportPending?
    private static var healthScoringPending: HealthScoringPending?
    private static var runHistorical: Run?
    private static var cancelWork: Cancel?
    private static var registered = false

    @discardableResult
    static func install(
        drainHealthImport: @escaping DrainHealthImport,
        drainHealthScoring: @escaping DrainHealthScoring,
        healthImportPending: @escaping HealthImportPending,
        healthScoringPending: @escaping HealthScoringPending,
        runHistorical: @escaping Run,
        cancelWork: @escaping Cancel
    ) -> Bool {
        self.drainHealthImport = drainHealthImport
        self.drainHealthScoring = drainHealthScoring
        self.healthImportPending = healthImportPending
        self.healthScoringPending = healthScoringPending
        self.runHistorical = runHistorical
        self.cancelWork = cancelWork
        guard !registered else { return true }

        let taskIdentifier = identifier
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let completion = HistoricalScoringBackgroundCompletionGate { success in
                processingTask.setTaskCompleted(success: success)
            }
            let worker = Task { @MainActor in
                guard let drainHealthImport = Self.drainHealthImport,
                      let drainHealthScoring = Self.drainHealthScoring,
                      let healthImportPending = Self.healthImportPending,
                      let healthScoringPending = Self.healthScoringPending,
                      let runHistorical = Self.runHistorical else {
                    Self.schedule()
                    completion.complete(success: false)
                    return
                }

                let result = await runBackgroundWork(
                    drainHealthImport: drainHealthImport,
                    drainHealthScoring: drainHealthScoring,
                    runHistorical: runHistorical
                )
                guard !Task.isCancelled else { return }

                switch completionDisposition(
                    for: result,
                    healthImportPending: healthImportPending(),
                    healthScoringPending: healthScoringPending()
                ) {
                case .complete:
                    cancelPendingRequest()
                    completion.complete(success: true)
                case .retry:
                    schedule()
                    completion.complete(success: false)
                }
            }

            processingTask.expirationHandler = {
                worker.cancel()
                // Submit synchronously before reporting completion. iOS may suspend the process as soon as
                // the task is completed; the durable lease cleanup below is best-effort, but the next wake
                // must already be armed even if this process is reclaimed first.
                Self.submitRequest(identifier: taskIdentifier)
                Task { @MainActor in
                    if let cancelWork = Self.cancelWork {
                        await cancelWork()
                    }
                    completion.complete(success: false)
                }
            }
        }
        return registered
    }

    static func completionDisposition(
        for result: HistoricalPipelineRuntimeResult?
    ) -> CompletionDisposition {
        guard let result,
              !result.alreadyRunning,
              result.deferredWork == 0,
              let pendingWork = result.pendingWork,
              pendingWork == 0 else {
            return .retry
        }
        return .complete
    }

    static func completionDisposition(
        for result: HistoricalPipelineRuntimeResult?,
        healthScoringPending: Bool
    ) -> CompletionDisposition {
        guard !healthScoringPending else { return .retry }
        return completionDisposition(for: result)
    }

    static func completionDisposition(
        for result: HistoricalPipelineRuntimeResult?,
        healthImportPending: Bool,
        healthScoringPending: Bool
    ) -> CompletionDisposition {
        guard !healthImportPending else { return .retry }
        return completionDisposition(
            for: result,
            healthScoringPending: healthScoringPending
        )
    }

    static func runBackgroundWork(
        drainHealthImport: @escaping DrainHealthImport,
        drainHealthScoring: @escaping @MainActor @Sendable () async -> Bool,
        runHistorical: @escaping Run
    ) async -> HistoricalPipelineRuntimeResult? {
        // A locked HealthKit database can leave the import journal pending while already-committed local
        // rows still need Recovery publication. Try the import first, but do not strand scoring when the
        // database remains locked; completion policy keeps the same request armed for another import pass.
        _ = await drainHealthImport()
        guard !Task.isCancelled else { return nil }
        guard await drainHealthScoring() else { return nil }
        guard !Task.isCancelled else { return nil }
        return await runHistorical()
    }

    /// Keep one best-effort request armed. The durable pipeline remains authoritative if iOS discards it.
    static func schedule() {
        submitRequest(identifier: identifier)
    }

    nonisolated private static func submitRequest(identifier: String) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("NOOP historical scoring background request failed: %@", String(describing: error))
        }
    }

    static func cancelPendingRequest() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
#endif
