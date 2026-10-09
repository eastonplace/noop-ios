import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class StrainScorerV2CumulativeCardioTests: XCTestCase {
    private typealias Fixtures = StrainDayFixtures
    private typealias Point = StrainScorerV2.CumulativeCardioPoint

    private let dayLength = 86_400

    private func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    private func fixtureDay(_ name: String) throws -> [HRSample] {
        try XCTUnwrap(Fixtures.days.first { $0.name == name }, "no fixture day named \(name)").samples
    }

    private func fixtureContext(_ name: String) throws -> StrainScorerV2.DayContext {
        try XCTUnwrap(Fixtures.contexts.first { $0.name == name }, "no fixture context named \(name)").value
    }

    private func curve(_ samples: [HRSample], _ context: StrainScorerV2.DayContext,
                       maxHR: Double? = Fixtures.maxHR,
                       start: Date? = nil, end: Date? = nil,
                       bucket: TimeInterval = 300) -> [Point] {
        StrainScorerV2.cumulativeCardioStrain(
            samples, maxHR: maxHR, restingHR: Fixtures.restingHR, context: context,
            start: start ?? date(Fixtures.t0), end: end ?? date(Fixtures.t0 + dayLength), bucket: bucket)
    }

    private func components(_ samples: [HRSample], _ context: StrainScorerV2.DayContext,
                            maxHR: Double? = Fixtures.maxHR) -> StrainScorerV2.DayStrainComponents {
        StrainScorerV2.dayStrainComponents(samples, maxHR: maxHR, restingHR: Fixtures.restingHR,
                                           context: context)
    }

    /// The readings with `start <= ts <= through`, as a defensive caller would hand them over.
    private func readings(_ samples: [HRSample], from start: Date, through: Date) -> [HRSample] {
        samples.filter {
            Double($0.ts) >= start.timeIntervalSince1970 && Double($0.ts) <= through.timeIntervalSince1970
        }
    }

    // MARK: - shape

    func testNoReadingsInTheWindowReturnsNoPoints() throws {
        let context = StrainScorerV2.DayContext(validWornSleepMinutes: 480)
        XCTAssertEqual(curve([], context), [])
        let day = try fixtureDay("hard hour in a resting day")
        XCTAssertEqual(curve(day, context, start: date(Fixtures.t0 + 30_000)), [])   // day ends near +25,200 s
        XCTAssertEqual(curve(day, context, start: date(Fixtures.t0 - 5_000), end: date(Fixtures.t0 - 1)), [])
        let invalidOnly = (0..<100).map { HRSample(ts: Fixtures.t0 + $0, bpm: 0) }
        XCTAssertEqual(curve(invalidOnly, context), [])
    }

    func testPointsRunFromStartToTheLastReadingAtEveryBucket() throws {
        let day = try fixtureDay("hard hour in a resting day")
        let lastTs = try XCTUnwrap(day.map(\.ts).max())
        let points = curve(day, try fixtureContext("all three"))

        XCTAssertEqual(points.first?.t, date(Fixtures.t0))
        XCTAssertEqual(points.last?.t, date(lastTs))
        let span = lastTs - Fixtures.t0
        XCTAssertEqual(points.count, (span + 299) / 300 + 1)
        for (earlier, later) in zip(points, points.dropFirst().dropLast()) {
            XCTAssertEqual(later.t.timeIntervalSince(earlier.t), 300)
        }
        let closing = try XCTUnwrap(points.last)
        XCTAssertLessThanOrEqual(closing.t.timeIntervalSince(points[points.count - 2].t), 300)
        XCTAssertGreaterThan(closing.t, points[points.count - 2].t)
    }

    func testLastPointIsNeverAfterEndEvenWhenReadingsContinue() throws {
        let day = try fixtureDay("hard hour in a resting day")
        let end = date(Fixtures.t0 + 12_000)
        let points = curve(day, try fixtureContext("all three"), end: end)
        XCTAssertEqual(points.last?.t, end)
        XCTAssertEqual(points.last?.value,
                       components(readings(day, from: date(Fixtures.t0), through: end),
                                  try fixtureContext("all three")).cardio)
    }

    func testValuesNeverDecrease() {
        for day in Fixtures.days {
            for context in Fixtures.contexts {
                for bucket in [300.0, 60.0] {
                    let points = curve(day.samples, context.value, bucket: bucket)
                    for (earlier, later) in zip(points, points.dropFirst()) {
                        XCTAssertGreaterThanOrEqual(later.value, earlier.value,
                                                    "\(day.name) / \(context.name) / \(bucket) s")
                    }
                }
            }
        }
    }

    // MARK: - equals the components

    func testFinalValueEqualsTheCardioComponentForEveryFixtureAndContext() {
        for day in Fixtures.days {
            for context in Fixtures.contexts {
                let label = "\(day.name) / \(context.name)"
                let points = curve(day.samples, context.value)
                let hasReadings = !StrainScorerV2.sortedValidSamples(day.samples).isEmpty
                if hasReadings, let cardio = components(day.samples, context.value).cardio {
                    XCTAssertEqual(points.last?.value, cardio, label)
                } else {
                    XCTAssertEqual(points, [], label)
                }
            }
        }
    }

    func testFinalValueEqualsTheCardioComponentWithTheDefaultMaxHR() throws {
        let context = try fixtureContext("sleep and steps")
        for name in ["hard hour in a resting day", "gappy day", "messy day"] {
            let day = try fixtureDay(name)
            XCTAssertEqual(curve(day, context, maxHR: nil).last?.value,
                           components(day, context, maxHR: nil).cardio, name)
        }
    }

    func testEveryPointEqualsTheComponentsOfTheReadingsSoFar() throws {
        // The defining property: at every boundary the curve reads what the day's cardio component would
        // be had the day ended there. Checked against the components API on every prefix, for a stream
        // with a gap, with duplicates and out-of-range readings, and with the gates still closed early on.
        let bucketByDay: [(name: String, bucket: TimeInterval)] = [
            ("hard hour in a resting day", 1_800), ("gappy day", 900), ("messy day", 600),
        ]
        for (name, bucket) in bucketByDay {
            let day = try fixtureDay(name)
            for contextName in ["bare", "sleep only"] {
                let context = try fixtureContext(contextName)
                for start in [date(Fixtures.t0), Date(timeIntervalSince1970: TimeInterval(Fixtures.t0) + 0.5)] {
                    let points = curve(day, context, start: start, bucket: bucket)
                    XCTAssertGreaterThan(points.count, 3, name)
                    for point in points {
                        let expected = components(readings(day, from: start, through: point.t), context)
                        XCTAssertEqual(point.value, expected.cardio ?? 0,
                                       "\(name) / \(contextName) / start \(start) / t \(point.t)")
                    }
                }
            }
        }
    }

    func testFinalValueMatchesTheExistingScorerWhenCardioIsTheWinner() throws {
        let messy = try fixtureDay("messy day")
        let context = try fixtureContext("sleep only")
        let points = curve(messy, context)
        let stored = StrainScorerV2.strain(messy, maxHR: Fixtures.maxHR, restingHR: Fixtures.restingHR,
                                           mode: .physiologicalDay(context))
        XCTAssertEqual(stored, points.last.map { StrainScorerV2.storedValue(fromDisplay: $0.value) })
    }

    // MARK: - behaviour through the day

    func testGapsCarryTheLastValueForward() throws {
        let day = try fixtureDay("gappy day")
        let context = try fixtureContext("sleep and steps")
        let firstBlock = Array(day.prefix(1_800))
        let gapValue = try XCTUnwrap(components(firstBlock, context).cardio)
        let gapStart = Fixtures.t0 + 1_800              // first boundary after the first block's last reading
        let secondBlockStart = Fixtures.t0 + 1_800 + 3 * 3_600

        let points = curve(day, context)
        let inGap = points.filter { $0.t >= date(gapStart) && $0.t <= date(secondBlockStart) }
        XCTAssertGreaterThanOrEqual(inGap.count, 30)
        XCTAssertTrue(inGap.allSatisfy { $0.value == gapValue }, "values moved inside the gap")
        let afterGap = try XCTUnwrap(points.first { $0.t > date(secondBlockStart) })
        XCTAssertGreaterThan(afterGap.value, gapValue)
    }

    func testReadingsOutsideTheWindowAreIgnored() throws {
        let day = try fixtureDay("hard hour in a resting day")
        let context = try fixtureContext("all three")
        let start = date(Fixtures.t0 + 3_600)
        let end = date(Fixtures.t0 + 12_000)
        let windowed = curve(day, context, start: start, end: end)
        let trimmed = curve(readings(day, from: start, through: end), context, start: start, end: end)
        XCTAssertEqual(windowed, trimmed)
        XCTAssertEqual(windowed.first?.t, start)
        XCTAssertEqual(windowed.last?.t, end)
        // Load from before `start` is not carried into the window.
        let lateStart = date(Fixtures.t0 + 12_000)                 // 20 minutes into the hard hour
        let seed = try XCTUnwrap(components([], context).cardio)
        XCTAssertEqual(curve(day, context, start: lateStart).first?.value, seed)
        XCTAssertGreaterThan(try XCTUnwrap(curve(day, context).first { $0.t >= lateStart }).value, seed)
    }

    func testStartsAtTheSleepSeedAndHeartRateJoinsWhenTheCoverageGateOpens() {
        let hard = StrainDayFixtures.block(from: Fixtures.t0, count: 1_200,
                                           center: Fixtures.bpm(atHRR: 80), wobble: 3, seed: 21)
        let context = StrainScorerV2.DayContext(validWornSleepMinutes: 480)
        let seed = components([], context).cardio
        XCTAssertEqual(seed.map { $0 > 3.9 && $0 < 4.0 }, true, "8 h of sleep seeds about 4.0")

        let values = curve(hard, context).map(\.value)
        XCTAssertEqual(values.count, 5)                       // t0, +300, +600, +900 and the last reading
        XCTAssertEqual(values[0], seed)                       // one reading, no interval yet
        XCTAssertEqual(values[1], seed)                       // 300 s covered, under the 600 s gate
        XCTAssertGreaterThan(values[2], values[1])            // 600 s covered: the gate opens
        XCTAssertGreaterThan(values[3], values[2])
        XCTAssertGreaterThan(values[4], values[3])
    }

    func testFewerThanMinReadingsNeverCountsLoad() throws {
        let sparse = try fixtureDay("10 readings 90 s apart")
        let seeded = curve(sparse, StrainScorerV2.DayContext(validWornSleepMinutes: 480),
                           end: date(Fixtures.t0 + 2_000))
        let seed = try XCTUnwrap(components([], StrainScorerV2.DayContext(validWornSleepMinutes: 480)).cardio)
        XCTAssertFalse(seeded.isEmpty)
        XCTAssertTrue(seeded.allSatisfy { $0.value == seed })
        XCTAssertEqual(curve(sparse, .init()), [])            // nothing to score at all
    }

    func testADayWithNoCardioComponentHasNoCurve() throws {
        // Five minutes of heart rate is under the coverage gate, and nothing else says anything.
        XCTAssertEqual(curve(try fixtureDay("5 minute burst"), .init()), [])
    }

    func testZeroEvidenceGivesAFlatZeroCurve() throws {
        let points = curve(try fixtureDay("19 readings"), .init(steps: 0))
        XCTAssertFalse(points.isEmpty)
        XCTAssertTrue(points.allSatisfy { $0.value == 0 })
    }

    func testDisplayedScoreSitsAboveTheCurveWhenStepsDominate() throws {
        let easy = try fixtureDay("resting 6 h")
        let bigSteps = try fixtureContext("big steps")
        let parts = components(easy, bigSteps)
        let displayed = StrainScorerV2.displayValue(fromStored: try XCTUnwrap(parts.score))
        XCTAssertEqual(parts.dominant, .steps)
        XCTAssertLessThan(try XCTUnwrap(curve(easy, bigSteps).last).value, displayed - 1)

        let hard = try fixtureDay("hard hour in a resting day")
        let allThree = try fixtureContext("all three")
        let hardParts = components(hard, allThree)
        XCTAssertEqual(hardParts.dominant, .cardio)
        XCTAssertEqual(try XCTUnwrap(curve(hard, allThree).last).value,
                       StrainScorerV2.displayValue(fromStored: try XCTUnwrap(hardParts.score)),
                       accuracy: 1e-12)
    }

    // MARK: - input handling

    func testUnsortedDuplicatedAndOutOfRangeInputGivesTheCurveOfTheReducedReadings() throws {
        let messy = try fixtureDay("messy day")
        var maxPerSecond: [Int: Int] = [:]
        for sample in messy where (30...240).contains(sample.bpm) {
            maxPerSecond[sample.ts] = max(maxPerSecond[sample.ts] ?? 0, sample.bpm)
        }
        let reduced = maxPerSecond.keys.sorted().map { HRSample(ts: $0, bpm: maxPerSecond[$0]!) }
        let context = try fixtureContext("all three")
        let fromMessy = curve(messy, context)
        XCTAssertFalse(fromMessy.isEmpty)
        XCTAssertEqual(fromMessy, curve(reduced, context))
        XCTAssertEqual(fromMessy, curve(reduced.shuffled(using: &seededGenerator), context))
    }

    func testUnusableParametersReturnNoPoints() throws {
        let day = try fixtureDay("hard hour in a resting day")
        let context = try fixtureContext("sleep and steps")
        let start = date(Fixtures.t0)
        let end = date(Fixtures.t0 + dayLength)
        for bucket in [0.0, -300.0, .nan, .infinity] {
            XCTAssertEqual(curve(day, context, bucket: bucket), [], "bucket \(bucket)")
        }
        XCTAssertEqual(curve(day, context, start: end, end: start), [])
        XCTAssertEqual(curve(day, context, start: Date(timeIntervalSince1970: .nan)), [])
        XCTAssertEqual(curve(day, context, maxHR: 60), [])
        XCTAssertEqual(curve(day, context, maxHR: .nan), [])
        XCTAssertEqual(
            StrainScorerV2.cumulativeCardioStrain(day, maxHR: Fixtures.maxHR, restingHR: .infinity,
                                                  context: context, start: start, end: end), [])
        XCTAssertEqual(curve(day, try fixtureContext("no wear coverage")), [])
    }

    func testBucketUnderOneSecondBehavesAsOneSecond() throws {
        let hot = StrainDayFixtures.block(from: Fixtures.t0, count: 900,
                                          center: Fixtures.bpm(atHRR: 80), wobble: 3, seed: 22)
        let context = StrainScorerV2.DayContext(validWornSleepMinutes: 480)
        let fine = curve(hot, context, bucket: 0.25)
        XCTAssertEqual(fine, curve(hot, context, bucket: 1))
        XCTAssertEqual(fine.count, 900)
    }

    func testAnAbsurdSpanIsRejectedInsteadOfAllocated() throws {
        let day = try fixtureDay("hard hour in a resting day")
        let points = StrainScorerV2.cumulativeCardioStrain(
            day, maxHR: Fixtures.maxHR, restingHR: Fixtures.restingHR,
            context: try fixtureContext("sleep only"), start: .distantPast, end: date(Fixtures.t0 + dayLength))
        XCTAssertEqual(points, [])
    }

    // MARK: - cost

    func testAFullDayAtOneHertzReplaysQuickly() throws {
        let day = (0..<dayLength).map { second -> HRSample in
            let hour = second / 3_600
            let bpm = hour == 17 ? 150 + second % 40 : 62 + second % 23
            return HRSample(ts: Fixtures.t0 + second, bpm: bpm)
        }
        let context = StrainScorerV2.DayContext(validWornSleepMinutes: 450, steps: 7_000)
        let clock = ContinuousClock()

        var points: [Point] = []
        let replay = clock.measure { points = curve(day, context) }
        var parts = StrainScorerV2.DayStrainComponents.unscored
        let batch = clock.measure { parts = components(day, context) }
        print("cumulativeCardioStrain, \(day.count) samples at 1 Hz: \(replay); "
              + "dayStrainComponents on the same samples: \(batch)")

        XCTAssertEqual(points.count, (dayLength - 1 + 299) / 300 + 1)
        XCTAssertEqual(points.last?.value, parts.cardio)
        XCTAssertLessThan(replay, .seconds(5))
    }

    private var seededGenerator = SeededGenerator()
}

/// A tiny deterministic generator (SplitMix64) so the shuffled fixture is identical on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x2545_F491_4F6C_DD1D

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
