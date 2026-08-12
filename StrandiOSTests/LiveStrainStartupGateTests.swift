import XCTest
@testable import NOOP

/// A cold launch has a durable V2 Strain snapshot before Repository's daily cache is ready. The live
/// accumulator must wait for that cache; otherwise an incomplete start-of-day calculation can overwrite
/// the visible snapshot with 0.0.
final class LiveStrainStartupGateTests: XCTestCase {
    func testLiveStrainWaitsForInitialRepositoryCache() {
        XCTAssertFalse(Repository.canRefreshLiveDayStrain(repositoryLoaded: false))
    }

    func testLiveStrainRunsAfterInitialRepositoryCache() {
        XCTAssertTrue(Repository.canRefreshLiveDayStrain(repositoryLoaded: true))
    }
}
