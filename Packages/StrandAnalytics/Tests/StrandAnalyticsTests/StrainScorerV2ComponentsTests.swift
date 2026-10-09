import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class StrainScorerV2ComponentsTests: XCTestCase {
    private typealias Fixtures = StrainDayFixtures
    private typealias Components = StrainScorerV2.DayStrainComponents

    private func components(_ samples: [HRSample],
                            _ context: StrainScorerV2.DayContext) -> Components {
        StrainScorerV2.dayStrainComponents(samples, maxHR: Fixtures.maxHR,
                                           restingHR: Fixtures.restingHR, context: context)
    }

    private func samples(_ name: String) throws -> [HRSample] {
        try XCTUnwrap(Fixtures.days.first { $0.name == name }, "no fixture day named \(name)").samples
    }

    private func context(_ name: String) throws -> StrainScorerV2.DayContext {
        try XCTUnwrap(Fixtures.contexts.first { $0.name == name }, "no fixture context named \(name)").value
    }

    /// The dominant component worked out independently of the implementation: the first of cardio,
    /// steps, energy that holds the largest value, provided that value is above zero.
    private func expectedDominant(_ parts: Components) -> Components.Component? {
        let candidates: [(Components.Component, Double)] = [
            (.cardio, parts.cardio ?? 0), (.steps, parts.steps ?? 0), (.energy, parts.energy ?? 0),
        ]
        guard let top = candidates.map(\.1).max(), top > 0 else { return nil }
        return candidates.first { $0.1 == top }?.0
    }

    // MARK: - score equals the existing functions

    func testScoreEqualsTheExistingFunctionsForEveryFixtureAndContext() {
        for day in Fixtures.days {
            let sorted = StrainScorerV2.sortedValidSamples(day.samples)
            for context in Fixtures.contexts {
                let label = "\(day.name) / \(context.name)"
                let parts = components(day.samples, context.value)
                let mode = StrainScorerV2.Mode.physiologicalDay(context.value)
                XCTAssertEqual(parts.score,
                               StrainScorerV2.strain(day.samples, maxHR: Fixtures.maxHR,
                                                     restingHR: Fixtures.restingHR, mode: mode), label)
                XCTAssertEqual(parts.score,
                               StrainScorerV2.strainSorted(sorted, maxHR: Fixtures.maxHR,
                                                           restingHR: Fixtures.restingHR, mode: mode), label)
                XCTAssertEqual(StrainScorerV2.dayStrainComponentsSorted(
                    sorted, maxHR: Fixtures.maxHR, restingHR: Fixtures.restingHR, context: context.value),
                               parts, label)
            }
        }
    }

    func testDefaultMaxHRMatchesTheExistingFunctionToo() {
        let day = Fixtures.hardHourSamples
        let context = StrainScorerV2.DayContext(validWornSleepMinutes: 420, steps: 8_000)
        XCTAssertEqual(
            StrainScorerV2.dayStrainComponents(day, context: context).score,
            StrainScorerV2.strain(day, mode: .physiologicalDay(context)))
    }

    func testLiveAccumulatorAgreesWithTheComponentsScore() {
        // The one stream shape left out is fewer than 20 readings that still span 10 minutes: the batch
        // scorer (and so the components) ignore its load, while the live accumulator has never applied
        // that minimum-reading gate. That difference predates the components and is out of scope here.
        for day in Fixtures.days where day.name != "10 readings 90 s apart" {
            let sorted = StrainScorerV2.sortedValidSamples(day.samples)
            for context in Fixtures.contexts {
                let accumulator = StrainScorerV2.PhysiologicalDayAccumulator(
                    samples: sorted, maxHR: Fixtures.maxHR, restingHR: Fixtures.restingHR,
                    context: context.value)
                XCTAssertEqual(accumulator.strain, components(day.samples, context.value).score,
                               "\(day.name) / \(context.name)")
            }
        }
    }

    // MARK: - dominant and the stored/display scales

    func testDominantNamesTheMaximumAndScoreIsItsStoredValue() {
        for day in Fixtures.days {
            for context in Fixtures.contexts {
                let label = "\(day.name) / \(context.name)"
                let parts = components(day.samples, context.value)
                XCTAssertEqual(parts.dominant, expectedDominant(parts), label)
                XCTAssertEqual(parts.cardio == nil, parts.score == nil, label)
                guard let score = parts.score else {
                    XCTAssertEqual(parts, .unscored, label)
                    continue
                }
                let top = max(parts.cardio ?? 0, parts.steps ?? 0, parts.energy ?? 0)
                XCTAssertEqual(score, StrainScorerV2.storedValue(fromDisplay: top), label)
                XCTAssertEqual(StrainScorerV2.displayValue(fromStored: score), top,
                               accuracy: 1e-12, label)
            }
        }
    }

    func testDominantTieBreakAndZero() {
        let dominant = Components.dominantComponent(cardio:steps:energy:)
        XCTAssertEqual(dominant(5, 5, 5), .cardio)
        XCTAssertEqual(dominant(5, 5, nil), .cardio)
        XCTAssertEqual(dominant(3, 5, 5), .steps)
        XCTAssertEqual(dominant(3, 3, 5), .energy)
        XCTAssertEqual(dominant(0, 1, nil), .steps)
        XCTAssertEqual(dominant(0, nil, 1), .energy)
        XCTAssertEqual(dominant(2, nil, nil), .cardio)
        XCTAssertNil(dominant(0, 0, 0))
        XCTAssertNil(dominant(0, nil, nil))
    }

    func testCardioDominatesAHardDay() throws {
        let parts = components(try samples("hard hour in a resting day"), try context("all three"))
        let cardio = try XCTUnwrap(parts.cardio)
        XCTAssertEqual(parts.dominant, .cardio)
        XCTAssertGreaterThan(cardio, 13)
        XCTAssertGreaterThan(cardio, try XCTUnwrap(parts.steps))
        XCTAssertGreaterThan(cardio, try XCTUnwrap(parts.energy))
        XCTAssertEqual(parts.score, StrainScorerV2.storedValue(fromDisplay: cardio))
    }

    func testStepsDominateAnEasyDayWithManySteps() throws {
        let parts = components(try samples("resting 6 h"), try context("big steps"))
        let steps = try XCTUnwrap(parts.steps)
        XCTAssertEqual(parts.dominant, .steps)
        XCTAssertGreaterThan(steps, try XCTUnwrap(parts.cardio))
        XCTAssertNil(parts.energy)
        XCTAssertEqual(parts.score, StrainScorerV2.storedValue(fromDisplay: steps))
    }

    func testEnergyDominatesAnEasyDayWithHighActiveEnergy() throws {
        let parts = components(try samples("resting 6 h"), try context("big energy"))
        let energy = try XCTUnwrap(parts.energy)
        XCTAssertEqual(parts.dominant, .energy)
        XCTAssertGreaterThan(energy, try XCTUnwrap(parts.cardio))
        XCTAssertGreaterThan(energy, try XCTUnwrap(parts.steps))
        XCTAssertEqual(parts.score, StrainScorerV2.storedValue(fromDisplay: energy))
    }

    func testADayWithoutStepsOrEnergyReportsOnlyCardio() throws {
        let parts = components(try samples("hard hour in a resting day"), try context("sleep only"))
        XCTAssertNotNil(parts.cardio)
        XCTAssertNil(parts.steps)
        XCTAssertNil(parts.energy)
        XCTAssertEqual(parts.dominant, .cardio)
    }

    // MARK: - nil handling

    func testNothingToScoreIsUnscored() {
        XCTAssertEqual(components([], .init()), .unscored)
        XCTAssertNil(StrainScorerV2.strain([], maxHR: Fixtures.maxHR, restingHR: Fixtures.restingHR,
                                           mode: .physiologicalDay(.init())))
    }

    func testSingleBackgroundSourcesScoreTheDayAndLeaveTheRestAbsent() throws {
        let stepsOnly = components([], .init(steps: 9_000))
        XCTAssertEqual(stepsOnly.cardio, 0)
        XCTAssertEqual(stepsOnly.steps, StrainScorerV2.stepFloor(9_000))
        XCTAssertNil(stepsOnly.energy)
        XCTAssertEqual(stepsOnly.dominant, .steps)
        XCTAssertEqual(stepsOnly.score,
                       StrainScorerV2.storedValue(fromDisplay: StrainScorerV2.stepFloor(9_000)))

        let energyOnly = components([], .init(activeEnergyKcal: 600))
        XCTAssertEqual(energyOnly.cardio, 0)
        XCTAssertNil(energyOnly.steps)
        XCTAssertEqual(energyOnly.energy, StrainScorerV2.activeEnergyFloor(600))
        XCTAssertEqual(energyOnly.dominant, .energy)

        let sleepOnly = components([], .init(validWornSleepMinutes: 480))
        XCTAssertEqual(try XCTUnwrap(sleepOnly.cardio), 4, accuracy: 0.05)
        XCTAssertNil(sleepOnly.steps)
        XCTAssertNil(sleepOnly.energy)
        XCTAssertEqual(sleepOnly.dominant, .cardio)
    }

    func testZeroAndOutOfRangeEvidenceScoresZeroWithNoDominant() {
        let zero = Components(cardio: 0, steps: 0, energy: 0, score: 0, dominant: nil)
        XCTAssertEqual(components([], .init(validWornSleepMinutes: 0, steps: 0, activeEnergyKcal: 0)), zero)
        XCTAssertEqual(components([], .init(validWornSleepMinutes: -30, steps: -5,
                                            activeEnergyKcal: .nan)), zero)
    }

    func testBackgroundEvidenceNeedsWearCoverage() throws {
        let noWear = StrainScorerV2.DayContext(validWornSleepMinutes: 420, steps: 8_000,
                                               activeEnergyKcal: 350, hasWearCoverage: false)
        XCTAssertEqual(components([], noWear), .unscored)
        XCTAssertEqual(components(try samples("hard hour in a resting day"), noWear), .unscored)
    }

    func testUnusableHeartRateRangeIsUnscoredWhateverElseIsKnown() throws {
        let day = try samples("hard hour in a resting day")
        let context = StrainScorerV2.DayContext(validWornSleepMinutes: 420, steps: 8_000)
        for (maxHR, restingHR) in [(60.0, 60.0), (50.0, 60.0), (Double.nan, 60.0),
                                   (190.0, Double.infinity), (190.0, Double.nan)] {
            XCTAssertEqual(
                StrainScorerV2.dayStrainComponents(day, maxHR: maxHR, restingHR: restingHR, context: context),
                .unscored, "max \(maxHR) resting \(restingHR)")
            XCTAssertNil(StrainScorerV2.strain(day, maxHR: maxHR, restingHR: restingHR,
                                               mode: .physiologicalDay(context)))
        }
    }

    // MARK: - what counts as cardio

    func testHeartRateLoadOnlyCountsOnceReadingAndCoverageGatesOpen() throws {
        let context = StrainScorerV2.DayContext(validWornSleepMinutes: 480)
        let sleepSeedOnly = components([], context)
        // 19 hot readings: fewer than minReadings.
        XCTAssertEqual(components(try samples("19 readings"), context), sleepSeedOnly)
        // 10 hot readings 90 s apart cover 810 s, but are still fewer than minReadings.
        XCTAssertEqual(components(try samples("10 readings 90 s apart"), context), sleepSeedOnly)
        // A five minute burst covers 299 s, under minCoverageSeconds.
        XCTAssertEqual(components(try samples("5 minute burst"), context), sleepSeedOnly)
        // A hard hour clears both gates.
        let hardHour = components(try samples("hard hour in a resting day"), context)
        XCTAssertGreaterThan(try XCTUnwrap(hardHour.cardio), try XCTUnwrap(sleepSeedOnly.cardio))
    }

    func testEqualSecondDuplicatesAndOutOfRangeReadingsFollowTheScorersFilter() throws {
        let messy = try samples("messy day")
        let allThree = try context("all three")
        // Reference: the same readings reduced by hand to one in-range maximum per second, in order.
        var maxPerSecond: [Int: Int] = [:]
        for sample in messy where (30...240).contains(sample.bpm) {
            maxPerSecond[sample.ts] = max(maxPerSecond[sample.ts] ?? 0, sample.bpm)
        }
        let reduced = maxPerSecond.keys.sorted().map { HRSample(ts: $0, bpm: maxPerSecond[$0]!) }
        XCTAssertEqual(components(messy, allThree).cardio, components(reduced, allThree).cardio)
        XCTAssertEqual(components(messy, allThree).score, components(reduced, allThree).score)
    }
}
