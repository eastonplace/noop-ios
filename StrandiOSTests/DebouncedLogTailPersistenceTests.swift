import XCTest
@testable import NOOP

final class DebouncedLogTailPersistenceTests: XCTestCase {
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [[String]] = []

        func append(_ value: [String]) {
            lock.lock()
            storage.append(value)
            lock.unlock()
        }

        var values: [[String]] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    func testRapidBurstBatchesAndBoundsTail() async throws {
        let writes = Writes()
        let persistence = DebouncedLogTailPersistence(
            debounceInterval: 0.03,
            tailLimit: 100,
            loadPersisted: { [] },
            persist: writes.append
        )
        for index in 0..<500 { persistence.append("line \(index)") }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(writes.values.count, 1)
        XCTAssertEqual(writes.values[0].count, 100)
        XCTAssertEqual(writes.values[0].first, "line 400")
        XCTAssertEqual(writes.values[0].last, "line 499")
    }

    func testForceFlushIncludesNewestQueuedMessages() async {
        let writes = Writes()
        let persistence = DebouncedLogTailPersistence(
            debounceInterval: 60,
            tailLimit: 10,
            loadPersisted: { [] },
            persist: writes.append
        )
        ["a", "b", "newest"].forEach(persistence.append)
        await persistence.flush()
        XCTAssertEqual(writes.values, [["a", "b", "newest"]])
    }

    func testSeparateRapidBurstsProduceOneWritePerBurst() async throws {
        let writes = Writes()
        let persistence = DebouncedLogTailPersistence(
            debounceInterval: 0.025,
            tailLimit: 100,
            loadPersisted: { [] },
            persist: writes.append
        )
        for index in 0..<50 { persistence.append("first \(index)") }
        try await Task.sleep(for: .milliseconds(70))
        for index in 0..<50 { persistence.append("second \(index)") }
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(writes.values.count, 2)
        XCTAssertEqual(writes.values[0].last, "first 49")
        XCTAssertEqual(writes.values[1].last, "second 49")
    }

    func testExistingDurableTailIsPreservedAndBounded() async {
        let writes = Writes()
        let persistence = DebouncedLogTailPersistence(
            debounceInterval: 60,
            tailLimit: 3,
            loadPersisted: { ["old 1", "old 2"] },
            persist: writes.append
        )
        persistence.append("new")
        await persistence.flush()
        XCTAssertEqual(writes.values, [["old 1", "old 2", "new"]])
    }

    func testClearCannotBeUndoneByPendingDebounce() async throws {
        let writes = Writes()
        let persistence = DebouncedLogTailPersistence(
            debounceInterval: 0.04,
            tailLimit: 10,
            loadPersisted: { [] },
            persist: writes.append
        )
        persistence.append("stale")
        await persistence.clear()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(writes.values, [[]])
    }

    func testRepeatedFlushWithoutNewMessagesDoesNotRewriteTail() async {
        let writes = Writes()
        let persistence = DebouncedLogTailPersistence(
            debounceInterval: 60,
            tailLimit: 10,
            loadPersisted: { [] },
            persist: writes.append
        )
        persistence.append("one")
        await persistence.flush()
        await persistence.flush()
        XCTAssertEqual(writes.values, [["one"]])
    }
}
