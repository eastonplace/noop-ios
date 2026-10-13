import XCTest
import WhoopProtocol

/// BLE-5: once full, the reject archive used to read, re-derive (hex-decoding every line) and atomically
/// rewrite the whole 5 MB file on every chunk, on the main actor. It now appends to an active segment and
/// rotates between two segments, carrying only the per-version floor lines, with the version stored as
/// its own field.
final class RawHistoryArchiveRotationTests: XCTestCase {

    private func tmpDir(_ tag: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noop-rotate-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A WHOOP 4 type-47 frame whose hist_version byte (frame[5]) is `version`; ~96 B as a JSONL line.
    private func whoop4Frame(version: UInt8, filler: UInt8) -> [UInt8] {
        [0xAA, 0x01, 0x00, 0x00, 47, version] + [UInt8](repeating: filler, count: 24)
    }

    func testRotationKeepsTheMinimumLinesForEachVersion() async {
        let dir = tmpDir("floor"); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir, maxBytes: 4_096, perVersionFloor: 2)
        let rare = [whoop4Frame(version: 19, filler: 0xA1), whoop4Frame(version: 19, filler: 0xB2)]
        _ = await archive.archive(rare, trim: 1, family: .whoop4)
        for i in 0..<400 {
            let result = await archive.archive([whoop4Frame(version: 18, filler: UInt8(i & 0xFF))],
                                               trim: 2, family: .whoop4)
            guard case .written(let count, _) = result else { return XCTFail("\(result)") }
            XCTAssertEqual(count, 1)
        }
        let back = await archive.readAll()
        XCTAssertTrue(back.contains { $0.frame == rare[0] } && back.contains { $0.frame == rare[1] },
                      "both rare v19 lines survive many rotations")
        XCTAssertTrue(back.contains { RawHistoryArchive.versionByte($0.frame, family: .whoop4) == 18 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.previousFileURL.path), "rotation happened")
        let activeSize = (try? FileManager.default.attributesOfItem(atPath: archive.fileURL.path)[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(activeSize, 4_096, "the active segment stays within the cap")
        let total = await archive.totalBytes()
        XCTAssertLessThanOrEqual(total, 2 * 4_096 + 4 * 120, "bounded at about twice the cap plus floors")
    }

    /// Between rotations an append touches only the active segment; the previous one is not rewritten.
    func testAppendAfterRotationDoesNotRewriteThePreviousSegment() async throws {
        let dir = tmpDir("append"); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir, maxBytes: 4_096, perVersionFloor: 2)
        for i in 0..<45 {
            _ = await archive.archive([whoop4Frame(version: 18, filler: UInt8(i))], trim: 1, family: .whoop4)
        }
        let previous = try Data(contentsOf: archive.previousFileURL)
        _ = await archive.archive([whoop4Frame(version: 18, filler: 0xEE)], trim: 2, family: .whoop4)
        XCTAssertEqual(try Data(contentsOf: archive.previousFileURL), previous)
    }

    /// F3: the archive is the only copy of records the strap already deleted, so a rotation must never
    /// cut retention below the cap. The old half-cap segments kept only ~cap/2 right after a rotation.
    func testNewestCapWorthOfRecordsAlwaysSurvivesRotation() async throws {
        let dir = tmpDir("retain"); defer { try? FileManager.default.removeItem(at: dir) }
        let cap = 4_096
        let archive = RawHistoryArchive(directory: dir, maxBytes: cap, perVersionFloor: 2)
        var frames: [[UInt8]] = []
        var evictedTotal = 0
        for i in 0..<400 {
            let frame = whoop4Frame(version: 18, filler: UInt8(i & 0xFF)) + [UInt8(i >> 8), UInt8(i & 0xFF)]
            frames.append(frame)
            let result = await archive.archive([frame], trim: UInt32(i), family: .whoop4)
            guard case .written(_, let evicted) = result else { return XCTFail("\(result)") }
            evictedTotal += evicted
            let lineBytes = try String(contentsOf: archive.fileURL, encoding: .utf8)
                .split(separator: "\n").last.map { $0.utf8.count + 1 } ?? 1
            let mustSurvive = min(frames.count, cap / lineBytes)
            let back = await archive.readAll().map(\.frame)
            XCTAssertEqual(Array(back.suffix(mustSurvive)), Array(frames.suffix(mustSurvive)),
                           "the newest \(mustSurvive) records (one cap's worth) must survive, after append \(i)")
        }
        XCTAssertGreaterThan(evictedTotal, 0, "evictions happen and are reported so the caller can log them")
        let survivors = await archive.readAll().count
        XCTAssertEqual(survivors + evictedTotal, frames.count, "every record is either kept or reported evicted")
    }

    /// A hand-built archive line in the writer's format.
    private func line(_ frame: [UInt8], capturedAtMs: Int) -> String {
        let hex = frame.map { String(format: "%02x", $0) }.joined()
        return "{\"capturedAtMs\":\(capturedAtMs),\"trim\":1,\"family\":\"whoop4\",\"version\":18,\"frameHex\":\"\(hex)\"}\n"
    }

    /// Review #5: once the previous segment is replaced, its evicted lines are gone even if the rest of
    /// the write fails. The failure used to drop the count, and the retry rotated nothing, so the loss was
    /// never logged. Here clearing the active segment fails (it cannot be removed).
    func testEvictionsAreReportedWhenTheWriteFailsAfterRotating() async throws {
        let dir = tmpDir("fail")
        let archive = RawHistoryArchive(directory: dir, maxBytes: 200, perVersionFloor: 0)
        let locked = archive.fileURL.appendingPathComponent("locked", isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let older = (0..<5).map { line(whoop4Frame(version: 18, filler: UInt8($0)), capturedAtMs: $0) }
        try Data(older.joined().utf8).write(to: archive.previousFileURL)
        // An active segment that cannot be removed: a directory holding a file in a read-only folder.
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: locked.appendingPathComponent("pinned"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        let result = await archive.archive([whoop4Frame(version: 18, filler: 0xEE)], trim: 9, family: .whoop4)

        XCTAssertEqual(result, .failed(evicted: 5), "the ack is held, and the five evicted lines are reported")
        let previous = try String(contentsOf: archive.previousFileURL, encoding: .utf8)
        XCTAssertTrue(previous.isEmpty, "the rotation really did drop them before the failure")
    }

    /// Review #6: a crash after the previous segment is rewritten but before the active one is cleared
    /// leaves the active lines in both files. The next rotation must not report those lines as evicted:
    /// their active copies survive into the new previous segment.
    func testACrashLeftoverDuplicateIsNotReportedAsEvicted() async throws {
        let dir = tmpDir("dup"); defer { try? FileManager.default.removeItem(at: dir) }
        let stale = (0..<5).map { line(whoop4Frame(version: 18, filler: UInt8($0)), capturedAtMs: $0) }
        let carriedOver = (0..<10).map {
            line(whoop4Frame(version: 18, filler: UInt8(0x40 + $0)), capturedAtMs: 100 + $0)
        }
        // The crash state: previous = stale + carriedOver, active = carriedOver. The cap leaves room for
        // the active lines but not one more, so the next write rotates.
        let archive = RawHistoryArchive(directory: dir, maxBytes: carriedOver.joined().utf8.count + 50,
                                        perVersionFloor: 0)
        try Data((stale + carriedOver).joined().utf8).write(to: archive.previousFileURL)
        try Data(carriedOver.joined().utf8).write(to: archive.fileURL)

        let newest = whoop4Frame(version: 18, filler: 0xEE)
        let result = await archive.archive([newest], trim: 9, family: .whoop4)

        XCTAssertEqual(result, .written(count: 1, evicted: 5), "only the five stale lines are really gone")
        let back = await archive.readAll().map(\.frame)
        XCTAssertEqual(back.count, 11, "the ten carried-over records and the newest one remain")
        XCTAssertEqual(back.last, newest)
    }

    func testNewLinesStoreTheVersionAsItsOwnField() async throws {
        let dir = tmpDir("field"); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir)
        _ = await archive.archive([whoop4Frame(version: 25, filler: 0x01)], trim: 7, family: .whoop4)
        let text = try String(contentsOf: archive.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\":25"), text)
        XCTAssertTrue(text.contains("\"family\":\"whoop4\""))
    }

    /// Lines written before the version field existed still get their floor (version from frameHex).
    func testLegacyLinesWithoutAVersionFieldKeepTheirFloor() async throws {
        let dir = tmpDir("legacy"); defer { try? FileManager.default.removeItem(at: dir) }
        let archive = RawHistoryArchive(directory: dir, maxBytes: 4_096, perVersionFloor: 2)
        let legacyFrame = whoop4Frame(version: 21, filler: 0x5A)
        let hex = legacyFrame.map { String(format: "%02x", $0) }.joined()
        let legacyLine = "{\"capturedAtMs\":1,\"trim\":1,\"family\":\"whoop4\",\"frameHex\":\"\(hex)\"}\n"
        try Data(legacyLine.utf8).write(to: archive.fileURL)
        for i in 0..<400 {
            _ = await archive.archive([whoop4Frame(version: 18, filler: UInt8(i & 0xFF))], trim: 2, family: .whoop4)
        }
        let back = await archive.readAll()
        XCTAssertTrue(back.contains { $0.frame == legacyFrame }, "a legacy v21 line keeps its floor slot")
    }

    func testLowercaseHexMatchesStringFormat() {
        let bytes: [UInt8] = [0x00, 0x0F, 0xA0, 0xFF, 0x7E]
        XCTAssertEqual(lowercaseHex(bytes), bytes.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(lowercaseHex([UInt8]()), "")
    }
}
