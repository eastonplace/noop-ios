import Foundation

/// FIFO hand-off queue whose waits honour Task cancellation (CC-3).
///
/// Lock and lease owners stop work by cancelling a task and then awaiting it. A bare
/// `withCheckedContinuation` wait never sees that cancel, so the owner never unwinds and the stop hangs.
/// Each waiter here registers under an id inside `withTaskCancellationHandler`. A cancel that arrives
/// before the hand-off removes the waiter and resumes it with `CancellationError`.
///
/// The queue only hands off; ownership belongs to its caller. `resumeNext()` resumes the oldest waiter
/// still queued, and the caller records that waiter as the new owner in the same isolated turn. A waiter
/// that was cancelled after it received ownership returns normally, so the caller must check
/// `Task.isCancelled` after `wait` and release at once.
///
/// `wait` runs on its caller's actor and joins the queue before it first suspends. A caller that checks its
/// own state and then waits therefore can't be overtaken by a release scheduled on the same actor: the
/// release always finds the waiter.
public final class CancellableWaiterQueue<Payload: Sendable>: @unchecked Sendable {
    private struct Waiter {
        let id: UInt64
        let payload: Payload
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var nextId: UInt64 = 0
    private var waiters: [Waiter] = []

    public init() {}

    public var isEmpty: Bool { lock.withLock { waiters.isEmpty } }
    public var count: Int { lock.withLock { waiters.count } }

    /// Suspend until `resumeNext()` hands this waiter ownership.
    /// - Throws: `CancellationError` when the calling task is cancelled before the hand-off. The waiter has
    ///   left the queue by then, so no later hand-off can reach it.
    public func wait(_ payload: Payload, isolation: isolated (any Actor)? = #isolation) async throws {
        let id = lock.withLock { () -> UInt64 in
            nextId &+= 1
            return nextId
        }
        // Lost wake-up fix: stay on the caller's actor (no hop to the generic executor) until the waiter is
        // appended, so nothing else on that actor can run between the caller's check and the append.
        try await withTaskCancellationHandler(operation: {
            // Capturing the isolated parameter keeps this closure on the caller's actor; the continuation call
            // inherits that isolation, so its body (the append) runs before the first suspension.
            _ = isolation
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // Checking cancellation under the same lock as `onCancel` closes the race where the cancel
                // lands between this task's last check and the append: one of the two always sees the other.
                let rejected = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    waiters.append(Waiter(id: id, payload: payload, continuation: continuation))
                    return false
                }
                if rejected { continuation.resume(throwing: CancellationError()) }
            }
        }, onCancel: {
            let cancelled = lock.withLock { () -> Waiter? in
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }, isolation: isolation)
    }

    /// Hand ownership to the oldest waiter still queued.
    /// - Returns: that waiter's payload, or nil when every waiter has left (finished or cancelled).
    @discardableResult
    public func resumeNext() -> Payload? {
        let next = lock.withLock { () -> Waiter? in
            waiters.isEmpty ? nil : waiters.removeFirst()
        }
        guard let next else { return nil }
        next.continuation.resume()
        return next.payload
    }

    /// Resume every queued waiter, for owners that release a whole group (for example, callers coalesced
    /// onto one run). Returns how many were resumed.
    @discardableResult
    public func resumeAll() -> Int {
        let all = lock.withLock { () -> [Waiter] in
            defer { waiters.removeAll() }
            return waiters
        }
        all.forEach { $0.continuation.resume() }
        return all.count
    }
}
