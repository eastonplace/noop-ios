import XCTest
@testable import NOOP
import StrandAnalytics
import StrandDesign

final class StressPresentationTests: XCTestCase {
    private func result(hours: [DaytimeStress.HourPoint]) -> DaytimeStress.Result {
        DaytimeStress.Result(
            hours: hours,
            sustainedHigh: false,
            sustainedRun: 0,
            dayMean: hours.compactMap(\.level).first,
            peak: hours.first(where: { $0.level != nil })
        )
    }

    func testCoverageModesDistinguishNoSignalFromFirstBaseline() {
        let scored = result(hours: [
            .init(hour: 9, startTs: 1, level: 1.4, meanHR: 70, rmssd: nil)
        ])

        XCTAssertEqual(
            StressPresentation.mode(dailyAvailable: true, intraday: scored, historyAvailable: true),
            .combined
        )
        XCTAssertEqual(
            StressPresentation.mode(dailyAvailable: false, intraday: scored, historyAvailable: false),
            .intradayOnly
        )
        XCTAssertEqual(
            StressPresentation.mode(dailyAvailable: true, intraday: .empty, historyAvailable: true),
            .dailyOnly
        )
        XCTAssertEqual(
            StressPresentation.mode(dailyAvailable: false, intraday: .empty, historyAvailable: true),
            .empty
        )
        XCTAssertEqual(
            StressPresentation.mode(dailyAvailable: false, intraday: .empty, historyAvailable: false),
            .baselineCalibration
        )
    }

    func testDailyHeadlineRemainsAuthoritativeWhenIntradayAlsoExists() {
        let read = result(hours: [
            .init(hour: 9, startTs: 1, level: 0.8, meanHR: 65, rmssd: nil),
            .init(hour: 11, startTs: 3, level: 2.1, meanHR: 85, rmssd: nil)
        ])

        XCTAssertEqual(
            StressPresentation.headlineScore(dailyScore: 1.2, intraday: read),
            1.2
        )
        XCTAssertEqual(
            StressPresentation.headlineScore(dailyScore: nil, intraday: read),
            2.1
        )
    }

    func testUnscoredIntradayHoursAreLoadedContentButHaveNoHeadline() {
        let read = result(hours: [
            .init(hour: 9, startTs: 1, level: nil, meanHR: 65, rmssd: nil)
        ])

        XCTAssertEqual(
            StressPresentation.mode(dailyAvailable: false, intraday: read, historyAvailable: true),
            .intradayOnly
        )
        XCTAssertNil(StressPresentation.headlineScore(dailyScore: nil, intraday: read))
    }

    func testDailyOnlyUsesTheActualBandWord() {
        XCTAssertEqual(StressModuleBand.word(0.8, mode: .dailyOnly), "Low")
        XCTAssertEqual(StressModuleBand.word(1.4, mode: .dailyOnly), "Moderate")
        XCTAssertEqual(StressModuleBand.word(2.2, mode: .dailyOnly), "High")
        XCTAssertEqual(StressModuleBand.word(nil, mode: .baselineCalibration), "Calibrating")
        XCTAssertEqual(StressModuleBand.word(nil, mode: .empty), "No data")
    }

    func testIntradayCopyDistinguishesBaselineBuilding() {
        XCTAssertEqual(
            StressModuleBand.why(1.4, mode: .intradayOnly, baselineBuilding: true),
            "Same-day signal is available while your daily baseline builds."
        )
        XCTAssertEqual(
            StressModuleBand.why(1.4, mode: .intradayOnly, baselineBuilding: false),
            "Same-day signal is available; a daily score has not landed yet."
        )
    }
}
