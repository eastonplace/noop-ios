import XCTest
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
}
