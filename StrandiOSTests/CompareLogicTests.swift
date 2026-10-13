import XCTest
@testable import NOOP
import StrandDesign

/// The arithmetic under the Compare screen: windows and lags read off day keys as plain day numbers, the split by the first
/// metric's median, the link wording and the series colours.
final class CompareLogicTests: XCTestCase {
    private typealias Row = (day: String, value: Double)

    private func rows(_ days: [String], start: Double = 1) -> [Row] {
        days.enumerated().map { ($0.element, start + Double($0.offset)) }
    }

    // MARK: Windows

    func testASliceCountsBackFromTheSeriesOwnLatestDay() {
        let series = rows(["2026-01-01", "2026-01-05", "2026-01-09", "2026-01-10"])
        XCTAssertEqual(CompareLogic.slice(series, days: 2).map(\.day), ["2026-01-09", "2026-01-10"])
        XCTAssertEqual(CompareLogic.slice(series, days: 10).map(\.day), series.map(\.day))
        XCTAssertEqual(CompareLogic.slice(series, days: nil).count, 4)
    }

    func testASliceIsTheSameWhateverTheDeviceCalendarOrTimeZone() {
        // A window over a daylight-saving change and a leap day is still a count of calendar days.
        let series = rows(["2024-02-27", "2024-02-28", "2024-02-29", "2024-03-01", "2024-03-10", "2024-03-11"])
        XCTAssertEqual(CompareLogic.slice(series, days: 3).map(\.day), ["2024-03-10", "2024-03-11"])
        // Twelve days ending 11 March reach back to 29 February (the leap day counts as a day).
        XCTAssertEqual(CompareLogic.slice(series, days: 12).map(\.day), ["2024-02-29", "2024-03-01", "2024-03-10", "2024-03-11"])
        XCTAssertEqual(CompareLogic.slice(series, days: 14).count, 6)
    }

    func testTheSpanIsFromTheEarliestFirstToTheLatestLastReading() {
        let a = rows(["2025-01-01", "2025-06-01"])
        let b = rows(["2024-12-30", "2025-02-01"])
        XCTAssertEqual(CompareLogic.spanDays([a, b]), 153)
        XCTAssertEqual(CompareLogic.spanDays([a]), 151)
        XCTAssertEqual(CompareLogic.spanDays([]), 0)
        let unreadable: [Row] = [("not-a-day", 1)]
        XCTAssertEqual(CompareLogic.spanDays([unreadable]), 0)
    }

    // MARK: What the overlay chart is built from

    private func overlayKey(
        _ series: [(id: String, colorIndex: Int, rows: [Row])], zone: String = "Europe/Berlin"
    ) -> String {
        CompareLogic.overlayKey(series, timeZone: zone)
    }

    /// The chart is rebuilt for anything that changes what it draws, and for nothing else.
    func testTheOverlayKeyChangesWithColourReadingsDaysSeriesAndTimeZone() {
        let steps: [Row] = [("2026-10-10", 4000), ("2026-10-11", 6000), ("2026-10-12", 4000)]
        let hrv: [Row] = [("2026-10-10", 50), ("2026-10-11", 55), ("2026-10-12", 52)]
        let base = overlayKey([("hrv", 0, hrv), ("steps", 3, steps)])
        XCTAssertEqual(base, overlayKey([("hrv", 0, hrv), ("steps", 3, steps)]), "Same inputs, same key")

        // A line takes another colour when an empty metric leaves the selection: same rows, new slot.
        XCTAssertNotEqual(base, overlayKey([("hrv", 0, hrv), ("steps", 2, steps)]))
        // A sync changes today's value but not the row count or the first and last day.
        var synced = steps
        synced[2].value = 9000
        XCTAssertEqual(synced.count, steps.count)
        XCTAssertNotEqual(base, overlayKey([("hrv", 0, hrv), ("steps", 3, synced)]))
        // A reading moves to another day with the count and the edges unchanged.
        var moved = steps
        moved[1].day = "2026-10-09"
        XCTAssertNotEqual(base, overlayKey([("hrv", 0, hrv), ("steps", 3, moved)]))
        // The series, their order, and the zone the days are read in.
        XCTAssertNotEqual(base, overlayKey([("steps", 3, steps), ("hrv", 0, hrv)]))
        XCTAssertNotEqual(base, overlayKey([("hrv", 0, hrv)]))
        XCTAssertNotEqual(base, overlayKey([("hrv", 0, hrv), ("steps", 3, steps)], zone: "America/Los_Angeles"))
    }

    func testAFingerprintSeesEveryReadingAndIsStableForTheSameOnes() {
        let rows: [Row] = (0..<1100).map { (ExploreDayKey.key(forDayNumber: 20_000 + $0), Double($0 % 97)) }
        XCTAssertEqual(CompareLogic.fingerprint(rows), CompareLogic.fingerprint(rows))
        var last = rows
        last[last.count - 1].value += 0.5
        XCTAssertNotEqual(CompareLogic.fingerprint(rows), CompareLogic.fingerprint(last))
        var middle = rows
        middle[500].value += 0.5
        XCTAssertNotEqual(CompareLogic.fingerprint(rows), CompareLogic.fingerprint(middle))
        XCTAssertNotEqual(CompareLogic.fingerprint(rows), CompareLogic.fingerprint(Array(rows.dropFirst())))
    }

    /// A day read off a long window, or from another year, carries its year; a day this year on a short window does not.
    func testTheYearIsShownOnALongWindowOrForADayFromAnotherYear() {
        let gregorian = Calendar(identifier: .gregorian)
        let now = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
        let thisYear = gregorian.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12))!
        let lastYear = gregorian.date(from: DateComponents(year: 2025, month: 10, day: 12, hour: 12))!
        XCTAssertFalse(CompareLogic.showsYear(for: thisYear, spanDays: 90, now: now, calendar: gregorian))
        XCTAssertTrue(CompareLogic.showsYear(for: lastYear, spanDays: 90, now: now, calendar: gregorian))
        XCTAssertTrue(CompareLogic.showsYear(for: thisYear, spanDays: 366, now: now, calendar: gregorian))
        XCTAssertFalse(CompareLogic.showsYear(for: thisYear, spanDays: 365, now: now, calendar: gregorian))
    }

    /// The year check follows the calendar the date is shown in: 1 March 2026 is in Persian year 1404 and 12 October 2026
    /// in 1405, so it names its year although both are 2026 in the Gregorian calendar.
    func testTheYearCheckUsesTheCalendarTheDateIsShownIn() {
        let gregorian = Calendar(identifier: .gregorian)
        let persian = Calendar(identifier: .persian)
        let now = gregorian.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 12))!
        let march = gregorian.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 12))!
        XCTAssertFalse(CompareLogic.showsYear(for: march, spanDays: 30, now: now, calendar: gregorian))
        XCTAssertTrue(CompareLogic.showsYear(for: march, spanDays: 30, now: now, calendar: persian))
    }

    func testAnEmptySeriesAndAnUnreadableLastKeySliceToNothing() {
        XCTAssertTrue(CompareLogic.slice([], days: 7).isEmpty)
        XCTAssertTrue(CompareLogic.slice([("2026-13-40", 1)], days: 7).isEmpty)
    }

    func testAnUnreadableKeyInsideAWindowIsDropped() {
        let series: [Row] = [("2026-02-01", 1), ("not-a-day", 2), ("2026-02-02", 3)]
        XCTAssertEqual(CompareLogic.slice(series, days: 5).map(\.day), ["2026-02-01", "2026-02-02"])
    }

    // MARK: Reading a day

    func testTheValueOnADayIsTheLatestReadingForThatKey() {
        let series: [Row] = [("2026-02-01", 1), ("2026-02-02", 2), ("2026-02-02", 5)]
        XCTAssertEqual(CompareLogic.value(in: series, onDay: "2026-02-02"), 5)
        XCTAssertNil(CompareLogic.value(in: series, onDay: "2026-02-03"))
    }

    // MARK: Lags

    func testASameDayPairingMatchesDaysThatBothSeriesRecorded() {
        let a = rows(["2026-03-01", "2026-03-02", "2026-03-04"], start: 10)
        let b = rows(["2026-03-02", "2026-03-03", "2026-03-04"], start: 100)
        let pairs = CompareLogic.lagPairs(a, b, lagDays: 0)
        XCTAssertEqual(pairs.map(\.x), [11, 12])
        XCTAssertEqual(pairs.map(\.y), [100, 102])
    }

    func testANextMorningPairingReadsTheSecondSeriesADayLater() {
        let a = rows(["2026-03-01", "2026-03-02", "2026-03-04"], start: 10)
        let b = rows(["2026-03-02", "2026-03-03", "2026-03-04"], start: 100)
        let pairs = CompareLogic.lagPairs(a, b, lagDays: 1)
        XCTAssertEqual(pairs.map(\.x), [10, 11])
        XCTAssertEqual(pairs.map(\.y), [100, 101])
    }

    func testALagCrossesMonthYearAndLeapDayBoundaries() {
        let a = rows(["2023-12-31", "2024-02-28", "2024-02-29"], start: 1)
        let b = rows(["2024-01-01", "2024-02-29", "2024-03-01"], start: 50)
        let pairs = CompareLogic.lagPairs(a, b, lagDays: 1)
        XCTAssertEqual(pairs.map(\.x), [1, 2, 3])
        XCTAssertEqual(pairs.map(\.y), [50, 51, 52])
    }

    // MARK: Split by the first metric's median

    func testTheSplitAveragesTheSecondMetricOnHighAndLowDaysOfTheFirst() throws {
        let pairs: [(x: Double, y: Double)] = [(1, 10), (2, 20), (8, 60), (9, 80)]
        let split = try XCTUnwrap(CompareLogic.splitMeans(pairs))
        XCTAssertEqual(split.high, 70, accuracy: 1e-9)
        XCTAssertEqual(split.low, 15, accuracy: 1e-9)
    }

    func testTheSplitNeedsTwoPairsAndBothSides() {
        XCTAssertNil(CompareLogic.splitMeans([(1, 1)]))
        // Every x the same: all of them sit at the median, none below it.
        XCTAssertNil(CompareLogic.splitMeans([(4, 1), (4, 2), (4, 3)]))
    }

    // MARK: Link wording shares the correlation rule

    func testALinkIsOnlyDrawnFromModerateUpAndFollowsThePrintedNumber() {
        XCTAssertEqual(CompareLogic.Link(r: 0.0), .none)
        XCTAssertEqual(CompareLogic.Link(r: 0.29), .none)
        // 0.295 prints as 0.30 and reads moderate, so it is a link; the headline can never disagree with the word.
        XCTAssertEqual(CompareLogic.Link(r: 0.295), .rises)
        XCTAssertEqual(CompareLogic.Link(r: -0.295), .falls)
        XCTAssertEqual(CompareLogic.Link(r: 0.7), .rises)
        XCTAssertEqual(CompareLogic.Link(r: -0.9), .falls)
        XCTAssertEqual(CompareLogic.Link(r: .nan), .none)
    }

    func testTheLinkAgreesWithTheStrengthWordForEveryR() {
        for hundredths in -100...100 {
            let r = Double(hundredths) / 100
            let notable = CorrelationStrength(r: r).isNotable
            XCTAssertEqual(CompareLogic.Link(r: r) != .none, notable, "r = \(r)")
        }
    }

    // MARK: Series colours

    private func indices(_ keys: [String]) -> [Int] {
        CompareLogic.colorIndices(
            keys: keys,
            canonical: { $0 == "recovery" ? 0 : ($0 == "sleep_performance" || $0 == "sleep_total_min" ? 1 : nil) },
            paletteCount: 4)
    }

    func testRecoveryAndSleepKeepTheirCanonicalColours() {
        XCTAssertEqual(indices(["sleep_performance", "recovery"]), [1, 0])
    }

    func testNoTwoSelectedSeriesShareAColour() {
        // Two sleep metrics both want slate; the second takes the next free colour.
        let result = indices(["sleep_performance", "sleep_total_min", "hrv", "rhr"])
        XCTAssertEqual(Set(result).count, result.count)
        XCTAssertEqual(result[0], 1)
    }

    func testAMetricWithoutACanonicalColourTakesTheFirstFreeOne() {
        XCTAssertEqual(indices(["hrv", "rhr"]), [0, 1])
    }

    func testAnEarlierMetricNeverTakesTheColourARecoveryOrSleepMetricOwns() {
        // HRV comes first, but Recovery owns blue (0), so HRV takes the first colour no line has.
        XCTAssertEqual(indices(["hrv", "recovery"]), [1, 0])
    }

    func testTheSecondOfTwoMetricsAfterTheSameCanonicalColourMovesOn() {
        XCTAssertEqual(indices(["sleep_performance", "sleep_total_min"]), [1, 0])
    }
}
