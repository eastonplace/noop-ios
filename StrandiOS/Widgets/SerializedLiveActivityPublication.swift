#if os(iOS)
import Foundation
import NoopPhase34Core

/// One FIFO owns every ActivityKit await. Live commands coalesce to the newest state, while durable verified
/// commands stay ordered and are always drained before a pending live command.
@MainActor
final class SerializedLiveActivityPublication<Payload: Sendable> {
    typealias Perform = @MainActor (Payload, VerifiedSinkToken?) async throws -> ExternalSinkPublicationResult
    typealias ValidateToken = @MainActor (VerifiedSinkToken) -> Bool

    private struct VerifiedCommand {
        let payload: Payload
        let token: VerifiedSinkToken
        let continuation: CheckedContinuation<ExternalSinkPublicationResult, Error>
    }

    private let perform: Perform
    private let validateToken: ValidateToken
    private var pendingLive: Payload?
    private var liveWaiters: [CheckedContinuation<Void, Never>] = []
    private var verifiedQueue: [VerifiedCommand] = []
    private var worker: Task<Void, Never>?

    init(
        validateToken: @escaping ValidateToken,
        perform: @escaping Perform
    ) {
        self.validateToken = validateToken
        self.perform = perform
    }

    func submitLive(_ payload: Payload) {
        pendingLive = payload
        startIfNeeded()
    }

    func submitLiveAndWait(_ payload: Payload) async {
        await withCheckedContinuation { continuation in
            pendingLive = payload
            liveWaiters.append(continuation)
            startIfNeeded()
        }
    }

    func submitVerified(
        _ payload: Payload,
        token: VerifiedSinkToken
    ) async throws -> ExternalSinkPublicationResult {
        try await withCheckedThrowingContinuation { continuation in
            verifiedQueue.append(VerifiedCommand(
                payload: payload,
                token: token,
                continuation: continuation))
            startIfNeeded()
        }
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !Task.isCancelled {
            if !verifiedQueue.isEmpty {
                let command = verifiedQueue.removeFirst()
                guard validateToken(command.token) else {
                    command.continuation.resume(returning: .superseded)
                    continue
                }
                do {
                    let result = try await perform(command.payload, command.token)
                    let final = validateToken(command.token) ? result : .superseded
                    command.continuation.resume(returning: final)
                } catch {
                    command.continuation.resume(throwing: error)
                }
                continue
            }

            if let live = pendingLive {
                pendingLive = nil
                _ = try? await perform(live, nil)
                let waiters = liveWaiters
                liveWaiters.removeAll(keepingCapacity: true)
                waiters.forEach { $0.resume() }
                continue
            }
            break
        }
        worker = nil
        if pendingLive != nil || !verifiedQueue.isEmpty { startIfNeeded() }
    }
}
#endif
