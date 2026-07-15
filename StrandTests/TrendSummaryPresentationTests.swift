import XCTest
import StrandDesign
import WhoopStore
@testable import Strand

final class TrendSummaryPresentationTests: XCTestCase {
    func testLatestDeltaAndSparkUseExactChartedSeries() throws {
        let charted = (0..<10).map {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0 * 86_400)),
                       value: Double($0 * 3))
        }

        let summary = TrendSummaryPresentation(series: charted, goodDirection: .higher)

        assertSamePoints(summary.source, charted)
        XCTAssertEqual(try XCTUnwrap(summary.latest), 27, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(summary.delta), 3, accuracy: 1e-12)
        assertSamePoints(summary.spark, Array(charted.suffix(7)))
        XCTAssertEqual(summary.deltaTone, .positive)
    }

    func testStrainDeltaStaysNeutralRegardlessOfSign() throws {
        let down = [
            TrendPoint(date: Date(timeIntervalSince1970: 0), value: 14.2),
            TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: 9.1),
        ]
        let up = [
            TrendPoint(date: Date(timeIntervalSince1970: 0), value: 9.1),
            TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: 14.2),
        ]

        let downSummary = TrendSummaryPresentation(series: down, goodDirection: .neutral)
        let upSummary = TrendSummaryPresentation(series: up, goodDirection: .neutral)

        XCTAssertEqual(try XCTUnwrap(downSummary.delta), -5.1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(upSummary.delta), 5.1, accuracy: 1e-12)
        XCTAssertEqual(downSummary.deltaTone, .neutral)
        XCTAssertEqual(upSummary.deltaTone, .neutral)
    }

    func testSparseSeriesNeverFabricatesDeltaOrSparkPoints() {
        let only = TrendPoint(date: Date(timeIntervalSince1970: 123), value: 62)
        let summary = TrendSummaryPresentation(series: [only], goodDirection: .higher)

        XCTAssertEqual(summary.latest, 62)
        XCTAssertNil(summary.delta)
        assertSamePoints(summary.spark, [only])
        XCTAssertEqual(summary.deltaTone, .neutral)
    }

    func testEmptySeriesNeverFabricatesSummaryValues() {
        let summary = TrendSummaryPresentation(series: [], goodDirection: .higher)

        XCTAssertTrue(summary.source.isEmpty)
        XCTAssertNil(summary.latest)
        XCTAssertNil(summary.delta)
        XCTAssertTrue(summary.spark.isEmpty)
        XCTAssertEqual(summary.deltaTone, .neutral)
    }

    func testChartSeriesBuilderUsesConfiguredStrainDisplayValue() throws {
        let day = DailyMetric(
            day: "2026-07-14", totalSleepMin: nil, efficiency: nil,
            deepMin: nil, remMin: nil, lightMin: nil, disturbances: nil,
            restingHr: nil, avgHrv: nil, recovery: 68, strain: 12.3,
            exerciseCount: nil
        )
        let date = Date(timeIntervalSince1970: 1_783_987_200)

        let series = PaperTrendSeries.build(
            days: [day], sleepByDay: [day.day: 91], date: { _ in date }
        )

        XCTAssertEqual(try XCTUnwrap(series.strain.first?.value),
                       StrainScale.displayValue(fromStored: 12.3), accuracy: 1e-12)
        XCTAssertEqual(series.strain.first?.date, date)
        XCTAssertEqual(series.recovery.first?.value, 68)
        XCTAssertEqual(series.sleep.first?.value, 91)
    }

    private func assertSamePoints(_ actual: [TrendPoint], _ expected: [TrendPoint],
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (lhs, rhs) in zip(actual, expected) {
            XCTAssertEqual(lhs.date, rhs.date, file: file, line: line)
            XCTAssertEqual(lhs.value, rhs.value, accuracy: 1e-12, file: file, line: line)
        }
    }
}
