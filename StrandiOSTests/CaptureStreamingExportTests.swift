import XCTest
import ZIPFoundation
@testable import NOOP

final class CaptureStreamingExportTests: XCTestCase {
    func testStagedCaptureMatchesWholeScrubAcrossReadBoundaries() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureIO-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("input.jsonl")
        let shapes = [
            "WHOOP 4A2B9C1D", "A1:B2:C3:D4:E5:F6", "12345678-1234-1234-1234-123456789abc",
            "61080003-8d6d-82b8-614a-1c8cb0f8dcc6", "142e1c0001d36e3d1c12a3574242354150303533393835320000",
            "WHOOP 123456789ABC", "é😴\n",
        ]
        for shape in shapes {
            for split in 1...shape.utf8.count {
                let body = String(repeating: "!", count: 65_536 - split) + shape + "\n"
                try Data(body.utf8).write(to: source)
                let staged = try FileExport.stagedSanitizedCapture(at: source, suggestedName: "safe-\(UUID()).jsonl")
                defer { try? FileManager.default.removeItem(at: staged) }
                XCTAssertEqual(try Data(contentsOf: staged), Data(LiveState.redactPii(body).utf8), "\(shape), split \(split)")
                XCTAssertEqual(try Data(contentsOf: source), Data(body.utf8))
            }
        }
    }

    func testInvalidUTF8NeverProducesAStagedCapture() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("invalid-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data([0xFF, 0xFE]).write(to: source)
        XCTAssertThrowsError(try FileExport.stagedSanitizedCapture(at: source, suggestedName: "invalid-safe-\(UUID()).jsonl"))
    }
    func testRecordLimitKeepsExactBoundaryAndRejectsOversizeWithoutPartialOutput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureLimit-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jsonl")
        let limit = 1_024 * 1_024
        let accepted = Data((String(repeating: "!", count: limit - 1) + "\n").utf8)
        try accepted.write(to: source)
        let staged = try FileExport.stagedSanitizedCapture(at: source, suggestedName: "boundary.jsonl")
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        XCTAssertEqual(try Data(contentsOf: staged), accepted)
        let oversized = Data((String(repeating: "!", count: limit) + "\n").utf8)
        try oversized.write(to: source)
        XCTAssertThrowsError(try FileExport.stagedSanitizedCapture(at: source, suggestedName: "oversize.jsonl"))
        XCTAssertEqual(try Data(contentsOf: source), oversized)
    }

    func testZipPreservesEveryEntryByteAndDoesNotCollideWithAnotherExport() throws {
        let entries = [
            FileExport.BundleEntry(name: "report.txt", data: Data("safe report\n".utf8)),
            FileExport.BundleEntry(name: "raw-capture.jsonl", data: Data(repeating: 0x21, count: 131_073)),
            FileExport.BundleEntry(name: "empty.txt", data: Data()),
        ]
        let first = try XCTUnwrap(FileExport.zipData(entries: entries, baseName: "same-name"))
        let second = try XCTUnwrap(FileExport.zipData(entries: entries, baseName: "same-name"))
        defer {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        XCTAssertNotEqual(first, second)
        for url in [first, second] {
            let archive = try Archive(url: url, accessMode: .read)
            for expected in entries {
                let entry = try XCTUnwrap(archive[expected.name])
                var actual = Data()
                _ = try archive.extract(entry) { actual.append($0) }
                XCTAssertEqual(actual, expected.data, expected.name)
            }
        }
    }

    @MainActor
    func testStreamedTailMatchesExistingRedactThenCapByteOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureTail-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.jsonl")
        let body = String(repeating: "{\"hex\":\"424235415030353339383532\",\"log\":\"WHOOP 4A2B9C1D é😴\"}\n", count: 100)
        try Data(body.utf8).write(to: source)
        let complete = Data(LiveState.redactPii(body).utf8)
        for budget in [0, 1, 7, 500, complete.count, complete.count + 1] {
            let result = try await FileExport.sanitizedCaptureTail(at: source, maximumBytes: budget)
            let tail = try XCTUnwrap(result)
            XCTAssertEqual(tail.data, Data(complete.suffix(budget)), "budget \(budget)")
            XCTAssertEqual(tail.truncated, complete.count > budget)
        }
        let missing = try await FileExport.sanitizedCaptureTail(at: directory.appendingPathComponent("missing"), maximumBytes: 50)
        XCTAssertNil(missing)
    }

}
