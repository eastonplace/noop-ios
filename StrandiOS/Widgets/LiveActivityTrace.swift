#if os(iOS)
import Foundation

/// Where a Live Activity write came from, so a device trace shows which edge reached ActivityKit and which did not.
enum LiveActivityDriveSource: String, Sendable {
    case startEdge = "start-edge"
    case endEdge = "end-edge"
    case workoutHR = "workout-hr"
    case passiveHR = "hr"
    case connectivity
    case pauseEdge = "pause-edge"
    case timer
    case foreground
    case dayBoundary = "day-boundary"
    case projection
    case scoring
    case worker
    case lifecycle
}

/// The last `capacity` trace lines. A line that repeats the one before it is counted on that line instead of added, so a
/// heart-rate stream of identical writes cannot push the Start edge out of the window.
struct LiveActivityTraceLog: Equatable {
    static let maxLineLength = 240

    let capacity: Int
    private(set) var lines: [String]
    private var lastEntry: String?
    private var lastStartedAt = ""
    private var repeats = 0

    init(capacity: Int, lines: [String] = []) {
        self.capacity = max(1, capacity)
        self.lines = Array(lines.suffix(self.capacity))
    }

    /// Returns true when a new line was added, false when the last one only counted a repeat.
    @discardableResult
    mutating func record(_ entry: String, stamp: String) -> Bool {
        let entry = String(entry.prefix(Self.maxLineLength))
        if entry == lastEntry, !lines.isEmpty {
            repeats += 1
            lines[lines.count - 1] = "\(lastStartedAt) \(entry) x\(repeats + 1) until \(stamp)"
            return false
        }
        lastEntry = entry
        lastStartedAt = stamp
        repeats = 0
        lines.append("\(stamp) \(entry)")
        if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
        return true
    }
}

/// A small persistent trace of every Live Activity decision: one line per write with its source, mode, result and reason
/// (token state, superseded generation, suspended lane, Live Activities off, visibility off, request result). No health value
/// and no context identity is ever written. Kept in all configurations, bounded to `capacity` lines (well under 64 KB), and
/// written to the app container's `Library/Caches/live-activity-trace.log`, so it can be copied off a phone after a run.
@MainActor
final class LiveActivityTrace {
    static let fileName = "live-activity-trace.log"
    static let shared = LiveActivityTrace(
        fileURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(fileName))

    private let fileURL: URL?
    private var log: LiveActivityTraceLog
    private var unwrittenRepeats = 0

    init(fileURL: URL?, capacity: Int = 200) {
        self.fileURL = fileURL
        let previous = fileURL
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { $0.split(separator: "\n").map(String.init) } ?? []
        log = LiveActivityTraceLog(capacity: capacity, lines: previous)
        record("process start")
    }

    var lines: [String] { log.lines }

    func record(_ entry: String, at date: Date = Date()) {
        if log.record(entry, stamp: date.formatted(.iso8601)) {
            write()
        } else {
            // A repeat only bumps the count on the last line; write that now and then, not on every heart-rate tick.
            unwrittenRepeats += 1
            if unwrittenRepeats >= 30 { write() }
        }
    }

    private func write() {
        unwrittenRepeats = 0
        guard let fileURL else { return }
        try? (log.lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
#endif
