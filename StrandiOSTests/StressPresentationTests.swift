import XCTest
@testable import NOOP
import StrandAnalytics
import StrandDesign
import WhoopStore

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

    private func day(_ key: String, rhr: Int? = nil, hrv: Double? = nil) -> DailyMetric {
        DailyMetric(
            day: key,
            totalSleepMin: nil,
            efficiency: nil,
            deepMin: nil,
            remMin: nil,
            lightMin: nil,
            disturbances: nil,
            restingHr: rhr,
            avgHrv: hrv,
            recovery: nil,
            strain: nil,
            exerciseCount: nil,
            skinTempDevC: nil
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

    func testPastDayUsesItsExactPersistedValueRatherThanLatestDay() {
        let days = [
            day("2026-08-14", rhr: 50, hrv: 60),
            day("2026-08-15", rhr: 54, hrv: 50),
            day("2026-08-16", rhr: 60, hrv: 38),
        ]
        let stored = [
            (day: "2026-08-15", value: 0.7),
            (day: "2026-08-16", value: 2.4),
        ]

        XCTAssertEqual(
            StressPresentation.dailyScore(for: "2026-08-15", days: days, stored: stored),
            0.7
        )
        XCTAssertEqual(
            StressPresentation.dailyScore(for: "2026-08-16", days: days, stored: stored),
            2.4
        )
    }

    func testFutureRowsDoNotProvidePastDayCalibrationEvidence() {
        let days = [
            day("2026-08-15"),
            day("2026-08-16", rhr: 60, hrv: 38),
        ]
        let stored = [(day: "2026-08-16", value: 2.4)]

        XCTAssertFalse(
            StressPresentation.historyAvailable(
                for: "2026-08-15",
                days: days,
                stored: stored
            )
        )
        XCTAssertTrue(
            StressPresentation.historyAvailable(
                for: "2026-08-17",
                days: days,
                stored: stored
            )
        )
    }

    func testConvenienceHistoryCheckUsesLatestDayAcrossUnsortedInputs() {
        let days = [
            day("2026-08-16", rhr: 60, hrv: 38),
            day("2026-08-14", rhr: 50, hrv: 60),
        ]
        let stored = [(day: "2026-08-15", value: 1.1)]

        XCTAssertTrue(
            StressPresentation.historyAvailable(days: days, stored: stored)
        )
    }

    func testMissingTargetDayNeverBorrowsTheLatestDerivedDay() {
        let days = [
            day("2026-08-14", rhr: 50, hrv: 60),
            day("2026-08-16", rhr: 60, hrv: 38),
        ]

        XCTAssertNil(
            StressPresentation.dailyScore(
                for: "2026-08-15",
                days: days,
                stored: []
            )
        )
    }
}
