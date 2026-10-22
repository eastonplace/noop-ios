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

    func testThirtyMinuteStageGapKeepsEpisodeButLongerGapSeparatesIt() throws {
        let first = interval(.asleepCore, "2024-03-09T23:00:00Z", "2024-03-09T23:30:00Z")
        let continuous = AppleHealthAggregator.sleepDaily([first,
            interval(.asleepCore, "2024-03-10T00:00:00Z", "2024-03-10T00:30:00Z")])
        XCTAssertNil(continuous["2024-03-09"])
        XCTAssertEqual(continuous["2024-03-10"]?.asleep, 60)
        let separate = AppleHealthAggregator.sleepDaily([first,
            interval(.asleepCore, "2024-03-10T00:01:00Z", "2024-03-10T00:30:00Z")])
        XCTAssertEqual(separate["2024-03-09"]?.asleep, 30)
        XCTAssertEqual(separate["2024-03-10"]?.asleep, 29)
    }

    func testDetailedSourcePriorityIsCoverageThenStableSourceIdentity() throws {
        let a = interval(.asleepCore, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z", source: "A")
        let b = interval(.asleepDeep, "2024-03-10T02:00:00Z", "2024-03-10T04:00:00Z", source: "B")
        let tied = interval(.asleepDeep, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z", source: "B")
        for input in [[a, b], [b, a], [a, tied], [tied, a]] {
            let night = try XCTUnwrap(AppleHealthAggregator.sleepDaily(input)["2024-03-10"])
            XCTAssertEqual(night.core, 480)
            XCTAssertEqual(night.deep, 0)
        }
    }

    func testBoundaryCarryMatchesBatchReductionAndDoesNotEmitStageTwice() throws {
        let first = interval(.asleepCore, "2024-03-09T22:00:00Z", "2024-03-09T23:00:00Z")
        let crossing = interval(.asleepDeep, "2024-03-09T23:00:00Z", "2024-03-10T01:00:00Z")
        let last = interval(.asleepCore, "2024-03-10T01:00:00Z", "2024-03-10T07:00:00Z")
        var reducer = AppleSleepEpisodeReducer.Accumulator()
        let parser = ISO8601DateFormatter()
        XCTAssertTrue(reducer.ingest([first, crossing], through: parser.date(from: "2024-03-10T00:00:00Z")!).isEmpty)
        let episodes = reducer.ingest([crossing, last], through: parser.date(from: "2024-03-11T00:00:00Z")!)
        XCTAssertEqual(episodes.count, 1)
        XCTAssertEqual(episodes.first?.wakeDay, "2024-03-10")
        XCTAssertEqual(episodes.first?.asleep, 540)
        XCTAssertEqual(episodes.first?.core, 420)
        XCTAssertEqual(episodes, AppleSleepEpisodeReducer.reduce([first, crossing, last]))
        XCTAssertTrue(reducer.finish().isEmpty)
    }

    func testWakeOffsetUsesFinalEpisodeEvidenceAfterTravelAndFallDST() throws {
        let travel = AppleHealthAggregator.sleepDaily([
            interval(.asleepCore, "2024-03-09T21:00:00Z", "2024-03-09T23:30:00Z", offset: 120),
            interval(.asleepDeep, "2024-03-09T23:30:00Z", "2024-03-10T00:30:00Z", offset: -120)
        ])
        XCTAssertNil(travel["2024-03-10"])
        XCTAssertEqual(travel["2024-03-09"]?.asleep, 210)
        let fall = AppleHealthAggregator.sleepDaily([
            interval(.asleepCore, "2024-11-03T02:00:00Z", "2024-11-03T05:30:00Z", offset: -240),
            interval(.asleepDeep, "2024-11-03T05:30:00Z", "2024-11-03T12:00:00Z", offset: -300)
        ])
        XCTAssertNil(fall["2024-11-02"])
        XCTAssertEqual(fall["2024-11-03"]?.asleep, 600)
    }

    func testInBedEnvelopesAreUnionedSeparatelyFromAsleep() throws {
        let night = try XCTUnwrap(AppleHealthAggregator.sleepDaily([
            interval(.asleepCore, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z"),
            interval(.inBed, "2024-03-09T23:00:00Z", "2024-03-10T08:30:00Z", source: "A"),
            interval(.inBed, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z", source: "B")
        ])["2024-03-10"])
        XCTAssertEqual(night.asleep, 480)
        XCTAssertEqual(night.inBed, 570)
    }

    func testUnknownStageCannotMoveTheWakeDayOfKnownSleep() throws {
        let result = AppleHealthAggregator.sleepDaily([
            interval(.asleepCore, "2024-03-09T22:00:00Z", "2024-03-09T23:00:00Z"),
            interval(.unknown, "2024-03-09T23:00:00Z", "2024-03-10T07:00:00Z")
        ])
        XCTAssertEqual(result["2024-03-09"]?.asleep, 60)
        XCTAssertEqual(result["2024-03-10"]?.asleep, 0)
    }

    func testInBedOnlyIsNotAReadSleepTotalButAwakeCanOverrideObservedSleepToZero() throws {
        let inBed = interval(.inBed, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z")
        let empty = try XCTUnwrap(AppleSleepEpisodeReducer.reduce([inBed]).first)
        XCTAssertFalse(empty.hasAsleepEvidence)
        let observed = try XCTUnwrap(AppleSleepEpisodeReducer.reduce([
            interval(.asleepUnspecified, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z", source: "Summary"),
            interval(.awake, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z")
        ]).first)
        XCTAssertTrue(observed.hasAsleepEvidence)
        XCTAssertEqual(observed.asleep, 0)
        XCTAssertEqual(observed.awake, 480)
    }

    func testBroadInBedEnvelopesCannotJoinSeparateSleepNights() throws {
        let result = AppleHealthAggregator.sleepDaily([
            interval(.asleepCore, "2024-03-09T22:00:00Z", "2024-03-10T06:00:00Z"),
            interval(.asleepCore, "2024-03-10T22:00:00Z", "2024-03-11T06:00:00Z"),
            interval(.inBed, "2024-03-09T00:00:00Z", "2024-03-10T00:00:00Z", source: "Bed app"),
            interval(.inBed, "2024-03-10T00:00:00Z", "2024-03-11T00:00:00Z", source: "Bed app")
        ])
        XCTAssertEqual(result["2024-03-10"]?.asleep, 480)
        XCTAssertEqual(result["2024-03-11"]?.asleep, 480)
    }

    func testExactThirtyMinuteGapAtChunkBoundaryMatchesBatchWakeDay() throws {
        let first = interval(.asleepCore, "2024-03-09T23:00:00Z", "2024-03-09T23:30:00Z")
        let second = interval(.asleepCore, "2024-03-10T00:00:00Z", "2024-03-10T01:00:00Z")
        let parser = ISO8601DateFormatter()
        var reducer = AppleSleepEpisodeReducer.Accumulator()
        XCTAssertTrue(reducer.ingest([first], through: parser.date(from: "2024-03-10T00:00:00Z")!).isEmpty)
        let episodes = reducer.ingest([second], through: parser.date(from: "2024-03-10T02:00:00Z")!)
        XCTAssertEqual(episodes, AppleSleepEpisodeReducer.reduce([first, second]))
        XCTAssertEqual(episodes.first?.wakeDay, "2024-03-10")
        XCTAssertEqual(episodes.first?.asleep, 90)
        XCTAssertTrue(reducer.finish().isEmpty)
    }

    func testAggregateDistinguishesMissingAsleepEvidenceFromObservedZero() throws {
        func aggregate(_ intervals: [SleepStageInterval]) throws -> AppleDailyAggregate {
            let result = AppleHealthImportResult(samples: [], workouts: [], sleepIntervals: intervals,
                summary: .init(sourceKind: .appleHealth, recordCount: intervals.count,
                               earliest: intervals.first?.start, latest: intervals.last?.end, countsByCategory: [:]))
            return try XCTUnwrap(AppleHealthAggregator.aggregate(result).first)
        }
        for stage in [SleepStage.inBed, .awake] {
            let row = try aggregate([interval(stage, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z")])
            XCTAssertNil(row.asleepMin)
            XCTAssertNil(row.deepMin)
            XCTAssertNil(row.remMin)
            XCTAssertNil(row.coreMin)
        }
        let observed = try aggregate([
            interval(.asleepUnspecified, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z", source: "Summary"),
            interval(.awake, "2024-03-10T00:00:00Z", "2024-03-10T08:00:00Z")
        ])
        XCTAssertEqual(observed.asleepMin, 0)
        XCTAssertEqual(observed.deepMin, 0)
        XCTAssertEqual(observed.awakeMin, 480)
    }
}
