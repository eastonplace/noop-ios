import XCTest
import SwiftUI
@testable import StrandDesign

/// The capped x-axis (`xAxisLabelCount`) labels calendar days, so it must never repeat a date.
final class TrendChartAxisTests: XCTestCase {
    private let calendar = Calendar.current

    /// `days` daily points at local noon, starting 2026-10-01.
    private func daily(_ days: Int) -> [TrendPoint] {
        (0..<days).map { index in
            let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1 + index, hour: 12))!
            return TrendPoint(date: date, value: Double(index))
        }
    }

    private func distinctDays(_ dates: [Date]) -> Int { Set(dates.map { calendar.startOfDay(for: $0) }).count }

    func testTwoDaysGetTwoDistinctLabels() throws {
        let ticks = try XCTUnwrap(TrendChart(points: daily(2), xAxisLabelCount: 4).xAxisTicks)
        XCTAssertEqual(ticks.count, 2)
        XCTAssertEqual(distinctDays(ticks), 2)
    }

    func testThreeDaysGetThreeDistinctLabels() throws {
        let ticks = try XCTUnwrap(TrendChart(points: daily(3), xAxisLabelCount: 4).xAxisTicks)
        XCTAssertEqual(ticks.count, 3)
        XCTAssertEqual(distinctDays(ticks), 3)
    }

    func testAMonthKeepsTheRequestedFourLabelsOnDistinctDaysWithBothEndsPinned() throws {
        let points = daily(30)
        let ticks = try XCTUnwrap(TrendChart(points: points, xAxisLabelCount: 4).xAxisTicks)
        XCTAssertEqual(ticks.count, 4)
        XCTAssertEqual(distinctDays(ticks), 4)
        XCTAssertEqual(ticks.first, points.first?.date)
        XCTAssertEqual(ticks.last, points.last?.date)
        XCTAssertEqual(ticks, ticks.sorted())
    }

    func testASeriesInsideOneDayFallsBackToTheAutomaticAxis() {
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 0))!
        let hourly = (0..<6).map { TrendPoint(date: day.addingTimeInterval(Double($0) * 3600), value: Double($0)) }
        XCTAssertNil(TrendChart(points: hourly, xAxisLabelCount: 4).xAxisTicks)
    }

    func testNoLabelCountKeepsTheAutomaticAxis() {
        XCTAssertNil(TrendChart(points: daily(30)).xAxisTicks)
    }
}
