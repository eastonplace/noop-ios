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
        // The launch handler inherits `@MainActor`; see BackgroundTaskLaunchPolicy for why the queue matters.
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: BackgroundTaskLaunchPolicy.launchQueue
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let completion = HistoricalScoringBackgroundCompletionGate { success in
                processingTask.setTaskCompleted(success: success)
            }
            let worker = Task { @MainActor in
                if ActiveSessionGate.isActive() {
                    Self.schedule(after: ActiveSessionGate.retryDelay)
                    completion.complete(success: false)
                    return
                }
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

            processingTask.expirationHandler = makeExpirationHandler(
                cancelWorker: { worker.cancel() },
                rearm: { submitRequest(identifier: taskIdentifier) },
                cancelDurableWork: {
                    // Forced analysis runs in the coordinator's own task and ignores caller cancellation, so
                    // expiry stops it explicitly; the engine then stops between days. Quiesce follows.
                    IntelligenceAnalysisCoordinator.shared.cancelRunningWork()
                    if let cancelWork = Self.cancelWork {
                        await cancelWork()
                    }
                },
                complete: { completion.complete(success: $0) }
            )
        }
        return registered
    }

    /// Built `nonisolated` and `@Sendable` so it is safe on whichever queue iOS expires the task from;
    /// the only main-actor work (durable lease cleanup) hops explicitly.
    ///
    /// CC-2 / CORE-08: completion is reported synchronously, before the handler returns, like the sibling
    /// registrars. Quiesce waits for every in-flight drain and can take arbitrarily long; reporting completion
    /// after it made iOS terminate the app for overrunning an expired task. Durable leases expire and recover
    /// by themselves, so the cleanup is fire-and-forget.
    nonisolated static func makeExpirationHandler(
        cancelWorker: @escaping @Sendable () -> Void,
        rearm: @escaping @Sendable () -> Void,
        cancelDurableWork: @escaping Cancel,
        complete: @escaping @Sendable (Bool) -> Void
    ) -> @Sendable () -> Void {
        {
            cancelWorker()
            // Submit before reporting completion. iOS may suspend the process as soon as the task is
            // completed, so the next wake must already be armed.
            rearm()
            complete(false)
            Task { @MainActor in
                await cancelDurableWork()
            }
        }
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
        // The strap pipeline doesn't depend on HealthKit scoring succeeding. A parked or backing-off scoring
        // journal returns false at once, and gating on it skipped strap scoring on every BG wake until the
        // next foreground. A pending journal still makes the completion policy retry.
        _ = await drainHealthScoring()
        guard !Task.isCancelled else { return nil }
        return await runHistorical()
    }

    /// Keep one best-effort request armed. The durable pipeline remains authoritative if iOS discards it.
    static func schedule(after delay: TimeInterval = 0) {
        submitRequest(identifier: identifier, after: delay)
    }

    nonisolated private static func submitRequest(identifier: String, after delay: TimeInterval = 0) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        if delay > 0 { request.earliestBeginDate = Date(timeIntervalSinceNow: delay) }
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
