#if os(iOS)
import Foundation
@preconcurrency import BackgroundTasks

enum SmartAlarmBackgroundRequestLoadResult: Equatable, Sendable {
    case missing
    case malformed
    case loaded(SmartAlarmBackgroundRequest)
}

/// Registers the production BGTask launch handler before the legacy scheduler enum attempts registration.
/// iOS accepts only one handler per identifier in a process, so the legacy registration becomes a harmless
/// `false` return while its request persistence/scheduling helpers remain the single storage seam.
@MainActor
enum SmartAlarmBackgroundTaskRegistrar {
    private static let requestKey = "smartAlarm.runtime.backgroundRequest"
    private static weak var runtime: SmartAlarmRuntimeController?
    private static var registered = false

    @discardableResult
    static func install(_ runtime: SmartAlarmRuntimeController) -> Bool {
        self.runtime = runtime
        guard !registered else { return true }

        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: SmartAlarmRuntimeBackgroundScheduler.bgTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }

            let completion = SmartAlarmBackgroundCompletionGate { success in
                refreshTask.setTaskCompleted(success: success)
            }
            let operation = Task { @MainActor in
                let request: SmartAlarmBackgroundRequest
                switch loadRequest() {
                case .missing:
                    completion.complete(.missingRequest)
                    return
                case .malformed:
                    completion.complete(.malformedRequest)
                    return
                case .loaded(let loaded):
                    request = loaded
                }

                guard let runtime = Self.runtime else {
                    completion.complete(.missingRuntime)
                    return
                }
                guard !Task.isCancelled else {
                    completion.complete(.cancelled)
                    return
                }

                do {
                    let succeeded = try await evaluate(request, runtime: runtime)
                    guard !Task.isCancelled else {
                        completion.complete(.cancelled)
                        return
                    }
                    SmartAlarmRuntimeBackgroundScheduler.clearRequest(ifMatching: request)
                    completion.complete(succeeded ? .success : .failure)
                } catch is CancellationError {
                    completion.complete(.cancelled)
                } catch {
                    completion.complete(.evaluationError)
                }
            }
            refreshTask.expirationHandler = {
                operation.cancel()
                completion.complete(.expired)
            }
        }
        return registered
    }

    static func loadRequest(
        defaults: UserDefaults = .standard
    ) -> SmartAlarmBackgroundRequestLoadResult {
        guard let data = defaults.data(forKey: requestKey) else { return .missing }
        guard let request = try? JSONDecoder().decode(SmartAlarmBackgroundRequest.self, from: data)
        else { return .malformed }
        return .loaded(request)
    }

    private static func evaluate(
        _ request: SmartAlarmBackgroundRequest,
        runtime: SmartAlarmRuntimeController
    ) async throws -> Bool {
        try Task.checkCancellation()
        let succeeded = await runtime.handleBackgroundRefresh(request)
        try Task.checkCancellation()
        return succeeded
    }
}
#endif
