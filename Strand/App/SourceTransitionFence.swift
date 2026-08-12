import Foundation

/// Serializes source-lineage changes and the sink invalidation that surrounds them.
///
/// Registry publishers, BLE callbacks, foreground recovery, and device actions can all arrive at the
/// same time. A transition must finish its old-scope retirement and latest-state invalidation before the
/// next source is allowed to publish. The operation itself runs on the main actor because it owns the
/// Repository and live-source composition objects.
@MainActor
final class SourceTransitionFence {
    private var tail: Task<Void, Never>?
    private var pendingRunCount = 0
    private var executing = false
    private var queuedSynchronousOperations: [() -> Void] = []

    /// Run a source transition immediately when no durable transition is open. If a durable transition is
    /// waiting on SQLite, defer the live-source callback until its cleanup boundary completes.
    func runSync(_ operation: @escaping () -> Void) {
        if executing || pendingRunCount > 0 {
            queuedSynchronousOperations.append(operation)
        } else {
            operation()
        }
    }

    func run(_ operation: @escaping () async -> Void) async {
        // Increment before creating the task. Task scheduling is cooperative, so a synchronous BLE/UI
        // callback can arrive in the gap before the task reaches its body. The callback must see this
        // pending transition and queue behind it instead of racing the old-scope cleanup.
        pendingRunCount += 1
        let previous = tail
        let current = Task { @MainActor in
            await previous?.value
            executing = true
            await operation()
            pendingRunCount -= 1
            executing = false
            if pendingRunCount == 0 {
                let queued = queuedSynchronousOperations
                queuedSynchronousOperations.removeAll(keepingCapacity: true)
                for operation in queued {
                    operation()
                }
            }
        }
        tail = current
        await current.value
    }

    /// Throwing variant for durable source transitions. The queued operation remains serialized with BLE and
    /// UI callbacks, but its failure is returned to the caller so the registry cannot advance fail-open.
    func runThrowing<T: Sendable>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        pendingRunCount += 1
        let previous = tail
        let current = Task { @MainActor () throws -> T in
            await previous?.value
            executing = true
            defer {
                pendingRunCount -= 1
                executing = false
                if pendingRunCount == 0 {
                    let queued = queuedSynchronousOperations
                    queuedSynchronousOperations.removeAll(keepingCapacity: true)
                    for operation in queued { operation() }
                }
            }
            return try await operation()
        }
        tail = Task { @MainActor in _ = try? await current.value }
        return try await current.value
    }
}
