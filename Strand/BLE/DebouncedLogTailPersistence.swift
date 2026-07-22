import Foundation
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Serial background owner for the durable strap-log tail. `LiveState` keeps UI updates immediate; this
/// object maintains its own bounded tail and batches UserDefaults work after a quiet period.
final class DebouncedLogTailPersistence: @unchecked Sendable {
    typealias Persist = @Sendable ([String]) -> Void

    private let queue = DispatchQueue(label: "com.noopapp.strap-log-persistence", qos: .utility)
    private let debounceInterval: TimeInterval
    private let tailLimit: Int
    private let loadPersisted: @Sendable () -> [String]
    private let persist: Persist

    private var tail: [String]?
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
        registerLifecycleObservers()
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
        pendingWork?.cancel()
    }

    func append(_ line: String) {
        queue.async { [self] in
            loadIfNeeded()
            tail?.append(line)
            boundTail()
            isDirty = true
            scheduleWrite()
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

    func clear() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                revision &+= 1
                pendingWork?.cancel()
                pendingWork = nil
                tail = []
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
                queue.async { self.flushOnQueue() }
            })
        }
    }

    private func flushOnQueue() {
        loadIfNeeded()
        revision &+= 1
        pendingWork?.cancel()
        pendingWork = nil
        persistCurrentTail()
    }

    private func loadIfNeeded() {
        guard tail == nil else { return }
        tail = loadPersisted()
        boundTail()
    }

    private func boundTail() {
        guard let tail else { return }
        if tailLimit == 0 {
            self.tail = []
        } else if tail.count > tailLimit {
            self.tail = Array(tail.suffix(tailLimit))
        }
    }

    private func scheduleWrite() {
        revision &+= 1
        let scheduledRevision = revision
        pendingWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, revision == scheduledRevision else { return }
            pendingWork = nil
            persistCurrentTail()
        }
        pendingWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    private func persistCurrentTail() {
        guard isDirty else { return }
        persist(tail ?? [])
        isDirty = false
        #if DEBUG
        debugWrites += 1
        #endif
    }
}
