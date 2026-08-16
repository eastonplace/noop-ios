import Foundation

/// Lossless single-flight signal owner.
///
/// The final `needsDrain` check and `activeTask = nil` happen in one actor turn,
/// so a signal cannot land in the gap and be forgotten. Signals received while
/// suspended remain pending and resume only after the lifecycle owner reopens
/// the gate. Callers that need semantic accumulation supply a typed combiner.
public actor LosslessDrainSignalGate<Output: Sendable> {
    public typealias Operation = @Sendable () async -> Output
    public typealias Combine = @Sendable (_ accumulated: Output, _ next: Output) -> Output

    private let combineResults: Combine
    private let operation: Operation
    private var activeTask: Task<Output, Never>?
    private var needsDrain = false
    private var suspended = false
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(operation: @escaping Operation) {
        combineResults = { _, next in next }
        self.operation = operation
    }

    public init(
        combine: @escaping Combine,
        operation: @escaping Operation
    ) {
        combineResults = combine
        self.operation = operation
    }

    public func signal() async -> Output {
        needsDrain = true
        await waitUntilResumed()
        if let activeTask { return await activeTask.value }

        let task = Task { await self.runLoop() }
        activeTask = task
        return await task.value
    }

    public func suspendAndCancel() async {
        suspended = true
        needsDrain = false
        guard let activeTask else { return }
        activeTask.cancel()
        _ = await activeTask.value
        self.activeTask = nil
    }

    public func resume() {
        guard suspended else { return }
        suspended = false
        let waiters = resumeWaiters
        resumeWaiters.removeAll(keepingCapacity: true)
        for waiter in waiters { waiter.resume() }
    }

    public var isRunning: Bool { activeTask != nil }
    public var isSuspended: Bool { suspended }
    var hasPendingDrainForTesting: Bool { needsDrain }

    private func waitUntilResumed() async {
        guard suspended else { return }
        await withCheckedContinuation { continuation in
            resumeWaiters.append(continuation)
        }
    }

    private func runLoop() async -> Output {
        await waitUntilResumed()
        needsDrain = false
        var result = await operation()

        while true {
            if Task.isCancelled || suspended {
                activeTask = nil
                return result
            }

            // No suspension between this check and clearing `activeTask`. A new
            // signal either set `needsDrain` before this turn, or it observes nil
            // after this turn and creates the next task.
            guard needsDrain else {
                activeTask = nil
                return result
            }
            needsDrain = false
            let next = await operation()
            result = combineResults(result, next)
        }
    }
}
