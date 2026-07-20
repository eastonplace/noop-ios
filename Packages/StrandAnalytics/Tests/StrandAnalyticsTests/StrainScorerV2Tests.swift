import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class StrainScorerV2Tests: XCTestCase {
    private let maxHR = 190.0
    private let restingHR = 60.0

    private func samples(bpm: Int, durationSeconds: Int, cadence: Int = 1) -> [HRSample] {
        stride(from: 0, through: durationSeconds, by: cadence)
            .map { HRSample(ts: 1_000 + $0, bpm: bpm) }
    }

    private func bpm(atHRR hrr: Double) -> Int {
        Int((restingHR + hrr / 100 * (maxHR - restingHR)).rounded())
    }

    private func display(_ stored: Double?) -> Double? {
        stored.map(StrainScorerV2.displayValue)
    }

    func testPhysiologicalDayAnchorsAndActivityStayOnOneV2Scale() throws {
        let sleep = try XCTUnwrap(display(StrainScorerV2.strain(
            [], maxHR: maxHR, restingHR: restingHR,
            mode: .physiologicalDay(.init(validWornSleepMinutes: 480)))))
        let training = try XCTUnwrap(display(StrainScorerV2.strain(
            samples(bpm: bpm(atHRR: 70), durationSeconds: 3_600),
            maxHR: maxHR, restingHR: restingHR,
            mode: .physiologicalDay(.init(validWornSleepMinutes: 480)))))
        XCTAssertEqual(sleep, 4, accuracy: 0.05)
        XCTAssertTrue((13...14.5).contains(training), "score was \(training)")
    }

    func testGapsOverNinetySecondsDoNotCreateActivityLoad() {
        let separated = (0..<20).map { HRSample(ts: 1_000 + $0 * 91, bpm: 180) }
        XCTAssertNil(StrainScorerV2.strain(separated, maxHR: maxHR,
                                           restingHR: restingHR, mode: .activity))
    }

    func testBackgroundEvidenceRequiresWearCoverage() {
        XCTAssertNil(StrainScorerV2.strain(
            [], maxHR: maxHR, restingHR: restingHR,
            mode: .physiologicalDay(.init(steps: 10_000, hasWearCoverage: false))))
    }

    func testLiveAndPersistedEntryPointsMatchForIdenticalPhysiologicalDayContext() throws {
        var sorted = samples(bpm: 145, durationSeconds: 1_200)
        sorted.insert(HRSample(ts: 1_100, bpm: 175), at: 101)
        let context = StrainScorerV2.DayContext(validWornSleepMinutes: 420, steps: 8_000)
        let defensive = try XCTUnwrap(StrainScorerV2.strain(
            sorted, maxHR: maxHR, restingHR: restingHR, mode: .physiologicalDay(context)))
        let fast = try XCTUnwrap(StrainScorerV2.strainSorted(
            sorted, maxHR: maxHR, restingHR: restingHR, mode: .physiologicalDay(context)))
        XCTAssertEqual(fast, defensive, accuracy: 1e-10)
    }
}

final class StrainScorerV2ActivityAccumulatorTests: XCTestCase {
    private let maxHR = 190.0
    private let restingHR = 60.0

    func testAccumulatorMatchesAuthoritativeActivityScorerWithDuplicateSecondsAndGap() {
        var samples = (0..<700).map { offset in
            HRSample(ts: 10_000 + offset, bpm: 120 + offset % 35)
        }
        samples.insert(HRSample(ts: 10_100, bpm: 175), at: 101)
        samples += (0..<700).map { offset in
            HRSample(ts: 11_000 + offset, bpm: 130 + offset % 30)
        }

        var accumulator = StrainScorerV2.ActivityAccumulator(
            maxHR: maxHR, restingHR: restingHR)
        for sample in samples { accumulator.append(sample) }

        let accumulated = try! XCTUnwrap(accumulator.strain)
        let batch = try! XCTUnwrap(
            StrainScorerV2.strain(samples, maxHR: maxHR, restingHR: restingHR, mode: .activity))
        XCTAssertEqual(accumulated, batch, accuracy: 1e-10)
        XCTAssertEqual(accumulator.coverageSeconds, 1_398)
    }

    func testAccumulatorMaintainsRunningAveragePeakAndRejectsInvalidSamples() {
        var accumulator = StrainScorerV2.ActivityAccumulator(
            maxHR: maxHR, restingHR: restingHR)
        accumulator.append(HRSample(ts: 100, bpm: 100))
        accumulator.append(HRSample(ts: 101, bpm: 140))
        accumulator.append(HRSample(ts: 102, bpm: 400))
        accumulator.append(HRSample(ts: 0, bpm: 150))

        XCTAssertEqual(accumulator.readingCount, 2)
        XCTAssertEqual(accumulator.averageHR, 120)
        XCTAssertEqual(accumulator.peakHR, 140)
        XCTAssertNil(accumulator.strain)
    }

    func testAccumulatorCanRebuildFromPersistedChronologicalSamples() {
        let samples = (0..<1_000).map { offset in
            HRSample(ts: 50_000 + offset, bpm: 145)
        }

        let accumulator = StrainScorerV2.ActivityAccumulator(
            samples: samples, maxHR: maxHR, restingHR: restingHR)

        XCTAssertEqual(accumulator.readingCount, samples.count)
        XCTAssertEqual(accumulator.averageHR, 145)
        XCTAssertEqual(accumulator.peakHR, 145)
        XCTAssertNotNil(accumulator.strain)
    }
}
