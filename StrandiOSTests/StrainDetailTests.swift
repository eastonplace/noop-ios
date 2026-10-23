import XCTest
@testable import NOOP
import StrandDesign
import StrandAnalytics
import WhoopProtocol
import WhoopStore

// MARK: - The Strain detail's read models

final class StrainTargetGuidanceTests: XCTestCase {
    private let band: ClosedRange<Double> = 14...18

    func testBelowTheBandReportsTheDistanceToItsFloor() {
        XCTAssertEqual(StrainTargetGuidance.make(value: 7.7, target: band), .below(6.3))
        XCTAssertEqual(StrainTargetGuidance.make(value: 0, target: band), .below(14))
    }

    func testInsideTheBandIsOnTargetIncludingBothEdges() {
        for value in [14.0, 15.5, 18.0] {
            XCTAssertEqual(StrainTargetGuidance.make(value: value, target: band), .onTarget, "\(value)")
        }
    }

    func testAboveTheBandReportsTheDistancePastItsCeiling() {
        XCTAssertEqual(StrainTargetGuidance.make(value: 20.4, target: band), .above(2.4))
    }

    /// The hero prints one decimal, so a value that prints "14.0" is on the band and one that prints "13.9" is
    /// not: never "0.0 below".
    func testTheComparisonIsMadeOnTheFiguresTheHeroPrints() {
        XCTAssertEqual(StrainTargetGuidance.make(value: 13.96, target: band), .onTarget)
        XCTAssertEqual(StrainTargetGuidance.make(value: 13.94, target: band), .below(0.1))
        XCTAssertEqual(StrainTargetGuidance.make(value: 18.04, target: band), .onTarget)
        XCTAssertEqual(StrainTargetGuidance.make(value: 18.06, target: band), .above(0.1))
    }

    func testNoValueOrNoTargetGivesNoGuidance() {
        XCTAssertNil(StrainTargetGuidance.make(value: nil, target: band))
        XCTAssertNil(StrainTargetGuidance.make(value: 12, target: nil))
        XCTAssertNil(StrainTargetGuidance.make(value: .nan, target: band))
    }

    func testTheTextNamesTheDistanceOrTheState() {
        XCTAssertTrue(StrainTargetGuidance.below(6.3).text.contains("6.3"))
        XCTAssertTrue(StrainTargetGuidance.above(2.4).text.contains("2.4"))
        XCTAssertFalse(StrainTargetGuidance.onTarget.text.isEmpty)
    }

    func testTheTargetSourceNamesTheRecoveryThatSetsIt() {
        XCTAssertEqual(StrainTargetSource.make(recovery: 71.6, isToday: true), .today(recovery: 72))
        XCTAssertEqual(StrainTargetSource.make(recovery: 28.4, isToday: false), .pastDay(recovery: 28))
        XCTAssertEqual(StrainTargetSource.make(recovery: nil, isToday: true), .notYetScored)
        XCTAssertEqual(StrainTargetSource.make(recovery: nil, isToday: false), .noRecovery)
        XCTAssertTrue(StrainTargetSource.today(recovery: 72).text.contains("72"))
        XCTAssertTrue(StrainTargetSource.pastDay(recovery: 28).text.contains("28"))
    }
}

final class StrainScorePartsTests: XCTestCase {
    private func components(cardio: Double?, steps: Double?, energy: Double? = nil,
                            dominant: StrainScorerV2.DayStrainComponents.Component?) -> StrainScorerV2.DayStrainComponents {
        let top = max(cardio ?? 0, steps ?? 0, energy ?? 0)
        return .init(cardio: cardio, steps: steps, energy: energy,
                     score: cardio == nil ? nil : StrainScorerV2.storedValue(fromDisplay: top), dominant: dominant)
    }

    func testTheDominantRowSetsTheScoreWhenThePartsAgreeWithTheHero() throws {
        let parts = try XCTUnwrap(StrainScoreParts.make(components(cardio: 12, steps: 5.2, dominant: .cardio), hero: 12))
        XCTAssertTrue(parts.agreesWithHero)
        XCTAssertEqual(parts.rows.map(\.kind), [.cardio, .steps])
        XCTAssertEqual(parts.rows.map(\.setsScore), [true, false])
        XCTAssertEqual(parts.rows[0].value, 12)
        XCTAssertEqual(parts.rows[1].value, 5.2)
    }

    /// With no energy source there is no Active energy row at all (never an always-empty one); the screen says what
    /// the score is worked out from instead.
    func testActiveEnergyHasNoRowWhileNothingFeedsIt() throws {
        let parts = try XCTUnwrap(StrainScoreParts.make(components(cardio: 12, steps: nil, dominant: .cardio), hero: 12))
        XCTAssertEqual(parts.rows.map(\.kind), [.cardio, .steps])
        XCTAssertTrue(parts.isScoredFromCardioAndSteps)
    }

    func testActiveEnergyGetsItsRowOnceASourceFeedsIt() throws {
        let parts = try XCTUnwrap(StrainScoreParts.make(
            components(cardio: 4, steps: 3, energy: 2.5, dominant: .cardio), hero: 4))
        XCTAssertEqual(parts.rows.map(\.kind), [.cardio, .steps, .energy])
        XCTAssertFalse(parts.isScoredFromCardioAndSteps)
    }

    func testStepsCanSetTheScore() throws {
        let parts = try XCTUnwrap(StrainScoreParts.make(components(cardio: 4, steps: 6.5, dominant: .steps), hero: 6.5))
        XCTAssertEqual(parts.rows.map(\.setsScore), [false, true])
    }

    func testEnergyCanSetTheScoreWhenAnySourceFeedsIt() throws {
        let parts = try XCTUnwrap(StrainScoreParts.make(
            components(cardio: 4, steps: 3, energy: 6.9, dominant: .energy), hero: 6.9))
        XCTAssertEqual(parts.rows.map(\.setsScore), [false, false, true])
        XCTAssertEqual(parts.rows[2].value, 6.9)
    }

    /// Fewer than 20 readings is the one way the hero (the live score) and the parts (the batch rules) differ: the rows
    /// show, no row claims the score.
    func testWhenThePartsDisagreeWithTheHeroNoRowSetsTheScore() throws {
        let parts = try XCTUnwrap(StrainScoreParts.make(components(cardio: 4.0, steps: 3, dominant: .cardio), hero: 9.1))
        XCTAssertFalse(parts.agreesWithHero)
        XCTAssertEqual(parts.rows.map(\.setsScore), [false, false])
        XCTAssertEqual(parts.rows.count, 2)
    }

    func testNoHeroMeansNoRowClaimsTheScore() throws {
        let parts = try XCTUnwrap(StrainScoreParts.make(components(cardio: 4.0, steps: 3, dominant: .cardio), hero: nil))
        XCTAssertEqual(parts.rows.map(\.setsScore), [false, false])
    }

    func testAnUnscoredDayHasNoParts() {
        XCTAssertNil(StrainScoreParts.make(.unscored, hero: 5))
    }

    func testAHeroWithinHalfAHundredthOfTheScoreAgrees() throws {
        let parts = try XCTUnwrap(StrainScoreParts.make(components(cardio: 12, steps: nil, dominant: .cardio), hero: 12.04))
        XCTAssertTrue(parts.agreesWithHero)
    }
}

/// A past day's parts and curve are worked out from what the nightly batch scored the stored day on: its cycle and its
/// cycle step total, not the calendar day's.
final class StrainBatchParityTests: XCTestCase {
    private let dayStart = 1_790_000_000
    private let maxHR = StrainScorer.tanakaHRmax(age: 34)

    func testStoreInclusiveEndCannotCountTheNextCyclesFirstSample() {
        let rows = [StepSample(ts: dayStart - 1, counter: 98),
                    StepSample(ts: dayStart, counter: 100),
                    StepSample(ts: dayStart + 1, counter: 102),
                    StepSample(ts: dayStart + 2, counter: 104)]
        let clipped = StrainBatchCycle.stepRows(rows, from: dayStart, to: dayStart + 2)
        XCTAssertEqual(clipped.map(\.ts), [dayStart, dayStart + 1])
        XCTAssertEqual(StrainBatchCycle.steps(clipped, ticksPerStep: 1), 2)
        XCTAssertTrue(StrainBatchCycle.stepRows([rows.last!], from: dayStart, to: dayStart + 2).isEmpty)
    }

    private func sleeps() -> [StrainCycleWindow.Sleep] {
        [.init(start: dayStart + 3_600, end: dayStart + 8 * 3_600, effectiveStart: dayStart + 1_800),   // the night
         .init(start: dayStart + 14 * 3_600, end: dayStart + 14 * 3_600 + 1_800, effectiveStart: dayStart + 14 * 3_600),  // a nap
         .init(start: dayStart - 6 * 3_600, end: dayStart - 600, effectiveStart: dayStart - 6 * 3_600)]  // last night's
    }

    func testTheCycleStartsAtTheMainNightThatEndedOnTheDayNotAtTheCorrectedOnset() {
        let start = StrainBatchCycle.start(sleeps: sleeps(), dayStart: dayStart, dayEnd: dayStart + 86_400,
                                           offsetSec: 0, habitualMidsleepSec: nil)
        XCTAssertEqual(start, dayStart + 3_600)
        XCTAssertEqual(StrainBatchCycle.start(sleeps: [], dayStart: dayStart, dayEnd: dayStart + 86_400,
                                              offsetSec: 0, habitualMidsleepSec: nil), dayStart)
    }

    /// AN-05: the batch's cycle runs to the next day's main-night onset (here 23:00, before midnight), or to the next
    /// day's start when it has no main night, so consecutive days meet without overlapping.
    func testTheCycleEndsAtTheNextDaysCycleStart() {
        let nextDay = dayStart + 86_400
        let tonight = StrainCycleWindow.Sleep(start: nextDay - 3_600, end: nextDay + 7 * 3_600,
                                              effectiveStart: nextDay - 3_600)
        XCTAssertEqual(StrainBatchCycle.end(sleeps: sleeps() + [tonight], dayEnd: nextDay,
                                            nextDayEnd: nextDay + 86_400, nextOffsetSec: 0,
                                            habitualMidsleepSec: nil), nextDay - 3_600)
        XCTAssertEqual(StrainBatchCycle.end(sleeps: sleeps(), dayEnd: nextDay, nextDayEnd: nextDay + 86_400,
                                            nextOffsetSec: 0, habitualMidsleepSec: nil), nextDay)
    }

    func testTheCycleStepTotalScalesByTicksPerStepAndIsNilWithoutReadings() {
        let rows = (0..<100).map { StepSample(ts: dayStart + $0 * 300, counter: $0 * 100) }
        XCTAssertEqual(StrainBatchCycle.steps(rows, ticksPerStep: 1), 9_900)
        XCTAssertEqual(StrainBatchCycle.steps(rows, ticksPerStep: 2), 4_950)
        XCTAssertEqual(StrainBatchCycle.steps(rows, ticksPerStep: 0.1), 19_800, "the batch floors the divisor at 0.5")
        XCTAssertNil(StrainBatchCycle.steps([], ticksPerStep: 1))
    }

    /// 16,500 steps on the calendar day, 15,800 over the cycle: the stored score is the cycle's. Worked out from the
    /// calendar steps the parts miss it by more than the tolerance and no row could claim the score.
    func testAStepsLedPastDayAgreesWithItsStoredScoreOnTheCycleStepTotal() throws {
        let hr = stride(from: dayStart + 3_600, to: dayStart + 86_400, by: 10).map { HRSample(ts: $0, bpm: 64) }
        let rows = (0..<158).map { StepSample(ts: dayStart + 3_600 + $0 * 540, counter: $0 * 100) }
        let cycleSteps = try XCTUnwrap(StrainBatchCycle.steps(rows, ticksPerStep: 1))
        XCTAssertEqual(cycleSteps, 15_700)
        func context(_ steps: Int) -> StrainScorerV2.DayContext {
            .init(validWornSleepMinutes: 420, steps: steps, activeEnergyKcal: nil, hasWearCoverage: true)
        }
        let stored = try XCTUnwrap(StrainScorerV2.strain(hr, maxHR: maxHR, restingHR: 52, mode: .physiologicalDay(context(cycleSteps))))
        let hero = StrainScale.displayValue(fromStored: stored)
        let start = Date(timeIntervalSince1970: TimeInterval(dayStart + 3_600))
        let end = Date(timeIntervalSince1970: TimeInterval(dayStart + 86_400))

        let onCycle = StrainDayAnalysis.make(samples: hr, maxHR: maxHR, restingHR: 52, context: context(cycleSteps), start: start, end: end)
        XCTAssertEqual(StrainCurveRelation.make(components: onCycle.components, hero: hero), .otherSetsScore(.steps))
        let parts = try XCTUnwrap(StrainScoreParts.make(onCycle.components, hero: hero))
        XCTAssertEqual(parts.rows.map(\.setsScore), [false, true])

        let onCalendar = StrainDayAnalysis.make(samples: hr, maxHR: maxHR, restingHR: 52, context: context(16_500), start: start, end: end)
        XCTAssertEqual(StrainCurveRelation.make(components: onCalendar.components, hero: hero), .scoreDiffers)
    }

    func testThePastDaysMaximumIsTheOverrideOrTheUnroundedEstimate() {
        XCTAssertEqual(ProfileStore.hrMaxForBatchScoring(override: 0, age: 34), 208 - 0.7 * 34, accuracy: 1e-9)
        XCTAssertEqual(ProfileStore.hrMaxForBatchScoring(override: 191, age: 34), 191)
        XCTAssertEqual(ProfileStore.hrMaxForBatchScoring(override: 0, age: 0), 208 - 0.7 * Double(StrainScorer.defaultAge), accuracy: 1e-9)
        XCTAssertNotEqual(ProfileStore.hrMaxForBatchScoring(override: 0, age: 34), Double(ProfileStore.hrMax(age: 34, override: 0)))
    }
}

final class StrainCurveModelTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 10) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func components(cardio: Double, steps: Double?, dominant: StrainScorerV2.DayStrainComponents.Component?)
        -> StrainScorerV2.DayStrainComponents {
        .init(cardio: cardio, steps: steps, energy: nil,
              score: StrainScorerV2.storedValue(fromDisplay: max(cardio, steps ?? 0)), dominant: dominant)
    }

    // MARK: Curve against the score

    func testWhenCardioSetsTheScoreTheCurveEndsAtItAndDrawsNoConnector() {
        let parts = components(cardio: 12, steps: 5, dominant: .cardio)
        let relation = StrainCurveRelation.make(components: parts, hero: 12)
        XCTAssertEqual(relation, .cardioSetsScore)
        XCTAssertFalse(StrainCurveRelation.showsConnector(relation: relation, hero: 12, curveEnd: 12))
    }

    func testWhenStepsSetTheScoreTheCurveEndsBelowItAndSaysSo() {
        let parts = components(cardio: 4, steps: 6.5, dominant: .steps)
        let relation = StrainCurveRelation.make(components: parts, hero: 6.5)
        XCTAssertEqual(relation, .otherSetsScore(.steps))
        XCTAssertTrue(StrainCurveRelation.showsConnector(relation: relation, hero: 6.5, curveEnd: 4))
    }

    func testAConnectorNeedsAGapWorthDrawing() {
        let relation = StrainCurveRelation.otherSetsScore(.steps)
        XCTAssertFalse(StrainCurveRelation.showsConnector(relation: relation, hero: 4.2, curveEnd: 4.0))
        XCTAssertTrue(StrainCurveRelation.showsConnector(relation: relation, hero: 4.25, curveEnd: 4.0))
    }

    func testAHeroTheCurveCannotExplainDrawsNoConnector() {
        // The curve is cardio only; here the hero is not the parts' score (another source or moment). However far
        // apart they are, that is a passing difference and gets no connector.
        let parts = components(cardio: 4, steps: 3, dominant: .cardio)
        XCTAssertEqual(StrainCurveRelation.make(components: parts, hero: 9.1), .scoreDiffers)
        XCTAssertFalse(StrainCurveRelation.showsConnector(relation: .scoreDiffers, hero: 9.1, curveEnd: 4))
        XCTAssertEqual(StrainCurveRelation.make(components: .unscored, hero: 9.1), .none)
        XCTAssertEqual(StrainCurveRelation.make(components: parts, hero: nil), .none)
    }

    func testTheMarkerNamesWhatSetTheScore() throws {
        let day = StrainDayResult(
            analysis: StrainDayAnalysis(
                components: components(cardio: 4, steps: 6.5, dominant: .steps),
                curve: [.init(t: date(7), value: 3.5), .init(t: date(9), value: 4)],
                gateOpenedAt: date(7, 10)),
            wake: date(7), cycleStart: date(1), end: date(9), sampleCount: 100)
        let content = try XCTUnwrap(StrainCurveContent.make(
            result: day, hero: 6.5, workouts: [], sleepMinutes: 420, live: true, calendar: utc))
        XCTAssertTrue(content.showsConnector)
        XCTAssertEqual(content.markerLabel(isToday: true), "Today's score comes from steps")
        XCTAssertEqual(content.markerLabel(isToday: false), "That day's score came from steps")
    }

    func testTheMarkerIsAbsentWhenCardioSetsTheScore() throws {
        let day = StrainDayResult(
            analysis: StrainDayAnalysis(
                components: components(cardio: 12, steps: 5, dominant: .cardio),
                curve: [.init(t: date(7), value: 3.5), .init(t: date(9), value: 12)],
                gateOpenedAt: date(7, 10)),
            wake: date(7), cycleStart: date(1), end: date(9), sampleCount: 100)
        let content = try XCTUnwrap(StrainCurveContent.make(
            result: day, hero: 12, workouts: [], sleepMinutes: 420, live: true, calendar: utc))
        XCTAssertFalse(content.showsConnector)
        XCTAssertNil(content.markerLabel(isToday: true))
    }

    func testTheSleepSeedIsNamedOnlyWhenSleepAccountsForTheStart() throws {
        let curve: [StrainScorerV2.CumulativeCardioPoint] = [.init(t: date(1), value: 3.5), .init(t: date(7), value: 3.5),
                                                              .init(t: date(9), value: 8)]
        let analysis = StrainDayAnalysis(components: components(cardio: 8, steps: nil, dominant: .cardio),
                                         curve: curve, gateOpenedAt: date(7, 10))
        let result = StrainDayResult(analysis: analysis, wake: date(7), cycleStart: date(1), end: date(9), sampleCount: 9)
        XCTAssertEqual(try XCTUnwrap(StrainCurveContent.make(
            result: result, hero: 8, workouts: [], sleepMinutes: 420, live: true, calendar: utc)).sleepSeed, 3.5)
        XCTAssertNil(try XCTUnwrap(StrainCurveContent.make(
            result: result, hero: 8, workouts: [], sleepMinutes: nil, live: true, calendar: utc)).sleepSeed)
    }

    // MARK: Shape

    func testThePlotStartsAtWakeCarryingTheValueInForce() throws {
        let curve = (0...20).map { StrainScorerV2.CumulativeCardioPoint(t: date(1).addingTimeInterval(Double($0) * 1800),
                                                                         value: Double($0) * 0.5) }
        // Wake at 03:10: the value in force is that of the 03:00 point (index 4 = 2.0).
        let shape = try XCTUnwrap(StrainCurveShape.make(curve: curve, wake: date(3, 10), now: nil))
        XCTAssertEqual(shape.domain.lowerBound, date(3, 10))
        XCTAssertEqual(shape.points.first?.t, date(3, 10))
        XCTAssertEqual(shape.startValue, 2.0)
        XCTAssertEqual(shape.points.last?.t, curve.last?.t)
        XCTAssertEqual(shape.endValue, 10.0)
        XCTAssertEqual(shape.points.count, 1 + curve.filter { $0.t > date(3, 10) }.count)
    }

    func testWithoutAWakeTheCurveStartsAtItsFirstPointAndAWakeAfterTheEndIsIgnored() throws {
        let curve = (0...6).map { StrainScorerV2.CumulativeCardioPoint(t: date(8).addingTimeInterval(Double($0) * 1800), value: Double($0)) }
        XCTAssertEqual(try XCTUnwrap(StrainCurveShape.make(curve: curve, wake: nil, now: nil)).domain.lowerBound, date(8))
        XCTAssertEqual(try XCTUnwrap(StrainCurveShape.make(curve: curve, wake: date(23), now: nil)).domain.lowerBound, date(8))
    }

    func testAShortSpanIsStretchedToThreeHoursAndALiveDayReachesNow() throws {
        let curve = [StrainScorerV2.CumulativeCardioPoint(t: date(8), value: 3), .init(t: date(8, 30), value: 4)]
        let past = try XCTUnwrap(StrainCurveShape.make(curve: curve, wake: nil, now: nil))
        XCTAssertEqual(past.domain.upperBound, date(11))
        let live = try XCTUnwrap(StrainCurveShape.make(curve: curve, wake: nil, now: date(14)))
        XCTAssertEqual(live.domain.upperBound, date(14))
        // `now` behind the last reading never shortens the plot.
        let early = try XCTUnwrap(StrainCurveShape.make(curve: curve, wake: nil, now: date(8, 10)))
        XCTAssertEqual(early.domain.upperBound, date(11))
    }

    func testFewerThanTwoPointsMakeNoShape() {
        XCTAssertNil(StrainCurveShape.make(curve: [], wake: nil, now: nil))
        XCTAssertNil(StrainCurveShape.make(curve: [.init(t: date(8), value: 3)], wake: nil, now: nil))
    }

    func testTimeLabelsAreWholeHoursOnTheSmallestStepThatKeepsFourOrFewer() {
        func hours(_ from: Date, _ to: Date) -> [Int] {
            StrainCurveShape.hourTicks(in: from...to, calendar: utc).map { utc.component(.hour, from: $0) }
        }
        XCTAssertEqual(hours(date(7, 59), date(10, 5)), [8, 9, 10])
        XCTAssertEqual(hours(date(6, 59), date(14, 30)), [8, 10, 12, 14])
        XCTAssertEqual(hours(date(6, 59), date(21, 0)), [8, 12, 16, 20])
        for (from, to) in [(date(5), date(23)), (date(0), date(23, 59)), (date(9), date(9, 40)), (date(7, 30), date(20))] {
            XCTAssertLessThanOrEqual(hours(from, to).count, 4, "\(from) to \(to)")
        }
        XCTAssertEqual(hours(date(9, 5), date(9, 40)), [])
    }

    func testWorkoutsBecomeSegmentsOfThePlotAndThoseOutsideItAreDropped() {
        func workout(_ sport: String, _ start: Date, _ end: Date) -> WorkoutRow {
            WorkoutRow(startTs: Int(start.timeIntervalSince1970), endTs: Int(end.timeIntervalSince1970), sport: sport,
                       source: "manual", durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
                       distanceM: nil, zonesJSON: nil, notes: nil)
        }
        let domain = date(7)...date(15)
        let segments = StrainCurveShape.segments(for: [
            workout("Running", date(12), date(13)), workout("Cycling", date(8), date(9)),
            workout("Yoga", date(2), date(3)), workout("Late", date(16), date(17)),
        ], in: domain)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.map(\.start), [date(8), date(12)])
        XCTAssertEqual(Set(segments.map(\.id)).count, 2, "each segment keeps its own identity")
    }

    // MARK: Analysis

    private func readings(from start: Date, seconds: Int, step: Int = 1, bpm: Int) -> [HRSample] {
        let first = Int(start.timeIntervalSince1970)
        return stride(from: 0, to: seconds, by: step).map { HRSample(ts: first + $0, bpm: bpm) }
    }

    private let context = StrainScorerV2.DayContext(validWornSleepMinutes: 420, steps: nil, activeEnergyKcal: nil,
                                                     hasWearCoverage: true)

    func testTheGateOpensAtTheReadingThatBringsTenMinutesOfCoverage() {
        let samples = readings(from: date(8), seconds: 3600, bpm: 150)
        let opened = StrainDayAnalysis.gateOpenTime(samples: samples, maxHR: 187, restingHR: 52, context: context)
        XCTAssertEqual(opened, date(8).addingTimeInterval(600))
    }

    func testTheGateStaysClosedBelowTwentyReadingsOrTenMinutes() {
        let sparse = readings(from: date(8), seconds: 15 * 60, step: 60, bpm: 150)   // 15 readings
        XCTAssertNil(StrainDayAnalysis.gateOpenTime(samples: sparse, maxHR: 187, restingHR: 52, context: context))
        let brief = readings(from: date(8), seconds: 300, bpm: 150)                   // 300 readings, 5 minutes
        XCTAssertNil(StrainDayAnalysis.gateOpenTime(samples: brief, maxHR: 187, restingHR: 52, context: context))
    }

    func testOutOfRangeReadingsNeverCountTowardTheGate() {
        let junk = readings(from: date(8), seconds: 3600, bpm: 20) + readings(from: date(9), seconds: 3600, bpm: 250)
        XCTAssertNil(StrainDayAnalysis.gateOpenTime(samples: junk, maxHR: 187, restingHR: 52, context: context))
    }

    func testTheCurveEndsAtTheCardioComponentAndNeverDecreases() {
        let samples = readings(from: date(8), seconds: 2 * 3600, bpm: 150)
        let analysis = StrainDayAnalysis.make(samples: samples, maxHR: 187, restingHR: 52, context: context,
                                              start: date(7), end: date(11))
        XCTAssertTrue(analysis.gateOpen)
        XCTAssertEqual(analysis.curve.last?.value, analysis.components.cardio)
        XCTAssertEqual(zip(analysis.curve, analysis.curve.dropFirst()).filter { $1.value < $0.value }.count, 0)
        // It starts at the sleep seed and rises once the gate opens.
        XCTAssertGreaterThan(analysis.curve.first?.value ?? 0, 3)
        XCTAssertGreaterThan(analysis.curve.last?.value ?? 0, analysis.curve.first?.value ?? 0)
    }

    func testBeforeTheGateOpensTheCurveSitsOnTheSleepSeed() throws {
        let samples = readings(from: date(8), seconds: 15 * 60, step: 60, bpm: 160)
        let analysis = StrainDayAnalysis.make(samples: samples, maxHR: 187, restingHR: 52, context: context,
                                              start: date(7), end: date(9))
        XCTAssertFalse(analysis.gateOpen)
        let values = Set(analysis.curve.map(\.value))
        XCTAssertEqual(values.count, 1)
        XCTAssertGreaterThan(try XCTUnwrap(values.first), 0)
    }

    func testAFullDayOfReadingsIsAnalysedWithinTheBudget() {
        let samples = readings(from: date(0), seconds: 86_400, bpm: 90)
        let began = ContinuousClock.now
        let analysis = StrainDayAnalysis.make(samples: samples, maxHR: 187, restingHR: 52, context: context,
                                              start: date(0), end: date(0).addingTimeInterval(86_400))
        let elapsed = ContinuousClock.now - began
        let milliseconds = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        NSLog("[strain-curve] benchmark 86,400 samples: %.1f ms (debug build, simulator), %d points", milliseconds, analysis.curve.count)
        XCTAssertEqual(analysis.curve.count, 289)
        // Release runs this in a few milliseconds; the bound only catches an accidental quadratic.
        XCTAssertLessThan(milliseconds, 3000)
    }

    // MARK: Cycle window

    func testTheCycleStartsAtTheLongestSleepThatWokeOnTheDay() {
        let day = Int(date(0).timeIntervalSince1970)
        let next = day + 86_400
        let night = StrainCycleWindow.Sleep(start: day - 2 * 3600, end: day + 6 * 3600, effectiveStart: day - 2 * 3600 + 600)
        let nap = StrainCycleWindow.Sleep(start: day + 13 * 3600, end: day + 14 * 3600, effectiveStart: day + 13 * 3600)
        let tonight = StrainCycleWindow.Sleep(start: day + 23 * 3600, end: next + 7 * 3600, effectiveStart: day + 23 * 3600)
        let window = StrainCycleWindow.resolve(logicalStart: day, logicalEnd: next, windowEnd: next, sleeps: [night, nap, tonight])
        XCTAssertEqual(window.cycleStart, night.effectiveStart, "the user's corrected onset starts the cycle")
        XCTAssertEqual(window.wake, night.end)
    }

    func testAnOngoingSleepThatHasBegunCountsTodayLikeTheLiveScore() {
        let day = Int(date(0).timeIntervalSince1970)
        let now = day + 23 * 3600 + 1800
        let tonight = StrainCycleWindow.Sleep(start: day + 23 * 3600, end: day + 31 * 3600, effectiveStart: day + 23 * 3600)
        let window = StrainCycleWindow.resolve(logicalStart: day, logicalEnd: Int.max, windowEnd: now, sleeps: [tonight])
        XCTAssertEqual(window.cycleStart, tonight.effectiveStart)
    }

    func testWithNoSleepTheCycleStartsAtTheLogicalDay() {
        let day = Int(date(0).timeIntervalSince1970)
        let window = StrainCycleWindow.resolve(logicalStart: day, logicalEnd: day + 86_400, windowEnd: day + 3600, sleeps: [])
        XCTAssertEqual(window.cycleStart, day)
        XCTAssertNil(window.wake)
    }
}

@MainActor
final class StrainDayCacheTests: XCTestCase {
    private func request(day: String = "2026-10-10", today: Bool = true, refresh: Int = 1, maxHR: Double = 187,
                         hero: Int? = 82) -> StrainDayRequest {
        StrainDayRequest(dayKey: day, logicalStart: Date(timeIntervalSince1970: 1_000), isToday: today, maxHR: maxHR,
                         restingHR: 52, steps: 8200, stepTicksPerStep: 1, sleepMinutes: 400, heroTenths: hero,
                         refreshSeq: refresh)
    }

    private var result: StrainDayResult {
        StrainDayResult(analysis: StrainDayAnalysis(components: .unscored, curve: [], gateOpenedAt: nil),
                        wake: nil, cycleStart: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 1), sampleCount: 0)
    }

    func testTodayIsTrustedForAWhileAndThenReadAgain() throws {
        let cache = StrainDayCache()
        let now = Date()
        cache.store(result, for: request(), now: now)
        let entry = try XCTUnwrap(cache.entry(for: "2026-10-10"))
        XCTAssertTrue(cache.isFresh(entry, for: request(), now: now.addingTimeInterval(StrainDayCache.todayLifetime - 1)))
        XCTAssertFalse(cache.isFresh(entry, for: request(), now: now.addingTimeInterval(StrainDayCache.todayLifetime + 1)))
    }

    /// The live score ticks every 20 s. A pass read for 8.2 is behind a hero that now says 8.6, however young it is,
    /// or the curve and the parts would disagree with the hero until the lifetime ran out.
    func testTodayIsStaleAsSoonAsTheHeroOrTheDataMoves() throws {
        let cache = StrainDayCache()
        let now = Date()
        cache.store(result, for: request(hero: 82), now: now)
        let entry = try XCTUnwrap(cache.entry(for: "2026-10-10"))
        let soon = now.addingTimeInterval(20)
        XCTAssertTrue(cache.isFresh(entry, for: request(hero: 82), now: soon))
        XCTAssertFalse(cache.isFresh(entry, for: request(hero: 86), now: soon))
        XCTAssertFalse(cache.isFresh(entry, for: request(hero: nil), now: soon))
        XCTAssertFalse(cache.isFresh(entry, for: request(refresh: 2, hero: 82), now: soon))
    }

    func testAPastDayIsReadAgainOnlyWhenTheDataRefreshesOrItsInputsChange() throws {
        let cache = StrainDayCache()
        let now = Date()
        cache.store(result, for: request(day: "2026-10-09", today: false), now: now)
        let entry = try XCTUnwrap(cache.entry(for: "2026-10-09"))
        let later = now.addingTimeInterval(3600)
        XCTAssertTrue(cache.isFresh(entry, for: request(day: "2026-10-09", today: false), now: later))
        XCTAssertFalse(cache.isFresh(entry, for: request(day: "2026-10-09", today: false, refresh: 2), now: later))
        XCTAssertFalse(cache.isFresh(entry, for: request(day: "2026-10-09", today: false, maxHR: 190), now: later))
        // A past day's hero is the stored score, which only moves with a refresh.
        XCTAssertTrue(cache.isFresh(entry, for: request(day: "2026-10-09", today: false, hero: 90), now: later))
    }

    func testTheCacheKeepsTheLastFewDays() {
        let cache = StrainDayCache()
        let now = Date()
        for index in 0..<(StrainDayCache.capacity + 3) {
            cache.store(result, for: request(day: "2026-09-\(10 + index)", today: false), now: now)
        }
        XCTAssertNil(cache.entry(for: "2026-09-10"))
        XCTAssertNil(cache.entry(for: "2026-09-12"))
        XCTAssertNotNil(cache.entry(for: "2026-09-13"))
        XCTAssertNotNil(cache.entry(for: "2026-09-\(10 + StrainDayCache.capacity + 2)"))
    }
}

// MARK: - Activities and the trend's early state

final class StrainActivityRowTests: XCTestCase {
    private func workout(_ sport: String, start: Int, source: String = "manual", strain: Double?, version: Int?,
                         avg: Int? = 140) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 1800, sport: sport, source: source, durationS: 1800, energyKcal: nil,
                   avgHr: avg, maxHr: nil, strain: strain, distanceM: nil, zonesJSON: nil, notes: nil, strainVersion: version)
    }

    func testNoopScoreShowsAsTheNoopValueOnTheDisplayScale() {
        let row = StrainActivityRow(workout("Running", start: 100, strain: StrainScorerV2.storedValue(fromDisplay: 9.8), version: 2))
        guard case .noop(let value) = row.score else { return XCTFail("\(row.score)") }
        XCTAssertEqual(value, 9.8, accuracy: 0.0001)
        XCTAssertEqual(row.averageHR, 140)
        XCTAssertEqual(row.durationSeconds, 1800)
    }

    func testAWhoopExportScoreIsLabelledAsWhoops() {
        let row = StrainActivityRow(workout("Strength", start: 100, source: "whoop", strain: 37.5, version: nil))
        guard case .whoop(let value) = row.score else { return XCTFail("\(row.score)") }
        XCTAssertEqual(value, StrainScale.displayValue(fromStored: 37.5), accuracy: 0.0001)
    }

    func testAWorkoutNobodyScoredReadsNotScored() {
        XCTAssertEqual(StrainActivityRow(workout("Walking", start: 100, source: "apple-health", strain: nil, version: nil)).score, .notScored)
        // An unversioned manual row has no trustworthy attribution either, even with a number on it.
        XCTAssertEqual(StrainActivityRow(workout("Walking", start: 100, source: "manual", strain: 20, version: nil)).score, .notScored)
    }

    func testRowsAreChronologicalWithAStableIdentity() {
        let rows = StrainActivityRow.rows(for: [
            workout("B", start: 300, strain: nil, version: nil), workout("A", start: 100, strain: nil, version: nil),
            workout("C", start: 200, strain: nil, version: nil),
        ])
        XCTAssertEqual(rows.map(\.sport), ["A", "C", "B"])
        XCTAssertEqual(Set(rows.map(\.id)).count, 3)
    }
}

final class TrendBuildingProgressTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ offset: Int, _ value: Double?) -> CalendarMetricDay {
        let base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10))!
        return CalendarMetricDay(date: calendar.date(byAdding: .day, value: -offset, to: base)!, value: value)
    }

    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 10))! }

    func testNoDaysAndOneDayAreBuildingTwoAreNot() {
        XCTAssertEqual(TrendBuildingProgress.make(values: [], through: today, calendar: calendar)?.recordedDays, 0)
        XCTAssertEqual(TrendBuildingProgress.make(values: [day(0, 7)], through: today, calendar: calendar)?.recordedDays, 1)
        XCTAssertNil(TrendBuildingProgress.make(values: [day(0, 7), day(1, 5)], through: today, calendar: calendar))
    }

    func testDaysWithoutAValueDoNotCount() {
        XCTAssertEqual(TrendBuildingProgress.make(values: [day(0, nil), day(1, 5)], through: today, calendar: calendar)?.recordedDays, 1)
    }

    func testTheStripIsAWeekOldestFirstWithTheReferenceDayLast() throws {
        let progress = try XCTUnwrap(TrendBuildingProgress.make(values: [day(0, 7)], through: today, calendar: calendar))
        XCTAssertEqual(progress.window, [false, false, false, false, false, false, true])
        let earlier = try XCTUnwrap(TrendBuildingProgress.make(values: [day(5, 7)], through: today, calendar: calendar))
        XCTAssertEqual(earlier.window, [false, true, false, false, false, false, false])
    }

    func testAValueOlderThanTheStripStillCountsAsNothingToShowButKeepsTheTrendBuilding() throws {
        // One day, long ago: the trend is still building, and none of this week's dots are filled.
        let progress = try XCTUnwrap(TrendBuildingProgress.make(values: [day(30, 7)], through: today, calendar: calendar))
        XCTAssertEqual(progress.recordedDays, 0)
    }
}

// MARK: - Strength Strain on the Strain detail

/// Once the day has logged lifting (M > 0): the curve is named for heart rate and lifting, "What set the score" gains a
/// Lifting row that is what the sets add, and the pill on the deciding row is "Decides score".
final class StrainLiftingDetailTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func components(cardio: Double, steps: Double?) -> StrainScorerV2.DayStrainComponents {
        .init(cardio: cardio, steps: steps, energy: nil,
              score: StrainScorerV2.storedValue(fromDisplay: max(cardio, steps ?? 0)), dominant: .cardio)
    }

    func testALiftingDayAddsALiftingRowThatIsWhatTheSetsAdd() throws {
        let parts = components(cardio: 10, steps: 4)
        let hero = StrengthStrain.combinedDisplay(hrDisplay: 10, muscularLoad: 12)
        let result = try XCTUnwrap(StrainScoreParts.make(parts, hero: hero, liftLoad: 12))
        XCTAssertEqual(result.rows.map(\.kind), [.cardio, .steps, .lifting])
        XCTAssertTrue(result.agreesWithHero, "the parts add up to the combined hero")
        let lifting = try XCTUnwrap(result.rows.last)
        XCTAssertEqual(try XCTUnwrap(lifting.value), hero - 10, accuracy: 1e-6)
        XCTAssertFalse(lifting.setsScore, "the Lifting row is a part of the cardio row's score, never the one that decides")
        XCTAssertTrue(result.rows[0].setsScore, "cardio, which carries the lifts, decides the score")
        XCTAssertEqual(StrainCopy.liftingRowDetail(add: DrillInFormat.number(try XCTUnwrap(lifting.value), fractionDigits: 1)),
                       "Logged working sets add \(DrillInFormat.number(hero - 10, fractionDigits: 1))")
    }

    func testADayWithoutLiftingHasNoLiftingRowAndTheOldBits() throws {
        let parts = components(cardio: 10, steps: 4)
        let plain = try XCTUnwrap(StrainScoreParts.make(parts, hero: 10))
        let zero = try XCTUnwrap(StrainScoreParts.make(parts, hero: 10, liftLoad: 0))
        XCTAssertEqual(plain, zero)
        XCTAssertEqual(plain.rows.map(\.kind), [.cardio, .steps])
    }

    func testTheCurveCaptionsFollowTheDaysLiftLoad() {
        let curve = (0..<4).map { StrainScorerV2.CumulativeCardioPoint(t: origin.addingTimeInterval(Double($0) * 3_600), value: Double($0)) }
        let base = StrainDayAnalysis(components: components(cardio: 3, steps: nil), curve: curve, gateOpenedAt: origin)
        XCTAssertEqual(base.liftMuscularLoad, 0)
        let end = Int(origin.addingTimeInterval(3_600).timeIntervalSince1970)
        let lifted = StrainDayLiftTransform.apply(base, loads: [StrainDayLiftLoad(endTs: end, muscularLoad: 12)])
        XCTAssertGreaterThan(lifted.liftMuscularLoad, 0)
        for analysis in [base, lifted] {
            let lifting = analysis.liftMuscularLoad > 0
            XCTAssertEqual(StrainCopy.curveReadoutCaption(isToday: true, lifting: lifting),
                           lifting ? "Heart rate + lifting so far" : "Cardio load so far")
            XCTAssertEqual(StrainCopy.curveReadoutCaption(isToday: false, lifting: lifting),
                           lifting ? "Heart rate + lifting that day" : "Cardio load that day")
        }
    }
}
