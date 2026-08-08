import Foundation

/// Target-scoped ownership gate used before nonactive archive/privacy deletion.
/// Active-source transitions may still use the global epoch fence, but deleting
/// source A must wait for A's historical/HealthKit work without stopping source B.
public actor TargetScopedPipelineFence {
    /// One process-wide gate is shared by historical analysis, downstream publication, and source lifecycle
    /// commits. Separate instances would provide no mutual exclusion at the deletion boundary.
    public static let shared = TargetScopedPipelineFence()

    private var blockedSources = Set<String>()
    private var inFlightBySource: [String: Int] = [:]
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    public init() {}

    public func begin(sourceId: String) throws {
        let source = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !blockedSources.contains(source) else {
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

    public func quiesce(sourceId: String) async {
        let source = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return }
        blockedSources.insert(source)
        guard (inFlightBySource[source] ?? 0) > 0 else { return }
        await withCheckedContinuation { continuation in
            waiters[source, default: []].append(continuation)
        }
    }

    public func resume(sourceId: String) {
        blockedSources.remove(sourceId.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func isBlocked(sourceId: String) -> Bool {
        blockedSources.contains(sourceId.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

public enum TargetScopedFenceError: Error, Equatable, Sendable {
    case blocked
}
