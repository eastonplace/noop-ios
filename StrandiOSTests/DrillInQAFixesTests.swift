import SwiftUI
import XCTest
@testable import NOOP
import StrandDesign

/// The drill-in review fixes: one word per recovery score, one colour per stress band, honest rankings, and the
/// Deep Timeline's day-level totals.
@MainActor
final class DrillInQAFixesTests: XCTestCase {
    // MARK: One recovery word per score, and it never crosses a colour band

    func testRecoveryWordEdges() {
        // The cuts are on the score as drawn, whole points with a half rounding up: a 24.5 is drawn "25".
        XCTAssertEqual(RecoveryBands.word(for: 0), "Depleted")
        XCTAssertEqual(RecoveryBands.word(for: 24.4), "Depleted")
        XCTAssertEqual(RecoveryBands.word(for: 24.5), "Low")
        XCTAssertEqual(RecoveryBands.word(for: 33.4), "Low")
        XCTAssertEqual(RecoveryBands.word(for: 33.5), "Moderate")
        XCTAssertEqual(RecoveryBands.word(for: 66.4), "Moderate")
        XCTAssertEqual(RecoveryBands.word(for: 66.5), "Primed")
        XCTAssertEqual(RecoveryBands.word(for: 87.4), "Primed")
        XCTAssertEqual(RecoveryBands.word(for: 87.5), "Peak")
        XCTAssertEqual(RecoveryBands.word(for: 100), "Peak")
    }

    func testEveryRecoveryWordWearsExactlyOneColour() {
        var colours: [String: Set<Color>] = [:]
        for tenth in 0...1000 {
            let score = Double(tenth) / 10
            colours[RecoveryBands.word(for: score), default: []].insert(RecoveryBands.color(for: score))
        }
        XCTAssertEqual(Set(colours.keys), ["Depleted", "Low", "Moderate", "Primed", "Peak"])
        for (word, set) in colours { XCTAssertEqual(set.count, 1, "\(word) wears more than one colour") }
    }

    /// What the screens print for a score, asked of the call sites themselves: the caption under Today's pillar card
    /// and the caps word the ring and the heat-strip tooltip draw. Literal words, so a call site that drifts to its own
    /// cut points (the old 50/70 and 35/70 cuts) fails here.
    func testTheCallSitesPrintTheBandWordOfTheScoreAsDrawn() {
        let drawn: [(Double, String)] = [(10, "Depleted"), (40, "Moderate"), (60, "Moderate"), (66.6, "Primed"),
                                         (80, "Primed"), (87.5, "Peak"), (95, "Peak")]
        for (score, word) in drawn {
            XCTAssertEqual(TodayView.paperScoreState(score, kind: .charge), word, "Today caption for \(score)")
            XCTAssertEqual(StrandPalette.recoveryState(score), word.uppercased(), "ring caps for \(score)")
        }
        XCTAssertEqual(TodayView.paperScoreState(nil, kind: .charge), "Not rated")
        XCTAssertEqual(TodayView.paperScoreState(.nan, kind: .charge), "Depleted")
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
        // Two days beaten and one tied is 2.5 of 4 days: 62.5%, shown as 63.
        XCTAssertEqual(PaperPillarDetailView.standingPercent(of: 30, among: [10, 20, 30, 40]), 63)
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

    // MARK: Time in range belongs to its day

    func testTimeInRangeTotalsAreOnlyShownForTheirOwnDay() {
        let monday = Date(timeIntervalSince1970: 1_700_000_000)
        let tuesday = monday.addingTimeInterval(86_400)
        let totals = FullDayChartView.ZoneTotals(day: monday, seconds: [600, 1_200, 60])
        XCTAssertEqual(totals.seconds(for: monday), [600, 1_200, 60])
        // Stepping to the next day before its read lands (or after a read that was cancelled) draws no totals,
        // never Monday's under Tuesday.
        XCTAssertEqual(totals.seconds(for: tuesday), [0, 0, 0])
    }

    // MARK: The spoken stress hour is one format string and follows the app's clock

    func testTheSpokenStressHourNamesItsBandAndFollowsTheAppsClock() {
        var slots = [Double?](repeating: nil, count: 24)
        slots[7] = 2.6
        let twelve = StressHero.spokenHour(7, in: slots, locale: Locale(identifier: "en_US@hours=h12"))
        let twentyFour = StressHero.spokenHour(7, in: slots, locale: Locale(identifier: "en_US@hours=h23"))
        XCTAssertTrue(twelve.contains("AM"), twelve)
        XCTAssertFalse(twentyFour.contains("AM") || twentyFour.contains("PM"), twentyFour)
        for spoken in [twelve, twentyFour] {
            XCTAssertTrue(spoken.contains(StressHero.bandWord(2.6)), spoken)
            XCTAssertTrue(spoken.contains(DrillInFormat.number(2.6, fractionDigits: 1)), spoken)
        }
        // An hour that carried no signal says so, in the same clock.
        let silent = StressHero.spokenHour(8, in: slots, locale: Locale(identifier: "en_US@hours=h23"))
        XCTAssertTrue(silent.contains("no signal"), silent)
        XCTAssertFalse(silent.contains("AM") || silent.contains("PM"), silent)
    }
}
