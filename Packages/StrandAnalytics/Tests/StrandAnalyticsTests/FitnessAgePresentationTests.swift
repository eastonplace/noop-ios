import XCTest
@testable import StrandAnalytics

final class FitnessAgePresentationTests: XCTestCase {
    func testDriverImpactsReproduceUnclampedFitnessAge() {
        let impacts = FitnessAgeEngine.driverImpacts(age: 32, sex: "male", restingHR: 52, paIndex: 8)
        XCTAssertEqual(32 + impacts.restingHRYears + impacts.activityYears,
                       impacts.unclampedFitnessAge, accuracy: 0.000_001)
        XCTAssertEqual(FitnessAgeEngine.fitnessAge(age: 32, sex: "male", restingHR: 52, paIndex: 8),
                       impacts.displayedFitnessAge, accuracy: 0.000_001)
    }

    func testPaceRequiresTwelveSamplesAndNinetyDays() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let eleven = (0..<11).map { FitnessAgeTrendSample(date: start.addingTimeInterval(Double($0) * 9 * 86_400), fitnessAge: 40) }
        XCTAssertNil(FitnessAgePresentation.paceOfAging(samples: eleven))
        let short = (0..<12).map { FitnessAgeTrendSample(date: start.addingTimeInterval(Double($0) * 7 * 86_400), fitnessAge: 40) }
        XCTAssertNil(FitnessAgePresentation.paceOfAging(samples: short))
    }

    func testPaceUsesRealElapsedTime() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let year = 365.2425 * 86_400
        let samples = (0..<13).map { index in
            let fraction = Double(index) / 12
            return FitnessAgeTrendSample(date: start.addingTimeInterval(fraction * year),
                                         fitnessAge: 30 + 0.8 * fraction)
        }
        XCTAssertEqual(FitnessAgePresentation.paceOfAging(samples: samples) ?? -1, 0.8, accuracy: 0.000_1)
    }

    func testDynamicRailContainsBothAgesAndEngineBounds() {
        let range = FitnessAgePresentation.dynamicRailRange(fitnessAge: 27.4, chronologicalAge: 72)
        XCTAssertTrue(range.contains(27.4))
        XCTAssertTrue(range.contains(72))
        XCTAssertGreaterThanOrEqual(range.lowerBound, FitnessAgeEngine.minAge)
        XCTAssertLessThanOrEqual(range.upperBound, FitnessAgeEngine.maxAge)
    }

    func testDeltaIsWholeYearsAgainstTheFractionalCalendarAge() {
        let younger = FitnessAgePresentation.delta(fitnessAge: 38.4, chronologicalAge: 42.7)
        XCTAssertEqual(younger, FitnessAgeDelta(years: 4, direction: .younger))
        let older = FitnessAgePresentation.delta(fitnessAge: 47.2, chronologicalAge: 42.0)
        XCTAssertEqual(older, FitnessAgeDelta(years: 5, direction: .older))
    }

    func testDeltaUnderHalfAYearIsTheSameNotZeroYears() {
        XCTAssertEqual(FitnessAgePresentation.delta(fitnessAge: 42.3, chronologicalAge: 42.6),
                       FitnessAgeDelta(years: 0, direction: .same))
        XCTAssertEqual(FitnessAgePresentation.delta(fitnessAge: 42.0, chronologicalAge: 42.49),
                       FitnessAgeDelta(years: 0, direction: .same))
        XCTAssertEqual(FitnessAgePresentation.delta(fitnessAge: 42.0, chronologicalAge: 42.5),
                       FitnessAgeDelta(years: 1, direction: .younger))
    }

    func testDeltaIgnoresNonFiniteInput() {
        XCTAssertEqual(FitnessAgePresentation.delta(fitnessAge: .nan, chronologicalAge: 40),
                       FitnessAgeDelta(years: 0, direction: .same))
    }
}
