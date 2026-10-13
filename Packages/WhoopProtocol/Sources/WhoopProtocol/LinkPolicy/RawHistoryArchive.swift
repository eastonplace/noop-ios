import Foundation

/// Append-only on-disk archive of HISTORICAL_DATA record frames that FAILED decode (#77 / #91).
///
/// The strap frees acked history the instant we send HISTORICAL_DATA_RESULT. On an unmapped
/// firmware layout the Backfiller decodes those records to zero rows, yet still has to ack the trim
/// (refusing would wedge the whole offload on a re-send loop). Without somewhere to put the raw
/// bytes first, every undecodable record is gone forever while the UI shows a healthy "History
/// synced". This archive is the user's only remaining copy — and the corpus a later layout mapping
/// re-ingests.
///
/// Format: newline-delimited JSON, one object per line, fsynced before returning so the bytes are
/// durable BEFORE the trim ack deletes the strap's copy (the whole point):
///   {"capturedAtMs":Double,"trim":Int,"family":"whoop4"|"whoop5","version":Int,"frameHex":String}
/// `version` (BLE-5) is the hist_version byte, stored so retention never has to hex-decode a frame;
/// lines written before it existed are still read (their version is derived from `frameHex`). Frames
/// carry sensor payloads, not identifiers — no serials/MACs land here.
///
/// BLE-5: an actor, so the durable write runs off the main actor (the Backfiller awaits it before the
/// ACK), and the cap is enforced by rotating two segment files instead of reading, re-deriving and
/// rewriting the whole 5 MB file on every chunk once it was full. Appends go to the active segment
/// (`rejected_history.jsonl`, the original file name, so existing archives carry over). When it would
/// pass `maxBytes` it becomes the previous segment (`rejected_history.prev.jsonl`), and only the segment
/// it replaces is evicted, except its per-version floor lines.
///
/// Retention: each segment holds up to `maxBytes`, so the newest `maxBytes` of records are always kept
/// (never less than the single-file evictor this replaced) and the disk use is bounded at about twice
/// that plus the floor lines. Every eviction is reported in `Result.written(evicted:)` so the caller can
/// log it loudly: these are records the strap has already deleted.
public actor RawHistoryArchive {
    /// Active segment file name under `<AppSupport>/com.noopapp.noop/` (the pre-rotation file name).
    public static let fileName = "rejected_history.jsonl"
    /// The previous (older) segment.
    public static let previousFileName = "rejected_history.prev.jsonl"
    /// Guaranteed retention (~5 MB): the newest `maxBytes` of archived records always survive. Each
    /// segment holds up to this much, so the files total at most about twice it plus the floor lines.
    /// Only a batch that can't fit even an empty segment is skipped (reported as unarchived). (#344)
    public static let maxBytes = 5 * 1024 * 1024

    /// Per distinct layout VERSION, keep at least this many of the newest archived lines, immune to
    /// rotation. A never-seen version (WHOOP 4 v19, WHOOP 5 v20/v21 — `frame[5]` / `frame[9]`, the
    /// hist_version byte) emits only a handful of frames, so this floor guarantees those rare samples
    /// survive while the most-populous versions shed their oldest surplus. Bounded: the floor can hold at
    /// most `floor × distinctVersions` lines, a tiny set. (#344)
    public static let perVersionFloor = 64

    /// Outcome of an archive attempt.
    public enum Result: Equatable, Sendable {
        /// Frames were durably written (fsynced). `count` is how many lines were appended; `evicted` is
        /// how many of the oldest archived lines a rotation dropped to make room (log it: the strap no
        /// longer has those records).
        case written(count: Int, evicted: Int = 0)
        /// The archive is full; nothing was written but the caller may still ack. `count` frames
        /// were dropped (counted as unarchived so the sync status never claims "saved").
        case capReached(count: Int)
        /// The write genuinely failed. The caller must NOT ack — hold the cursor so the strap
        /// re-sends the chunk (no data loss either way). `evicted` is non-zero when a rotation had
        /// already dropped old lines before the failure: those are gone even though this write failed.
        case failed(evicted: Int = 0)
    }

    private let directory: URL
    /// Effective cap/floor; default to the static constants but overridable so tests can drive the
    /// rotation path with a small archive instead of generating 5 MB of frames. (#344)
    private let maxBytes: Int
    private let perVersionFloor: Int

    /// Default location: `<AppSupport>/com.noopapp.noop/`, created on demand. Overridable for tests.
    public init(directory: URL? = nil,
                maxBytes: Int = RawHistoryArchive.maxBytes,
                perVersionFloor: Int = RawHistoryArchive.perVersionFloor) {
        if let directory {
            self.directory = directory
        } else {
            let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: true))
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            self.directory = base.appendingPathComponent("com.noopapp.noop", isDirectory: true)
        }
        self.maxBytes = maxBytes
        self.perVersionFloor = perVersionFloor
    }

    /// The active segment URL (does not create anything).
    public nonisolated var fileURL: URL { directory.appendingPathComponent(RawHistoryArchive.fileName) }
    /// The previous segment URL (does not create anything).
    public nonisolated var previousFileURL: URL {
        directory.appendingPathComponent(RawHistoryArchive.previousFileName)
    }

    private var segmentBytes: Int { max(1, maxBytes) }

    /// The hist_version byte distinguishing one historical layout from another: `frame[5]` on WHOOP 4,
    /// `frame[9]` on WHOOP 5/MG (the puffin envelope is 4 bytes longer). Same indices the reject filter
    /// uses. Frames too short to carry it fall back to a sentinel so they still form their own bucket.
    public static func versionByte(_ frame: [UInt8], family: DeviceFamily) -> Int {
        let idx = family == .whoop5 ? 9 : 5
        return frame.count > idx ? Int(frame[idx]) : -1
    }

    /// A per-version retention key. Family is part of the key so a WHOOP 4 v18 and a WHOOP 5 v18 are
    /// kept as distinct buckets (their layouts differ despite the shared version number).
    private struct VersionKey: Hashable { let family: String; let version: Int }

    /// Durably append `frames` as JSONL. `trim`/`family` tag each line so the corpus is replayable.
    /// Empty input is a no-op success. See `Result` for the ack contract.
    public func archive(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily) -> Result {
        guard !frames.isEmpty else { return .written(count: 0) }
        let capturedAtMs = Date().timeIntervalSince1970 * 1000
        // Hand-built JSON: the only dynamic strings are the family raw value and [0-9a-f] hex, so no
        // escaping is needed, and this avoids a JSONEncoder allocation per frame on the offload hot path.
        let newLines: [String] = frames.map { f in
            "{\"capturedAtMs\":\(capturedAtMs),\"trim\":\(Int(trim)),"
                + "\"family\":\"\(family.rawValue)\","
                + "\"version\":\(RawHistoryArchive.versionByte(f, family: family)),"
                + "\"frameHex\":\"\(lowercaseHex(f))\"}\n"
        }
        let incomingBytes = newLines.reduce(0) { $0 + $1.utf8.count }
        // The batch alone can't fit even an empty segment: nothing rotation frees makes room, so skip
        // it (the offload may still ack — by now there is ample sample material).
        guard incomingBytes <= segmentBytes else { return .capReached(count: frames.count) }
        // Once the previous segment is replaced its evicted lines are gone, so the count is reported
        // whatever fails after that (clearing the active segment, or the append itself).
        var evicted = 0
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let activeSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int)
                .flatMap { $0 } ?? 0
            if activeSize + incomingBytes > segmentBytes {
                evicted = try replacePreviousSegment()
                try clearActiveSegment()
            }
            try appendDurably(Data(newLines.joined().utf8), to: fileURL)
            return .written(count: frames.count, evicted: evicted)
        } catch {
            return .failed(evicted: evicted)
        }
    }

    /// Rotation, step 1: the active segment (up to `maxBytes`, the newest records) becomes the previous
    /// one, and only the segment it replaces, which is entirely older than `maxBytes` of newer records, is
    /// evicted. Its lines survive only while they are within the newest `perVersionFloor` lines of their
    /// version across both segments, so a rare layout is never binned by a flood of a common one. The new
    /// previous segment is written durably BEFORE the active one is cleared (step 2): a crash in between
    /// duplicates lines, never loses them. Returns how many lines were evicted. A line of the old previous
    /// segment that is also in the active one (that crash's duplicate) is not counted: its copy survives.
    private func replacePreviousSegment() throws -> Int {
        let older = Self.readLines(previousFileURL)
        let active = Self.readLines(fileURL)
        let protected = Self.protectedIndices(older + active, floor: perVersionFloor)
        let carried = older.indices.filter { protected.contains($0) }.map { older[$0] }
        try writeDurably(Data((carried + active).joined().utf8), to: previousFileURL)
        let stillOnDisk = Set(active)
        return older.indices.filter { !protected.contains($0) && !stillOnDisk.contains(older[$0]) }.count
    }

    /// Rotation, step 2: clear the active segment its lines were carried out of.
    private func clearActiveSegment() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Append `data` to `url`, fsyncing before returning so it is durable BEFORE the trim ack.
    private func appendDurably(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()   // durable BEFORE the ack — the point of the archive
        } else {
            try writeDurably(data, to: url)
        }
    }

    /// Write `data` to a temporary sibling, fsync it, then move it over `url`.
    private func writeDurably(_ data: Data, to url: URL) throws {
        let tmp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        let handle = try FileHandle(forWritingTo: tmp)
        try handle.synchronize()
        try handle.close()
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }

    private static func readLines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) + "\n" }
    }

    /// The `VersionKey` of one archived JSONL line: the stored `version` field when present (BLE-5), else
    /// re-derived from the stored frame for lines written before that field existed. `nil` for a
    /// malformed line — those get NO retention floor (evicted first, never occupying a floor slot a real
    /// rare version could use).
    private static func lineVersionKey(_ line: String) -> VersionKey? {
        guard let fr = line.range(of: "\"family\":\"") else { return nil }
        let fam = String(line[fr.upperBound...].prefix { $0 != "\"" })
        guard let family = DeviceFamily(rawValue: fam) else { return nil }
        if let vr = line.range(of: "\"version\":") {
            let digits = line[vr.upperBound...].prefix { $0 == "-" || $0.isNumber }
            if let version = Int(digits) { return VersionKey(family: fam, version: version) }
        }
        guard let hr = line.range(of: "\"frameHex\":\"") else { return nil }
        let hex = line[hr.upperBound...].prefix { $0 != "\"" }
        guard let bytes = decodeHex(hex) else { return nil }
        return VersionKey(family: fam, version: RawHistoryArchive.versionByte(bytes, family: family))
    }

    private static func decodeHex(_ hex: Substring) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2); var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b); i = j
        }
        return bytes
    }

    /// Indices of the newest `floor` lines of each version (scan newest→oldest). Malformed lines (nil
    /// key) are never protected.
    private static func protectedIndices(_ lines: [String], floor: Int) -> Set<Int> {
        var protectedIdx = Set<Int>()
        var seen: [VersionKey: Int] = [:]
        for idx in lines.indices.reversed() {
            guard let k = lineVersionKey(lines[idx]) else { continue }
            let c = seen[k] ?? 0
            if c < floor { protectedIdx.insert(idx); seen[k] = c + 1 }
        }
        return protectedIdx
    }

    /// Floor-aware cap eviction (#344), PURE so it is unit-testable. `lines` is the full
    /// newline-terminated JSONL set, oldest-first. Drops oldest SURPLUS lines until the UTF-8 byte total
    /// fits `maxBytes`, but NEVER a line within the newest `floor` lines of its version. Bounded: if
    /// everything left is floor-protected it stops even if still over cap (the floor wins). Mirrors the
    /// Android RawHistoryArchive.evictLines; the iOS archive itself now bounds size by segment rotation.
    public static func evictLines(_ lines: [String], maxBytes: Int, floor: Int) -> [String] {
        let protectedIdx = protectedIndices(lines, floor: floor)
        var total = lines.reduce(0) { $0 + $1.utf8.count }
        guard total > maxBytes else { return lines }
        var dropped = Set<Int>()
        for idx in lines.indices where total > maxBytes {   // ascending = oldest first
            if protectedIdx.contains(idx) { continue }
            dropped.insert(idx)
            total -= lines[idx].utf8.count
        }
        return lines.enumerated().filter { !dropped.contains($0.offset) }.map(\.element)
    }

    /// Every archived frame with its strap family, oldest first (previous segment, then active). Malformed
    /// lines are skipped; absent/empty files yield []. Hand-parsed to match the hand-built writer.
    public func readAll() -> [(frame: [UInt8], family: DeviceFamily)] {
        (Self.readLines(previousFileURL) + Self.readLines(fileURL)).compactMap { line in
            guard let fr = line.range(of: "\"family\":\""),
                  let hr = line.range(of: "\"frameHex\":\"") else { return nil }
            let fam = String(line[fr.upperBound...].prefix { $0 != "\"" })
            let hex = line[hr.upperBound...].prefix { $0 != "\"" }
            guard let family = DeviceFamily(rawValue: fam), let bytes = Self.decodeHex(hex) else { return nil }
            return (bytes, family)
        }
    }

    /// Bytes on disk across both segments.
    public func totalBytes() -> Int {
        [fileURL, previousFileURL].reduce(0) { sum, url in
            sum + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0)
        }
    }

    /// Re-decode every archived frame through the CURRENT decoder and hand whatever now decodes to
    /// `insert`, which returns the rows it ACTUALLY inserted. The strap freed these records when they
    /// were acked, so this archive is the ONLY way banked history backfills after a newly-landed layout
    /// (e.g. WHOOP 4.0 v25). Idempotent when `insert` dedupes by (deviceId, ts), so a re-run can't
    /// double-insert. Returns rows recovered (for logging). Rethrows an insert failure — the caller MUST
    /// NOT advance the replay gate in that case, or these records (whose only surviving copy is this
    /// archive) would never be retried. (#152)
    ///
    /// `subLagInterp` threads the opt-in HR-from-PPG sub-lag interpolation flag (Test Centre →
    /// Experimental algorithms) so the replay re-derives v26 HR with the same variant the live offload
    /// uses. The caller owns that setting; this package stays free of app preferences.
    @discardableResult
    public func replay(subLagInterp: Bool,
                       insert: @Sendable (Streams) async throws -> Int) async throws -> Int {
        let archived = readAll()
        var rows = 0
        for family in Set(archived.map(\.family)) {
            let parsed = archived.filter { $0.family == family }.map { parseFrame($0.frame, family: family) }
            // type-47 records carry their own real-unix ts (clock offset ignored), so an identity
            // clock ref is correct here — the same fallback the Backfiller uses when clockRef is nil.
            let streams = extractHistoricalStreams(parsed, family: family, deviceClockRef: 0, wallClockRef: 0,
                                                   subLagInterp: subLagInterp)
            // Count rows ACTUALLY inserted, not decoded: under the replay gate the archive replays on
            // every gate change, and dedupe makes those re-runs insert 0 — counting decoded rows would
            // log a false "retro-decoded N" success. (#152)
            rows += try await insert(streams)
        }
        return rows
    }
}
