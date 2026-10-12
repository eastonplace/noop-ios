import XCTest
import WhoopProtocol

/// BLE-6: the Oura cursor (any commit action) moves only after its batch and every earlier batch were
/// written; failed inserts are retried a bounded number of times, in order.
@MainActor
final class BatchedRetryingSinkTests: XCTestCase {

    private struct Boom: Error {}

    func testCursorDoesNotMoveWhenTheInsertFails() async {
        var cursor = 0
        let sink = BatchedRetryingSink<Int>(retryDelaysNanoseconds: [0, 0], sleep: { _ in }) { _ in throw Boom() }
        var dropped = 0
        let ok = await sink.submit([1, 2], onCommitted: { cursor = 42 }, onFailed: { dropped = $0 }).value
        XCTAssertFalse(ok)
        XCTAssertEqual(cursor, 0, "the page's events were not written, so its cursor must not be saved")
        XCTAssertEqual(dropped, 2)
        XCTAssertEqual(sink.droppedBatches, 2)
    }

    func testATransientFailureIsRetriedThenCommits() async {
        var attempts = 0
        var written: [Int] = []
        let sink = BatchedRetryingSink<Int>(retryDelaysNanoseconds: [0, 0], sleep: { _ in }) { value in
            attempts += 1
            if attempts == 1 { throw Boom() }
            written.append(value)
        }
        var cursor = 0
        let ok = await sink.submit([7], onCommitted: { cursor = 7 }).value
        XCTAssertTrue(ok)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(written, [7])
        XCTAssertEqual(cursor, 7)
    }

    func testRetriesAreBounded() async {
        var attempts = 0
        var sleeps: [UInt64] = []
        let sink = BatchedRetryingSink<Int>(retryDelaysNanoseconds: [5, 10], sleep: { sleeps.append($0) }) { _ in
            attempts += 1
            throw Boom()
        }
        _ = await sink.submit([1]).value
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleeps, [5, 10])
    }

    /// A later page must not save its cursor past an earlier page that failed (that would leave a gap).
    func testAnEarlierFailureBlocksLaterCommitsUntilANewSession() async {
        var written: [Int] = []
        let sink = BatchedRetryingSink<Int>(retryDelaysNanoseconds: [], sleep: { _ in }) { value in
            if value == 1 { throw Boom() }
            written.append(value)
        }
        var cursor = 0
        sink.submit([1], onCommitted: { cursor = 1 })
        let second = await sink.submit([2], onCommitted: { cursor = 2 }).value
        XCTAssertFalse(second)
        XCTAssertEqual(written, [2], "later batches are still written")
        XCTAssertEqual(cursor, 0)
        sink.startNewSession()
        let third = await sink.submit([3], onCommitted: { cursor = 3 }).value
        XCTAssertTrue(third)
        XCTAssertEqual(cursor, 3)
    }

    func testBatchesAreWrittenInSubmissionOrder() async {
        var written: [Int] = []
        let sink = BatchedRetryingSink<Int>(retryDelaysNanoseconds: [], sleep: { _ in }) { value in
            await Task.yield()
            written.append(value)
        }
        for i in 0..<20 { sink.submit([i * 2, i * 2 + 1]) }
        let ok = await sink.drain()
        XCTAssertTrue(ok)
        XCTAssertEqual(written, Array(0..<40))
    }
}
