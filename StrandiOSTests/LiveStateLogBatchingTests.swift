import XCTest
import Combine
import StrandAnalytics
@testable import NOOP

/// BLE-10: strap-log lines are redacted once, queued, and published into `LiveState.log` in batches.
@MainActor
final class LiveStateLogBatchingTests: XCTestCase {

    func testABurstOfLinesPublishesAtMostOnce() {
        let live = LiveState()
        live.publishPendingLog()
        var publishes = 0
        let token = live.$log.dropFirst().sink { _ in publishes += 1 }
        defer { token.cancel() }
        for index in 0..<100 { live.append(log: "burst line \(index)") }
        XCTAssertEqual(publishes, 0, "lines are queued, not republished one by one")
        live.publishPendingLog()
        XCTAssertEqual(publishes, 1)
        XCTAssertEqual(Array(live.log.suffix(100)), (0..<100).map { "burst line \($0)" })
    }

    func testTrimsInChunksBackToTheCap() {
        let live = LiveState()
        for index in 0..<(LiveState.maxLogLines + LiveState.logTrimSlack + 1) { live.append(log: "l\(index)") }
        live.publishPendingLog()
        XCTAssertEqual(live.log.count, LiveState.maxLogLines)
        XCTAssertEqual(live.log.last, "l\(LiveState.maxLogLines + LiveState.logTrimSlack)")
    }

    func testTaggedTailAndExportIncludeQueuedLines() {
        let live = LiveState()
        live.append(log: "queued sleep line", domain: .sleep)
        XCTAssertEqual(live.taggedTail(domain: .sleep).last, "[\(TestDomain.sleep.id)] queued sleep line")
        XCTAssertTrue(live.exportableLogText().hasSuffix("[\(TestDomain.sleep.id)] queued sleep line"))
    }

    /// Appended lines are already redacted; the persisted-tail write must store them as given.
    func testPersistTailDoesNotRedactAgain() {
        let key = "strapLog.tail"
        let saved = UserDefaults.standard.array(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        let line = "peer AA:BB:CC:DD:EE:FF"
        XCTAssertNotEqual(LiveState.redactPii(line), line, "fixture must be a line redaction would change")
        LiveState.persistTail([line])
        XCTAssertEqual(UserDefaults.standard.array(forKey: key) as? [String], [line])
    }

    func testPrecompiledRedactionMatchesTheOldRules() {
        XCTAssertEqual(LiveState.redactPii("mac AA:BB:CC:DD:EE:FF"), "mac AA:••:••:••:••:FF")
        XCTAssertEqual(LiveState.redactPii("found WHOOP 4A1234567"), "found WHOOP <serial>")
        XCTAssertEqual(LiveState.redactPii("id 12345678-ABCD-1234-ABCD-1234567890AB"), "id <device>")
        XCTAssertEqual(LiveState.redactPii("svc 0000180d-0000-1000-8000-00805f9b34fb"),
                       "svc 0000180d-0000-1000-8000-00805f9b34fb", "standard Bluetooth UUIDs are kept")
    }
}
