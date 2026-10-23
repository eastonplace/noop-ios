import XCTest
@testable import NOOP

final class BackgroundFlushOwnershipTests: XCTestCase {
    func testExpiredFlushCannotEndOrReplaceANewerAssertion() throws {
        var owner = BackgroundFlushOwnership<Int>()
        let first = try XCTUnwrap(owner.reserve())
        owner.assign(101, to: first)
        XCTAssertEqual(owner.finish(first), 101, "expiration ends the old assertion")

        let second = try XCTUnwrap(owner.reserve())
        owner.assign(202, to: second)
        owner.assign(999, to: first)
        XCTAssertNil(owner.finish(first), "the old IO completion cannot end the newer assertion")
        XCTAssertNil(owner.reserve(), "the newer assertion still owns its flush")
        XCTAssertEqual(owner.finish(second), 202)
        XCTAssertNil(owner.finish(second), "late expiration cannot end an assertion twice")
    }

    func testReservationPreventsDuplicateFlushesBeforeIdentifierAssignment() throws {
        var owner = BackgroundFlushOwnership<Int>()
        let first = try XCTUnwrap(owner.reserve())
        XCTAssertNil(owner.reserve())
        XCTAssertNil(owner.finish(first), "a refused OS assertion still releases its reservation")
        XCTAssertNotNil(owner.reserve())
    }
}
