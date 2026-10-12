import XCTest
@testable import NOOP

/// What the glance-first live screen puts where, from plain values.
final class LiveWorkoutGlanceTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private typealias G = LiveWorkoutGlance

    // MARK: Sport class

    func testARouteSportWithARouteIsPaceOrSpeedByTheSport() {
        XCTAssertEqual(G.sportClass(sport: "Running", tracksRoute: true), .routePace)
        XCTAssertEqual(G.sportClass(sport: "Walking", tracksRoute: true), .routePace)
        XCTAssertEqual(G.sportClass(sport: "Cycling", tracksRoute: true), .routeSpeed)
    }

    func testWithoutARouteEverySportIsIndoor() {
        for sport in ["Running", "Cycling", "Strength Training", "Yoga"] {
            XCTAssertEqual(G.sportClass(sport: sport, tracksRoute: false), .indoor, sport)
        }
    }

    // MARK: Layouts

    func testARunLeadsWithDistanceThenTimeAndPace() {
        let layout = G.layout(for: .routePace)
        XCTAssertEqual(layout.focus, .distance)
        XCTAssertEqual(layout.secondaries, [.time, .pace])
        XCTAssertEqual(layout.footer, [.strain, .calories])
        XCTAssertTrue(layout.zoneLineShowsBPM)
    }

    func testARideReadsAsSpeedNotPace() {
        let layout = G.layout(for: .routeSpeed)
        XCTAssertEqual(layout.focus, .distance)
        XCTAssertEqual(layout.secondaries, [.time, .speed])
        XCTAssertFalse(layout.secondaries.contains(.pace))
    }

    func testAnIndoorSessionLeadsWithTimeAndShowsTheHeartRateOnce() {
        let layout = G.layout(for: .indoor)
        XCTAssertEqual(layout.focus, .time)
        XCTAssertEqual(layout.secondaries, [.heartRate, .strain])
        XCTAssertEqual(layout.footer, [.calories, .averageHeartRate])
        XCTAssertFalse(layout.zoneLineShowsBPM, "the heart rate is already a secondary: it is not drawn again in the zone line")
    }

    func testNoMetricAppearsTwiceInAnyLayout() {
        for sportClass in [G.SportClass.routePace, .routeSpeed, .indoor] {
            for chosen in [nil] + G.Metric.allCases.map(Optional.some) {
                let layout = G.layout(for: sportClass, chosenFocus: chosen)
                let shown = [layout.focus] + layout.secondaries + layout.footer
                XCTAssertEqual(Set(shown).count, shown.count, "\(sportClass) focus \(String(describing: chosen)): \(shown)")
            }
        }
    }

    // MARK: The big-number choice

    func testAChosenSecondaryAndTheDefaultFocusSwapPlaces() {
        let layout = G.layout(for: .routePace, chosenFocus: .pace)
        XCTAssertEqual(layout.focus, .pace)
        XCTAssertEqual(layout.secondaries, [.time, .distance])
    }

    func testAChosenFooterMetricAndTheDefaultFocusSwapPlaces() {
        let layout = G.layout(for: .indoor, chosenFocus: .calories)
        XCTAssertEqual(layout.focus, .calories)
        XCTAssertEqual(layout.footer, [.time, .averageHeartRate])
    }

    func testAChoiceThatIsNotOnTheScreenIsIgnoredRatherThanDroppingSomethingVisible() {
        // Speed is not part of a run's screen.
        XCTAssertEqual(G.layout(for: .routePace, chosenFocus: .speed), G.layout(for: .routePace))
        // The default focus chosen is the default.
        XCTAssertEqual(G.layout(for: .routePace, chosenFocus: .distance), G.layout(for: .routePace))
    }

    // MARK: Values

    private func input(_ sport: String = "Running", route: Bool = true, meters: Double = 0, pace: Double? = nil,
                       bpm: Int? = nil, calories: Int? = nil, avg: Int = 0, imperial: Bool = false) -> LiveWorkoutTiles.Input {
        .init(sport: sport, tracksRoute: route, distanceMeters: meters, paceSecPerKm: pace, bpm: bpm, calories: calories,
              averageHR: avg, peakHR: 0, imperial: imperial)
    }

    private func value(_ metric: G.Metric, _ input: LiveWorkoutTiles.Input, elapsed: TimeInterval = 2_052,
                       strain: LiveStrainState = .scored(storedValue: 8.4)) -> G.Value {
        G.value(metric, input: input, elapsed: elapsed, strain: strain, locale: locale)
    }

    func testRunValuesReadLikeTheTilesDid() {
        let run = input(meters: 5_490, pace: 373, bpm: 149, calories: 471, avg: 140)
        XCTAssertEqual(value(.distance, run).text, "5.49")
        XCTAssertEqual(value(.distance, run).eyebrow, "\(String(localized: "Distance")) · km")
        XCTAssertEqual(value(.pace, run).text, "6:13")
        XCTAssertEqual(value(.pace, run).eyebrow, "\(String(localized: "Avg pace")) · /km")
        XCTAssertEqual(value(.time, run, elapsed: 2_052).text, "34:12")
        XCTAssertEqual(value(.heartRate, run).text, "149")
        XCTAssertEqual(value(.averageHeartRate, run).text, "140")
        XCTAssertEqual(value(.calories, run).text, "471")
    }

    func testARideShowsAverageSpeedWithItsUnit() {
        let ride = input("Cycling", meters: 20_000, pace: 144)
        XCTAssertEqual(value(.speed, ride).text, "25.0")
        XCTAssertEqual(value(.speed, ride).eyebrow, "\(String(localized: "Avg speed")) · km/h")
    }

    func testImperialUnitsFollowThePreference() {
        let run = input(meters: 8_047, pace: 373, imperial: true)
        XCTAssertTrue(value(.distance, run).eyebrow.hasSuffix("· mi"))
        XCTAssertTrue(value(.pace, run).eyebrow.hasSuffix("· /mi"))
    }

    func testAnUnknownNumberIsADashNeverZero() {
        let nothing = input()
        for metric in [G.Metric.distance, .pace, .heartRate, .averageHeartRate, .calories] {
            let v = value(metric, nothing)
            XCTAssertTrue(v.isMissing, "\(metric) reads \(v.text)")
            XCTAssertEqual(v.text, LiveWorkoutTiles.missing)
            XCTAssertEqual(v.spoken, LiveWorkoutTiles.missing, "VoiceOver does not read a unit after a dash")
        }
    }

    func testBuildingStrainShowsADashAndTheTimeUntilItScores() {
        // 4 minutes of coverage of the 10 needed: 6:00 to go.
        let v = value(.strain, input(), strain: .building(readings: 200, coverageSeconds: 240))
        XCTAssertTrue(v.isMissing)
        XCTAssertEqual(v.micro, String(localized: "scores in \("6:00")"))
        // Past the threshold the countdown never goes negative.
        let past = value(.strain, input(), strain: .building(readings: 900, coverageSeconds: 700))
        XCTAssertEqual(past.micro, String(localized: "scores in \("0:00")"))
    }

    func testScoredStrainShowsTheNumberAndNoCaption() {
        let v = value(.strain, input(), strain: .scored(storedValue: 8.4))
        XCTAssertFalse(v.isMissing)
        XCTAssertNil(v.micro)
        XCTAssertEqual(v.name, String(localized: "Strain"))
    }

    func testTheNameIsTheEyebrowWithoutItsUnit() {
        XCTAssertEqual(value(.distance, input(meters: 1_000)).name, String(localized: "Distance"))
        XCTAssertEqual(value(.heartRate, input(bpm: 100)).name, String(localized: "Heart rate"))
    }

    func testAveragePaceIsLabelledAverageAndNeverJustPace() {
        // The tile is the session's average, so the label must say so.
        XCTAssertTrue(value(.pace, input(meters: 1_000, pace: 360)).eyebrow.hasPrefix(String(localized: "Avg pace")))
        XCTAssertTrue(value(.speed, input(meters: 1_000, pace: 360)).eyebrow.hasPrefix(String(localized: "Avg speed")))
    }
}

/// The reserved notice slot under the header: which notices apply, and in which order.
final class LiveWorkoutSlotNoticeTests: XCTestCase {
    private typealias Notice = LiveWorkoutSlotNotice

    func testNothingIsSaidWhenEverythingIsFine() {
        XCTAssertEqual(Notice.pending(.init()), [])
    }

    func testNoticesAreOrderedDurabilityHeartRateGpsStrapLocation() {
        let all = Notice.Inputs(hasDurabilityWarning: true, heartRateIsStale: true,
                                strapNeverConnected: false, gps: .lost, locationIsOff: true, isJustStarted: true)
        XCTAssertEqual(Notice.pending(all), [.durability, .heartRate, .gpsLost, .locationOff])
    }

    func testAStrapThatNeverConnectedReplacesNoHeartRateSignal() {
        let quiet = Notice.Inputs(heartRateIsStale: true, strapNeverConnected: true)
        XCTAssertEqual(Notice.pending(quiet), [.noStrap])
        XCTAssertFalse(Notice.pending(quiet).contains(.heartRate))
    }

    func testEachGpsStateHasItsOwnNoticeAndTheHealthyOnesHaveNone() {
        XCTAssertEqual(Notice.pending(.init(gps: .lost)), [.gpsLost])
        XCTAssertEqual(Notice.pending(.init(gps: .weak)), [.gpsWeak])
        XCTAssertEqual(Notice.pending(.init(gps: .searching)), [.gpsSearching])
        for fine in [GpsWorkoutRecorder.SignalState.ok, .paused, .notRecording] {
            XCTAssertEqual(Notice.pending(.init(gps: fine)), [], "\(fine)")
        }
        XCTAssertEqual(Notice.pending(.init(gps: nil)), [])
    }

    func testLocationIsOffIsSaidOnlyJustAfterTheStartThenTheHeaderGlyphCarriesIt() {
        XCTAssertEqual(Notice.pending(.init(locationIsOff: true, isJustStarted: true)), [.locationOff])
        XCTAssertEqual(Notice.pending(.init(locationIsOff: true, isJustStarted: false)), [])
        XCTAssertEqual(Notice.pending(.init(locationIsOff: false, isJustStarted: true)), [])
    }

    /// The slot is for warnings. "Paused" is the header's to say ("PAUSED · 3:11"); a pill for it would only sit beside the
    /// Minimize button and say it twice.
    func testAPausedWorkoutHasNoNoticeOfItsOwn() {
        XCTAssertEqual(Notice.pending(.init(gps: .paused)), [])
        XCTAssertFalse(Notice.allCases.map { "\($0)" }.contains("paused"))
    }

    /// A workout restored after the app was closed is good news with a gap in it. It is not "Not safely recoverable", it comes
    /// after every real warning, and it is only to be known, not to be worried about.
    func testARestoredGapIsItsOwnQuietNoticeBehindTheRealWarnings() {
        XCTAssertEqual(Notice.pending(.init(gpsGapIsRecent: true)), [.gpsGap])
        let all = Notice.Inputs(hasDurabilityWarning: true, heartRateIsStale: true, gps: .lost, gpsGapIsRecent: true)
        XCTAssertEqual(Notice.pending(all), [.durability, .heartRate, .gpsLost, .gpsGap])
        XCTAssertEqual(Notice.gpsGap.tone, .neutral)
        XCTAssertEqual(Notice.durability.tone, .warning)
        XCTAssertTrue(Notice.gpsGap.hasLongExplanation)
        XCTAssertFalse(Notice.heartRate.hasLongExplanation)
    }

    func testEveryNoticeHasWordsForTheScreenAndForVoiceOver() {
        for notice in Notice.allCases {
            XCTAssertFalse(notice.spoken.isEmpty, "\(notice)")
        }
    }
}
