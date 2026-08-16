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

    func testCoverageModesStaySharedAcrossStressSurfaces() {
        let scored = result(hours: [
            .init(hour: 9, startTs: 1, level: 1.4, meanHR: 70, rmssd: nil)
        ])

        XCTAssertEqual(StressPresentation.mode(dailyAvailable: true, intraday: scored), .combined)
        XCTAssertEqual(StressPresentation.mode(dailyAvailable: false, intraday: scored), .intradayOnly)
        XCTAssertEqual(StressPresentation.mode(dailyAvailable: true, intraday: .empty), .dailyOnly)
        XCTAssertEqual(StressPresentation.mode(dailyAvailable: false, intraday: .empty), .baselineCalibration)
    }

    func testIntradayHeadlineUsesLatestScoredHourWithoutChangingFormula() {
        let read = result(hours: [
            .init(hour: 9, startTs: 1, level: 0.8, meanHR: 65, rmssd: nil),
            .init(hour: 10, startTs: 2, level: nil, meanHR: nil, rmssd: nil),
            .init(hour: 11, startTs: 3, level: 2.1, meanHR: 85, rmssd: nil)
        ])

        XCTAssertEqual(
            StressPresentation.headlineScore(dailyScore: nil, intraday: read),
            2.1
        )
    }

    func testUnscoredIntradayHoursAreLoadedContentButHaveNoHeadline() {
        let read = result(hours: [
            .init(hour: 9, startTs: 1, level: nil, meanHR: 65, rmssd: nil)
        ])

        XCTAssertEqual(StressPresentation.mode(dailyAvailable: false, intraday: read), .intradayOnly)
        XCTAssertNil(StressPresentation.headlineScore(dailyScore: nil, intraday: read))
    }

    func testLoadedContentAndGapCopyStayDistinct() {
        XCTAssertTrue(StressPresentationMode.intradayOnly.hasLoadedContent)
        XCTAssertTrue(StressPresentationMode.dailyOnly.lacksSameDaySignal)
        XCTAssertFalse(StressPresentationMode.baselineCalibration.hasLoadedContent)
        XCTAssertEqual(StressModuleBand.word(nil, mode: .dailyOnly), "No same-day signal")
        XCTAssertEqual(StressModuleBand.word(nil, mode: .baselineCalibration), "Calibrating")
    }
}
