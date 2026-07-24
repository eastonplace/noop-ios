import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class HeartRateRecoveryTests: XCTestCase {
    private let end = 10_000

    private func denseEligible(endHR: Int = 170) -> [HRSample] {
        // Five minutes of continuous Zone-3+ effort, ending at the requested cessation HR.
        (end - 300...end).map {
            HRSample(ts: $0, bpm: $0 >= end - 30 ? endHR : 145)
        }
    }

    private func window(minutes: Int, values: [Int]) -> [HRSample] {
        let target = end + minutes * 60
        return values.enumerated().map { index, bpm in
            HRSample(ts: target - values.count / 2 + index, bpm: bpm)
        }
    }

    func testCalculatesOneTwoAndFiveMinuteDropsFromRobustReadings() {
        let samples = denseEligible()
            + window(minutes: 1, values: [146, 146, 220, 146, 146])
            + window(minutes: 2, values: [132, 132, 132])
            + window(minutes: 5, values: [112, 112, 112])

        let result = HeartRateRecovery.calculate(
            samples: samples.shuffled(),
            workoutStart: end - 300,
            workoutEnd: end,
            maxHR: 200
        )
        XCTAssertEqual(
            result,
            .init(endHR: 170, after1Minute: 24, after2Minutes: 38, after5Minutes: 58)
        )
    }

    func testRequiresSustainedHighIntensityRatherThanOnePeak() {
        var samples = (end - 300...end).map { HRSample(ts: $0, bpm: 120) }
        samples.append(HRSample(ts: end, bpm: 190))
        samples += window(minutes: 1, values: [140, 140, 140])

        XCTAssertNil(HeartRateRecovery.calculate(
            samples: samples,
            workoutStart: end - 300,
            workoutEnd: end,
            maxHR: 200
        ))
    }

    func testRejectsDisconnectedHighIntensityFragments() {
        let sparse = stride(from: end - 300, through: end, by: 15)
            .map { HRSample(ts: $0, bpm: 170) }
        let samples = sparse + window(minutes: 1, values: [140, 140, 140])

        XCTAssertNil(HeartRateRecovery.calculate(
            samples: samples,
            workoutStart: end - 300,
            workoutEnd: end,
            maxHR: 200
        ))
    }

    func testDenseHighIntensityBurstsDoNotAddTogetherAcrossLowHeartRateBreaks() {
        var samples = (end - 300...end).map { HRSample(ts: $0, bpm: 120) }
        let burstRanges = [
            (end - 300)...(end - 270),
            (end - 220)...(end - 190),
            (end - 140)...(end - 110),
            (end - 40)...end,
        ]
        for range in burstRanges {
            for ts in range {
                let index = ts - (end - 300)
                samples[index] = HRSample(ts: ts, bpm: 170)
            }
        }
        samples += window(minutes: 1, values: [140, 140, 140])

        XCTAssertNil(HeartRateRecovery.calculate(
            samples: samples,
            workoutStart: end - 300,
            workoutEnd: end,
            maxHR: 200
        ))
    }

    func testDoesNotCreditPreWorkoutHeartRateTowardEligibility() {
        let samples = denseEligible() + window(minutes: 1, values: [140, 140, 140])

        XCTAssertNil(HeartRateRecovery.calculate(
            samples: samples,
            workoutStart: end - 60,
            workoutEnd: end,
            maxHR: 200
        ))
    }

    func testReturnsOnlyMeasurementsWithRealCoverage() {
        let samples = denseEligible()
            + window(minutes: 1, values: [150, 150, 150])
            + window(minutes: 5, values: [110, 110])

        let result = HeartRateRecovery.calculate(
            samples: samples,
            workoutStart: end - 300,
            workoutEnd: end,
            maxHR: 200
        )
        XCTAssertEqual(
            result,
            .init(endHR: 170, after1Minute: 20, after2Minutes: nil, after5Minutes: nil)
        )
    }

    func testDuplicateCallbacksAtOneSecondDoNotFakeCoverage() {
        let oneMinute = end + 60
        let duplicated = [140, 141, 142, 143].map {
            HRSample(ts: oneMinute, bpm: $0)
        }
        XCTAssertNil(HeartRateRecovery.calculate(
            samples: denseEligible() + duplicated,
            workoutStart: end - 300,
            workoutEnd: end,
            maxHR: 200
        ))
    }

    func testNoPostWorkoutCoverageReturnsNil() {
        XCTAssertNil(HeartRateRecovery.calculate(
            samples: denseEligible(),
            workoutStart: end - 300,
            workoutEnd: end,
            maxHR: 200
        ))
    }

    func testAHeartRateRiseRemainsSignedInsteadOfBeingClamped() {
        let samples = denseEligible(endHR: 160)
            + window(minutes: 1, values: [165, 165, 165])

        let result = HeartRateRecovery.calculate(
            samples: samples,
            workoutStart: end - 300,
            workoutEnd: end,
            maxHR: 200
        )
        XCTAssertEqual(result?.after1Minute, -5)
    }

    func testRejectsNonFiniteOrImplausibleMaxHeartRate() {
        let samples = denseEligible() + window(minutes: 1, values: [140, 140, 140])
        for maxHR in [Double.nan, 0, 29, 301] {
            XCTAssertNil(HeartRateRecovery.calculate(
                samples: samples,
                workoutStart: end - 300,
                workoutEnd: end,
                maxHR: maxHR
            ))
        }
    }

    func testExtremeWorkoutTimestampsFailClosedWithoutArithmeticOverflow() {
        XCTAssertNil(HeartRateRecovery.calculate(
            samples: [],
            workoutStart: Int.max - 100,
            workoutEnd: Int.max - 1,
            maxHR: 200
        ))
    }
}
