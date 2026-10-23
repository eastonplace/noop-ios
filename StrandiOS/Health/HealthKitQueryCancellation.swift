import Foundation

/// A one-shot HealthKit read must release its query and its awaiting import lease when a background
/// grant expires. Stopping HKQuery alone does not guarantee a final callback, so cancellation also
/// resumes the continuation. HealthKit callbacks and cancellation settle on MainActor exactly once.
@MainActor
enum HealthKitCancellableQuery {
    static func run<Value: Sendable>(
        start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void,
        stop: @escaping @MainActor () -> Void
    ) async throws -> Value {
        let lifetime = Lifetime<Value>(stop: stop)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lifetime.continuation = continuation
                start { result in
                    Task { @MainActor in lifetime.finish(result) }
                }
            }
        } onCancel: {
            Task { @MainActor in lifetime.finish(.failure(CancellationError())) }
        }
    }

    @MainActor
    private final class Lifetime<Value: Sendable> {
        var continuation: CheckedContinuation<Value, Error>?
        private var stop: (@MainActor () -> Void)?

        init(stop: @escaping @MainActor () -> Void) { self.stop = stop }

        func finish(_ result: Result<Value, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            let stop = self.stop
            self.stop = nil
            stop?()
            continuation.resume(with: result)
        }
    }
}
