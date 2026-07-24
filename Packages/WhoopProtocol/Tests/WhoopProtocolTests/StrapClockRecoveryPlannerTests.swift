import XCTest
@testable import WhoopProtocol

final class StrapClockRecoveryPlannerTests: XCTestCase {
    func testRetriesAreBoundedThenDataRangeFallbackInstalls() {
        var planner = StrapClockRecoveryPlanner()
        XCTAssertEqual(
            planner.nextAction(hasPreciseCorrelation: false, newestBankedUnix: 900, wallUnix: 1_000),
            .retryGetClock(attempt: 1, maximum: 3)
        )
        XCTAssertEqual(
            planner.nextAction(hasPreciseCorrelation: false, newestBankedUnix: 900, wallUnix: 1_000),
            .retryGetClock(attempt: 2, maximum: 3)
        )
        XCTAssertEqual(
            planner.nextAction(hasPreciseCorrelation: false, newestBankedUnix: 900, wallUnix: 1_000),
            .retryGetClock(attempt: 3, maximum: 3)
        )
        XCTAssertEqual(
            planner.nextAction(hasPreciseCorrelation: false, newestBankedUnix: 900, wallUnix: 1_000),
            .installDataRangeFallback(deviceUnix: 900, wallUnix: 1_000)
        )
        XCTAssertEqual(planner.retryCount, 3)
    }

    func testPreciseCorrelationSuppressesRetriesAndFallback() {
        var planner = StrapClockRecoveryPlanner(retryCount: 2)
        XCTAssertEqual(
            planner.nextAction(hasPreciseCorrelation: true, newestBankedUnix: 900, wallUnix: 1_000),
            .none
        )
        XCTAssertEqual(planner.retryCount, 2)
    }

    func testFallbackFailsClosedWithoutValidDataRange() {
        var planner = StrapClockRecoveryPlanner(maximumRetries: 0)
        XCTAssertEqual(
            planner.nextAction(hasPreciseCorrelation: false, newestBankedUnix: nil, wallUnix: 1_000),
            .none
        )
        XCTAssertEqual(
            planner.nextAction(hasPreciseCorrelation: false, newestBankedUnix: 0, wallUnix: 1_000),
            .none
        )
        XCTAssertEqual(
            planner.nextAction(hasPreciseCorrelation: false, newestBankedUnix: 900, wallUnix: 0),
            .none
        )
    }

    func testResetRearmsFirstRetry() {
        var planner = StrapClockRecoveryPlanner(retryCount: 3)
        planner.reset()
        XCTAssertEqual(
            planner.nextAction(hasPreciseCorrelation: false, newestBankedUnix: nil, wallUnix: 1_000),
            .retryGetClock(attempt: 1, maximum: 3)
        )
    }

    func testInitializerClampsInvalidCounts() {
        XCTAssertEqual(
            StrapClockRecoveryPlanner(maximumRetries: -2, retryCount: 9),
            StrapClockRecoveryPlanner(maximumRetries: 0, retryCount: 0)
        )
        XCTAssertEqual(
            StrapClockRecoveryPlanner(maximumRetries: 2, retryCount: 9).retryCount,
            2
        )
    }
}
