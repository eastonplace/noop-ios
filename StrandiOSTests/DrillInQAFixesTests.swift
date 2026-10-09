import XCTest
@testable import NOOP
import StrandDesign

/// The drill-in review fixes: one word per recovery score, one colour per stress band, honest rankings, and the
/// Deep Timeline's day-level totals.
final class DrillInQAFixesTests: XCTestCase {
    // MARK: Recovery words follow the bands the colours follow

    func testRecoveryWordChangesExactlyWhereTheBandColourDoes() {
        XCTAssertEqual(RecoveryBands.word(for: 0), "Low")
        XCTAssertEqual(RecoveryBands.word(for: 33.9), "Low")
        XCTAssertEqual(RecoveryBands.word(for: 34), "Moderate")
        XCTAssertEqual(RecoveryBands.word(for: 66.9), "Moderate")
        XCTAssertEqual(RecoveryBands.word(for: 67), "Good")
        XCTAssertEqual(RecoveryBands.word(for: 100), "Good")
    }

    // MARK: Stress colour is the band's colour

    func testStressColourIsConstantWithinABandAndChangesAtTheWordEdges() {
        // Same band, same colour: 2.0 and 3.0 are both "High", so they wear one colour (the old ramp blended them).
        XCTAssertEqual(StressHeatStyle.color(for: 2.0), StressHeatStyle.color(for: 3.0))
        XCTAssertEqual(StressHeatStyle.color(for: 1.0), StressHeatStyle.color(for: 1.99))
        XCTAssertEqual(StressHeatStyle.color(for: 0), StressHeatStyle.color(for: 0.99))
        // The band index and the word agree at every edge.
        for (level, word) in [(0.99, "Low"), (1.0, "Moderate"), (1.99, "Moderate"), (2.0, "High"), (2.4, "High")] {
            XCTAssertEqual(StressModuleBand.word(level), word)
            XCTAssertEqual(StressHeatStyle.color(for: level),
                           StressHeatStyle.zoneColor(StressModuleBand.band(level)))
        }
        XCTAssertNotEqual(StressHeatStyle.color(for: 0.99), StressHeatStyle.color(for: 1.0))
        XCTAssertNotEqual(StressHeatStyle.color(for: 1.99), StressHeatStyle.color(for: 2.0))
    }

    // MARK: How today ranks

    func testStandingCountsTiesAsHalfADayBeaten() {
        XCTAssertEqual(PaperPillarDetailView.standingPercent(of: 50, among: [50, 50, 50, 50]), 50)
        XCTAssertEqual(PaperPillarDetailView.standingPercent(of: 90, among: [10, 20, 30, 40]), 100)
        XCTAssertEqual(PaperPillarDetailView.standingPercent(of: 5, among: [10, 20, 30, 40]), 0)
        XCTAssertEqual(PaperPillarDetailView.standingPercent(of: 30, among: [10, 20, 30, 40]), 50)
        XCTAssertEqual(PaperPillarDetailView.standingPercent(of: 30, among: []), 0)
    }

    // MARK: Time in range

    func testZoneDurationNamesASliverAndAnEmptyZone() {
        XCTAssertEqual(FullDayChartView.zoneDuration(0), WidgetMetrics.missingValue)
        XCTAssertEqual(FullDayChartView.zoneDuration(30), "<1m")
        XCTAssertEqual(FullDayChartView.zoneDuration(59), "<1m")
        XCTAssertNotEqual(FullDayChartView.zoneDuration(60), "<1m")
        XCTAssertTrue(FullDayChartView.zoneDuration(3_900).contains("1"))
    }

    // MARK: Range control

    func testRangeDaysAndTitles() {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let earliest = calendar.date(byAdding: .day, value: -499, to: today)
        XCTAssertEqual(DrillInRange.week.days(earliest: earliest, through: today, calendar: calendar), 7)
        XCTAssertEqual(DrillInRange.year.days(earliest: earliest, through: today, calendar: calendar), 365)
        XCTAssertEqual(DrillInRange.all.days(earliest: earliest, through: today, calendar: calendar), 500)
        // A short history never collapses ALL below a month.
        XCTAssertEqual(DrillInRange.all.days(earliest: today, through: today, calendar: calendar), 30)
        XCTAssertEqual(DrillInRange.all.days(earliest: nil, through: today, calendar: calendar), 30)
        XCTAssertEqual(DrillInRange.standard, [.week, .month, .quarter, .half])
        XCTAssertEqual(DrillInRange.extended.last, .all)
        XCTAssertTrue(DrillInRange.all.showsYear && DrillInRange.year.showsYear && !DrillInRange.half.showsYear)
    }
}
