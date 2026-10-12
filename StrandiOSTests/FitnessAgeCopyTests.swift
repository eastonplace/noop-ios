import XCTest
import StrandAnalytics
@testable import NOOP

/// The "N years younger" sentence is the gap between the two whole numbers the screens print, so the hero, the
/// "vs age N" eyebrow and the sentence always agree.
final class FitnessAgeCopyTests: XCTestCase {
    func testSentenceMatchesTheShownNumbersWhenFractionsStraddleARoundingBoundary() {
        // Shown: 42 against "vs age 42". The unrounded gap is 0.8, which used to read "1 year younger".
        let same = FitnessAgeCopy.delta(fitnessAge: 41.6, calendarAge: 42.4)
        XCTAssertEqual(FitnessAgeCopy.shownAge(41.6), 42)
        XCTAssertEqual(FitnessAgeCopy.shownCalendarAge(42.4), 42)
        XCTAssertEqual(same, FitnessAgeDelta(years: 0, direction: .same))

        // Shown: 39 against "vs age 42". The unrounded gap is 3.7, which used to read "4 years younger".
        let younger = FitnessAgeCopy.delta(fitnessAge: 38.6, calendarAge: 42.3)
        XCTAssertEqual(FitnessAgeCopy.shownAge(38.6), 39)
        XCTAssertEqual(FitnessAgeCopy.shownCalendarAge(42.3), 42)
        XCTAssertEqual(younger, FitnessAgeDelta(years: 3, direction: .younger))
    }

    func testOlderAndZeroAndNonFinite() {
        XCTAssertEqual(FitnessAgeCopy.delta(fitnessAge: 34.0, calendarAge: 29.9),
                       FitnessAgeDelta(years: 5, direction: .older))
        XCTAssertEqual(FitnessAgeCopy.delta(fitnessAge: 30.4, calendarAge: 30.0),
                       FitnessAgeDelta(years: 0, direction: .same))
        XCTAssertEqual(FitnessAgeCopy.delta(fitnessAge: .nan, calendarAge: 30),
                       FitnessAgeDelta(years: 0, direction: .same))
        XCTAssertEqual(FitnessAgeCopy.delta(fitnessAge: 30, calendarAge: .infinity),
                       FitnessAgeDelta(years: 0, direction: .same))
    }

    func testEveryPairSaysTheGapOfItsShownNumbers() {
        for tenthsFitness in stride(from: 200, through: 600, by: 7) {
            for tenthsCalendar in stride(from: 200, through: 600, by: 11) {
                let fitness = Double(tenthsFitness) / 10, calendar = Double(tenthsCalendar) / 10
                let delta = FitnessAgeCopy.delta(fitnessAge: fitness, calendarAge: calendar)
                let gap = FitnessAgeCopy.shownCalendarAge(calendar) - FitnessAgeCopy.shownAge(fitness)
                XCTAssertEqual(delta.years, abs(gap), "F=\(fitness) C=\(calendar)")
            }
        }
    }
}
