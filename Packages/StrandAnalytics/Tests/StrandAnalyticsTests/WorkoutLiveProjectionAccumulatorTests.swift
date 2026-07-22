import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class WorkoutLiveProjectionAccumulatorTests: XCTestCase {
    private let profile = UserProfile(
        weightKg: 78,
        heightCm: 181,
        age: 31,
        sex: "male"
    )

    func testIncrementalProjectionMatchesExistingCalculatorsForGappyStream() {
        assertParity([
            HRSample(ts: 1_000, bpm: 92),
            HRSample(ts: 1_001, bpm: 108),
            HRSample(ts: 1_003, bpm: 131),
            HRSample(ts: 1_003, bpm: 138),
            HRSample(ts: 1_012, bpm: 151),
            HRSample(ts: 1_412, bpm: 166),
            HRSample(ts: 1_413, bpm: 121),
        ])
    }

    func testIncrementalAppendMatchesFullRebuildAcrossLongWorkout() {
        let samples = (0..<7_200).map { index in
            HRSample(
                ts: 1_700_000_000 + index,
                bpm: 105 + Int((35 * sin(Double(index) / 73)).rounded())
            )
        }
        let zoneSet = HRZones.zones(maxHR: 190, source: "profile")
        var incremental = WorkoutLiveProjectionAccumulator(
            profile: profile, hrmax: 190, restingHR: nil, zoneSet: zoneSet)
        for sample in samples { XCTAssertTrue(incremental.append(sample)) }
        let incrementalSnapshot = incremental.snapshot()
        let rebuiltSnapshot = WorkoutLiveProjectionAccumulator(
            samples: samples,
            profile: profile,
            hrmax: 190,
            restingHR: nil,
            zoneSet: zoneSet
        ).snapshot()
        XCTAssertEqual(incrementalSnapshot, rebuiltSnapshot)
        XCTAssertEqual(incrementalSnapshot.hrTrace, Array(samples.suffix(48).map(\.bpm)))
    }

    func testOutOfOrderAppendRequestsAuthoritativeRebuild() {
        let zoneSet = HRZones.zones(maxHR: 190, source: "profile")
        var accumulator = WorkoutLiveProjectionAccumulator(
            samples: [HRSample(ts: 100, bpm: 120)],
            profile: profile,
            hrmax: 190,
            restingHR: nil,
            zoneSet: zoneSet
        )
        XCTAssertFalse(accumulator.append(HRSample(ts: 99, bpm: 130)))
        XCTAssertEqual(accumulator.snapshot().sampleCount, 1)
    }

    func testEmptyAndSingleSampleSemanticsMatchExistingCalculators() {
        assertParity([])
        assertParity([HRSample(ts: 100, bpm: 140)])
    }

    private func assertParity(
        _ samples: [HRSample],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let zoneSet = HRZones.zones(maxHR: 190, source: "profile")
        let projection = WorkoutLiveProjectionAccumulator(
            samples: samples,
            profile: profile,
            hrmax: 190,
            restingHR: nil,
            zoneSet: zoneSet
        ).snapshot()
        let expectedCalories = Calories.estimateBoutCalories(
            samples, profile: profile, hrmax: 190, restingHR: nil).0
        let expectedZones = HRZones.timeInZone(samples, zoneSet: zoneSet).seconds
        XCTAssertEqual(
            projection.caloriesKcal, expectedCalories, accuracy: 0.000_000_1,
            file: file, line: line)
        XCTAssertEqual(projection.zoneSeconds.count, expectedZones.count, file: file, line: line)
        for (actual, expected) in zip(projection.zoneSeconds, expectedZones) {
            XCTAssertEqual(actual, expected, accuracy: 0.000_000_1, file: file, line: line)
        }
        XCTAssertEqual(projection.sampleCount, samples.count, file: file, line: line)
    }
}
