import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class StrainScorerV2Tests: XCTestCase {
    private let maxHR = 190.0
    private let restingHR = 60.0

    private func samples(bpm: Int, durationSeconds: Int, cadence: Int = 1,
                         start: Int = 1_000) -> [HRSample] {
        stride(from: 0, through: durationSeconds, by: cadence)
            .map { HRSample(ts: start + $0, bpm: bpm) }
    }

    private func bpm(atHRR hrr: Double) -> Int {
        Int((restingHR + hrr / 100 * (maxHR - restingHR)).rounded())
    }

    private func display(_ stored: Double?) -> Double? {
        stored.map(StrainScorerV2.displayValue)
    }

    func testContinuousLoadInterpolatesAnchors() {
        XCTAssertEqual(StrainScorerV2.loadPerMinute(atHRR: 30), 0, accuracy: 1e-12)
        XCTAssertEqual(StrainScorerV2.loadPerMinute(atHRR: 50), 0.125, accuracy: 1e-12)
        XCTAssertEqual(StrainScorerV2.loadPerMinute(atHRR: 75), 0.575, accuracy: 1e-12)
        XCTAssertEqual(StrainScorerV2.loadPerMinute(atHRR: 95), 1, accuracy: 1e-12)
    }

    func testEightHoursWornSleepSeedsApproximatelyFour() throws {
        let score = try XCTUnwrap(display(StrainScorerV2.strain(
            [], maxHR: maxHR, restingHR: restingHR,
            mode: .physiologicalDay(.init(validWornSleepMinutes: 480)))))
        XCTAssertEqual(score, 4, accuracy: 0.05)
    }

    func testMovementFloorsAreNonAdditiveAndQuietDaysStayBelowSeven() throws {
        let sixK = try XCTUnwrap(display(StrainScorerV2.strain(
            [], maxHR: maxHR, restingHR: restingHR,
            mode: .physiologicalDay(.init(validWornSleepMinutes: 480, steps: 6_000)))))
        let twelveK = try XCTUnwrap(display(StrainScorerV2.strain(
            [], maxHR: maxHR, restingHR: restingHR,
            mode: .physiologicalDay(.init(validWornSleepMinutes: 480, steps: 12_000)))))
        XCTAssertGreaterThanOrEqual(sixK, 4)
        XCTAssertLessThan(twelveK, 7)
        XCTAssertGreaterThan(twelveK, sixK)
    }

    func testOneHourAtSeventyPercentHRRWithSleepSeedHitsDayAnchor() throws {
        let score = try XCTUnwrap(display(StrainScorerV2.strain(
            samples(bpm: bpm(atHRR: 70), durationSeconds: 3_600),
            maxHR: maxHR, restingHR: restingHR,
            mode: .physiologicalDay(.init(validWornSleepMinutes: 480)))))
        XCTAssertTrue((13...14.5).contains(score), "score was \(score)")
    }

    func testOneHourZoneFiveWithSleepSeedHitsEighteenToNineteen() throws {
        let score = try XCTUnwrap(display(StrainScorerV2.strain(
            samples(bpm: bpm(atHRR: 95), durationSeconds: 3_600),
            maxHR: maxHR, restingHR: restingHR,
            mode: .physiologicalDay(.init(validWornSleepMinutes: 480)))))
        XCTAssertTrue((18...19).contains(score), "score was \(score)")
    }

    func testSixHoursZoneFiveApproachesMaximum() throws {
        let score = try XCTUnwrap(display(StrainScorerV2.strain(
            samples(bpm: bpm(atHRR: 95), durationSeconds: 21_600, cadence: 30),
            maxHR: maxHR, restingHR: restingHR, mode: .activity)))
        XCTAssertGreaterThanOrEqual(score, 20.9)
        XCTAssertLessThanOrEqual(score, 21)
    }

    func testDenseAndThirtySecondCadenceAgree() throws {
        let dense = try XCTUnwrap(display(StrainScorerV2.strain(
            samples(bpm: bpm(atHRR: 80), durationSeconds: 3_600),
            maxHR: maxHR, restingHR: restingHR, mode: .activity)))
        let sparse = try XCTUnwrap(display(StrainScorerV2.strain(
            samples(bpm: bpm(atHRR: 80), durationSeconds: 3_600, cadence: 30),
            maxHR: maxHR, restingHR: restingHR, mode: .activity)))
        XCTAssertEqual(dense, sparse, accuracy: 0.2)
    }

    func testIntervalsOverNinetySecondsDoNotContribute() {
        let separated = (0..<20).map {
            HRSample(ts: 1_000 + $0 * 91, bpm: bpm(atHRR: 95))
        }
        XCTAssertNil(StrainScorerV2.strain(separated, maxHR: maxHR,
                                           restingHR: restingHR, mode: .activity))
    }

    func testInvalidInputsAndMissingWearReturnNil() {
        let valid = samples(bpm: 150, durationSeconds: 600, cadence: 30)
        XCTAssertNil(StrainScorerV2.strain(valid, maxHR: 60, restingHR: 60, mode: .activity))
        XCTAssertNil(StrainScorerV2.strain(Array(valid.prefix(19)), maxHR: maxHR,
                                           restingHR: restingHR, mode: .activity))
        XCTAssertNil(StrainScorerV2.strain(valid, maxHR: maxHR, restingHR: restingHR,
                                           mode: .physiologicalDay(.init(steps: 10_000,
                                                                         hasWearCoverage: false))))
    }

    func testActivityModeDoesNotReceiveSleepOrMovementCredit() throws {
        let low = samples(bpm: 60, durationSeconds: 600, cadence: 30)
        let score = try XCTUnwrap(display(StrainScorerV2.strain(
            low, maxHR: maxHR, restingHR: restingHR, mode: .activity)))
        XCTAssertEqual(score, 0, accuracy: 1e-12)
    }
}
