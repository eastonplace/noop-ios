
import XCTest
@testable import NOOP

final class LatestWinsLoadStateTests: XCTestCase {
    func testOlderCompletionCannotReplaceNewerRequest() {
        var state = LatestWinsLoadState()
        let first = state.begin()
        let second = state.begin()

        XCTAssertFalse(state.finish(.loaded, requestID: first))
        XCTAssertTrue(state.finish(.empty, requestID: second))
        XCTAssertEqual(state.phase, .empty(requestID: second))
    }

    func testEveryCurrentPathHasATerminalState() {
        var state = LatestWinsLoadState()

        let loaded = state.begin()
        XCTAssertTrue(state.finish(.loaded, requestID: loaded))
        XCTAssertEqual(state.phase, .loaded(requestID: loaded))

        let empty = state.begin()
        XCTAssertTrue(state.finish(.empty, requestID: empty))
        XCTAssertEqual(state.phase, .empty(requestID: empty))

        let failed = state.begin()
        XCTAssertTrue(state.finish(.failed("read failed"), requestID: failed))
        XCTAssertEqual(state.errorMessage, "read failed")

        let cancelled = state.begin()
        XCTAssertTrue(state.finish(.cancelled, requestID: cancelled))
        XCTAssertEqual(state.phase, .cancelled(requestID: cancelled))
    }

    func testRequestIdentifierWrapDoesNotUseZero() {
        var state = LatestWinsLoadState()
        for _ in 0..<4 {
            XCTAssertGreaterThan(state.begin(), 0)
        }
    }
}
