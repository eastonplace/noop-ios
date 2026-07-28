import XCTest
@testable import NOOP

final class BackfillBurstPublicationTests: XCTestCase {
    func testDurablePassPublishesCheapProgressBeforeBurstFinalization() {
        var burst = BackfillBurstPublication()

        let first = burst.record(rowsPersisted: 240, requiresTimestampHeal: false,
                                 latestFrontierUnix: 1_000, at: 10)
        XCTAssertEqual(first, HistoricalSyncPassProgress(rowsPersisted: 240, passNumber: 1,
                                                         latestFrontierUnix: 1_000, publishedAt: 10))
        XCTAssertTrue(burst.needsPublication)

        let second = burst.record(rowsPersisted: 360, requiresTimestampHeal: false,
                                  latestFrontierUnix: 1_100, at: 20)
        XCTAssertEqual(second?.passNumber, 2)
        XCTAssertEqual(second?.rowsPersisted, 360)
        XCTAssertTrue(burst.consume())
        XCTAssertFalse(burst.consume())
    }

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
