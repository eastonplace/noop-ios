import XCTest
@testable import StrandAnalytics

final class StrapComparisonTests: XCTestCase {
    func testAgreementBandsAndSingleSource() {
        let metric = MetricArbitrationPolicy.MetricKind.restingHR
        XCTAssertEqual(StrapComparison.agreement(metric: metric, a: 55, b: 57), .agree)
        XCTAssertEqual(StrapComparison.agreement(metric: metric, a: 55, b: 60), .minorDelta)
        XCTAssertEqual(StrapComparison.agreement(metric: metric, a: 55, b: 70), .conflict)
        XCTAssertEqual(StrapComparison.agreement(metric: metric, a: 55, b: nil), .single)
    }

    func testPercentToleranceIsSymmetric() {
        let metric = MetricArbitrationPolicy.MetricKind.steps
        XCTAssertEqual(StrapComparison.agreement(metric: metric, a: 10_000, b: 10_800), .agree)
        XCTAssertEqual(StrapComparison.agreement(metric: metric, a: 10_800, b: 10_000), .agree)
    }

    func testCompareIncludesMetricsReportedByEitherStrap() {
        let rhr = MetricArbitrationPolicy.MetricKind.restingHR
        let hrv = MetricArbitrationPolicy.MetricKind.hrv
        let spo2 = MetricArbitrationPolicy.MetricKind.spo2
        let rows = StrapComparison.compare([rhr: 55, hrv: 60], [rhr: 56, spo2: 97])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.first(where: { $0.metric == rhr })?.agreement, .agree)
        XCTAssertNil(rows.first(where: { $0.metric == spo2 })?.a)
    }

    func testInvalidValuesAreTreatedAsMissing() {
        let rhr = MetricArbitrationPolicy.MetricKind.restingHR
        let spo2 = MetricArbitrationPolicy.MetricKind.spo2
        let rows = StrapComparison.compare(
            [rhr: .nan, spo2: 101],
            [rhr: 55, spo2: 97]
        )
        XCTAssertEqual(rows.first(where: { $0.metric == rhr })?.a, nil)
        XCTAssertEqual(rows.first(where: { $0.metric == rhr })?.agreement, .single)
        XCTAssertEqual(rows.first(where: { $0.metric == spo2 })?.a, nil)
        XCTAssertEqual(rows.first(where: { $0.metric == spo2 })?.b, 97)
    }

    func testBothInvalidValuesDoNotProduceComparisonRow() {
        let steps = MetricArbitrationPolicy.MetricKind.steps
        XCTAssertTrue(StrapComparison.compare([steps: -1], [steps: .infinity]).isEmpty)
    }
}
