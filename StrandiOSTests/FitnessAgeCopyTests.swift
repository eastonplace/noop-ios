import XCTest
import StrandAnalytics
import StrandDesign
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

    // MARK: The calendar age agrees with the profile's whole-year age

    func testAFractionJustUnderABirthdayStaysInTheProfilesYear() {
        // A date of birth exactly 30 calendar years back is 10,957 days: 29.9998 by the 365.2425-day divisor.
        let now = Date(timeIntervalSince1970: 1_791_842_400)          // 2026-10-12 22:00 UTC
        let dob = Date(timeIntervalSince1970: 845_135_961)            // 1996-10-12 15:59:21 UTC
        let fraction = FitnessAgePresentation.chronologicalAge(on: now, dateOfBirth: dob)
        let years = ProfileStore.years(from: dob, to: now)
        XCTAssertEqual(years, 30)
        XCTAssertLessThan(fraction, 30, "premise: the raw fraction reads under the birthday")
        let held = FitnessAgeCopy.withinWholeYear(fraction, wholeYears: years)
        XCTAssertEqual(FitnessAgeCopy.shownCalendarAge(held), 30)
    }

    func testTheFractionStaysInsideItsYear() {
        XCTAssertEqual(FitnessAgeCopy.withinWholeYear(29.9998, wholeYears: 30), 30)
        XCTAssertEqual(FitnessAgeCopy.withinWholeYear(30.4, wholeYears: 30), 30.4)
        XCTAssertLessThan(FitnessAgeCopy.withinWholeYear(31.0002, wholeYears: 30), 31)
        XCTAssertEqual(FitnessAgeCopy.shownCalendarAge(FitnessAgeCopy.withinWholeYear(31.0002, wholeYears: 30)), 30)
        XCTAssertTrue(FitnessAgeCopy.withinWholeYear(.nan, wholeYears: 30).isNaN)
    }

    // MARK: The rail says what the sentence says

    func testTheRailIsDrawnOnTheShownNumbersAndReadsLikeTheSentence() throws {
        // Fitness 29.6 shows as 30 against a calendar age shown as 29: "1 year older". The raw fractions put the dot
        // left of the tick, in green.
        let older = try XCTUnwrap(FitnessAgeCopy.railMarks(fitnessAge: 29.6, calendarAge: 29.7))
        XCTAssertEqual(older.fitness, 30)
        XCTAssertEqual(older.calendar, 29)
        XCTAssertEqual(older.reading, .older)
        // Fitness 30.4 against 30.2: both show as 30, "about the same": no side, no colour.
        let same = try XCTUnwrap(FitnessAgeCopy.railMarks(fitnessAge: 30.4, calendarAge: 30.2))
        XCTAssertEqual(same.fitness, same.calendar)
        XCTAssertEqual(same.reading, .same)
        let younger = try XCTUnwrap(FitnessAgeCopy.railMarks(fitnessAge: 38.6, calendarAge: 42.3))
        XCTAssertEqual(younger.fitness, 39)
        XCTAssertEqual(younger.calendar, 42)
        XCTAssertEqual(younger.reading, .younger)
        XCTAssertNil(FitnessAgeCopy.railMarks(fitnessAge: .nan, calendarAge: 30))
        XCTAssertNil(FitnessAgeCopy.railMarks(fitnessAge: 30, calendarAge: .infinity))
    }

    func testTheDotIsOnTheSideTheSentenceNamesForEveryPair() throws {
        for tenthsFitness in stride(from: 200, through: 600, by: 7) {
            for tenthsCalendar in stride(from: 200, through: 600, by: 11) {
                let fitness = Double(tenthsFitness) / 10, calendar = Double(tenthsCalendar) / 10
                let marks = try XCTUnwrap(FitnessAgeCopy.railMarks(fitnessAge: fitness, calendarAge: calendar))
                let delta = FitnessAgeCopy.delta(fitnessAge: fitness, calendarAge: calendar)
                switch delta.direction {
                case .younger: XCTAssertEqual(marks.reading, .younger); XCTAssertLessThan(marks.fitness, marks.calendar)
                case .older: XCTAssertEqual(marks.reading, .older); XCTAssertGreaterThan(marks.fitness, marks.calendar)
                case .same: XCTAssertEqual(marks.reading, .same); XCTAssertEqual(marks.fitness, marks.calendar)
                }
                XCTAssertEqual(abs(marks.fitness - marks.calendar), Double(delta.years), "F=\(fitness) C=\(calendar)")
            }
        }
    }
}
