import XCTest
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
}
