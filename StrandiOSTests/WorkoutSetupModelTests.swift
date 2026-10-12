import XCTest
import WhoopStore
@testable import NOOP

/// What the setup page says, from plain values.
@MainActor
final class WorkoutSetupModelTests: XCTestCase {
    private typealias Start = WorkoutStartPresentation

    // MARK: Start

    func testAnOrdinaryStartSaysWhatItWillDo() {
        let run = Start.make(sportTitle: "Run", isRouteSport: true, gps: .locked(accuracyMeters: 6), strapConnected: true,
                             countdownOn: true)
        XCTAssertEqual(run.label, .start(title: "Run"))
        XCTAssertEqual(run.caption, .holdToSkip)
        XCTAssertEqual(run.labelText, "Start Run")
    }

    func testTheHoldCaptionIsOnlyThereWhileTheCountdownIs() {
        let off = Start.make(sportTitle: "Run", isRouteSport: true, gps: .locating, strapConnected: true, countdownOn: false)
        XCTAssertEqual(off.caption, .none)
        XCTAssertNil(off.captionText)
    }

    func testAskingForLocationStillPromisesARoute() {
        let asks = Start.make(sportTitle: "Run", isRouteSport: true, gps: .allowNeeded, strapConnected: true, countdownOn: true)
        XCTAssertEqual(asks.label, .start(title: "Run"), "starting asks once, so the route is still expected")
    }

    func testARouteSportWithLocationRefusedStartsWithoutARoute() {
        for gps in [GpsReadiness.off, .restricted] {
            let refused = Start.make(sportTitle: "Run", isRouteSport: true, gps: gps, strapConnected: true, countdownOn: true)
            XCTAssertEqual(refused.label, .withoutRoute(title: "Run"), "\(gps)")
            XCTAssertEqual(refused.labelText, "Start Run without route")
            XCTAssertEqual(refused.caption, .holdToSkip)
        }
    }

    func testAnIndoorSportWithNoStrapSaysThereIsNothingToSave() {
        let none = Start.make(sportTitle: "Strength Training", isRouteSport: false, gps: .locked(accuracyMeters: 3),
                              strapConnected: false, countdownOn: true)
        XCTAssertEqual(none.label, .withoutHeartRate)
        XCTAssertEqual(none.caption, .nothingToSave)
        XCTAssertEqual(none.labelText, "Start without heart rate")
        XCTAssertEqual(none.captionText, "Without heart rate there is nothing to save for this sport. You can still discard it.")
    }

    func testAnIndoorSportWithAStrapStartsNormally() {
        let ok = Start.make(sportTitle: "Yoga", isRouteSport: false, gps: .off, strapConnected: true, countdownOn: true)
        XCTAssertEqual(ok.label, .start(title: "Yoga"), "the GPS means nothing to a sport with no route")
    }

    func testARouteSportWithNeitherARouteNorAStrapHasNothingToSaveToo() {
        let none = Start.make(sportTitle: "Run", isRouteSport: true, gps: .off, strapConnected: false, countdownOn: true)
        XCTAssertEqual(none.label, .withoutHeartRate)
        XCTAssertEqual(none.caption, .nothingToSave)
    }

    func testARouteSportWithoutAStrapStillSavesItsRoute() {
        let route = Start.make(sportTitle: "Run", isRouteSport: true, gps: .locked(accuracyMeters: 5), strapConnected: false,
                               countdownOn: true)
        XCTAssertEqual(route.label, .start(title: "Run"))
    }

    // MARK: Today

    func testARecoveryWithAStrainSoFarReadsTheTargetAndTheDay() {
        let today = WorkoutReadinessToday.make(recovery: 72, soFar: 6.1)
        XCTAssertEqual(today, .target(recovery: 72, range: 14...18, soFar: 6.1))
        XCTAssertFalse(today.isWarning)
        XCTAssertTrue(today.text().contains("72") && today.text().contains("14–18") && today.text().contains("6.1"), today.text())
    }

    func testBeforeAnyStrainTheLineHasNoSoFar() {
        let today = WorkoutReadinessToday.make(recovery: 50, soFar: nil)
        XCTAssertEqual(today, .target(recovery: 50, range: 10...14, soFar: nil))
        XCTAssertFalse(today.text().contains("so far"), today.text())
    }

    func testADayAlreadyPastItsTargetIsAWarning() {
        let today = WorkoutReadinessToday.make(recovery: 50, soFar: 15.1)
        XCTAssertEqual(today, .above(soFar: 15.1, range: 10...14))
        XCTAssertTrue(today.isWarning)
        XCTAssertTrue(today.text().contains("15.1") && today.text().contains("10–14"), today.text())
    }

    func testAStrainAtTheTopOfTheTargetIsStillOnIt() {
        // The comparison is at the one decimal shown: 14.04 reads "14.0".
        XCTAssertFalse(WorkoutReadinessToday.make(recovery: 50, soFar: 14.04).isWarning)
        XCTAssertTrue(WorkoutReadinessToday.make(recovery: 50, soFar: 14.2).isWarning)
    }

    func testWithoutARecoveryThereIsNoTarget() {
        XCTAssertEqual(WorkoutReadinessToday.make(recovery: nil, soFar: 8), .unscored)
        XCTAssertEqual(WorkoutReadinessToday.make(recovery: .nan, soFar: 8), .unscored)
        XCTAssertFalse(WorkoutReadinessToday.unscored.isWarning)
        XCTAssertFalse(WorkoutReadinessToday.unscored.text().isEmpty)
    }

    // MARK: Last time

    private func row(_ sport: String, start: Int, seconds: Double, meters: Double?) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + Int(seconds), sport: sport, source: "manual", durationS: seconds,
                   energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: meters, zonesJSON: nil, notes: nil)
    }

    func testTheNewestWorkoutInTheSportIsTheOneThatIsShown() {
        let rows = [row("Cycling", start: 300, seconds: 600, meters: 9_000),
                    row("running", start: 200, seconds: 1_800, meters: 5_000),
                    row("Running", start: 100, seconds: 1_800, meters: 4_000)]
        XCTAssertEqual(WorkoutSetupLastTime.newest(of: "Running", in: rows)?.startTs, 200, "newest first, case-insensitive")
        XCTAssertNil(WorkoutSetupLastTime.newest(of: "Yoga", in: rows))
    }

    func testARouteWorkoutReadsDistancePaceAndWhen() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let ran = row("Running", start: Int(now.timeIntervalSince1970) - 90_000, seconds: 1_800, meters: 5_000)
        let facts = WorkoutSetupLastTime.facts(for: ran, title: "Run", system: .metric, now: now, calendar: .current)
        XCTAssertEqual(facts.first, "Last Run")
        XCTAssertEqual(facts.count, 4, "\(facts)")
        XCTAssertTrue(facts[1].contains("5"), facts[1])
        XCTAssertTrue(facts[2].contains("6:00"), "1800 s over 5 km is 6:00 per km: \(facts[2])")
    }

    func testAWorkoutWithNoDistanceReadsItsDuration() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let lift = row("Strength Training", start: Int(now.timeIntervalSince1970) - 600, seconds: 3_120, meters: nil)
        let facts = WorkoutSetupLastTime.facts(for: lift, title: "Strength Training", system: .metric, now: now)
        XCTAssertEqual(facts.count, 3)
        XCTAssertEqual(facts[1], "52m")
    }

    /// VoiceOver says the last-time line in words: "5.0 kilometers", "6:00 per kilometer", never "km" and "/km" letter by letter.
    func testTheLastTimeLineIsSpokenWithUnitsAsWords() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let ran = row("Running", start: Int(now.timeIntervalSince1970) - 90_000, seconds: 1_800, meters: 5_000)
        let spoken = WorkoutSetupLastTime.spokenFacts(for: ran, title: "Run", system: .metric, now: now,
                                                      calendar: .current, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(spoken.count, 4, "\(spoken)")
        XCTAssertTrue(spoken[1].contains("kilometers"), spoken[1])
        XCTAssertEqual(spoken[2], WorkoutFormat.spokenPace("6:00", system: .metric))
        for fact in spoken { XCTAssertFalse(fact.contains(" km") || fact.contains("/km"), fact) }
        let miles = WorkoutSetupLastTime.spokenFacts(for: ran, title: "Run", system: .imperial, now: now,
                                                     calendar: .current, locale: Locale(identifier: "en_US"))
        XCTAssertTrue(miles[1].contains("miles"), miles[1])
        let lift = row("Strength Training", start: Int(now.timeIntervalSince1970) - 600, seconds: 3_120, meters: nil)
        XCTAssertEqual(WorkoutSetupLastTime.spokenFacts(for: lift, title: "Strength", system: .metric, now: now)[1],
                       WorkoutFormat.spokenDuration(3_120))
    }

    func testTheCountdownPreferenceIsOnUnlessTurnedOff() {
        XCTAssertTrue(WorkoutPrefs.countdownOnDefault)
        XCTAssertEqual(WorkoutPrefs.countdownOnKey, "workoutCountdownOn")
    }
}
