import XCTest
import StrandDesign
import WhoopStore
@testable import NOOP

/// The words on the Scores rows. Strain once showed 2.7 here while Training load and the weekly readout showed
/// 11.8 for the same day: the series is already on the 0–21 display scale, and the row scaled it a second time.
final class TrendsSummaryRowTextTests: XCTestCase {
    private func date(_ day: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    private func days(from first: Int, count: Int, recovery: Double? = nil, strain: Double? = nil,
                      hrv: Double? = nil) -> [DailyMetric] {
        (first..<(first + count)).map { index in
            DailyMetric(
                day: String(format: "2026-07-%02d", index), totalSleepMin: nil, efficiency: nil, deepMin: nil,
                remMin: nil, lightMin: nil, disturbances: nil, restingHr: nil, avgHrv: hrv,
                recovery: recovery, strain: strain, exerciseCount: nil
            )
        }
    }

    private func presentation(
        _ points: [TrendPoint], previous: [TrendPoint], good: TrendSummaryGoodDirection, expected: Int = 7
    ) -> TrendSummaryPresentation {
        TrendSummaryPresentation(series: points, previousSeries: previous, goodDirection: good, expectedCount: expected)
    }

    func testStrainRowShowsTheDisplayScaleOnceNotScaledTwice() {
        // Stored strain 60 is 12.6 on the 0–21 scale, and 50 is 10.5.
        let current = PaperTrendSeries.build(days: days(from: 8, count: 7, strain: 60), sleepByDay: [:], date: date)
        let previous = PaperTrendSeries.build(days: days(from: 1, count: 7, strain: 50), sleepByDay: [:], date: date)

        let text = TrendsSummaryRowText(
            metric: .strain,
            presentation: presentation(current.strain, previous: previous.strain, good: .neutral)
        )

        XCTAssertEqual(text.latest, "12.6")
        XCTAssertNotEqual(text.latest, "2.6", "the display-scale value must not be scaled a second time")
        XCTAssertEqual(text.delta, "+2.1 avg")
        XCTAssertEqual(text.tone, .neutral, "strain moving either way is neither good nor bad")
    }

    func testStrainRowFormatsTheSeriesValueTheSameWayTheMetricDoes() throws {
        let series = PaperTrendSeries.build(days: days(from: 1, count: 7, strain: 56), sleepByDay: [:], date: date)
        let value = try XCTUnwrap(series.strain.last?.value)
        XCTAssertEqual(value, StrainScale.displayValue(fromStored: 56))

        let text = TrendsSummaryRowText(
            metric: .strain,
            presentation: presentation(series.strain, previous: [], good: .neutral)
        )
        XCTAssertEqual(text.latest, ProductionTrendMetric.strain.format(value))
    }

    func testRecoveryAndHRVRowsKeepTheirUnitsAndTones() {
        let recoveryNow = PaperTrendSeries.build(days: days(from: 8, count: 7, recovery: 70), sleepByDay: [:], date: date)
        let recoveryBefore = PaperTrendSeries.build(days: days(from: 1, count: 7, recovery: 60), sleepByDay: [:], date: date)
        let recovery = TrendsSummaryRowText(
            metric: .recovery,
            presentation: presentation(recoveryNow.recovery, previous: recoveryBefore.recovery, good: .higher)
        )
        XCTAssertEqual(recovery.latest, "70")
        XCTAssertEqual(recovery.delta, "+10 avg")
        XCTAssertEqual(recovery.tone, .positive)

        let hrvNow = PaperTrendSeries.build(days: days(from: 8, count: 7, hrv: 60), sleepByDay: [:], date: date)
        let hrvBefore = PaperTrendSeries.build(days: days(from: 1, count: 7, hrv: 64), sleepByDay: [:], date: date)
        let hrv = TrendsSummaryRowText(
            metric: .hrv,
            presentation: presentation(hrvNow.hrv, previous: hrvBefore.hrv, good: .higher)
        )
        XCTAssertEqual(hrv.latest, "60 ms")
        XCTAssertEqual(hrv.delta, "−4 ms avg")
        XCTAssertEqual(hrv.tone, .negative)
    }

    func testAChangeThatRoundsToNothingReadsNoChangeWithoutColour() {
        let now = PaperTrendSeries.build(days: days(from: 8, count: 7, recovery: 70), sleepByDay: [:], date: date)
        let before = PaperTrendSeries.build(days: days(from: 1, count: 7, recovery: 70.2), sleepByDay: [:], date: date)
        let text = TrendsSummaryRowText(
            metric: .recovery,
            presentation: presentation(now.recovery, previous: before.recovery, good: .higher)
        )
        XCTAssertEqual(text.delta, String(localized: "No change"))
        XCTAssertEqual(text.tone, .neutral)
    }

    func testSparseAndMissingHistoryAreSaidPlainly() {
        let now = PaperTrendSeries.build(days: days(from: 12, count: 2, recovery: 70), sleepByDay: [:], date: date)
        let early = TrendsSummaryRowText(
            metric: .recovery,
            presentation: presentation(now.recovery, previous: [], good: .higher)
        )
        XCTAssertEqual(early.delta, "Early read · 2/7 days")
        XCTAssertEqual(early.tone, .neutral)

        let none = TrendsSummaryRowText(
            metric: .recovery,
            presentation: presentation([], previous: [], good: .higher)
        )
        XCTAssertEqual(none.latest, "—")
    }
}
