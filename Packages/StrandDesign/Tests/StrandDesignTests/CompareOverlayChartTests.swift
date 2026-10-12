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

    // MARK: Thinning a long series

    private func drawn(_ offsets: [Int]) -> (drawn: [TrendPoint], runs: [Range<Int>]) {
        let points = offsets.enumerated().map { TrendPoint(date: date($0.element), value: Double($0.offset % 7)) }
        return CompareOverlayGeometry.drawnLine(
            points: points, dayOffsets: offsets, gapLimit: TrendCadence.gapLimitDays(dayOffsets: offsets))
    }

    /// About three years of daily readings is thinned to a few hundred vertices, and it is still one continuous line: the
    /// thinned points sit further apart than three days, which is no reason to break the line.
    func testAThreeYearDailySeriesIsThinnedAndStaysOneContinuousLine() {
        let line = drawn(Array(0..<1_100))
        XCTAssertLessThan(line.drawn.count, 1_100)
        XCTAssertLessThanOrEqual(line.drawn.count, 420)
        XCTAssertEqual(line.runs, [0..<line.drawn.count])
        XCTAssertEqual(line.drawn.first?.date, date(0))
        XCTAssertEqual(line.drawn.last?.date, date(1_099))
        // Ascending, so the line never doubles back.
        XCTAssertEqual(line.drawn.map(\.date), line.drawn.map(\.date).sorted())
    }

    /// A real hole in the readings is still a gap, and each side is thinned on its own.
    func testARealGapStillBreaksTheLineAndEachSideKeepsItsEnds() {
        let offsets = Array(0..<600) + Array(700..<1_300)
        let line = drawn(offsets)
        XCTAssertEqual(line.runs.count, 2)
        XCTAssertEqual(line.runs.last?.upperBound, line.drawn.count)
        let first = line.drawn[line.runs[0]]
        let second = line.drawn[line.runs[1]]
        XCTAssertEqual(first.first?.date, date(0))
        XCTAssertEqual(first.last?.date, date(599))
        XCTAssertEqual(second.first?.date, date(700))
        XCTAssertEqual(second.last?.date, date(1_299))
        XCTAssertLessThan(line.drawn.count, offsets.count)
    }

    func testAShortSeriesIsDrawnAsItIsAndAWeeklyOneStaysConnected() {
        let daily = drawn(Array(0..<60))
        XCTAssertEqual(daily.drawn.count, 60)
        XCTAssertEqual(daily.runs, [0..<60])
        let weekly = drawn((0..<200).map { $0 * 7 })
        XCTAssertEqual(weekly.runs.count, 1)
        XCTAssertEqual(weekly.runs.first?.count, weekly.drawn.count)
        XCTAssertTrue(drawn([]).runs.isEmpty)
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
