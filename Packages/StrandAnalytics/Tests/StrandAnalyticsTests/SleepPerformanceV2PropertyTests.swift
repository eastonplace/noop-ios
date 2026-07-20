import XCTest
@testable import StrandAnalytics

final class SleepPerformanceV2PropertyTests: XCTestCase {
    private func need(_ minutes: Double, debt: Double = 0, nap: Double = 0,
                      effort: Double? = 0) -> SleepNeedV2.Breakdown {
        let baseline = SleepNeedV2.BaselineEstimate(minutes: 480, source: .defaultPopulation,
                                                     eligibleNightCount: 0)
        return SleepNeedV2.calculate(.init(baseline: baseline, previousDayEffort: effort,
                                            sleepDebtMinutes: debt, recentNapMinutes: nap))
    }

    func testFixedMonotonicScoreGrid() throws {
        var prior = -Double.infinity
        for slept in stride(from: 120.0, through: 660, by: 15) {
            let score = try XCTUnwrap(SleepPerformanceV2.score(.init(
                mainSleepMinutes: slept, need: need(480), efficiency: 0.9,
                consistency: 0.8, lowStressQuality: 0.8))).score
            XCTAssertGreaterThanOrEqual(score, prior); prior = score
        }
        prior = Double.infinity
        for needMinutes in stride(from: 390.0, through: 630, by: 15) {
            let score = try XCTUnwrap(SleepPerformanceV2.score(.init(
                mainSleepMinutes: 450, need: need(needMinutes), efficiency: 0.9,
                consistency: 0.8, lowStressQuality: 0.8))).score
            XCTAssertLessThanOrEqual(score, prior); prior = score
        }
        for keyPath in [\SleepPerformanceV2.Inputs.efficiency,
                        \SleepPerformanceV2.Inputs.consistency,
                        \SleepPerformanceV2.Inputs.lowStressQuality] {
            var last = -Double.infinity
            for value in stride(from: 0.1, through: 1.0, by: 0.1) {
                var efficiency: Double? = 0.8, consistency: Double? = 0.8, stress: Double? = 0.8
                if keyPath == \SleepPerformanceV2.Inputs.efficiency { efficiency = value }
                if keyPath == \SleepPerformanceV2.Inputs.consistency { consistency = value }
                if keyPath == \SleepPerformanceV2.Inputs.lowStressQuality { stress = value }
                let score = try XCTUnwrap(SleepPerformanceV2.score(.init(
                    mainSleepMinutes: 480, need: need(480), efficiency: efficiency,
                    consistency: consistency, lowStressQuality: stress))).score
                XCTAssertGreaterThanOrEqual(score, last); last = score
            }
        }
    }

    func testNeedInputsAndOutputBounds() throws {
        var lastDebtNeed = -Double.infinity
        for debt in stride(from: 0.0, through: 300, by: 15) {
            let value = need(480, debt: debt).totalMinutes
            XCTAssertGreaterThanOrEqual(value, lastDebtNeed); lastDebtNeed = value
        }
        var lastNapNeed = Double.infinity
        for nap in stride(from: 0.0, through: 180, by: 15) {
            let value = need(480, nap: nap).totalMinutes
            XCTAssertLessThanOrEqual(value, lastNapNeed); lastNapNeed = value
        }
        var lastEffortNeed = -Double.infinity
        for effort in stride(from: 0.0, through: 100, by: 5) {
            let value = need(480, effort: effort).totalMinutes
            XCTAssertGreaterThanOrEqual(value, lastEffortNeed); lastEffortNeed = value
        }
        for slept in stride(from: 30.0, through: 900, by: 30) {
            let result = try XCTUnwrap(SleepPerformanceV2.score(.init(
                mainSleepMinutes: slept, need: need(480), efficiency: 2,
                consistency: -1, lowStressQuality: 5)))
            XCTAssertTrue(result.score.isFinite && (0...100).contains(result.score))
            XCTAssertTrue(result.inputCoverage.isFinite && (0...1).contains(result.inputCoverage))
        }
    }

    func testMissingOptionalInputsCannotBeatFullCoverage() throws {
        let full = try XCTUnwrap(SleepPerformanceV2.score(.init(
            mainSleepMinutes: 480, need: need(480), efficiency: 1,
            consistency: 1, lowStressQuality: 1)))
        let missingConsistency = try XCTUnwrap(SleepPerformanceV2.score(.init(
            mainSleepMinutes: 480, need: need(480), efficiency: 1,
            consistency: nil, lowStressQuality: 1)))
        let missingBoth = try XCTUnwrap(SleepPerformanceV2.score(.init(
            mainSleepMinutes: 480, need: need(480), efficiency: 1,
            consistency: nil, lowStressQuality: nil)))
        XCTAssertLessThanOrEqual(missingConsistency.score, full.score)
        XCTAssertLessThanOrEqual(missingBoth.score, missingConsistency.score)
    }
}
