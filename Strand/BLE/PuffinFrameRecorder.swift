import Foundation
import CoreBluetooth
import WhoopProtocol
#if os(iOS)
import UIKit
#endif

/// An owned input batch crosses to the serial capture owner; LiveState and CoreBluetooth never do.
struct PuffinCapturedFrame: Sendable {
    let frame: [UInt8]
    let characteristic: String
    let timestampMs: Int
    let heartRate: Int?
}

/// Owns the cumulative capture and all parsing, JSON encoding, filesystem work and eviction. The
/// session remains untrimmed, as before. A write retains one encoded record rather than another
/// encoded copy of the complete session, and commits a complete sibling file with one atomic rename.
actor PuffinCaptureFileStore {
    private let buffer = PuffinCapture()
    private let directory: URL?
    private var fileURL: URL?
    private static let directorySoftCapBytes = 50 * 1024 * 1024

    init(directory: URL? = nil) { self.directory = directory }

    func persist(_ frames: [PuffinCapturedFrame]) throws -> URL? {
        for frame in frames {
            buffer.record(frame: frame.frame, char: frame.characteristic,
                          tsMs: frame.timestampMs, hr: frame.heartRate)
        }
        guard buffer.count > 0 else { return nil }
        let url = try sessionFileURL()
        let partial = url.deletingLastPathComponent().appendingPathComponent(".puffin-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: partial) }
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try output.write(contentsOf: Data("[\n".utf8))
        for (index, record) in buffer.records.enumerated() {
            try autoreleasepool {
                if index > 0 { try output.write(contentsOf: Data(",\n".utf8)) }
                // JSONEncoder indents each element of a pretty-printed array by two spaces. Keep its
                // record encoding and formatting flags, including omitted nils and slash escaping.
                let encoded = try encoder.encode(record)
                let object = String(decoding: encoded, as: UTF8.self)
                let indented = "  " + object.replacingOccurrences(of: "\n", with: "\n  ")
                try output.write(contentsOf: Data(indented.utf8))
            }
        }
        try output.write(contentsOf: Data("\n]".utf8))
        try output.close()
        try FileExport.installStagedFile(partial, at: url)
        evictOldCaptures(keeping: url)
        return url
    }

    private func sessionFileURL() throws -> URL {
        let fm = FileManager.default
        let dir: URL
        if let directory { dir = directory }
        else {
            dir = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                             appropriateFor: nil, create: true)
                .appendingPathComponent("OpenWhoop", isDirectory: true)
                .appendingPathComponent("puffin-captures", isDirectory: true)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let fileURL { return fileURL }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("puffin-\(formatter.string(from: Date())).json")
        fileURL = url
        return url
    }

    private func evictOldCaptures(keeping keep: URL) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: keep.deletingLastPathComponent(), includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return }
        let files = entries.filter { $0.pathExtension == "json" }
            .map { (url: $0, size: (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
        var total = files.reduce(0) { $0 + $1.size }
        for file in files {
            guard total > Self.directorySoftCapBytes else { break }
            if file.url == keep { continue }
            do { try fm.removeItem(at: file.url); total -= file.size }
            catch { /* The next successful flush retries eviction. */ }
        }
    }
}

/// MainActor only captures cheap session metadata and publishes progress. One drain task owns an IO
/// batch; later frames append to one pending batch, never replacing accepted content. No task is
/// created per frame. The opt-in session has no new size cap or record-drop policy.
@MainActor
final class PuffinFrameRecorder {
    static let enabledKey = "noopPuffinCapture"
    private static let flushEvery = 25
    private weak var state: LiveState?
    private let enabled: @MainActor () -> Bool
    private let persist: @Sendable ([PuffinCapturedFrame]) async -> URL?
    private var pending: [PuffinCapturedFrame] = []
    private var count = 0
    private var sinceFlush = 0
    private var flushRequested = false
    private var drain: Task<Void, Never>?
    private var requestedRevision = 0
    private var completedRevision = 0
    private var barriers: [(revision: Int, continuation: CheckedContinuation<Void, Never>)] = []
    #if os(iOS)
    private var backgroundObserver: NSObjectProtocol?
    private var backgroundFlush = BackgroundFlushOwnership<UIBackgroundTaskIdentifier>()
    #endif

    init(state: LiveState, enabled: @escaping @MainActor () -> Bool = {
        UserDefaults.standard.bool(forKey: PuffinFrameRecorder.enabledKey)
    }, persist: (@Sendable ([PuffinCapturedFrame]) async -> URL?)? = nil) {
        self.state = state
        self.enabled = enabled
        if let persist { self.persist = persist }
        else {
            let store = PuffinCaptureFileStore()
            self.persist = { frames in try? await store.persist(frames) }
        }
        #if os(iOS)
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.flushBeforeBackground() } }
        #endif
    }

    deinit {
        #if os(iOS)
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
        #endif
    }

    func capture(frame: [UInt8], char: CBUUID) {
        guard enabled() else { return }
        pending.append(PuffinCapturedFrame(frame: frame, characteristic: char.uuidString.lowercased(),
                                          timestampMs: Int(Date().timeIntervalSince1970 * 1000), heartRate: state?.heartRate))
        count += 1
        sinceFlush += 1
        state?.puffinCaptureCount = count
        if sinceFlush >= Self.flushEvery { flush() }
    }

    /// Periodic/disconnect flush request. It never blocks MainActor. Failures retain all records in the
    /// serial store so the next request can retry the complete session, preserving the prior best-effort policy.
    func flush() {
        guard count > 0 else { return }
        sinceFlush = 0
        requestedRevision += 1
        flushRequested = true
        guard drain == nil else { return }
        drain = Task { @MainActor in
            while flushRequested {
                flushRequested = false
                let batch = pending
                pending = []
                let revision = requestedRevision
                let url = await persist(batch)
                if let url { state?.puffinCaptureURL = url }
                completedRevision = revision
                let ready = barriers.filter { $0.revision <= revision }
                barriers.removeAll { $0.revision <= revision }
                ready.forEach { $0.continuation.resume() }
            }
            drain = nil
        }
    }

    /// An export waits for every preceding accepted frame's write attempt, even when it arrived while
    /// an earlier batch was writing. Later frames cannot postpone this barrier indefinitely.
    func flushAndWait() async {
        flush()
        let revision = requestedRevision
        guard completedRevision < revision else { return }
        await withCheckedContinuation { barriers.append((revision, $0)) }
    }

    #if os(iOS)
    private func flushBeforeBackground() {
        guard count > 0, let token = backgroundFlush.reserve() else { return }
        let identifier = UIApplication.shared.beginBackgroundTask(withName: "Capture save") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask(token) }
        }
        if identifier == .invalid { _ = backgroundFlush.finish(token) }
        else { backgroundFlush.assign(identifier, to: token) }
        Task { [weak self] in
            guard let self else { return }
            await flushAndWait()
            endBackgroundTask(token)
        }
    }

    private func endBackgroundTask(_ token: UUID) {
        guard let identifier = backgroundFlush.finish(token), identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
    }
    #endif
}
