import XCTest
@testable import StrandImport

final class AppleSleepEpisodeRegressionTests: XCTestCase {
    private func interval(_ stage: SleepStage, _ start: String, _ end: String,
                          source: String = "Watch", offset: Int = 0) -> SleepStageInterval {
        let parser = ISO8601DateFormatter()
        return SleepStageInterval(stage: stage, start: parser.date(from: start)!,
                                  end: parser.date(from: end)!, tzOffsetMin: offset, sourceName: source)
    }

    func testPreMidnightStagesStayOnWholeEpisodeWakeDay() throws {
        let result = AppleHealthAggregator.sleepDaily([
            interval(.asleepCore, "2024-03-09T22:00:00Z", "2024-03-09T23:00:00Z"),
            interval(.asleepDeep, "2024-03-09T23:00:00Z", "2024-03-10T01:00:00Z"),
            interval(.asleepCore, "2024-03-10T01:00:00Z", "2024-03-10T07:00:00Z")
        ])
        XCTAssertNil(result["2024-03-09"])
        let night = try XCTUnwrap(result["2024-03-10"])
        XCTAssertEqual(night.asleep, 540)
        XCTAssertEqual(night.core, 420)
    }

    func testDetailedStagesWinOverOverlappingSummariesAndDuplicates() throws {
        let stages = [
            interval(.asleepCore, "2024-03-10T00:00:00Z", "2024-03-10T06:00:00Z"),
            interval(.asleepDeep, "2024-03-10T06:00:00Z", "2024-03-10T07:00:00Z"),
            interval(.asleepREM, "2024-03-10T07:00:00Z", "2024-03-10T08:00:00Z"),
            interval(.asleepUnspecified, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z", source: "Summary"),
            interval(.asleepUnspecified, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z", source: "Other")
        ]
        for input in [stages, Array(stages.reversed()), stages + stages] {
            let night = try XCTUnwrap(AppleHealthAggregator.sleepDaily(input)["2024-03-10"])
            XCTAssertEqual(night.asleep, 480)
            XCTAssertEqual(night.core, 360)
            XCTAssertEqual(night.deep, 60)
            XCTAssertEqual(night.rem, 60)
        }
    }

    func testAwakeDetailedEvidenceOverridesSummarySleep() throws {
        let night = try XCTUnwrap(AppleHealthAggregator.sleepDaily([
            interval(.asleepUnspecified, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z", source: "Summary"),
            interval(.awake, "2024-03-10T03:00:00Z", "2024-03-10T03:30:00Z")
        ])["2024-03-10"])
        XCTAssertEqual(night.asleep, 450)
        XCTAssertEqual(night.awake, 30)
    }

    func testDSTUsesAbsoluteDurationAndFinalWakeOffset() throws {
        let night = try XCTUnwrap(AppleHealthAggregator.sleepDaily([
            interval(.asleepCore, "2024-03-10T03:00:00Z", "2024-03-10T04:00:00Z", offset: -300),
            interval(.asleepDeep, "2024-03-10T04:00:00Z", "2024-03-10T07:00:00Z", offset: -240),
            interval(.asleepCore, "2024-03-10T07:00:00Z", "2024-03-10T11:00:00Z", offset: -240)
        ])["2024-03-10"])
        XCTAssertEqual(night.asleep, 480)
        XCTAssertEqual(night.deep, 180)
    }

    func testNapsAddToWakeDayWithoutMovingPreviousNight() throws {
        let result = AppleHealthAggregator.sleepDaily([
            interval(.asleepCore, "2024-03-09T22:00:00Z", "2024-03-10T06:00:00Z"),
            interval(.asleepCore, "2024-03-10T15:00:00Z", "2024-03-10T15:30:00Z"),
            interval(.asleepCore, "2024-03-10T23:00:00Z", "2024-03-11T07:00:00Z")
        ])
        XCTAssertEqual(try XCTUnwrap(result["2024-03-10"]).asleep, 510)
        XCTAssertEqual(try XCTUnwrap(result["2024-03-11"]).asleep, 480)
    }

    func testPartiallyOverlappingSourcesUseIntervalUnion() throws {
        let night = try XCTUnwrap(AppleHealthAggregator.sleepDaily([
            interval(.asleepUnspecified, "2024-03-10T00:00:00Z", "2024-03-10T06:00:00Z", source: "A"),
            interval(.asleepUnspecified, "2024-03-10T04:00:00Z", "2024-03-10T08:00:00Z", source: "B")
        ])["2024-03-10"])
        XCTAssertEqual(night.asleep, 480)
    }
}
