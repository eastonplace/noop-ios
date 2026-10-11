import XCTest
@testable import NOOP

/// What the live workout screen shows in its tiles, and when it says a signal has gone quiet.
final class LiveWorkoutTilesTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    private func tiles(_ input: LiveWorkoutTiles.Input) -> [LiveWorkoutTiles.Tile] {
        LiveWorkoutTiles.tiles(for: input, locale: locale)
    }

    // MARK: Which tiles

    func testARunWithARouteLeadsWithDistanceAndPace() {
        let result = tiles(.init(sport: "Running", tracksRoute: true, distanceMeters: 5490, paceSecPerKm: 373,
                                 bpm: 149, calories: 471, averageHR: 140, peakHR: 167))
        XCTAssertEqual(result.map(\.kind), [.distance, .pace, .heartRate, .energy])
        XCTAssertEqual(result.map(\.value), ["5.49", "6:13", "149", "471"])
        XCTAssertEqual(result.map(\.unit), ["km", "/km", "bpm", "kcal"])
    }

    func testARideReadsAsSpeedNotPace() {
        let result = tiles(.init(sport: "Cycling", tracksRoute: true, distanceMeters: 20_000, paceSecPerKm: 144,
                                 bpm: 131, calories: 300))
        XCTAssertEqual(result.map(\.kind), [.distance, .speed, .heartRate, .energy])
        XCTAssertEqual(result[1].value, "25.0")
        XCTAssertEqual(result[1].unit, "km/h")
    }

    func testASessionWithoutARouteHasNoDistanceOrPaceTile() {
        let result = tiles(.init(sport: "Strength", tracksRoute: false, bpm: 151, calories: 210, averageHR: 146, peakHR: 167))
        XCTAssertEqual(result.map(\.kind), [.heartRate, .energy, .averageHeartRate, .peakHeartRate])
        XCTAssertFalse(result.contains { $0.kind == .distance || $0.kind == .pace || $0.kind == .speed })
        XCTAssertEqual(result.map(\.value), ["151", "210", "146", "167"])
    }

    // MARK: Never a fake zero

    func testAMissingNumberReadsAsADashWithNoUnit() {
        let route = tiles(.init(sport: "Running", tracksRoute: true))
        XCTAssertEqual(route.map(\.value), Array(repeating: LiveWorkoutTiles.missing, count: 4))
        XCTAssertTrue(route.allSatisfy { $0.isMissing && $0.unit == nil })

        let indoor = tiles(.init(sport: "Strength", tracksRoute: false))
        XCTAssertEqual(indoor.map(\.value), Array(repeating: LiveWorkoutTiles.missing, count: 4))
        XCTAssertTrue(indoor.allSatisfy { $0.unit == nil })
    }

    func testNoTileEverShowsZero() {
        let result = tiles(.init(sport: "Running", tracksRoute: true, distanceMeters: 0, paceSecPerKm: 0, bpm: 0,
                                 calories: 0, averageHR: 0, peakHR: 0))
        XCTAssertFalse(result.contains { $0.value == "0" || $0.value == "0.00" || $0.value == "0:00" })
        XCTAssertTrue(result.allSatisfy(\.isMissing))
    }

    func testAPaceSlowerThanAnHourPerKilometreIsAStandstillNotAPace() {
        XCTAssertEqual(LiveWorkoutTiles.paceText(secPerKm: 3600, imperial: false), LiveWorkoutTiles.missing)
        XCTAssertEqual(LiveWorkoutTiles.paceText(secPerKm: 3599, imperial: false), "59:59")
        XCTAssertEqual(LiveWorkoutTiles.paceText(secPerKm: nil, imperial: false), LiveWorkoutTiles.missing)
        XCTAssertEqual(LiveWorkoutTiles.paceText(secPerKm: .infinity, imperial: false), LiveWorkoutTiles.missing)
    }

    // MARK: Units

    func testImperialUnitsConvertDistancePaceAndSpeed() {
        let run = tiles(.init(sport: "Running", tracksRoute: true, distanceMeters: 1609.344, paceSecPerKm: 300, imperial: true))
        XCTAssertEqual(run[0].value, "1.00")
        XCTAssertEqual(run[0].unit, "mi")
        XCTAssertEqual(run[1].value, "8:03")   // 300 s/km = 482.8 s/mi
        XCTAssertEqual(run[1].unit, "/mi")

        let ride = tiles(.init(sport: "Cycling", tracksRoute: true, distanceMeters: 16_093.44, paceSecPerKm: 144, imperial: true))
        XCTAssertEqual(ride[1].value, "15.5")  // 25 km/h
        XCTAssertEqual(ride[1].unit, "mph")
    }

    func testDecimalSeparatorFollowsTheLocale() {
        let german = LiveWorkoutTiles.tiles(
            for: .init(sport: "Running", tracksRoute: true, distanceMeters: 5490, paceSecPerKm: 373),
            locale: Locale(identifier: "de_DE"))
        XCTAssertEqual(german[0].value, "5,49")
    }

    // MARK: Timer text

    func testElapsedTextAddsHoursOnlyOnceAnHourHasRun() {
        XCTAssertEqual(LiveWorkoutTiles.elapsedText(0), "0:00")
        XCTAssertEqual(LiveWorkoutTiles.elapsedText(2052), "34:12")
        XCTAssertEqual(LiveWorkoutTiles.elapsedText(3599.9), "59:59")
        XCTAssertEqual(LiveWorkoutTiles.elapsedText(3600), "1:00:00")
        XCTAssertEqual(LiveWorkoutTiles.elapsedText(5652), "1:34:12")
        XCTAssertEqual(LiveWorkoutTiles.elapsedText(-5), "0:00")
    }

    // MARK: Stale signals

    func testHeartRateGoesStaleAfterThePatienceAndNeverWhilePaused() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let last = start.addingTimeInterval(600)
        XCTAssertFalse(LiveWorkoutSignals.heartRateIsStale(
            lastReadingAt: last, workoutStart: start, isPaused: false, now: last.addingTimeInterval(14)))
        XCTAssertTrue(LiveWorkoutSignals.heartRateIsStale(
            lastReadingAt: last, workoutStart: start, isPaused: false, now: last.addingTimeInterval(16)))
        XCTAssertFalse(LiveWorkoutSignals.heartRateIsStale(
            lastReadingAt: last, workoutStart: start, isPaused: true, now: last.addingTimeInterval(600)),
            "a paused workout is not waiting for a reading")
    }

    func testAWorkoutThatNeverHeardFromTheStrapIsStaleFromItsStart() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(LiveWorkoutSignals.heartRateIsStale(
            lastReadingAt: nil, workoutStart: start, isPaused: false, now: start.addingTimeInterval(10)))
        XCTAssertTrue(LiveWorkoutSignals.heartRateIsStale(
            lastReadingAt: nil, workoutStart: start, isPaused: false, now: start.addingTimeInterval(20)))
    }

    func testNoticesNameOnlyWhatIsWrongAndPutHeartRateFirst() {
        XCTAssertEqual(LiveWorkoutSignals.notices(heartRateIsStale: false, gps: .ok), [])
        XCTAssertEqual(LiveWorkoutSignals.notices(heartRateIsStale: false, gps: nil), [])
        XCTAssertEqual(LiveWorkoutSignals.notices(heartRateIsStale: false, gps: .paused), [])
        XCTAssertEqual(LiveWorkoutSignals.notices(heartRateIsStale: false, gps: .notRecording), [])
        XCTAssertEqual(LiveWorkoutSignals.notices(heartRateIsStale: true, gps: nil), [.heartRate])
        XCTAssertEqual(LiveWorkoutSignals.notices(heartRateIsStale: false, gps: .searching), [.gpsSearching])
        XCTAssertEqual(LiveWorkoutSignals.notices(heartRateIsStale: false, gps: .weak), [.gpsWeak])
        XCTAssertEqual(LiveWorkoutSignals.notices(heartRateIsStale: true, gps: .lost), [.heartRate, .gpsLost])
    }

    // MARK: A stale number is never drawn as live

    func testAHeartRateThatWentQuietDimsTheHeartRateTileAndOnlyThat() {
        let quiet = LiveWorkoutSignals.Snapshot(heartRateIsStale: true, gps: .ok)
        XCTAssertTrue(LiveWorkoutTiles.isStale(.heartRate, signals: quiet))
        for kind in [LiveWorkoutTiles.Kind.distance, .pace, .speed, .energy, .averageHeartRate, .peakHeartRate] {
            XCTAssertFalse(LiveWorkoutTiles.isStale(kind, signals: quiet), "\(kind) does not come from the strap's live reading")
        }
    }

    func testALostGpsSignalDimsPaceAndSpeedNotDistanceOrTheHeartTile() {
        let lost = LiveWorkoutSignals.Snapshot(heartRateIsStale: false, gps: .lost)
        XCTAssertTrue(LiveWorkoutTiles.isStale(.pace, signals: lost))
        XCTAssertTrue(LiveWorkoutTiles.isStale(.speed, signals: lost))
        XCTAssertFalse(LiveWorkoutTiles.isStale(.distance, signals: lost), "the distance so far is still what was covered")
        XCTAssertFalse(LiveWorkoutTiles.isStale(.heartRate, signals: lost))
    }

    func testAHealthyOrUntrackedWorkoutDimsNothing() {
        for gps in [nil, GpsWorkoutRecorder.SignalState.ok, .paused, .searching, .weak, .notRecording] {
            let live = LiveWorkoutSignals.Snapshot(heartRateIsStale: false, gps: gps)
            for kind in [LiveWorkoutTiles.Kind.distance, .pace, .speed, .heartRate, .energy, .averageHeartRate, .peakHeartRate] {
                XCTAssertFalse(LiveWorkoutTiles.isStale(kind, signals: live), "\(kind) with gps \(String(describing: gps))")
            }
        }
    }

    func testTheSpokenTimerIsWholeWordsFromTheTimeThatRan() {
        XCTAssertEqual(LiveWorkoutTiles.spokenElapsed(0), "0 seconds")
        XCTAssertEqual(LiveWorkoutTiles.spokenElapsed(34 * 60 + 12), "34 minutes, 12 seconds")
        XCTAssertEqual(LiveWorkoutTiles.spokenElapsed(3_600 + 5 * 60 + 9), "1 hour, 5 minutes, 9 seconds")
    }
}
