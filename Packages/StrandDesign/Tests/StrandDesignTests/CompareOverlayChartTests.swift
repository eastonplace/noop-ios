import SwiftUI
import XCTest
@testable import StrandDesign

/// The geometry and rules under the Compare overlay: the days it can snap to, its date span, per-series scaling and the
/// gap limit a weekly series needs.
final class CompareOverlayChartTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private var start: Date { calendar.startOfDay(for: Date(timeIntervalSince1970: 1_750_000_000)) }

    private func date(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: start)! }

    private func series(_ title: String, _ readings: [(Int, Double)]) -> CompareSeries {
        CompareSeries(title: title, unit: "", tint: .blue, points: readings.map { ComparePoint(date: date($0.0), value: $0.1) })
    }

    func testTheDaysAreTheUnionOfEverySeriesAscendingAndOnceEach() {
        let a = series("A", [(0, 1), (2, 2), (4, 3)])
        let b = series("B", [(2, 5), (3, 6)])
        XCTAssertEqual(CompareOverlayGeometry.days(of: [a, b]), [date(0), date(2), date(3), date(4)])
        XCTAssertEqual(CompareOverlayGeometry.days(of: []), [])
    }

    func testTheDomainSpansEveryReadingAndIsNeverNarrowerThanADay() {
        let a = series("A", [(2, 1), (5, 2)])
        let b = series("B", [(0, 5), (3, 6)])
        XCTAssertEqual(CompareOverlayGeometry.domain(of: [a, b]), date(0)...date(5))
        let single = series("S", [(4, 1)])
        let domain = CompareOverlayGeometry.domain(of: [single])
        XCTAssertEqual(domain?.lowerBound, date(4))
        XCTAssertEqual(domain.map { $0.upperBound.timeIntervalSince($0.lowerBound) }, 86_400)
        XCTAssertNil(CompareOverlayGeometry.domain(of: []))
    }

    /// Each series is scaled to its own range, so a heart rate in the sixties and a step count in the thousands share
    /// one axis; a flat series sits on the middle line.
    func testEachSeriesIsScaledToItsOwnRange() {
        let rhr = series("RHR", [(0, 58), (1, 62), (2, 66)])
        let steps = series("Steps", [(0, 4_000), (1, 8_000), (2, 12_000)])
        for entry in [rhr, steps] {
            XCTAssertEqual(entry.normalized(entry.minValue), 0)
            XCTAssertEqual(entry.normalized(entry.maxValue), 1)
        }
        XCTAssertEqual(rhr.normalized(62), 0.5, accuracy: 1e-9)
        XCTAssertEqual(steps.normalized(8_000), 0.5, accuracy: 1e-9)
        let flat = series("Flat", [(0, 7), (1, 7)])
        XCTAssertEqual(flat.normalized(7), 0.5)
        // A value outside the range stays on the plot.
        XCTAssertEqual(rhr.normalized(100), 1)
        XCTAssertEqual(rhr.normalized(0), 0)
    }

    func testADailySeriesKeepsTheThreeDayLimitAndAWeeklyOneBridgesThreeWeeks() {
        XCTAssertEqual(TrendCadence.gapLimitDays(dayOffsets: Array(0..<30)), 3)
        XCTAssertEqual(TrendCadence.gapLimitDays(dayOffsets: [0, 1, 2, 3, 8, 9, 10, 11]), 3)
        XCTAssertEqual(TrendCadence.gapLimitDays(dayOffsets: [0, 7, 14, 21, 28]), 21)
        XCTAssertEqual(TrendCadence.gapLimitDays(dayOffsets: [0, 7, 21, 28, 35]), 21)
        XCTAssertEqual(TrendCadence.gapLimitDays(dayOffsets: []), 3)
        XCTAssertEqual(TrendCadence.gapLimitDays(dayOffsets: [9]), 3)
    }
}
