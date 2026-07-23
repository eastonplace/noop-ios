import XCTest
import WhoopProtocol
import WhoopStore
@testable import NOOP

final class WorkoutHeartChartProjectionTests: XCTestCase {
    func testProjectionUsesTrailingTimeWindowNotCallbackCount() {
        let now = 20_000
        let samples = [
            HRSample(ts: now - 3 * 60 * 60 - 1, bpm: 90),
            HRSample(ts: now - 3 * 60 * 60, bpm: 91),
            HRSample(ts: now - 1, bpm: 150),
            HRSample(ts: now, bpm: 151),
        ]

        let projection = WorkoutHeartChartProjection.make(samples: samples, now: now)

        XCTAssertEqual(projection.values, [91, 150, 151])
        XCTAssertEqual(projection.firstSampleAt, now - 3 * 60 * 60)
        XCTAssertEqual(projection.lastSampleAt, now)
        XCTAssertEqual(projection.observedSeconds, 3 * 60 * 60)
    }

    func testDuplicateSecondUsesLatestSmoothedValue() {
        let now = 1_000
        let samples = [
            HRSample(ts: 999, bpm: 100),
            HRSample(ts: 999, bpm: 105),
            HRSample(ts: 1_000, bpm: 110),
        ]

        let projection = WorkoutHeartChartProjection.make(samples: samples, now: now)

        XCTAssertEqual(projection.values, [105, 110])
    }

    func testExtremaPreservingSampleKeepsEndpointsSpikeAndTrough() {
        var samples = (0..<1_000).map { HRSample(ts: $0, bpm: 120) }
        samples[250] = HRSample(ts: 250, bpm: 42)
        samples[750] = HRSample(ts: 750, bpm: 228)

        let rendered = WorkoutHeartChartProjection.extremaPreservingSample(
            samples,
            maximumPoints: 80
        )

        XCTAssertLessThanOrEqual(rendered.count, 80)
        XCTAssertEqual(rendered.first?.ts, 0)
        XCTAssertEqual(rendered.last?.ts, 999)
        XCTAssertTrue(rendered.contains { $0.bpm == 42 })
        XCTAssertTrue(rendered.contains { $0.bpm == 228 })
    }

    func testDisplayRangeIncludesEasyAndPeakWorkWithoutFixedClipping() {
        XCTAssertEqual(
            WorkoutHeartChartProjection.displayRange([48, 52]),
            40...60
        )
        let intense = WorkoutHeartChartProjection.displayRange([175, 219])
        XCTAssertLessThanOrEqual(intense.lowerBound, 175)
        XCTAssertGreaterThanOrEqual(intense.upperBound, 219)
        XCTAssertLessThanOrEqual(intense.upperBound, 240)
    }

    func testInvalidPhysiologyIsExcluded() {
        let projection = WorkoutHeartChartProjection.make(
            samples: [
                HRSample(ts: 1, bpm: 0),
                HRSample(ts: 2, bpm: 29),
                HRSample(ts: 3, bpm: 80),
                HRSample(ts: 4, bpm: 241),
            ],
            now: 4,
            windowSeconds: 10
        )
        XCTAssertEqual(projection.values, [80])
    }

    @MainActor
    func testCanonicalWorkoutIngestionProducesEquivalentScoresAtOneAndThreeHertz() {
        let start = 1_700_000_000
        let oneHertz = AppModel.ActiveWorkout(
            start: Date(timeIntervalSince1970: TimeInterval(start)), sport: "Run", maxHR: 190
        )
        let threeHertz = AppModel.ActiveWorkout(
            start: Date(timeIntervalSince1970: TimeInterval(start)), sport: "Run", maxHR: 190
        )

        for offset in 0...1_200 {
            let bpm = 115 + offset % 55
            XCTAssertTrue(oneHertz.ingest(HRSample(ts: start + offset, bpm: bpm)))
            XCTAssertTrue(threeHertz.ingest(HRSample(ts: start + offset, bpm: bpm - 2)))
            XCTAssertTrue(threeHertz.ingest(HRSample(ts: start + offset, bpm: bpm + 3)))
            XCTAssertTrue(threeHertz.ingest(HRSample(ts: start + offset, bpm: bpm)))
        }

        XCTAssertEqual(threeHertz.samples, oneHertz.samples)
        XCTAssertEqual(threeHertz.samples.count, 1_201)
        XCTAssertEqual(threeHertz.avgHr, oneHertz.avgHr)
        XCTAssertEqual(threeHertz.peakHr, oneHertz.peakHr)
        XCTAssertEqual(threeHertz.liveStrainState, oneHertz.liveStrainState)
        XCTAssertEqual(threeHertz.chartProjection, oneHertz.chartProjection)
    }

    func testIncrementalChartProjectionStaysBoundedAcrossLongWorkout() {
        let start = 1_700_000_000
        var accumulator = WorkoutHeartChartAccumulator()
        for offset in 0..<(8 * 60 * 60) {
            XCTAssertTrue(accumulator.ingest(HRSample(
                ts: start + offset,
                bpm: offset == 7 * 60 * 60 ? 230 : 90 + offset % 100
            )))
        }

        let projection = accumulator.projection
        XCTAssertLessThanOrEqual(accumulator.retainedSampleCount, 3 * 60 * 60 + 1)
        XCTAssertLessThanOrEqual(projection.values.count, 360)
        XCTAssertEqual(projection.lastSampleAt, start + 8 * 60 * 60 - 1)
        XCTAssertTrue(projection.values.contains(230))
    }

    @MainActor
    func testSameSecondCorrectionDoesNotIncreaseReadingCountAndCanLowerPeak() {
        let workout = AppModel.ActiveWorkout(start: .now, sport: "Run", maxHR: 190)
        XCTAssertTrue(workout.ingest(HRSample(ts: 1_000, bpm: 180)))
        XCTAssertTrue(workout.ingest(HRSample(ts: 1_000, bpm: 120)))

        XCTAssertEqual(workout.samples, [HRSample(ts: 1_000, bpm: 120)])
        XCTAssertEqual(workout.avgHr, 120)
        XCTAssertEqual(workout.peakHr, 120)
        XCTAssertEqual(workout.liveStrainState, .building(readings: 1, coverageSeconds: 0))
    }

    @MainActor
    func testLifecycleIdentityChangesOnlyForStartEndOrReplacement() {
        let first = AppModel.ActiveWorkout(start: .now, sport: "Run", maxHR: 190)
        let replacement = AppModel.ActiveWorkout(start: .now, sport: "Ride", maxHR: 190)

        let firstIdentity = WorkoutLifecycleProjection.identity(first)
        XCTAssertEqual(firstIdentity, WorkoutLifecycleProjection.identity(first))
        XCTAssertNotEqual(firstIdentity, WorkoutLifecycleProjection.identity(replacement))
        XCTAssertNil(WorkoutLifecycleProjection.identity(nil))
    }
}
