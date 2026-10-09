import XCTest
import StrandDesign
@testable import NOOP

/// The pure rules behind the Sleep tab's presentation: value splitting, the balance strip's scale, the "on typical"
/// flag, the shares of the night, the score bands, the stage timeline and the spoken durations.
final class SleepScreenPartsTests: XCTestCase {
    // MARK: SleepValueSplit

    func testValueSplitSeparatesAUnitFromItsNumber() {
        let en = Locale(identifier: "en_US")
        XCTAssertTrue(SleepValueSplit.parts("55 bpm", locale: en) == ("55", "bpm"))
        XCTAssertTrue(SleepValueSplit.parts("7:00 AM", locale: en) == ("7:00", "AM"))
        // The narrow no-break space ICU puts before AM/PM is treated as the space it is.
        XCTAssertTrue(SleepValueSplit.parts("7:00\u{202F}PM", locale: en) == ("7:00", "PM"))
    }

    func testValueSplitKeepsCompoundsWhole() {
        let en = Locale(identifier: "en_US")
        XCTAssertTrue(SleepValueSplit.parts("6h 49m", locale: en) == ("6h 49m", nil))
        XCTAssertTrue(SleepValueSplit.parts("12 of 21", locale: en) == ("12 of 21", nil))
        XCTAssertTrue(SleepValueSplit.parts("—", locale: en) == ("—", nil))
        XCTAssertTrue(SleepValueSplit.parts("Unavailable", locale: en) == ("Unavailable", nil))
    }

    func testValueSplitMatchesTheLocalesOwnDayPeriodSymbols() {
        // Spanish writes "a. m." / "p. m.", two tokens: the old "last word" rule would have cut "7:00 a." / "m.".
        let es = Locale(identifier: "es_ES")
        let formatter = DateFormatter()
        formatter.locale = es
        func plain(_ text: String) -> String {
            text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        }
        let am = plain(formatter.amSymbol ?? "a. m.")
        let pm = plain(formatter.pmSymbol ?? "p. m.")
        XCTAssertTrue(am.contains(" "), "Spanish day periods are multi-token; this test needs that")
        XCTAssertTrue(SleepValueSplit.parts("7:00 \(am)", locale: es) == ("7:00", am))
        XCTAssertTrue(SleepValueSplit.parts("11:30\u{202F}\(pm)", locale: es) == ("11:30", pm))
    }

    func testValueSplitShowsNoUnitOnA24HourClock() {
        let de = Locale(identifier: "de_DE")
        XCTAssertTrue(SleepValueSplit.parts("06:49", locale: de) == ("06:49", nil))
        XCTAssertTrue(SleepValueSplit.parts("19:05", locale: de) == ("19:05", nil))
    }

    // MARK: Balance strip scale

    func testBalanceGeometryGivesSurplusAndDebtOneScale() {
        let layout = SleepBalanceBars.Geometry(minutes: [40, -20], height: 62)
        XCTAssertEqual(layout.perMinute, 1, accuracy: 0.0001)
        XCTAssertEqual(layout.mid, 41, accuracy: 0.0001)
        XCTAssertEqual(layout.barHeight(for: 40), 39, accuracy: 0.0001)
        XCTAssertEqual(layout.barHeight(for: -20), 19, accuracy: 0.0001)
        // A tiny night is still drawn.
        XCTAssertEqual(layout.barHeight(for: 1), 3, accuracy: 0.0001)
    }

    func testBalanceGeometryPutsTheCentreLineAtTheEdgeWhenOnlyOneSideHasBars() {
        let debtOnly = SleepBalanceBars.Geometry(minutes: [-30, -90], height: 62)
        XCTAssertEqual(debtOnly.mid, 6, accuracy: 0.0001, "no empty half above a fortnight of debt")
        XCTAssertEqual(debtOnly.barHeight(for: -90), 62 - 6 - 2, accuracy: 0.0001)

        let surplusOnly = SleepBalanceBars.Geometry(minutes: [30, 60], height: 62)
        XCTAssertEqual(surplusOnly.mid, 56, accuracy: 0.0001, "no empty half below a fortnight of surplus")
        XCTAssertEqual(surplusOnly.barHeight(for: 60), 54, accuracy: 0.0001)
    }

    func testBalanceGeometryHandlesNoNights() {
        let layout = SleepBalanceBars.Geometry(minutes: [], height: 62)
        XCTAssertEqual(layout.mid, 6, accuracy: 0.0001)
        XCTAssertTrue(layout.perMinute.isFinite)
    }

    // MARK: "On typical"

    func testIsOnTypicalIsWithinHalfAMinute() {
        func presentation(_ minutes: Double, typical: Double?) -> SleepStageRowPresentation {
            SleepStageRowPresentation(stage: .deep, minutes: minutes, total: 400, typical: typical)
        }
        XCTAssertTrue(presentation(90, typical: 90).isOnTypical)
        XCTAssertTrue(presentation(90.4, typical: 90).isOnTypical)
        XCTAssertFalse(presentation(90.5, typical: 90).isOnTypical)
        XCTAssertFalse(presentation(91, typical: 90).isOnTypical)
        XCTAssertFalse(presentation(89, typical: 90).isOnTypical)
        XCTAssertFalse(presentation(90, typical: nil).isOnTypical)
        XCTAssertFalse(presentation(90, typical: 0).isOnTypical)
    }

    // MARK: Shares of the night

    func testStageSharesAlwaysAddUpToOneHundred() {
        for minutes in [[301.0, 280, 100, 19], [1, 1, 1], [33, 33, 34], [200, 100, 50, 50], [7, 0, 0, 3]] {
            let shares = SleepStageShares.percents(minutes: minutes)
            XCTAssertEqual(shares.reduce(0, +), 100, "\(minutes) -> \(shares)")
            XCTAssertEqual(shares.count, minutes.count)
        }
    }

    func testStageSharesGiveALeftoverPointOnlyToAStageThatHasMinutes() {
        XCTAssertEqual(SleepStageShares.percents(minutes: [1, 1, 1]), [34, 33, 33])
        XCTAssertEqual(SleepStageShares.percents(minutes: [7, 0, 0, 3]), [70, 0, 0, 30])
    }

    func testStageSharesAreZeroWithoutAnyMinutes() {
        XCTAssertEqual(SleepStageShares.percents(minutes: [0, 0, 0, 0]), [0, 0, 0, 0])
        XCTAssertEqual(SleepStageShares.percents(minutes: []), [])
    }

    // MARK: Score bands

    func testScoreBandUsesTheScoreAsTheDialShowsIt() {
        XCTAssertEqual(SleepScoreBand(score: 0), .poor)
        XCTAssertEqual(SleepScoreBand(score: 49.4), .poor)
        XCTAssertEqual(SleepScoreBand(score: 49.6), .fair, "49.6 shows as 50, which is Fair")
        XCTAssertEqual(SleepScoreBand(score: 69.4), .fair)
        XCTAssertEqual(SleepScoreBand(score: 69.5), .good)
        XCTAssertEqual(SleepScoreBand(score: 84.6), .optimal)
        XCTAssertEqual(SleepScoreBand(score: 100), .optimal)
    }

    // MARK: Need breakdown

    func testNeedBreakdownShowsOnlyWhenV2IsComputed() {
        XCTAssertFalse(SleepNeedBreakdownVisibility.isVisible(mode: .off))
        XCTAssertTrue(SleepNeedBreakdownVisibility.isVisible(mode: .shadow))
        XCTAssertTrue(SleepNeedBreakdownVisibility.isVisible(mode: .on))
    }

    // MARK: Stage timeline

    @MainActor
    func testTimelineClipsOverlapsAndKeepsGaps() {
        let timeline = SleepStageTimeline([
            SleepInterval(stage: .light, start: 300, end: 1200),   // overlaps the deep fragment before it
            SleepInterval(stage: .deep, start: 0, end: 600),
            SleepInterval(stage: .rem, start: 5000, end: 5600),    // a separate fragment after a long gap
        ])
        XCTAssertEqual(timeline.origin, 0)
        XCTAssertEqual(timeline.span, 5600)
        XCTAssertEqual(timeline.intervals.count, 3)
        for (previous, next) in zip(timeline.intervals, timeline.intervals.dropFirst()) {
            XCTAssertGreaterThanOrEqual(next.start, previous.end, "no overlaps")
        }
        XCTAssertTrue(timeline.joins(timeline.intervals[0], timeline.intervals[1]))
        XCTAssertFalse(timeline.joins(timeline.intervals[1], timeline.intervals[2]), "no riser across a gap")
        // The overlapped time is counted once.
        XCTAssertEqual(timeline.stageMinutes[.deep] ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(timeline.stageMinutes[.light] ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(timeline.stageMinutes[.rem] ?? 0, 10, accuracy: 0.001)
    }

    @MainActor
    func testTimelineSmoothsEachRunWithoutBridgingAGap() {
        let timeline = SleepStageTimeline([
            SleepInterval(stage: .light, start: 0, end: 1800),
            SleepInterval(stage: .deep, start: 1800, end: 2400),
            SleepInterval(stage: .awake, start: 2400, end: 2460),  // a minute: absorbed into a neighbour
            SleepInterval(stage: .deep, start: 2460, end: 3000),
            SleepInterval(stage: .rem, start: 9000, end: 9060),    // a minute on its own after a gap: kept
        ], minimumSegment: 300)
        XCTAssertFalse(timeline.intervals.contains { $0.stage == .awake })
        XCTAssertEqual(timeline.intervals.last?.stage, .rem)
        XCTAssertEqual(timeline.intervals.last?.start, 9000)
        XCTAssertEqual(timeline.intervals.last?.end, 9060)
    }

    @MainActor
    func testEmptyTimelineIsEmpty() {
        XCTAssertTrue(SleepStageTimeline([]).isEmpty)
    }

    // MARK: Spoken durations

    func testSpokenDurationIsWordsInTheUsersLanguage() {
        let en = Locale(identifier: "en_US")
        let long = SleepSpokenDuration.text(minutes: 125, locale: en)
        XCTAssertTrue(long.contains("2 hours"), long)
        XCTAssertTrue(long.contains("5 minutes"), long)
        XCTAssertTrue(SleepSpokenDuration.text(minutes: 45, locale: en).contains("45 minutes"))
        XCTAssertTrue(SleepSpokenDuration.text(minutes: 60, locale: en).contains("1 hour"))
        XCTAssertTrue(SleepSpokenDuration.text(minutes: 0, locale: en).contains("0 minutes"))
        XCTAssertTrue(SleepSpokenDuration.text(minutes: 125, locale: Locale(identifier: "es_ES")).contains("horas"))
    }
}
