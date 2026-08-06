import Foundation
import NoopPhase34Core

/// One queue owns every ActivityKit request/update/end. Ordinary live state may
/// coalesce. Verified and lifecycle commands are FIFO and their continuations are
/// attached to the exact command that executes.
@MainActor
public final class SerializedLiveActivityCommands<Payload: Sendable> {
    public typealias Perform = @MainActor @Sendable (
        _ payload: Payload,
        _ token: VerifiedSinkToken?
    ) async throws -> ExternalSinkPublicationResult
    public typealias Validate = @MainActor @Sendable (VerifiedSinkToken) -> Bool
    public typealias RepairStale = @MainActor @Sendable () async -> Void

    private enum Kind { case verified, barrier }
    private struct FIFOCommand {
        let kind: Kind
        let payload: Payload
        let token: VerifiedSinkToken?
        let continuation: CheckedContinuation<ExternalSinkPublicationResult, Error>
    }
    private struct LiveCommand {
        let payload: Payload
        let token: VerifiedSinkToken?
    }

    private let validate: Validate
    private let perform: Perform
    private let repairStale: RepairStale
    private var fifo: [FIFOCommand] = []
    private var pendingLive: LiveCommand?
    private var liveSubmissionsSuspended = false
    private var worker: Task<Void, Never>?

    public init(
        validate: @escaping Validate,
        perform: @escaping Perform,
        repairStale: @escaping RepairStale
    ) {
        self.validate = validate
        self.perform = perform
        self.repairStale = repairStale
    }

    /// Health-bearing live updates should capture the current sink token. A nil
    /// token is reserved for connection-only/disconnect state and barriers.
    public func submitLive(_ payload: Payload, token: VerifiedSinkToken?) {
        guard !liveSubmissionsSuspended else { return }
        pendingLive = LiveCommand(payload: payload, token: token)
        startIfNeeded()
    }

    public func submitVerified(
        _ payload: Payload,
        token: VerifiedSinkToken
    ) async throws -> ExternalSinkPublicationResult {
        try await withCheckedThrowingContinuation { continuation in
            fifo.append(FIFOCommand(
                kind: .verified,
                payload: payload,
                token: token,
                continuation: continuation
            ))
            startIfNeeded()
        }
    }

    /// Used by end/disconnect/source-transition operations. A barrier invalidates
    /// every older coalesced live payload before entering FIFO. Source transitions
    /// may suspend later live submissions until the replacement sink is active.
    public func submitBarrier(
        _ payload: Payload,
        suspendLive: Bool = false
    ) async throws -> ExternalSinkPublicationResult {
        pendingLive = nil
        if suspendLive { liveSubmissionsSuspended = true }
        return try await withCheckedThrowingContinuation { continuation in
            fifo.append(FIFOCommand(
                kind: .barrier,
                payload: payload,
                token: nil,
                continuation: continuation
            ))
            startIfNeeded()
        }
    }

    public func suspendLiveSubmissions() {
        liveSubmissionsSuspended = true
        pendingLive = nil
    }

    public func resumeLiveSubmissions() {
        liveSubmissionsSuspended = false
    }

    public func cancelPendingLive() {
        pendingLive = nil
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled {
            if !fifo.isEmpty {
                let command = fifo.removeFirst()
                await executeFIFO(command)
                continue
            }
            if let live = pendingLive, !liveSubmissionsSuspended {
                pendingLive = nil
                _ = try? await execute(
                    payload: live.payload,
                    token: live.token,
                    isBarrier: false
                )
                continue
            }
            break
        }
        worker = nil
        // No suspension between the empty check and clearing worker. A command
        // arriving afterward observes nil and starts the next worker.
        if !fifo.isEmpty || (pendingLive != nil && !liveSubmissionsSuspended) {
            startIfNeeded()
        }
    }

    private func executeFIFO(_ command: FIFOCommand) async {
        do {
            let result = try await execute(
                payload: command.payload,
                token: command.token,
                isBarrier: command.kind == .barrier
            )
            command.continuation.resume(returning: result)
        } catch {
            command.continuation.resume(throwing: error)
        }
    }

    private func execute(
        payload: Payload,
        token: VerifiedSinkToken?,
        isBarrier: Bool
    ) async throws -> ExternalSinkPublicationResult {
        if let token, !validate(token) {
            await repairStale()
            return .superseded
        }
        let result = try await perform(payload, token)
        if let token, !validate(token) {
            // ActivityKit may already have accepted the stale state during the
            // await. Repair immediately instead of merely returning superseded.
            await repairStale()
            return .superseded
        }
        return result
    }
}
