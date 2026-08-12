import Foundation

public struct WidgetEnrichmentKey: Hashable, Sendable {
    public let epoch: UInt64
    public let contextId: String
    public let generation: Int64

    public init(epoch: UInt64, contextId: String, generation: Int64) {
        self.epoch = epoch
        self.contextId = contextId
        self.generation = generation
    }
}

/// Optional enrichment is single-flight and generation-fenced. It never
/// participates in durable Widget outbox acknowledgement.
public actor WidgetEnrichmentCoordinator {
    public typealias Operation = @Sendable (WidgetEnrichmentKey) async throws -> Void

    private let defaultOperation: Operation?
    private let minimumInterval: TimeInterval
    private var task: Task<Void, Never>?
    private var activeKey: WidgetEnrichmentKey?
    private var completedAt: [WidgetEnrichmentKey: Date] = [:]

    public init(
        minimumInterval: TimeInterval = 15 * 60,
        operation: Operation? = nil
    ) {
        self.minimumInterval = max(60, minimumInterval)
        self.defaultOperation = operation
    }

    public func schedule(
        key: WidgetEnrichmentKey,
        now: Date = Date(),
        operation: Operation? = nil
    ) {
        if activeKey == key, task != nil { return }
        if let completed = completedAt[key],
           now.timeIntervalSince(completed) < minimumInterval {
            return
        }

        task?.cancel()
        activeKey = key
        guard let operation = operation ?? defaultOperation else {
            activeKey = nil
            return
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await operation(key)
                try Task.checkCancellation()
                await self.noteCompleted(key: key, at: Date())
            } catch {
                // Optional enrichment remains retryable on the next bounded signal.
            }
            await self.finish(key: key)
        }
    }

    public func cancelAndWait() async {
        guard let task else { return }
        task.cancel()
        await task.value
        self.task = nil
        activeKey = nil
    }

    private func noteCompleted(key: WidgetEnrichmentKey, at date: Date) {
        completedAt[key] = date
        if completedAt.count > 16 {
            let newest = completedAt.sorted { $0.value > $1.value }.prefix(8)
            completedAt = Dictionary(uniqueKeysWithValues: newest.map { (key: $0.key, value: $0.value) })
        }
    }

    private func finish(key: WidgetEnrichmentKey) {
        guard activeKey == key else { return }
        task = nil
        activeKey = nil
    }
}

/*
WidgetPublish integration:

- Create one coordinator at the iOS composition root.
- After `WidgetVerifiedEnvelopeStore.commit` returns `.published` or
  `.alreadyCurrent`, call `schedule` with the exact active epoch/context/generation.
- Do not schedule from the high-frequency live lane.
- Source transition quiescence calls `cancelAndWait()`.
- The operation revalidates the active token before and after each await.
- HRV reads are exact trailing 12–30 daily points, not `exploreSeries` full history.
- Stress reads a persisted hourly/current-day aggregate. Until that aggregate
  exists, cap the current-day raw query and run it no more than once per TTL.
- Save enrichment only when rendered enrichment changed; the verified core
  identity never changes.
*/
