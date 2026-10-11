import XCTest
import StrandDesign
import WhoopStore
@testable import NOOP

/// What the workout summary decides before anything is drawn: whose strain the hero shows, which numbers the tiles
/// carry, what the heart-rate curve spans, where a touch lands on it and when an average has been edited.
final class WorkoutDetailModelTests: XCTestCase {
    private let start = 1_800_000_000

    private func row(
        sport: String = "Running", source: String = "manual", minutes: Int = 34, kcal: Double? = 402, avgHr: Int? = 157,
        maxHr: Int? = 176, strain: Double? = nil, version: Int? = nil, distanceM: Double? = nil, zonesJSON: String? = nil
    ) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport, source: source,
                   durationS: Double(minutes * 60), energyKcal: kcal, avgHr: avgHr, maxHr: maxHr, strain: strain,
                   distanceM: distanceM, zonesJSON: zonesJSON, notes: nil, strainVersion: version)
    }

    // MARK: Hero

    func testASessionNoopScoredIsNoopsWithItsDifferenceFromTheUsual() throws {
        let scored = row(source: "strap", strain: 61.9, version: 2)
        guard case .noop(let display, let delta) = WorkoutHeroStrain.make(for: scored, usualStored: 50) else {
            return XCTFail("a canonical score is NOOP's")
        }
        XCTAssertEqual(display, 61.9 * 21 / 100, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(delta), (61.9 - 50) * 21 / 100, accuracy: 0.001)
        XCTAssertEqual(WorkoutHeroStrain.make(for: scored, usualStored: 50).bandTitle, StrainBand.moderate.title)
    }

    func testWithNothingToCompareAgainstThereIsNoDifference() {
        guard case .noop(_, let delta) = WorkoutHeroStrain.make(for: row(strain: 40, version: 2), usualStored: nil) else {
            return XCTFail("expected a NOOP score")
        }
        XCTAssertNil(delta)
    }

    func testAnImportedWhoopNumberIsWhoopsAndIsNeverCompared() {
        let imported = row(source: "whoop", strain: 69.5, version: nil)
        guard case .whoop(let display) = WorkoutHeroStrain.make(for: imported, usualStored: 10) else {
            return XCTFail("an imported WHOOP score is WHOOP's")
        }
        XCTAssertEqual(display, 69.5 * 21 / 100, accuracy: 0.001)
        XCTAssertEqual(WorkoutHeroStrain.make(for: imported, usualStored: 10).bandTitle, StrainBand.high.title)
    }

    func testNoopsOwnScoreWinsOnAWhoopSourcedRow() {
        guard case .noop = WorkoutHeroStrain.make(for: row(source: "whoop", strain: 50, version: 2), usualStored: nil) else {
            return XCTFail("a canonical score takes precedence over the source")
        }
    }

    func testASessionNobodyScoredIsNotScored() {
        for unscored in [row(source: "manual", strain: nil), row(source: "manual", strain: 40, version: nil),
                         row(source: "apple", strain: 40, version: nil), row(source: "whoop", strain: nil)] {
            XCTAssertEqual(WorkoutHeroStrain.make(for: unscored, usualStored: 30), .unscored)
        }
        XCTAssertNil(WorkoutHeroStrain.unscored.bandTitle)
    }

    // MARK: Tiles

    func testARunReadsDistanceTimePaceHeartAndEnergy() {
        let tiles = WorkoutDetailTiles.make(for: row(distanceM: 5_800), unitSystem: .metric)
        XCTAssertEqual(tiles.map(\.kind), [.distance, .time, .pace, .averageHR, .maxHR, .calories])
        XCTAssertEqual(tiles.first { $0.kind == .distance }?.value, "5.8 km")
        XCTAssertEqual(tiles.first { $0.kind == .time }?.value, WorkoutFormat.duration(34 * 60))
        XCTAssertEqual(tiles.first { $0.kind == .pace }?.value, "5:52 /km")
        XCTAssertEqual(tiles.first { $0.kind == .averageHR }?.value, String(localized: "\(157) bpm"))
    }

    func testARideIsReadInSpeedNotPace() throws {
        let tiles = WorkoutDetailTiles.make(for: row(sport: "Cycling", minutes: 67, distanceM: 28_400), unitSystem: .metric)
        XCTAssertEqual(tiles.map(\.kind), [.distance, .time, .speed, .averageHR, .maxHR, .calories])
        XCTAssertTrue(try XCTUnwrap(tiles.first { $0.kind == .speed }).value.contains("25.4"))
    }

    func testASessionWithNoDistanceHasNoDistanceOrPaceAndMissingValuesReadAsADash() {
        let tiles = WorkoutDetailTiles.make(
            for: row(sport: "Yoga", kcal: nil, avgHr: nil, maxHr: nil), unitSystem: .metric)
        XCTAssertEqual(tiles.map(\.kind), [.time, .averageHR, .maxHR, .calories])
        XCTAssertEqual(tiles.filter { $0.value == "—" }.map(\.kind), [.averageHR, .maxHR, .calories])
    }

    func testImperialUnitsReachTheTiles() {
        let tiles = WorkoutDetailTiles.make(for: row(distanceM: 8_046.72), unitSystem: .imperial)
        XCTAssertEqual(tiles.first { $0.kind == .distance }?.value, "5.0 mi")
        XCTAssertTrue(tiles.first { $0.kind == .pace }?.value.hasSuffix("/mi") == true)
    }

    func testSpeedRefusesWhatIsNotAPlausibleSpeed() {
        XCTAssertNil(WorkoutSpeed.perHour(row(distanceM: nil), system: .metric))
        XCTAssertNil(WorkoutSpeed.perHour(row(minutes: 60, distanceM: 1_000_000), system: .metric))
        XCTAssertEqual(try XCTUnwrap(WorkoutSpeed.perHour(row(minutes: 60, distanceM: 20_000), system: .metric)), 20, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(WorkoutSpeed.perHour(row(minutes: 60, distanceM: 16_093.44), system: .imperial)), 10, accuracy: 0.001)
    }

    // MARK: Heart-rate series

    private func samples(_ bpms: [Double], every seconds: Double = 60) -> [WorkoutHeartRateSeries.Sample] {
        bpms.enumerated().map { .init(seconds: Double($0.offset) * seconds, bpm: $0.element) }
    }

    func testTooFewReadingsAreNotACurve() {
        XCTAssertNil(WorkoutHeartRateSeries(samples: [], duration: 600, recordedAverage: nil, recordedPeak: nil))
        XCTAssertNil(WorkoutHeartRateSeries(samples: samples([120]), duration: 600, recordedAverage: nil, recordedPeak: nil))
        XCTAssertNil(WorkoutHeartRateSeries(samples: samples([120, 130]), duration: 0, recordedAverage: nil, recordedPeak: nil))
    }

    func testTheSeriesUsesTheSessionsOwnFiguresAndFallsBackToItsReadings() throws {
        let readings = samples([100, 120, 140, 160])
        let own = try XCTUnwrap(WorkoutHeartRateSeries(samples: readings, duration: 180, recordedAverage: 131, recordedPeak: 171))
        XCTAssertEqual(own.average, 131)
        XCTAssertEqual(own.peak, 171, "a bucket mean never reaches the true peak, so the stored one is used")
        XCTAssertEqual(own.low, 100)
        let derived = try XCTUnwrap(WorkoutHeartRateSeries(samples: readings, duration: 180, recordedAverage: nil, recordedPeak: nil))
        XCTAssertEqual(derived.average, 130)
        XCTAssertEqual(derived.peak, 160)
        // A stored peak below what the readings reach cannot pull the rail under the line.
        let low = try XCTUnwrap(WorkoutHeartRateSeries(samples: readings, duration: 180, recordedAverage: nil, recordedPeak: 150))
        XCTAssertEqual(low.peak, 160)
    }

    func testTheAxisLeavesRoomAndNeverGoesBelowZero() throws {
        let series = try XCTUnwrap(WorkoutHeartRateSeries(samples: samples([100, 160]), duration: 60, recordedAverage: nil, recordedPeak: nil))
        XCTAssertEqual(series.axis, 92...168)
        let tiny = try XCTUnwrap(WorkoutHeartRateSeries(samples: samples([3, 9]), duration: 60, recordedAverage: nil, recordedPeak: nil))
        XCTAssertEqual(tiny.axis.lowerBound, 0)
        XCTAssertEqual(series.unit(forBPM: 92), 0)
        XCTAssertEqual(series.unit(forBPM: 168), 1)
        XCTAssertEqual(series.unit(forBPM: 500), 1, "a reading off the axis is clamped to it")
    }

    func testATouchLandsOnTheNearestReading() throws {
        let series = try XCTUnwrap(WorkoutHeartRateSeries(samples: samples([100, 110, 120, 130, 140]), duration: 240, recordedAverage: nil, recordedPeak: nil))
        XCTAssertEqual(series.index(atFraction: 0), 0)
        XCTAssertEqual(series.index(atFraction: 1), 4)
        XCTAssertEqual(series.index(atFraction: 0.5), 2)
        XCTAssertEqual(series.index(atFraction: 0.62), 2)
        XCTAssertEqual(series.index(atFraction: 0.7), 3)
        XCTAssertEqual(series.index(atFraction: -3), 0)
        XCTAssertEqual(series.index(atFraction: 9), 4)
    }

    func testAtMostFourTimeLabelsRunFromTheStartToTheEnd() throws {
        let series = try XCTUnwrap(WorkoutHeartRateSeries(samples: samples([100, 120, 140]), duration: 2_040, recordedAverage: nil, recordedPeak: nil))
        XCTAssertEqual(series.labelTimes(), [0, 680, 1_360, 2_040])
        XCTAssertEqual(series.labelTimes(count: 9).count, 4)
        XCTAssertEqual(series.labelTimes(count: 2), [0, 2_040])
    }

    func testUnorderedReadingsAreSortedAndBadOnesDropped() throws {
        let messy: [WorkoutHeartRateSeries.Sample] = [
            .init(seconds: 120, bpm: 140), .init(seconds: 0, bpm: 100), .init(seconds: 60, bpm: .nan), .init(seconds: 60, bpm: 120),
        ]
        let series = try XCTUnwrap(WorkoutHeartRateSeries(samples: messy, duration: 120, recordedAverage: nil, recordedPeak: nil))
        XCTAssertEqual(series.samples.map(\.bpm), [100, 120, 140])
    }

    // MARK: Elapsed time

    func testElapsedTimeReadsAsMinutesThenAsHours() {
        XCTAssertEqual(WorkoutElapsed.text(0), "0:00")
        XCTAssertEqual(WorkoutElapsed.text(349), "5:49")
        XCTAssertEqual(WorkoutElapsed.text(3_599), "59:59")
        XCTAssertEqual(WorkoutElapsed.text(3_600), "1:00:00")
        XCTAssertEqual(WorkoutElapsed.text(3_905), "1:05:05")
        XCTAssertEqual(WorkoutElapsed.text(-12), "0:00")
    }

    /// Spoken, "5:49" would be heard as a time of day, so the elapsed time is said in words.
    func testElapsedTimeIsSpokenInWordsNotAsAClockReading() {
        XCTAssertEqual(WorkoutElapsed.spoken(349), "5 minutes, 49 seconds")
        XCTAssertEqual(WorkoutElapsed.spoken(3_905), "1 hour, 5 minutes, 5 seconds")
        XCTAssertEqual(WorkoutElapsed.spoken(0), "0 seconds")
        XCTAssertEqual(WorkoutElapsed.spoken(-12), "0 seconds")
    }

    // MARK: Edited average

    func testAnAverageEditedAwayFromARecordingIsFlagged() {
        let recorded = row(avgHr: 150, strain: 50, version: 2)
        XCTAssertTrue(WorkoutDetailRules.averageWasEdited(recorded, traceMean: 160))
        XCTAssertFalse(WorkoutDetailRules.averageWasEdited(recorded, traceMean: 152), "rounding is not an edit")
        XCTAssertTrue(WorkoutDetailRules.averageWasEdited(row(avgHr: 150, zonesJSON: #"{"z1":50,"z2":50}"#), traceMean: 120))
    }

    func testNothingIsFlaggedWithoutARecordingBehindTheAverage() {
        XCTAssertFalse(WorkoutDetailRules.averageWasEdited(row(avgHr: 150), traceMean: 90),
                       "a manual entry has no captured strain or zones to disagree with")
        XCTAssertFalse(WorkoutDetailRules.averageWasEdited(row(avgHr: nil, strain: 50, version: 2), traceMean: 90))
    }
}
