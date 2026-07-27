import XCTest
@testable import NOOP

final class BackfillBurstPublicationTests: XCTestCase {
    func testDurableRowsPublishOnceWhenTheBurstQuiesces() {
        var burst = BackfillBurstPublication()

        burst.record(rowsPersisted: 240, requiresTimestampHeal: false)
        burst.record(rowsPersisted: 360, requiresTimestampHeal: false)

        XCTAssertTrue(burst.consume())
        XCTAssertFalse(burst.consume())
    }

    func testTimestampHealPublishesEvenWhenTheBadRowsWereRejected() {
        var burst = BackfillBurstPublication()

        burst.record(rowsPersisted: 0, requiresTimestampHeal: true)

        XCTAssertTrue(burst.consume())
    }

    func testEmptyBurstDoesNotRefreshTheDashboard() {
        var burst = BackfillBurstPublication()

        burst.record(rowsPersisted: 0, requiresTimestampHeal: false)

        XCTAssertFalse(burst.consume())
    }
}
