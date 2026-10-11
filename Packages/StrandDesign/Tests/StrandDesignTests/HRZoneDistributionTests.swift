import XCTest
@testable import StrandDesign

final class HRZoneDistributionTests: XCTestCase {
    func testAZoneVisitedForUnderAMinuteReadsLessThanOneMinuteNotADash() {
        // 22 seconds is a share of 1% on the row beside it; a dash there would say "none".
        XCTAssertEqual(HRZoneDistribution.rowDuration(22), String(localized: "<1m", bundle: .module))
        XCTAssertEqual(HRZoneDistribution.rowDuration(59), String(localized: "<1m", bundle: .module))
        XCTAssertEqual(HRZoneDistribution.rowDuration(0.5), String(localized: "<1m", bundle: .module))
    }

    func testAZoneNotVisitedReadsTheDashAndOthersReadTheirTime() {
        XCTAssertEqual(HRZoneDistribution.rowDuration(0), WidgetMetrics.missingValue)
        XCTAssertEqual(HRZoneDistribution.rowDuration(-3), WidgetMetrics.missingValue)
        XCTAssertEqual(HRZoneDistribution.rowDuration(60), HRZoneDistribution.durationText(60))
        XCTAssertEqual(HRZoneDistribution.rowDuration(3_900), HRZoneDistribution.durationText(3_900))
    }
}
