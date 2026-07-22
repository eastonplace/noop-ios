import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Serial background owner for the durable strap-log tail. `LiveState` keeps the visible log immediate on
/// MainActor; this object stores the durable suffix in an O(1) ring and batches UserDefaults writes.
final class DebouncedLogTailPersistence: @unchecked Sendable {
    typealias Persist = @Sendable ([String]) -> Void

    private struct Ring {
        private var storage: [String?]
        private var start = 0
        private(set) var count = 0

        init(capacity: Int, initial: [String]) {
            storage = Array(repeating: nil, count: max(0, capacity))
            guard !storage.isEmpty else { return }
            for value in initial.suffix(storage.count) { append(value) }
        }

        mutating func append(_ value: String) {
            guard !storage.isEmpty else { return }
            if count < storage.count {
                storage[(start + count) % storage.count] = value
                count += 1
            } else {
                storage[start] = value
                start = (start + 1) % storage.count
            }
        }

        mutating func removeAll() {
            storage = Array(repeating: nil, count: storage.count)
            start = 0
            count = 0
        }

        func snapshot() -> [String] {
            guard count > 0 else { return [] }
            var result: [String] = []
            result.reserveCapacity(count)
            for offset in 0..<count {
                if let value = storage[(start + offset) % storage.count] {
                    result.append(value)
                }
            }
            return result
        }
    }

    private let queue = DispatchQueue(label: "com.noopapp.strap-log-persistence", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let debounceInterval: TimeInterval
    private let tailLimit: Int
    private let loadPersisted: @Sendable () -> [String]
    private let persist: Persist

    private var ring: Ring?
    private var pendingWork: DispatchWorkItem?
    private var revision: UInt64 = 0
    private var isDirty = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    #if DEBUG
    private var debugWrites = 0
    #endif

    init(
        debounceInterval: TimeInterval = 3,
        tailLimit: Int,
        loadPersisted: @escaping @Sendable () -> [String],
        persist: @escaping Persist
    ) {
        self.debounceInterval = max(0, debounceInterval)
        self.tailLimit = max(0, tailLimit)
        self.loadPersisted = loadPersisted
        self.persist = persist
        queue.setSpecific(key: queueKey, value: 1)
        registerLifecycleObservers()
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingWork?.cancel()
    }

    func append(_ line: String) {
        queue.async { [self] in
            loadIfNeeded()
            ring?.append(line)
            isDirty = true
            scheduleWriteIfNeeded()
        }
    }

    func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                flushOnQueue()
                continuation.resume()
            }
        }
    }

    /// Termination-only barrier. Normal lifecycle paths use async `flush()`.
    @discardableResult
    func flushSync(timeout: TimeInterval = 1) -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            flushOnQueue()
            return true
        }
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [self] in
            flushOnQueue()
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + max(0, timeout)) == .success
    }

    func clear() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                revision &+= 1
                pendingWork?.cancel()
                pendingWork = nil
                loadIfNeeded()
                ring?.removeAll()
                isDirty = true
                persistCurrentTail()
                continuation.resume()
            }
        }
    }

    #if DEBUG
    func writeCountForTesting() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.debugWrites) }
        }
    }

    func tailForTesting() async -> [String] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                loadIfNeeded()
                continuation.resume(returning: ring?.snapshot() ?? [])
            }
        }
    }
    #endif

    private func registerLifecycleObservers() {
        #if os(iOS)
        let names: [Notification.Name] = [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification,
        ]
        #elseif os(macOS)
        let names: [Notification.Name] = [
            NSApplication.didResignActiveNotification,
            NSApplication.willTerminateNotification,
        ]
        #else
        let names: [Notification.Name] = []
        #endif

        for name in names {
            lifecycleObservers.append(NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.flushOnQueue() }
            })
        }
    }

    private func loadIfNeeded() {
        guard ring == nil else { return }
        ring = Ring(capacity: tailLimit, initial: loadPersisted())
    }

    private func scheduleWriteIfNeeded() {
        guard pendingWork == nil else { return }
        revision &+= 1
        let scheduledRevision = revision
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.revision == scheduledRevision else { return }
            self.pendingWork = nil
            self.persistCurrentTail()
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func flushOnQueue() {
        loadIfNeeded()
        revision &+= 1
        pendingWork?.cancel()
        pendingWork = nil
        persistCurrentTail()
    }

    private func persistCurrentTail() {
        guard isDirty else { return }
        persist(ring?.snapshot() ?? [])
        isDirty = false
        #if DEBUG
        debugWrites += 1
        #endif
    }
}
