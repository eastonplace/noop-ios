import XCTest
import WhoopProtocol
@testable import StrandAnalytics

final class WorkoutTypeSuggestionTests: XCTestCase {
    private let start = 1_790_000_000
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func workout(duration: Int = 1_200) -> DetectedWorkout {
        DetectedWorkout(startSec: start, endSec: start + duration, avgBpm: 145,
                        peakBpm: 178, durationMin: duration / 60)
    }

    private func movement(activityClass: Int, from: Int = 0, duration: Int = 1_200,
                          initialCounter: Int = 0, moving: Bool = true) -> [StepSample] {
        (0...duration).map {
            StepSample(ts: start + from + $0,
                       counter: (initialCounter + (moving ? $0 * 2 : 0)) & 0xFFFF,
                       activityClass: activityClass)
        }
    }

    private func history(_ sport: String, daysAgo: Int, offset: Int = 0,
                         duration: Int = 1_200) -> WorkoutTypeSuggestion.ConfirmedWorkout {
        let ts = start - daysAgo * 86_400 + offset
        return .init(startSec: ts, endSec: ts + duration, sport: sport)
    }

    private func suggest(steps: [StepSample] = [],
                         history: [WorkoutTypeSuggestion.ConfirmedWorkout] = [])
        -> WorkoutTypeSuggestion.Prediction {
        WorkoutTypeSuggestion.classify(workout: workout(), steps: steps,
                                       confirmedHistory: history, calendar: calendar)
    }

    func testHeartRateAloneKeepsGenericTypeEvenAtHighIntensity() {
        let result = suggest()
        XCTAssertEqual(result.sport, "Workout")
        XCTAssertEqual(result.confidence, .unclassified)
        XCTAssertEqual(result.evidence, [.insufficientTypeEvidence])
    }

    func testSustainedWalkingAndRunningHaveMovementEvidence() {
        for (activityClass, sport, evidence) in [
            (1, "Walking", WorkoutTypeSuggestion.Evidence.walkingMovement),
            (2, "Running", WorkoutTypeSuggestion.Evidence.runningMovement)
        ] {
            let result = suggest(steps: movement(activityClass: activityClass))
            XCTAssertEqual(result.sport, sport)
            XCTAssertEqual(result.confidence, .likely)
            XCTAssertEqual(result.evidence, [evidence])
        }
    }

    func testSparseClassesDoNotPretendToCoverTheWholeWindow() {
        let sparse = stride(from: 0, through: 1_200, by: 60).map {
            StepSample(ts: start + $0, counter: $0, activityClass: 2)
        }
        XCTAssertEqual(suggest(steps: sparse).sport, "Workout")
    }

    func testAClassWithoutActualCounterMovementIsInsufficient() {
        XCTAssertEqual(suggest(steps: movement(activityClass: 2, moving: false)).sport, "Workout")
    }

    func testMixedAndUnknownClassesKeepTheGenericFallback() {
        let mixed = movement(activityClass: 1, duration: 600)
            + movement(activityClass: 2, from: 601, duration: 599, initialCounter: 1_202)
        XCTAssertEqual(suggest(steps: mixed).sport, "Workout")
        XCTAssertEqual(suggest(steps: movement(activityClass: 99)).sport, "Workout")
        XCTAssertEqual(suggest(steps: movement(activityClass: 0)).sport, "Workout")
    }

    func testCounterWrapStillCountsButCounterResetDoesNotCreateMovement() {
        XCTAssertEqual(suggest(steps: movement(activityClass: 2, initialCounter: 65_000)).sport, "Running")
        let resets = (0...1_200).map {
            StepSample(ts: start + $0, counter: (1_200 - $0) * 20, activityClass: 2)
        }
        XCTAssertEqual(suggest(steps: resets).sport, "Workout")
    }

    func testOutOfWindowAndConflictingDuplicateSamplesCannotSupplyEvidence() {
        let outside = movement(activityClass: 2, from: -2_000, duration: 600)
        XCTAssertEqual(suggest(steps: outside).sport, "Workout")
        let contradictions = movement(activityClass: 1) + movement(activityClass: 2)
        XCTAssertEqual(suggest(steps: contradictions).sport, "Workout")
        let original = movement(activityClass: 1)
        XCTAssertEqual(suggest(steps: original + original), suggest(steps: original))
    }

    func testRepeatedConfirmedTypesGiveOnlyAPossibleContextSuggestion() {
        for sport in ["Cycling", "Strength"] {
            let result = suggest(history: (1...3).map { history(sport, daysAgo: $0) })
            XCTAssertEqual(result.sport, sport)
            XCTAssertEqual(result.confidence, .possible)
            XCTAssertEqual(result.evidence, [.similarConfirmedWorkouts(count: 3)])
        }
    }

    func testOneOrTwoPriorLabelsAndDuplicateSameDayRowsAreNotLearning() {
        let one = history("Cycling", daysAgo: 1)
        XCTAssertEqual(suggest(history: [one]).sport, "Workout")
        XCTAssertEqual(suggest(history: [one, history("Cycling", daysAgo: 2)]).sport, "Workout")
        XCTAssertEqual(suggest(history: [one, one, one]).sport, "Workout")
        let sameDay = [one, history("Cycling", daysAgo: 1, offset: 60),
                       history("Cycling", daysAgo: 1, offset: 120)]
        XCTAssertEqual(suggest(history: sameDay).sport, "Workout")
    }

    func testConflictingPriorTypesDoNotChooseTheMostRecentLabel() {
        let rows = (1...3).map { history("Cycling", daysAgo: $0) }
            + (4...6).map { history("Strength", daysAgo: $0) }
        XCTAssertEqual(suggest(history: rows).sport, "Workout")
    }

    func testHistoryMustBePriorRecentValidAndMatchTheSessionContext() {
        let invalid = (1...3).flatMap { day in [
            history("Cycling", daysAgo: -day),
            history("Cycling", daysAgo: day, duration: -300),
            history("Cycling", daysAgo: day, offset: 6 * 3_600),
            history("Cycling", daysAgo: day, duration: 5 * 3_600),
            history("Cycling", daysAgo: day + 90),
            history("Workout", daysAgo: day),
            history("detected", daysAgo: day)
        ] }
        XCTAssertEqual(suggest(history: invalid).sport, "Workout")
    }

    func testStrongMovementTakesPriorityOverAnUnrelatedHistoryLabel() {
        let result = suggest(steps: movement(activityClass: 2),
                             history: (1...3).map { history("Strength", daysAgo: $0) })
        XCTAssertEqual(result.sport, "Running")
        XCTAssertEqual(result.confidence, .likely)
        XCTAssertEqual(result.evidence, [.runningMovement])
    }

    func testConfirmedIndoorCorrectionCanRefineTheMatchingMovementFamily() {
        let result = suggest(steps: movement(activityClass: 2),
                             history: (1...3).map { history("Treadmill run", daysAgo: $0) })
        XCTAssertEqual(result.sport, "Treadmill run")
        XCTAssertEqual(result.confidence, .possible, "movement cannot tell indoor from outdoor")
        XCTAssertEqual(result.evidence, [.runningMovement, .similarConfirmedWorkouts(count: 3)])
    }

    func testHistoryMatchesAcrossMidnightUsingClockTimeDistance() {
        let midnightStart = start / 86_400 * 86_400 + 10 * 60
        let window = DetectedWorkout(startSec: midnightStart, endSec: midnightStart + 1_200,
                                     avgBpm: 140, peakBpm: 170, durationMin: 20)
        let history = (0...2).map { day in
            let prior = midnightStart - day * 86_400 - 40 * 60
            return WorkoutTypeSuggestion.ConfirmedWorkout(startSec: prior, endSec: prior + 1_200, sport: "Cycling")
        }
        let result = WorkoutTypeSuggestion.classify(workout: window, steps: [], confirmedHistory: history,
                                                    calendar: calendar)
        XCTAssertEqual(result.sport, "Cycling")
    }

    func testInvalidWindowIsGenericAndCannotOverflow() {
        for window in [
            DetectedWorkout(startSec: start, endSec: start, avgBpm: 140, peakBpm: 170, durationMin: 0),
            DetectedWorkout(startSec: .min, endSec: .max, avgBpm: 140, peakBpm: 170, durationMin: .max)
        ] {
            let result = WorkoutTypeSuggestion.classify(workout: window, steps: movement(activityClass: 2),
                                                       calendar: calendar)
            XCTAssertEqual(result.sport, "Workout")
        }
    }
}
