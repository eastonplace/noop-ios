#if os(iOS)
import Foundation
import UIKit
import WhoopStore
@preconcurrency import BackgroundTasks

enum SourcePrivacyCleanupBackgroundRetryPolicy {
    static let pendingDelay: TimeInterval = 60
    static let authorizationDelay: TimeInterval = 15 * 60
    static let quarantineCooldownDelay: TimeInterval = 24 * 60 * 60

    static func delay(for error: Error) -> TimeInterval? {
        guard let error = error as? SourcePrivacyCleanupCoordinatorError else { return nil }
        switch error {
        case .pending:
            return pendingDelay
        case .authorizationUnavailable:
            return authorizationDelay
        case .quarantinedGroup:
            return quarantineCooldownDelay
        default:
            return nil
        }
    }
}

enum SourcePrivacyCleanupBackgroundState: Equatable, Sendable {
    case none
    case ready
    case authorizationBlocked(until: Date)
    case quarantined(until: Date)

    static func pendingState(
        for candidate: SourcePrivacyCleanupGroup?,
        now: Date
    ) -> Self {
        guard let candidate else { return .none }
        if candidate.isReadyForRecovery(at: now) { return .ready }
        if candidate.hasQuarantinedWork,
           let until = candidate.nextRearmEligibleAt {
            return .quarantined(until: until)
        }
        if candidate.hasAuthorizationBlockedWork,
           let until = candidate.nextAuthorizationRetryAt {
            return .authorizationBlocked(until: until)
        }
        return .ready
    }

    func retryDelay(from now: Date) -> TimeInterval? {
        switch self {
        case .none: return nil
        case .ready: return SourcePrivacyCleanupBackgroundRetryPolicy.pendingDelay
        case let .authorizationBlocked(until), let .quarantined(until):
            return max(0, until.timeIntervalSince(now))
        }
    }
}

private final class SourcePrivacyCleanupBackgroundCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let completion: @Sendable (Bool) -> Void

    init(completion: @escaping @Sendable (Bool) -> Void) {
        self.completion = completion
    }

    func complete(success: Bool) {
        lock.lock()
        let shouldComplete = !completed
        completed = true
        lock.unlock()
        if shouldComplete { completion(success) }
    }
}

/// Registers and schedules one bounded post-commit privacy cleanup grant. The
/// durable coordinator advances one page, so expiration can cancel safely and
/// the next grant resumes from SQLite.
@MainActor
enum SourcePrivacyCleanupBackgroundTaskRegistrar {
    static let identifier = "com.noopapp.noop.privacycleanup"

    typealias Recover = @MainActor @Sendable () async -> Void
    typealias PendingState = @MainActor @Sendable () async throws -> SourcePrivacyCleanupBackgroundState

    private static var recover: Recover?
    private static var pendingState: PendingState?
    private static var registered = false

    @discardableResult
    static func install(
        recover: @escaping Recover,
        pendingState: @escaping PendingState
    ) -> Bool {
        self.recover = recover
        self.pendingState = pendingState
        guard !registered else { return true }

        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let completion = SourcePrivacyCleanupBackgroundCompletionGate { success in
                processingTask.setTaskCompleted(success: success)
            }
            let operation = Task { @MainActor in
                guard UIApplication.shared.isProtectedDataAvailable,
                      let recover = Self.recover,
                      let pendingState = Self.pendingState else {
                    Self.schedule(after: SourcePrivacyCleanupBackgroundRetryPolicy.pendingDelay)
                    completion.complete(success: false)
                    return
                }
                do {
                    try Task.checkCancellation()
                    await recover()
                    try Task.checkCancellation()
                    if let delay = try await pendingState().retryDelay(from: Date()) {
                        Self.schedule(after: delay)
                    }
                    completion.complete(success: true)
                } catch is CancellationError {
                    Self.schedule(after: SourcePrivacyCleanupBackgroundRetryPolicy.pendingDelay)
                    completion.complete(success: false)
                } catch {
                    Self.schedule(after: SourcePrivacyCleanupBackgroundRetryPolicy.pendingDelay)
                    completion.complete(success: false)
                }
            }
            processingTask.expirationHandler = {
                operation.cancel()
                Task { @MainActor in
                    Self.schedule(after: SourcePrivacyCleanupBackgroundRetryPolicy.pendingDelay)
                }
                completion.complete(success: false)
            }
        }
        return registered
    }

    static func scheduleRetry(for error: Error, now: Date = Date()) {
        guard let delay = SourcePrivacyCleanupBackgroundRetryPolicy.delay(for: error) else { return }
        schedule(after: delay, now: now)
    }

    static func schedule(_ state: SourcePrivacyCleanupBackgroundState, now: Date = Date()) {
        guard let delay = state.retryDelay(from: now) else { return }
        schedule(after: delay, now: now)
    }

    private static func schedule(after delay: TimeInterval, now: Date = Date()) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = now.addingTimeInterval(max(0, delay))
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            NSLog("NOOP privacy cleanup background request failed: %@", String(describing: error))
        }
    }
}
#endif
