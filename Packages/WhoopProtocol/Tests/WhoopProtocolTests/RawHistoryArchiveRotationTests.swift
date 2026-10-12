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
