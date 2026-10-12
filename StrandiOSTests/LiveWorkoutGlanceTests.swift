import XCTest
import StrandDesign
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

    func testARunLeadsWithDistanceThenTimePaceAndHeartRate() {
        let layout = G.layout(for: .routePace)
        XCTAssertEqual(layout.focus, .distance)
        XCTAssertEqual(layout.stack, [.time, .pace, .heartRate])
    }

    func testARideReadsAsSpeedNotPace() {
        let layout = G.layout(for: .routeSpeed)
        XCTAssertEqual(layout.focus, .distance)
        XCTAssertEqual(layout.stack, [.time, .speed, .heartRate])
        XCTAssertFalse(layout.stack.contains(.pace))
    }

    func testAnIndoorSessionLeadsWithTimeAndShowsHeartRateStrainAndTheAverage() {
        let layout = G.layout(for: .indoor)
        XCTAssertEqual(layout.focus, .time)
        XCTAssertEqual(layout.stack, [.heartRate, .strain, .averageHeartRate])
    }

    func testNoMetricAppearsTwiceInAnyLayout() {
        for sportClass in [G.SportClass.routePace, .routeSpeed, .indoor] {
            for chosen in [nil] + G.Metric.allCases.map(Optional.some) {
                let layout = G.layout(for: sportClass, chosenFocus: chosen)
                let shown = [layout.focus] + layout.stack
                XCTAssertEqual(Set(shown).count, shown.count, "\(sportClass) focus \(String(describing: chosen)): \(shown)")
                XCTAssertEqual(layout.stack.count, 3)
            }
        }
    }

    // MARK: The big-number choice

    func testAChosenStackMetricAndTheDefaultFocusSwapPlaces() {
        let layout = G.layout(for: .routePace, chosenFocus: .pace)
        XCTAssertEqual(layout.focus, .pace)
        XCTAssertEqual(layout.stack, [.time, .distance, .heartRate])
    }

    /// Strain and calories live on the Heart page, so a choice of one of them replaces the stack's figure that the Heart page
    /// repeats (the last of heart rate, strain, calories in the stack), and the old focus takes its place.
    func testAChosenHeartPageMetricDisplacesTheLastStackFigureTheHeartPageAlsoShows() {
        let indoor = G.layout(for: .indoor, chosenFocus: .calories)
        XCTAssertEqual(indoor.focus, .calories)
        XCTAssertEqual(indoor.stack, [.heartRate, .time, .averageHeartRate], "strain is the last figure the Heart page also shows")
        XCTAssertTrue(indoor.stack.contains(.time), "the old focus is still on the screen")
        let run = G.layout(for: .routePace, chosenFocus: .strain)
        XCTAssertEqual(run.focus, .strain)
        XCTAssertEqual(run.stack, [.time, .pace, .distance], "the heart rate is the one the Heart page repeats")
    }

    func testAChoiceThatIsNotOnTheScreenIsIgnoredRatherThanDroppingSomethingVisible() {
        // Speed is not part of a run's screen.
        XCTAssertEqual(G.layout(for: .routePace, chosenFocus: .speed), G.layout(for: .routePace))
        // The default focus chosen is the default.
        XCTAssertEqual(G.layout(for: .routePace, chosenFocus: .distance), G.layout(for: .routePace))
    }

    func testTheChoiceIsKeptPerKindOfSportAndOnlyOffersWhatTheScreensShow() {
        XCTAssertEqual(Set([G.SportClass.routePace, .routeSpeed, .indoor].map(G.FocusPreference.key(for:))).count, 3)
        XCTAssertEqual(G.FocusPreference.key(for: .routePace), "workoutFocus.routePace")
        XCTAssertEqual(G.FocusPreference.choices(for: .routePace), [.distance, .time, .pace, .heartRate, .strain, .calories])
        XCTAssertEqual(G.FocusPreference.choices(for: .indoor), [.time, .heartRate, .strain, .averageHeartRate, .calories])
        for sportClass in [G.SportClass.routePace, .routeSpeed, .indoor] {
            for metric in G.FocusPreference.choices(for: sportClass) {
                XCTAssertEqual(G.layout(for: sportClass, chosenFocus: metric).focus, metric,
                               "\(sportClass): every offered choice becomes the focus")
            }
        }
    }

    func testAStoredChoiceThatIsNotAMetricIsNoChoice() {
        XCTAssertEqual(G.FocusPreference.metric(from: "pace"), .pace)
        XCTAssertNil(G.FocusPreference.metric(from: ""))
        XCTAssertNil(G.FocusPreference.metric(from: "vo2max"))
    }

    // MARK: Values

    private func input(_ sport: String = "Running", route: Bool = true, meters: Double = 0, pace: Double? = nil,
                       bpm: Int? = nil, calories: Int? = nil, avg: Int = 0, imperial: Bool = false) -> LiveWorkoutTiles.Input {
        .init(sport: sport, tracksRoute: route, distanceMeters: meters, paceSecPerKm: pace, bpm: bpm, calories: calories,
              averageHR: avg, peakHR: 0, imperial: imperial)
    }

    private func value(_ metric: G.Metric, _ input: LiveWorkoutTiles.Input, elapsed: TimeInterval = 2_052,
                       strain: LiveStrainState = .scored(storedValue: 8.4), zoneWord: String? = nil) -> G.Value {
        G.value(metric, input: input, elapsed: elapsed, strain: strain, zoneWord: zoneWord, locale: locale)
    }

    func testRunValuesReadLikeTheTilesDid() {
        let run = input(meters: 5_490, pace: 373, bpm: 149, calories: 471, avg: 140)
        XCTAssertEqual(value(.distance, run).text, "5.49")
        XCTAssertEqual(value(.distance, run).unit, [String(localized: "km")])
        XCTAssertEqual(value(.pace, run).text, "6′13″", "the pace is drawn in minutes and seconds marks")
        XCTAssertEqual(value(.pace, run).unit, [String(localized: "Avg"), String(localized: "/km")])
        XCTAssertEqual(value(.time, run, elapsed: 2_052).text, "34:12")
        XCTAssertEqual(value(.time, run).unit, [])
        XCTAssertEqual(value(.heartRate, run).text, "149")
        XCTAssertEqual(value(.averageHeartRate, run).text, "140")
        XCTAssertEqual(value(.calories, run).text, "471")
        XCTAssertEqual(value(.calories, run).unit, [String(localized: "kcal")])
    }

    func testTheHeartRateUnitBlockLeadsWithTheZoneWord() {
        let run = input(bpm: 158)
        XCTAssertEqual(value(.heartRate, run, zoneWord: "Push").unit, ["Push", String(localized: "bpm")])
        XCTAssertEqual(value(.heartRate, run).unit, [String(localized: "bpm")])
        XCTAssertEqual(value(.averageHeartRate, input(avg: 140)).unit, [String(localized: "Avg"), String(localized: "bpm")])
    }

    func testARideShowsAverageSpeedWithItsUnit() {
        let ride = input("Cycling", meters: 20_000, pace: 144)
        XCTAssertEqual(value(.speed, ride).text, "25.0")
        XCTAssertEqual(value(.speed, ride).unit, [String(localized: "Avg"), String(localized: "km/h")])
    }

    func testImperialUnitsFollowThePreferenceOnEveryMetricThatHasOne() {
        let run = input(meters: 8_047, pace: 373, imperial: true)
        XCTAssertEqual(value(.distance, run).unit, [String(localized: "mi")])
        XCTAssertEqual(value(.pace, run).unit.last, String(localized: "/mi"))
        let ride = input("Cycling", meters: 20_000, pace: 144, imperial: true)
        XCTAssertEqual(value(.speed, ride).unit.last, String(localized: "mph"))
    }

    /// Whatever metric is chosen as the focus keeps its own unit block (a distance moved into the stack is still "KM").
    func testEveryMetricCarriesItsUnitWhereverItIsShown() {
        let all = input(meters: 5_490, pace: 373, bpm: 149, calories: 471, avg: 140)
        for metric in G.Metric.allCases where metric != .time {
            XCTAssertFalse(value(metric, all, zoneWord: nil).unit.isEmpty, "\(metric)")
        }
    }

    func testAnUnknownNumberIsADashNeverZero() {
        let nothing = input()
        for metric in [G.Metric.distance, .pace, .heartRate, .averageHeartRate, .calories] {
            let v = value(metric, nothing)
            XCTAssertTrue(v.isMissing, "\(metric) reads \(v.text)")
            XCTAssertEqual(v.text, LiveWorkoutTiles.missing)
            XCTAssertEqual(v.spoken, String(localized: "No reading"), "VoiceOver does not read a dash, or a unit after one")
        }
    }

    func testPaceIsDrawnWithMarksAndAMissingOneStaysADash() {
        XCTAssertEqual(G.paceDisplay("6:13"), "6′13″")
        XCTAssertEqual(G.paceDisplay("10:05"), "10′05″")
        XCTAssertEqual(G.paceDisplay(LiveWorkoutTiles.missing), LiveWorkoutTiles.missing)
    }

    func testEveryMetricHasOneColourAndHeartRateFollowsItsZone() {
        XCTAssertEqual(G.color(of: .time, zone: nil), LivePalette.time)
        XCTAssertEqual(G.color(of: .distance, zone: nil), LivePalette.distance)
        XCTAssertEqual(G.color(of: .pace, zone: nil), G.color(of: .speed, zone: nil))
        XCTAssertEqual(G.color(of: .strain, zone: nil), LivePalette.strain)
        XCTAssertEqual(G.color(of: .calories, zone: nil), LivePalette.calories)
        for zone in 0...2 {
            XCTAssertEqual(G.color(of: .heartRate, zone: zone), LivePalette.zone(zone))
            XCTAssertEqual(G.color(of: .averageHeartRate, zone: zone), LivePalette.zone(zone))
        }
        XCTAssertEqual(G.color(of: .heartRate, zone: nil), LivePalette.missing, "no reading, no zone, no colour")
    }

    /// A white figure's unit is the quiet grey; every coloured figure's unit wears the figure's colour.
    func testOnlyTheWhiteFiguresHaveAGreyUnit() {
        for metric in [G.Metric.distance, .pace, .speed] { XCTAssertEqual(G.unitColor(of: metric), LivePalette.secondaryText) }
        for metric in [G.Metric.time, .heartRate, .averageHeartRate, .strain, .calories] { XCTAssertNil(G.unitColor(of: metric), "\(metric)") }
    }

    /// What VoiceOver says for a number goes through the String Catalog: the unit is a word in the wearer's language, not the
    /// drawn abbreviation ("km", "/km", "bpm") read out letter by letter.
    func testSpokenValuesUseLocalizedUnitsNotTheDrawnAbbreviations() {
        let run = input(meters: 5_490, pace: 373, bpm: 149, calories: 471, avg: 140)
        XCTAssertEqual(value(.distance, run).spoken, String(localized: "\("5.49") kilometers"))
        XCTAssertEqual(value(.pace, run).spoken, WorkoutFormat.spokenPace("6:13", system: .metric))
        XCTAssertEqual(value(.heartRate, run).spoken, String(localized: "\(149) beats per minute"))
        XCTAssertEqual(value(.averageHeartRate, run).spoken, String(localized: "\(140) beats per minute"))
        XCTAssertEqual(value(.calories, run).spoken, WorkoutFormat.spokenEnergy(471))
        let ride = input("Cycling", meters: 20_000, pace: 144)
        XCTAssertEqual(value(.speed, ride).spoken, String(localized: "\("25.0") kilometers per hour"))
        let imperial = input(meters: 8_047, pace: 373, imperial: true)
        XCTAssertEqual(value(.distance, imperial).spoken, String(localized: "\("5.00") miles"))
        for metric in [G.Metric.distance, .pace, .heartRate, .calories] {
            let spoken = value(metric, run).spoken
            XCTAssertFalse(spoken.contains("/km") || spoken.contains(" km") || spoken.contains("bpm") || spoken.contains("kcal"),
                           "\(metric) is spoken as \"\(spoken)\"")
            XCTAssertFalse(spoken.contains("′") || spoken.contains("″"), "the drawn pace marks are not spoken: \(spoken)")
        }
    }

    /// A source that has gone quiet says so to VoiceOver as it does on screen ("no signal"), and a number that is not known is
    /// never read as a dash.
    @MainActor func testAStaleNumberIsSpokenWithNoSignalAndAMissingOneAsNoReading() {
        let heart = value(.heartRate, input(bpm: 142))
        XCTAssertEqual(LiveWorkoutFigure.spoken(heart, state: .live), heart.spoken)
        XCTAssertEqual(LiveWorkoutFigure.spoken(heart, state: .stale), "\(heart.spoken), \(String(localized: "no signal"))")
        let none = value(.pace, input())
        XCTAssertEqual(LiveWorkoutFigure.spoken(none, state: .missing), String(localized: "No reading"))
        let building = value(.strain, input(), strain: .building(readings: 200, coverageSeconds: 240))
        XCTAssertEqual(LiveWorkoutFigure.spoken(building, state: .missing), String(localized: "scores in \("6:00")"),
                       "the name is the label; the value says when it will score, without repeating the name")
    }

    /// A figure's state: paused is frozen, a quiet source steps back, totals are never stale.
    @MainActor func testAFigureIsFrozenWhenPausedStaleWhenItsSourceIsQuietAndMissingWithoutANumber() {
        let run = input(meters: 5_000, pace: 373, bpm: 149, calories: 471, avg: 140)
        var quiet = LiveWorkoutSignals.Snapshot()
        quiet.heartRateIsStale = true
        quiet.gps = .lost
        let live = LiveWorkoutSignals.Snapshot()
        func state(_ metric: G.Metric, paused: Bool = false, _ signals: LiveWorkoutSignals.Snapshot) -> LiveNumeral.State {
            LiveWorkoutFigure.state(of: value(metric, run), isPaused: paused, signals: signals)
        }
        XCTAssertEqual(state(.heartRate, live), .live)
        XCTAssertEqual(state(.heartRate, quiet), .stale)
        XCTAssertEqual(state(.pace, quiet), .stale)
        XCTAssertEqual(state(.distance, quiet), .live, "a total is never stale")
        XCTAssertEqual(state(.calories, quiet), .live)
        for metric in [G.Metric.heartRate, .pace, .distance, .time] {
            XCTAssertEqual(state(metric, paused: true, quiet), .paused, "\(metric)")
        }
        XCTAssertEqual(LiveWorkoutFigure.state(of: value(.pace, input()), isPaused: true, signals: live), .missing)
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
        XCTAssertEqual(v.unit, [String(localized: "Strain")])
    }

    func testTheNameIsWhatTheMetricIsCalled() {
        XCTAssertEqual(value(.distance, input(meters: 1_000)).name, String(localized: "Distance"))
        XCTAssertEqual(value(.heartRate, input(bpm: 100)).name, String(localized: "Heart rate"))
        for metric in G.Metric.allCases { XCTAssertFalse(G.name(of: metric).isEmpty, "\(metric)") }
    }

    func testAveragePaceIsNamedAverageAndNeverJustPace() {
        XCTAssertEqual(value(.pace, input(meters: 1_000, pace: 360)).name, String(localized: "Avg pace"))
        XCTAssertEqual(value(.speed, input(meters: 1_000, pace: 360)).name, String(localized: "Avg speed"))
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
        let all = Notice.Inputs(hasDurabilityWarning: true, gpsGapIsRecent: true, heartRateIsStale: true, gps: .lost)
        XCTAssertEqual(Notice.pending(all), [.durability, .heartRate, .gpsLost, .gpsGap])
        XCTAssertEqual(Notice.gpsGap.tone, .neutral)
        XCTAssertEqual(Notice.durability.tone, .warning)
        XCTAssertTrue(Notice.gpsGap.hasLongExplanation)
        XCTAssertTrue(Notice.heartRate.hasLongExplanation)
    }

    func testEveryNoticeHasWordsForTheScreenAndForVoiceOver() {
        for notice in Notice.allCases {
            XCTAssertFalse(notice.spoken.isEmpty, "\(notice)")
        }
    }

    /// Tapping a pill opens its explanation: the model's own text for the two it keeps, a text here for the others, and an
    /// action only where there is something to do about it.
    func testEveryNoticeExplainsItselfAndOffersTheRightAction() {
        for notice in Notice.allCases {
            if notice == .durability || notice == .gpsGap {
                XCTAssertNil(notice.explanation, "\(notice): the model keeps this text")
            } else {
                XCTAssertFalse(notice.explanation?.isEmpty ?? true, "\(notice)")
            }
        }
        XCTAssertEqual(Notice.heartRate.action, .manageDevices)
        XCTAssertEqual(Notice.noStrap.action, .manageDevices)
        XCTAssertEqual(Notice.locationOff.action, .openSettings)
        for notice in [Notice.durability, .gpsLost, .gpsWeak, .gpsSearching, .gpsGap] {
            XCTAssertNil(notice.action, "\(notice)")
        }
    }

    // MARK: The restored-gap window

    /// The 30 seconds start when the wearer first has the workout in front of them, not when the app launched: a workout
    /// restored in the background must still say it once the screen is opened.
    func testTheGapNoticeWindowRunsFromWhenTheScreenOpenedNotFromLaunch() {
        let opened = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(Notice.gapWindowIsOpen(openedAt: opened, now: opened.addingTimeInterval(1)))
        XCTAssertTrue(Notice.gapWindowIsOpen(openedAt: opened, now: opened.addingTimeInterval(Notice.gpsGapNoticeSeconds - 1)))
        XCTAssertFalse(Notice.gapWindowIsOpen(openedAt: opened, now: opened.addingTimeInterval(Notice.gpsGapNoticeSeconds)))
        XCTAssertFalse(Notice.gapWindowIsOpen(openedAt: nil, now: opened), "nothing opened yet: nothing to say")
    }

    /// Reading or reaching a long message can take longer than six seconds under VoiceOver or Switch Control: it stays open.
    @MainActor func testAnOpenNoticeClosesByItselfOnlyWithoutAssistiveTechnology() {
        XCTAssertTrue(LiveNoticeSlot.closesByItself(voiceOver: false, switchControl: false))
        XCTAssertFalse(LiveNoticeSlot.closesByItself(voiceOver: true, switchControl: false))
        XCTAssertFalse(LiveNoticeSlot.closesByItself(voiceOver: false, switchControl: true))
        XCTAssertFalse(LiveNoticeSlot.closesByItself(voiceOver: true, switchControl: true))
    }
}
