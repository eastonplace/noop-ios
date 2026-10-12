import XCTest
import StrandDesign
import WhoopStore
@testable import NOOP

/// What the journey's summary puts where: the live screen's figures, from the saved row.
final class WorkoutSummaryModelTests: XCTestCase {
    private let en = Locale(identifier: "en_US")
    private let thresholds = HRZoneStyle.Thresholds(hrMax: 200)
    private let start = 1_700_000_000

    private func row(_ sport: String = "Running", seconds: Double = 1_865, distance: Double? = 5_000, kcal: Double? = 412,
                     avg: Int? = 149, peak: Int? = 178, strain: Double? = 52, version: Int? = 2,
                     source: String = "recorded") -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + Int(seconds), sport: sport, source: source, durationS: seconds,
                   energyKcal: kcal, avgHr: avg, maxHr: peak, strain: strain, distanceM: distance, zonesJSON: nil, notes: nil,
                   strainVersion: version)
    }

    private func figures(_ row: WorkoutRow, imperial: Bool = false) -> WorkoutSummary.Figures {
        let hero = WorkoutHeroStrain.make(for: row, usualStored: nil)
        return WorkoutSummary.figures(for: row, strain: hero, imperial: imperial, thresholds: thresholds, locale: en)
    }

    private func ids(_ figures: WorkoutSummary.Figures) -> [String] { figures.rest.map(\.id) }

    // MARK: A workout that covered ground

    func testARunLeadsWithItsDistanceThenTimePaceHeartRateStrainPeakAndEnergy() {
        let run = figures(row())
        XCTAssertEqual(run.focus.id, "distance")
        XCTAssertEqual(run.focus.value.text, "5.00")
        XCTAssertEqual(ids(run), ["time", "pace", "averageHeartRate", "strain", "maxHeartRate", "calories"])
        XCTAssertEqual(run.rest[0].value.text, "31:05")
        XCTAssertEqual(run.rest[1].value.text, LiveWorkoutGlance.paceDisplay("6:13"))
    }

    func testARideIsReadAsSpeedNotPace() {
        let ride = figures(row("Cycling", seconds: 3_600, distance: 25_000))
        XCTAssertEqual(ids(ride).prefix(2), ["time", "speed"])
        XCTAssertFalse(ids(ride).contains("pace"))
    }

    func testDistanceAndPaceFollowTheUnitSetting() {
        let miles = figures(row(seconds: 2_400, distance: 8_047), imperial: true)
        XCTAssertEqual(miles.focus.value.text, "5.00")
        XCTAssertEqual(miles.focus.value.unit, [LiveWorkoutGlance.Units.distance(imperial: true)])
        XCTAssertEqual(miles.rest[1].value.unit.last, LiveWorkoutGlance.Units.pace(imperial: true))
    }

    // MARK: A workout without a route

    func testAStrengthSessionLeadsWithItsTimeAndHasNoPace() {
        let lift = figures(row("Strength Training", seconds: 2_700, distance: nil))
        XCTAssertEqual(lift.focus.id, "time")
        XCTAssertEqual(lift.focus.value.text, "45:00")
        XCTAssertEqual(ids(lift), ["averageHeartRate", "strain", "maxHeartRate", "calories"])
    }

    func testAVeryShortWorkoutWithNothingRecordedIsJustItsTime() {
        let short = figures(row("Strength Training", seconds: 41, distance: nil, kcal: nil, avg: nil, peak: nil, strain: nil,
                                version: nil))
        XCTAssertEqual(short.focus.id, "time")
        XCTAssertEqual(short.focus.value.text, "0:41")
        XCTAssertTrue(short.rest.isEmpty, "a figure with no value is left out, never drawn as a dash")
    }

    func testAFigureWithNoValueIsLeftOutNotDrawnAsADash() {
        let noEnergy = figures(row(kcal: nil, peak: nil))
        XCTAssertFalse(ids(noEnergy).contains("calories"))
        XCTAssertFalse(ids(noEnergy).contains("maxHeartRate"))
        XCTAssertTrue(([noEnergy.focus] + noEnergy.rest).allSatisfy { !$0.value.isMissing })
    }

    // MARK: Colours and words

    func testHeartRateFiguresCarryTheZoneTheirReadingIsIn() {
        let run = figures(row(avg: 90, peak: 178))
        let average = run.rest.first { $0.id == "averageHeartRate" }
        let peak = run.rest.first { $0.id == "maxHeartRate" }
        XCTAssertEqual(average?.zone, thresholds.zone(for: 90))
        XCTAssertEqual(peak?.zone, thresholds.zone(for: 178))
        XCTAssertNotEqual(average?.zone, peak?.zone)
        XCTAssertNil(run.rest.first { $0.id == "strain" }?.zone)
    }

    func testTheStrainNamesItsBandAndAnImportedOneNamesWhoop() {
        let noop = figures(row(strain: 52)).rest.first { $0.id == "strain" }
        XCTAssertEqual(noop?.value.micro, WorkoutHeroStrain.make(for: row(strain: 52), usualStored: nil).bandTitle)
        XCTAssertEqual(noop?.value.metric, .strain)
        let whoop = figures(row(strain: 52, version: nil, source: "whoop")).rest.first { $0.id == "strain" }
        XCTAssertEqual(whoop?.value.micro, String(localized: "WHOOP"))
        let manual = figures(row(strain: 52, version: nil, source: "manual"))
        XCTAssertFalse(ids(manual).contains("strain"), "a manual entry nobody scored has no strain")
    }

    func testSpokenValuesAreWordsNotTheDrawnAbbreviations() {
        let run = figures(row())
        XCTAssertEqual(run.focus.value.spoken, String(localized: "\("5.00") kilometers"))
        let peak = run.rest.first { $0.id == "maxHeartRate" }
        XCTAssertEqual(peak?.value.spoken, String(localized: "\(178) beats per minute"))
    }

    // MARK: The zone row

    func testTheZoneRowLightsTheZoneMostOfTheWorkoutWasSpentIn() {
        XCTAssertEqual(WorkoutSummary.dominantZone(of: [60, 1_500, 400]), 1)
        XCTAssertEqual(WorkoutSummary.dominantZone(of: [0, 0, 90]), 2)
        XCTAssertEqual(WorkoutSummary.dominantZone(of: [300, 300, 0]), 0, "the first of a tie")
        XCTAssertNil(WorkoutSummary.dominantZone(of: [0, 0, 0]), "no time in any zone lights none")
        XCTAssertNil(WorkoutSummary.dominantZone(of: []))
    }

    // MARK: The header

    func testTheStateLineSaysWhenTheWorkoutEnded() {
        let run = row(seconds: 600)
        let expected = AppClock.hourMinute(Date(timeIntervalSince1970: TimeInterval(start + 600)))
        XCTAssertEqual(WorkoutSummary.savedClock(for: run), expected)
    }
}
