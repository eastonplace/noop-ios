import XCTest
import StrandDesign
import WhoopStore
@testable import NOOP

final class TrendSummaryPresentationTests: XCTestCase {
    func testLatestDeltaAndSparkUseExactChartedSeries() throws {
        let charted = (0..<10).map {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0 * 86_400)),
                       value: Double($0 * 3))
        }

        // Current-period mean is 13.5; the preceding period's mean is 10.5. The summary
        // compares those periods, while latest/source/spark must still use the charted period.
        let previous = (-10..<0).map {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0 * 86_400)), value: 10.5)
        }
        let summary = TrendSummaryPresentation(
            series: charted, previousSeries: previous, goodDirection: .higher, expectedCount: 10
        )

        assertSamePoints(summary.source, charted)
        XCTAssertEqual(try XCTUnwrap(summary.latest), 27, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(summary.delta), 3, accuracy: 1e-12)
        // Ten points fit within the current 30-point density bound: none may be dropped.
        assertSamePoints(summary.spark, charted)
        XCTAssertEqual(summary.currentCount, 10)
        XCTAssertEqual(summary.previousCount, 10)
        XCTAssertEqual(summary.expectedCount, 10)
        XCTAssertTrue(summary.comparisonIsReliable)
        XCTAssertEqual(summary.deltaTone, .positive)
    }

    func testStrainDeltaStaysNeutralRegardlessOfSign() throws {
        let lower = (0..<3).map {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0 * 86_400)), value: 9.1)
        }
        let higher = (0..<3).map {
            TrendPoint(date: Date(timeIntervalSince1970: TimeInterval($0 * 86_400)), value: 14.2)
        }
        let previousLower = lower.map {
            TrendPoint(date: $0.date.addingTimeInterval(-3 * 86_400), value: $0.value)
        }
        let previousHigher = higher.map {
            TrendPoint(date: $0.date.addingTimeInterval(-3 * 86_400), value: $0.value)
        }
        let downSummary = TrendSummaryPresentation(
            series: lower, previousSeries: previousHigher, goodDirection: .neutral, expectedCount: 3
        )
        let upSummary = TrendSummaryPresentation(
            series: higher, previousSeries: previousLower, goodDirection: .neutral, expectedCount: 3
        )

        // Both comparisons clear the coverage gate, so neutral tone must come from the
        // metric's neutral direction rather than being masked by insufficient evidence.
        XCTAssertTrue(downSummary.comparisonIsReliable)
        XCTAssertTrue(upSummary.comparisonIsReliable)
        XCTAssertEqual(try XCTUnwrap(downSummary.delta), -5.1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(upSummary.delta), 5.1, accuracy: 1e-12)
        XCTAssertEqual(downSummary.deltaTone, .neutral)
        XCTAssertEqual(upSummary.deltaTone, .neutral)
    }

    func testSparseSeriesNeverFabricatesDeltaOrSparkPoints() {
        let only = TrendPoint(date: Date(timeIntervalSince1970: 123), value: 62)
        let summary = TrendSummaryPresentation(
            series: [only], previousSeries: [], goodDirection: .higher, expectedCount: 7
        )

        XCTAssertEqual(summary.latest, 62)
        XCTAssertNil(summary.delta)
        assertSamePoints(summary.spark, [only])
        XCTAssertEqual(summary.currentCount, 1)
        XCTAssertEqual(summary.previousCount, 0)
        XCTAssertFalse(summary.comparisonIsReliable)
        XCTAssertEqual(summary.deltaTone, .neutral)
    }

    func testSparsePriorPeriodCannotCreateAConfidentTrendTone() throws {
        let current = TrendPoint(date: Date(timeIntervalSince1970: 86_400), value: 62)
        let previous = TrendPoint(date: Date(timeIntervalSince1970: 0), value: 80)
        let summary = TrendSummaryPresentation(
            series: [current], previousSeries: [previous], goodDirection: .higher, expectedCount: 7
        )

        XCTAssertEqual(try XCTUnwrap(summary.delta), -18, accuracy: 1e-12)
        XCTAssertEqual(summary.currentCount, 1)
        XCTAssertEqual(summary.previousCount, 1)
        XCTAssertEqual(summary.expectedCount, 7)
        XCTAssertFalse(summary.comparisonIsReliable)
        XCTAssertEqual(summary.deltaTone, .neutral)
        assertSamePoints(summary.source, [current])
        assertSamePoints(summary.spark, [current])
    }

    func testEmptySeriesNeverFabricatesSummaryValues() {
        let summary = TrendSummaryPresentation(
            series: [], previousSeries: [], goodDirection: .higher, expectedCount: 7
        )

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
