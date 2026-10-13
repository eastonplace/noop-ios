import Foundation

/// Thrown by a persist closure when the store is not available yet, so the sink retries it.
public struct SinkUnavailableError: Error, Sendable {
    public init() {}
}

/// BLE-6: ordered, retrying persistence for the non-WHOOP live sources (Oura, generic HR, Huami).
///
/// Those sources used to hand every buffered sample to a fire-and-forget `Task { try? insert }`: a failed
/// insert vanished silently, and the Oura history cursor was saved the moment a page arrived, before its
/// events were written, so a failed or interrupted write left a permanent gap. Now batches are written
/// strictly in submission order, each with bounded retry, and a commit action (the Oura cursor save) runs
/// only when its batches and every batch submitted before them were written.
@MainActor
public final class BatchedRetryingSink<Batch> {
    public typealias Insert = @MainActor (Batch) async throws -> Void
    public typealias Sleep = @MainActor (UInt64) async -> Void

    public nonisolated static var defaultRetryDelaysNanoseconds: [UInt64] { [500_000_000, 2_000_000_000] }

    private let insert: Insert
    private let retryDelaysNanoseconds: [UInt64]
    private let sleep: Sleep
    private var tail: Task<Bool, Never>?
    private var ignoreEarlierFailure = false
    public private(set) var droppedBatches = 0

    /// `retryDelaysNanoseconds` are the waits between attempts, so a batch gets `count + 1` attempts.
    public init(retryDelaysNanoseconds: [UInt64] = BatchedRetryingSink.defaultRetryDelaysNanoseconds,
                sleep: Sleep? = nil,
                insert: @escaping Insert) {
        self.insert = insert
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
        self.sleep = sleep ?? { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) }
    }

    /// Queue `batches` behind everything submitted earlier. `onCommitted` runs only when these batches and
    /// every earlier batch (since the last `startNewSession()`) were written; `onFailed` gets the number of
    /// batches dropped after their retries ran out. The returned task resolves to that same verdict.
    @discardableResult
    public func submit(_ batches: [Batch],
                       onCommitted: (@MainActor () -> Void)? = nil,
                       onFailed: (@MainActor (Int) -> Void)? = nil) -> Task<Bool, Never> {
        let previous = tail
        let ignorePrior = ignoreEarlierFailure
        ignoreEarlierFailure = false
        let task = Task { @MainActor [self] in
            let priorOK = await previous?.value ?? true
            var dropped = 0
            for batch in batches where !(await write(batch)) { dropped += 1 }
            if dropped > 0 {
                droppedBatches += dropped
                onFailed?(dropped)
            }
            let committed = dropped == 0 && (priorOK || ignorePrior)
            if committed { onCommitted?() }
            return committed
        }
        tail = task
        return task
    }

    /// Resolves once everything submitted so far has been attempted; true when all of it committed.
    public func drain() async -> Bool {
        await tail?.value ?? true
    }

    /// A new session reloads its durable cursor, so an earlier session's dropped batch must no longer
    /// block this session's commits. Ordering is kept: new batches still wait for the old ones.
    public func startNewSession() {
        ignoreEarlierFailure = true
    }

    private func write(_ batch: Batch) async -> Bool {
        var attempt = 0
        while true {
            do {
                try await insert(batch)
                return true
            } catch {
                guard attempt < retryDelaysNanoseconds.count else { return false }
                await sleep(retryDelaysNanoseconds[attempt])
                attempt += 1
            }
        }
    }
}
