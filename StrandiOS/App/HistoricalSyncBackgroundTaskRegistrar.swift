#if os(iOS)
import Foundation
@preconcurrency import BackgroundTasks

private final class HistoricalSyncBackgroundCompletionGate: @unchecked Sendable {
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

/// Discretionary iOS wakes for durable historical debt and eligible WHOOP 4 maintenance. This is only a
/// scheduler: Bluetooth, secure-session, store, rate-limit, and active-sync admission stays inside
/// `BLEManager.requestSync`.
@MainActor
enum HistoricalSyncBackgroundTaskRegistrar {
    nonisolated static let identifier = "com.noopapp.noop.historysync"

    typealias Snapshot = @MainActor @Sendable () -> HistoricalSyncBackgroundSnapshot?
    typealias RequestSync = @MainActor @Sendable () -> Bool

    enum LaunchAdmission: Equatable {
        case completed(success: Bool)
        case syncStarted
        case cancelled
    }

    private static var snapshot: Snapshot?
    private static var requestSync: RequestSync?
    private static var registered = false

    @discardableResult
    static func install(
        snapshot: @escaping Snapshot,
        requestSync: @escaping RequestSync
    ) -> Bool {
        self.snapshot = snapshot
        self.requestSync = requestSync
        guard !registered else {
            refresh()
            return true
        }

        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: BackgroundTaskLaunchPolicy.launchQueue
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let completion = HistoricalSyncBackgroundCompletionGate { success in
                processingTask.setTaskCompleted(success: success)
            }
            let operation = makeOperation {
                if ActiveSessionGate.isActive() {
                    Self.schedule(after: ActiveSessionGate.retryDelay)
                    completion.complete(success: false)
                    return
                }
                guard let snapshot = Self.snapshot,
                      let requestSync = Self.requestSync else {
                    Self.cancel()
                    completion.complete(success: false)
                    return
                }

                switch admitLaunch(
                    initial: snapshot(),
                    requestSync: requestSync,
                    schedule: { Self.schedule(after: $0) },
                    cancel: { Self.cancel() }
                ) {
                case .completed(let success):
                    completion.complete(success: success)
                    return
                case .cancelled:
                    return
                case .syncStarted:
                    break
                }

                do {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .seconds(5))
                        guard let current = snapshot() else {
                            Self.cancel()
                            completion.complete(success: false)
                            return
                        }
                        if !current.syncActive {
                            Self.refresh(current)
                            completion.complete(success: true)
                            return
                        }
                    }
                } catch is CancellationError {
                    // Expiration owns completion and the bounded retry below.
                } catch {
                    Self.schedule(after: HistoricalSyncBackgroundSchedulingPolicy.minimumRetrySeconds)
                    completion.complete(success: false)
                }
            }

            processingTask.expirationHandler = makeExpirationHandler(
                cancelOperation: { operation.cancel() },
                rearm: { submitRequest(after: HistoricalSyncBackgroundSchedulingPolicy.minimumRetrySeconds) },
                complete: { completion.complete(success: $0) }
            )
        }
        refresh()
        return registered
    }

    /// The real launch admission path, independent of BGTaskScheduler delivery and the later wait for
    /// completion. In particular, caught-up maintenance must reach the same gated request as debt.
    static func admitLaunch(
        initial: HistoricalSyncBackgroundSnapshot?,
        requestSync: RequestSync,
        schedule: (TimeInterval) -> Void,
        cancel: () -> Void
    ) -> LaunchAdmission {
        guard let initial else {
            cancel()
            return .completed(success: false)
        }
        switch initial.plan {
        case .cancel:
            cancel()
            return .completed(success: true)
        case .schedule(let delay) where delay > 1:
            schedule(delay)
            return .completed(success: true)
        case .schedule:
            break
        }

        guard !Task.isCancelled else { return .cancelled }
        guard requestSync() else {
            schedule(HistoricalSyncBackgroundSchedulingPolicy.minimumRetrySeconds)
            return .completed(success: true)
        }
        return .syncStarted
    }

    /// A launch can expire before its main-actor operation first executes.
    static func makeOperation(
        _ operation: @escaping @MainActor @Sendable () async -> Void
    ) -> Task<Void, Never> {
        Task { @MainActor in
            guard !Task.isCancelled else { return }
            await operation()
        }
    }

    /// Built `nonisolated` and `@Sendable` so it is safe on whichever queue iOS expires the task from.
    /// The retry is armed synchronously, before completion is reported, because iOS may suspend the
    /// process as soon as the task completes.
    nonisolated static func makeExpirationHandler(
        cancelOperation: @escaping @Sendable () -> Void,
        rearm: @escaping @Sendable () -> Void,
        complete: @escaping @Sendable (Bool) -> Void
    ) -> @Sendable () -> Void {
        {
            cancelOperation()
            rearm()
            complete(false)
        }
    }

    static func refresh() {
        guard let current = snapshot?() else {
            cancel()
            return
        }
        refresh(current)
    }

    private static func refresh(_ current: HistoricalSyncBackgroundSnapshot) {
        switch current.plan {
        case .cancel:
            cancel()
        case .schedule(let delay):
            schedule(after: delay)
        }
    }

    private static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    private static func schedule(after delay: TimeInterval, now: Date = Date()) {
        submitRequest(after: delay, now: now)
    }

    /// `BGTaskScheduler` is thread-safe, so the expiration handler can call this from any queue.
    nonisolated private static func submitRequest(after delay: TimeInterval, now: Date = Date()) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = now.addingTimeInterval(max(0, delay))
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("NOOP historical sync background request failed: %@", String(describing: error))
        }
    }
}
#endif
