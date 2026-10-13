import XCTest
@testable import NOOP

#if os(iOS)
/// The Live Activity decision trace is read off a phone after a run, so it must stay small whatever happens: a bounded
/// number of lines, each of bounded length, with a heart-rate stream of identical writes folded into one line.
final class LiveActivityTraceTests: XCTestCase {
    func testTheLogKeepsOnlyTheLastCapacityLines() {
        var log = LiveActivityTraceLog(capacity: 200)
        for i in 0..<500 { log.record("hr passive updated n=\(i)", stamp: "t\(i)") }
        XCTAssertEqual(log.lines.count, 200)
        XCTAssertEqual(log.lines.first, "t300 hr passive updated n=300")
        XCTAssertEqual(log.lines.last, "t499 hr passive updated n=499")
    }

    func testARepeatIsCountedOnTheLastLineInsteadOfAdded() {
        var log = LiveActivityTraceLog(capacity: 3)
        let added = log.record("start-edge workout requested token=match", stamp: "t0")
        XCTAssertTrue(added)
        for i in 1...50 { log.record("workout-hr workout updated token=match", stamp: "t\(i)") }
        XCTAssertEqual(log.lines, [
            "t0 start-edge workout requested token=match",
            "t1 workout-hr workout updated token=match x50 until t50",
        ])
    }

    func testALongLineIsCut() {
        var log = LiveActivityTraceLog(capacity: 5)
        log.record(String(repeating: "e", count: 5_000), stamp: "t0")
        XCTAssertLessThanOrEqual(log.lines[0].count, LiveActivityTraceLog.maxLineLength + 3)
    }

    @MainActor
    func testTheFileStaysBoundedAndARelaunchKeepsItsTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("trace-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let first = LiveActivityTrace(fileURL: url, capacity: 10)
        for i in 0..<25 { first.record("hr passive updated n=\(i)") }
        let written = try String(contentsOf: url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(written.count, 10)
        XCTAssertTrue(written.last?.hasSuffix("n=24") == true)

        let relaunched = LiveActivityTrace(fileURL: url, capacity: 10)
        XCTAssertEqual(relaunched.lines.count, 10)
        XCTAssertTrue(relaunched.lines.last?.hasSuffix("process start") == true)
        XCTAssertTrue(relaunched.lines.contains { $0.hasSuffix("n=24") }, "the previous run's tail is kept")
    }
}
#endif
