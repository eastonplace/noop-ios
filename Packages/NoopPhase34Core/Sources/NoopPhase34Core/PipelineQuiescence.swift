import Foundation

public struct PipelineEpochToken: Equatable, Sendable {
    public let epoch: UInt64
}

public enum PipelineQuiescenceError: Error, Equatable, Sendable {
    case suspended
    case superseded
    case epochExhausted
}

/// Shared cancellation/epoch gate for source lifecycle boundaries. A token is valid only while admission is
/// open at the same epoch. Transition code closes admission, cancels owners, waits for all in-flight tokens,
/// mutates durable lineage, then resumes the committed epoch.
public actor PipelineQuiescence {
    private var epoch: UInt64 = 1
    private var accepting = true
    private var inFlight = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// Process-local recovery probe. Durable source-transition journals can outlive the actor that issued
    /// their epoch. A fresh actor starts open, so an old persisted epoch needs no local resume operation.
    public var isAccepting: Bool { accepting }

    public func begin() throws -> PipelineEpochToken {
        guard accepting else { throw PipelineQuiescenceError.suspended }
        inFlight += 1
        return PipelineEpochToken(epoch: epoch)
    }

    public func validate(_ token: PipelineEpochToken) throws {
        guard accepting, token.epoch == epoch else {
            throw PipelineQuiescenceError.superseded
        }
    }

    public func end(_ token: PipelineEpochToken) {
        precondition(inFlight > 0, "pipeline quiescence underflow")
        inFlight -= 1
        if inFlight == 0 {
            let waiters = idleWaiters
            idleWaiters.removeAll(keepingCapacity: true)
            waiters.forEach { $0.resume() }
        }
    }

    public func quiesce(cancelOwners: @Sendable () -> Void) async throws -> UInt64 {
        accepting = false
        let (next, overflow) = epoch.addingReportingOverflow(1)
        guard !overflow else { throw PipelineQuiescenceError.epochExhausted }
        epoch = next
        cancelOwners()
        if inFlight > 0 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                idleWaiters.append(continuation)
            }
        }
        return epoch
    }

    public func resume(expectedEpoch: UInt64) throws {
        guard expectedEpoch == epoch else { throw PipelineQuiescenceError.superseded }
        accepting = true
    }
}
