import XCTest
@testable import NOOP

/// The sport's name as the live screen, the resume bar and the start page draw it: specific, localized, and never a change to the
/// stored name.
final class WorkoutSportTitleTests: XCTestCase {
    func testARunIsOutdoorOrTreadmillAndStrengthIsOneName() {
        XCTAssertEqual(WorkoutSportTitle.name(for: "Running"), String(localized: "Outdoor run"))
        XCTAssertEqual(WorkoutSportTitle.name(for: "Treadmill run"), String(localized: "Treadmill run"))
        XCTAssertEqual(WorkoutSportTitle.name(for: "Strength"), String(localized: "Strength training"))
        XCTAssertEqual(WorkoutSportTitle.name(for: "Strength Training"), String(localized: "Strength training"))
        XCTAssertEqual(WorkoutSportTitle.name(for: "Traditional Strength Training"), String(localized: "Strength training"), "the Health spelling")
    }

    func testEveryCatalogueSportButTheFreeTextOtherHasAName() {
        for sport in WorkoutCatalog.all where sport.name != "Other" {
            XCTAssertTrue(WorkoutSportTitle.isKnown(sport.name), "\(sport.name) has no localized name")
            XCTAssertFalse(WorkoutSportTitle.name(for: sport.name).isEmpty)
        }
    }

    func testASportTheTableDoesNotKnowIsDrawnAsStored() {
        XCTAssertEqual(WorkoutSportTitle.name(for: "Underwater Hockey"), "Underwater Hockey")
        XCTAssertFalse(WorkoutSportTitle.isKnown("Underwater Hockey"))
        XCTAssertEqual(StartWorkoutChoices.displayTitle(for: "Underwater Hockey"), "Underwater Hockey")
    }

    func testTheStartPageKeepsRunRideAndHikeAndSharesTheRest() {
        XCTAssertEqual(StartWorkoutChoices.displayTitle(for: "Running"), String(localized: "Run"))
        XCTAssertEqual(StartWorkoutChoices.displayTitle(for: "Yoga"), WorkoutSportTitle.name(for: "Yoga"))
    }
}
