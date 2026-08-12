import Foundation

/// Target-scoped ownership gate used before nonactive archive/privacy deletion.
/// Active-source transitions may still use the global epoch fence, but deleting
/// source A must wait for A's historical/HealthKit work without stopping source B.
public actor TargetScopedPipelineFence {
    /// One process-wide gate is shared by historical analysis, downstream publication, and source lifecycle
    /// commits. Separate instances would provide no mutual exclusion at the deletion boundary.
    public static let shared = TargetScopedPipelineFence()

    /// Quiesce is nestable because AppModel owns the outer transition fence while the store independently
    /// protects its transaction. An inner resume must never reopen admission before the outer owner finishes.
    private var blockDepthBySource: [String: Int] = [:]
    private var inFlightBySource: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func begin(sourceId: String) throws {
        let source = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, (blockDepthBySource[source] ?? 0) == 0 else {
            throw TargetScopedFenceError.blocked
        }
        inFlightBySource[source, default: 0] += 1
    }

    public func end(sourceId: String) {
        let source = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        let next = max(0, (inFlightBySource[source] ?? 0) - 1)
        if next == 0 {
            inFlightBySource.removeValue(forKey: source)
            let ready = waiters.removeValue(forKey: source) ?? []
            ready.forEach { $0.resume() }
        } else {
            inFlightBySource[source] = next
        }
    }

    /// Hold one source lease across an async operation. The lease is released before this method returns,
    /// including error paths, so a waiting privacy transition cannot race the final side effect.
    public func withLease<Value: Sendable>(
        sourceId: String,
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        try begin(sourceId: sourceId)
        do {
            let value = try await operation()
            end(sourceId: sourceId)
            return value
        } catch {
            end(sourceId: sourceId)
            throw error
        }
    }

    /// Acquire every source in one actor turn so a multi-source HealthKit write cannot partially enter while a
    /// privacy delete is blocking one namespace. Duplicates and empty ids are removed before ownership starts.
    public func withLeases<Value: Sendable>(
        sourceIds: [String],
        operation: @Sendable () async throws -> Value
    ) async throws -> Value {
        var seen = Set<String>()
        let sources = sourceIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        var acquired: [String] = []
        for source in sources {
            do {
                try begin(sourceId: source)
                acquired.append(source)
            } catch {
                acquired.forEach { end(sourceId: $0) }
                throw error
            }
        }
        do {
            let value = try await operation()
            sources.forEach { end(sourceId: $0) }
            return value
        } catch {
            sources.forEach { end(sourceId: $0) }
            throw error
        }
    }

    public func quiesce(sourceId: String) async {
        let source = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        blockDepthBySource[source, default: 0] += 1
        guard (inFlightBySource[source] ?? 0) > 0 else { return }
        await withCheckedContinuation { continuation in
            waiters[source, default: []].append(continuation)
        }
    }

    public func resume(sourceId: String) {
        let source = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, let depth = blockDepthBySource[source] else { return }
        if depth <= 1 {
            blockDepthBySource.removeValue(forKey: source)
        } else {
            blockDepthBySource[source] = depth - 1
        }
    }

    public func isBlocked(sourceId: String) -> Bool {
        (blockDepthBySource[sourceId.trimmingCharacters(in: .whitespacesAndNewlines)] ?? 0) > 0
    }
}

public enum TargetScopedFenceError: Error, Equatable, Sendable {
    case blocked
}
