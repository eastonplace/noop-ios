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
        XCTAssertEqual(CompareLogic.slice(series, days: 12).map(\.day), ["2024-03-01", "2024-03-10", "2024-03-11"])
        XCTAssertEqual(CompareLogic.slice(series, days: 14).count, 6)
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
