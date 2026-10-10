import XCTest
import StrandDesign
@testable import NOOP

/// What the start sheet decides before anything is drawn: which sport it opens on, which recent sports it offers, how a
/// run's setting maps onto the catalogue and where a sport is done.
final class StartWorkoutModelTests: XCTestCase {

    // MARK: Recent sports

    func testRecentSportsKeepTheirOrderMostRecentFirstAndStopAtThree() {
        let shown = StartWorkoutChoices.recentSports(from: ["Cycling", "Running", "Yoga", "Padel"])
        XCTAssertEqual(shown.map(\.name), ["Cycling", "Running", "Yoga"])
        XCTAssertEqual(shown.count, RecentSportsPrefs.maxCount)
    }

    func testRecentSportsAreCataloguedNamesWithoutDuplicates() {
        let shown = StartWorkoutChoices.recentSports(from: ["running", "Running", " RUNNING "])
        XCTAssertEqual(shown.map(\.name), ["Running"], "one chip, spelled as the catalogue spells it")
    }

    func testAFreeTypedSportIsNotOfferedToALiveStart() {
        // A live start names a catalogue sport; a sport typed into the manual log stays out of this row.
        let shown = StartWorkoutChoices.recentSports(from: ["Underwater hockey", "Yoga"])
        XCTAssertEqual(shown.map(\.name), ["Yoga"])
        XCTAssertTrue(StartWorkoutChoices.recentSports(from: []).isEmpty)
    }

    // MARK: Opening sport

    func testTheSheetOpensOnTheMostRecentSportElseRunning() {
        XCTAssertEqual(StartWorkoutChoices.initialSport(recents: ["Yoga", "Running"]), "Yoga")
        XCTAssertEqual(StartWorkoutChoices.initialSport(recents: []), "Running")
        XCTAssertEqual(StartWorkoutChoices.initialSport(recents: ["Underwater hockey"]), "Running",
                       "a recent sport the catalogue lacks cannot be started, so it is not the default")
        XCTAssertEqual(StartWorkoutChoices.initialSport(recents: ["Underwater hockey", "Pilates"]), "Pilates")
        XCTAssertNotNil(WorkoutCatalog.sport(named: StartWorkoutChoices.fallbackSport))
    }

    // MARK: Run type

    func testRunTypeMapsOntoTheTwoCatalogueSportsThatSpellIt() {
        XCTAssertEqual(WorkoutRunType.outdoor.sportName, "Running")
        XCTAssertEqual(WorkoutRunType.treadmill.sportName, "Treadmill run")
        for type in WorkoutRunType.allCases {
            XCTAssertNotNil(WorkoutCatalog.sport(named: type.sportName), "\(type.sportName) must be a catalogue sport")
        }
    }

    func testRunTypeIsReadBackFromTheSelectedSport() {
        XCTAssertEqual(WorkoutRunType.of(sport: "Running"), .outdoor)
        XCTAssertEqual(WorkoutRunType.of(sport: "  running "), .outdoor)
        XCTAssertEqual(WorkoutRunType.of(sport: "Treadmill run"), .treadmill)
        XCTAssertNil(WorkoutRunType.of(sport: "Walking"))
        XCTAssertNil(WorkoutRunType.of(sport: "Treadmill walk"))
    }

    func testThereIsNoTrailOptionAndAHikeIsNeverARun() {
        // The catalogue has no trail-running sport, so there is nothing honest to map one to.
        XCTAssertEqual(WorkoutRunType.allCases.count, 2)
        XCTAssertNil(WorkoutRunType.of(sport: "Hiking"))
        XCTAssertNil(WorkoutRunType.of(sport: "Trail running"))
        XCTAssertFalse(WorkoutRunType.allCases.map(\.sportName).contains("Hiking"))
    }

    // MARK: Titles and settings

    func testTheThreeBigActivitiesReadAsTheThingYouDo() {
        XCTAssertEqual(StartWorkoutChoices.displayTitle(for: "Running"), String(localized: "Run"))
        XCTAssertEqual(StartWorkoutChoices.displayTitle(for: "Hiking"), String(localized: "Hike"))
        XCTAssertEqual(StartWorkoutChoices.displayTitle(for: "Cycling"), String(localized: "Ride"))
        // Everything else keeps its catalogue name, which is data and never translated.
        XCTAssertEqual(StartWorkoutChoices.displayTitle(for: "Yoga"), "Yoga")
        XCTAssertEqual(StartWorkoutChoices.displayTitle(for: "Treadmill run"), "Treadmill run")
    }

    func testASportIsOutdoorOrIndoorOnlyWhenTheCatalogueSaysSo() throws {
        func setting(_ name: String) throws -> WorkoutSetting? {
            StartWorkoutChoices.setting(for: try XCTUnwrap(WorkoutCatalog.sport(named: name)))
        }
        for outdoor in ["Running", "Walking", "Hiking", "Cycling", "Open-water swim", "Rowing", "Skiing", "Snowboarding"] {
            XCTAssertEqual(try setting(outdoor), .outdoor, outdoor)
        }
        for indoor in ["Treadmill run", "Treadmill walk", "Indoor cycle", "Row machine", "Elliptical"] {
            XCTAssertEqual(try setting(indoor), .indoor, indoor)
        }
        // A court, a studio and a gym floor can be either: the sheet says nothing rather than guess.
        for unsaid in ["Yoga", "Soccer", "Golf", "Tennis", "Strength", "Pool swim", "Other"] {
            XCTAssertNil(try setting(unsaid), unsaid)
        }
    }

    func testEveryCatalogueSportHasAGlyphAndARunTypeMatchesItsSetting() throws {
        for sport in WorkoutCatalog.all {
            XCTAssertFalse(sportSymbol(sport.name).isEmpty, sport.name)
        }
        let outdoor = try XCTUnwrap(WorkoutCatalog.sport(named: WorkoutRunType.outdoor.sportName))
        let treadmill = try XCTUnwrap(WorkoutCatalog.sport(named: WorkoutRunType.treadmill.sportName))
        XCTAssertEqual(StartWorkoutChoices.setting(for: outdoor), .outdoor)
        XCTAssertEqual(StartWorkoutChoices.setting(for: treadmill), .indoor)
    }

    // MARK: Remembering a choice

    func testAConfirmedChoiceIsRememberedMostRecentFirst() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "StartWorkoutModelTests.\(UUID().uuidString)"))
        XCTAssertTrue(RecentSportsPrefs.recent(defaults).isEmpty)
        RecentSportsPrefs.recordSelection("Yoga", in: defaults)
        RecentSportsPrefs.recordSelection("Running", in: defaults)
        RecentSportsPrefs.recordSelection("yoga", in: defaults)
        XCTAssertEqual(RecentSportsPrefs.recent(defaults), ["yoga", "Running"])
        XCTAssertEqual(StartWorkoutChoices.initialSport(recents: RecentSportsPrefs.recent(defaults)), "Yoga")
    }
}
