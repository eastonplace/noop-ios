import XCTest
@testable import NOOP

final class ManualWorkoutSportTests: XCTestCase {
    // MARK: Reading a stored sport into the picker

    func testAFreshLogHasNothingChosenAndNoSport() {
        let fresh = ManualWorkoutSport.choice(for: nil)
        XCTAssertEqual(fresh.chosen, "")
        XCTAssertEqual(fresh.custom, "")
        XCTAssertEqual(ManualWorkoutSport.sport(chosen: fresh.chosen, custom: fresh.custom), "")
        XCTAssertEqual(ManualWorkoutSport.choice(for: "  ").chosen, "")
    }

    func testACatalogueSportIsChosenUnderItsCataloguesSpelling() {
        let running = ManualWorkoutSport.choice(for: "running")
        XCTAssertEqual(running.chosen, "Running")
        XCTAssertEqual(running.custom, "")
        XCTAssertEqual(ManualWorkoutSport.choice(for: "Other").chosen, "Other")
        XCTAssertEqual(ManualWorkoutSport.choice(for: "Other").custom, "")
    }

    func testASportTheCatalogueDoesNotListIsOtherCarryingItsOwnNameAndSavesUnchanged() {
        for stored in ["Padel tennis", "Johns Birthday 5k", WorkoutSource.editableSport("detected")] {
            let choice = ManualWorkoutSport.choice(for: stored)
            XCTAssertEqual(choice.chosen, "Other", stored)
            XCTAssertEqual(choice.custom, stored)
            XCTAssertEqual(ManualWorkoutSport.sport(chosen: choice.chosen, custom: choice.custom), stored)
        }
    }

    // MARK: The sport that is saved

    func testOnlyOtherTakesItsOwnName() {
        XCTAssertEqual(ManualWorkoutSport.sport(chosen: "Running", custom: "Padel tennis"), "Running")
        XCTAssertEqual(ManualWorkoutSport.sport(chosen: "Other", custom: "  Padel tennis "), "Padel tennis")
        // Other with no name of its own is still a valid sport.
        XCTAssertEqual(ManualWorkoutSport.sport(chosen: "Other", custom: "   "), "Other")
        XCTAssertEqual(ManualWorkoutSport.sport(chosen: "", custom: "Padel tennis"), "")
    }

    func testTheSavedRowCarriesTheChosenSport() throws {
        let sport = ManualWorkoutSport.sport(chosen: "Yoga", custom: "")
        let row = try XCTUnwrap(WorkoutSource.buildManualRow(
            start: Date(timeIntervalSinceNow: -3_600), durationMin: 45, sport: sport, avgHr: nil, energyKcal: nil))
        XCTAssertEqual(row.sport, "Yoga")
        XCTAssertEqual(row.source, "manual")
        XCTAssertNil(WorkoutSource.buildManualRow(
            start: Date(timeIntervalSinceNow: -3_600), durationMin: 45,
            sport: ManualWorkoutSport.sport(chosen: "", custom: ""), avgHr: nil, energyKcal: nil))
    }

    // MARK: Chips and recents

    func testChipsAreTheRecentCatalogueSportsWithTheChoiceFirstWhenItIsNotAmongThem() {
        let recents = ["Running", "Cycling", "Yoga"]
        XCTAssertEqual(ManualWorkoutSport.chips(recents: recents, chosen: ""), recents)
        XCTAssertEqual(ManualWorkoutSport.chips(recents: recents, chosen: "Cycling"), recents)
        XCTAssertEqual(ManualWorkoutSport.chips(recents: recents, chosen: "Padel"), ["Padel", "Running", "Cycling"])
        XCTAssertEqual(ManualWorkoutSport.chips(recents: [], chosen: "Padel"), ["Padel"])
        XCTAssertEqual(ManualWorkoutSport.chips(recents: ["Running"], chosen: "Other"), ["Other", "Running"])
    }

    func testAFreeTypedRecentIsNotAChipAndIsNotRecorded() {
        XCTAssertEqual(ManualWorkoutSport.chips(recents: ["Johns Birthday 5k", "Yoga"], chosen: ""), ["Yoga"])
        XCTAssertEqual(ManualWorkoutSport.recordedName(for: "running"), "Running")
        XCTAssertNil(ManualWorkoutSport.recordedName(for: "Johns Birthday 5k"))
    }
}
