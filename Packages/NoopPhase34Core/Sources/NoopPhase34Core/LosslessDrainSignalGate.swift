import Foundation

/// Optional semantic accumulation hook for drain results. The protocol uses
/// `Any` at the boundary so the generic gate can discover conformance without
/// forcing every existing caller to adopt a new initializer.
public protocol DrainSignalResultAccumulating {
    static func combineDrainResults(_ accumulated: Any, _ next: Any) -> Any
}

/// Lossless single-flight signal owner.
///
/// The final `needsDrain` check and `activeTask = nil` happen in one actor turn,
/// so a signal cannot land in the gap and be forgotten. Signals received while
/// suspended remain pending and resume only after the lifecycle owner reopens
/// the gate. When `Output` conforms to `DrainSignalResultAccumulating`, every
/// coalesced pass contributes to the returned semantic result.
public actor LosslessDrainSignalGate<Output: Sendable> {
    public typealias Operation = @Sendable () async -> Output
    public typealias Combine = @Sendable (_ accumulated: Output, _ next: Output) -> Output

    private let explicitCombine: Combine?
    private let operation: Operation
    private var activeTask: Task<Output, Never>?
    private var needsDrain = false
    private var suspended = false
    private var resumeWaiters: [CheckedContinuation<Void, Never>] = []

    public init(operation: @escaping Operation) {
        explicitCombine = nil
        self.operation = operation
    }

    public init(
        combine: @escaping Combine,
        operation: @escaping Operation
    ) {
        explicitCombine = combine
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
            result = combine(result, next)
        }
    }

    private func combine(_ accumulated: Output, _ next: Output) -> Output {
        if let explicitCombine {
            return explicitCombine(accumulated, next)
        }
        if let accumulator = Output.self as? DrainSignalResultAccumulating.Type,
           let combined = accumulator.combineDrainResults(accumulated, next) as? Output {
            return combined
        }
        return next
    }
}
