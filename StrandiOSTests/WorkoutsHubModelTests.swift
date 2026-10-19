import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

/// The rules the Workouts hub decides before anything is drawn: how a week adds up, which Strain a row shows, which
/// number leads a row and how its lines read.
final class WorkoutsHubModelTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        calendar.firstWeekday = 1   // Sunday
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// Friday 9 October 2026, midday: the week runs Sunday 4 to Saturday 10.
    private var now: Date { date(2026, 10, 9, 12) }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func row(
        at start: Date, minutes: Int = 30, sport: String = "Running", source: String = "manual",
        kcal: Double? = 200, avgHr: Int? = 140, strain: Double? = nil, version: Int? = nil, distanceM: Double? = nil
    ) -> WorkoutRow {
        let startTs = Int(start.timeIntervalSince1970)
        return WorkoutRow(startTs: startTs, endTs: startTs + minutes * 60, sport: sport, source: source,
                          durationS: Double(minutes * 60), energyKcal: kcal, avgHr: avgHr, maxHr: nil,
                          strain: strain, distanceM: distanceM, zonesJSON: nil, notes: nil, strainVersion: version)
    }

    // MARK: Week summary

    func testWeekIsTheCalendarWeekWithSevenDaysAndTodayMarked() {
        let week = WorkoutWeekSummary.make(rows: [], now: now, calendar: calendar)
        XCTAssertEqual(week.days.count, 7)
        XCTAssertEqual(week.days.first?.start, date(2026, 10, 4))
        XCTAssertEqual(week.days.last?.start, date(2026, 10, 10))
        XCTAssertEqual(week.days.filter(\.isToday).map(\.start), [date(2026, 10, 9)])
        XCTAssertEqual(week.days.filter(\.isFuture).map(\.start), [date(2026, 10, 10)])
        XCTAssertFalse(week.hasSessions)
        XCTAssertNil(week.averageStrainStored)
    }

    func testWeekAddsUpOnlyTheSessionsInsideIt() {
        let inside = row(at: date(2026, 10, 5, 7), minutes: 40, kcal: 300)
        let alsoInside = row(at: date(2026, 10, 9, 6), minutes: 20, kcal: 150)
        let lastWeek = row(at: date(2026, 10, 3, 23, 30), minutes: 60, kcal: 500)
        let nextWeek = row(at: date(2026, 10, 11, 0, 5), minutes: 60, kcal: 500)
        let week = WorkoutWeekSummary.make(rows: [lastWeek, inside, alsoInside, nextWeek], now: now, calendar: calendar)
        XCTAssertEqual(week.sessionCount, 2)
        XCTAssertEqual(week.activeSeconds, 3_600)
        XCTAssertEqual(week.energyKcal, 450)
        XCTAssertEqual(week.days[1].sessions, 1)   // Monday
        XCTAssertEqual(week.days[5].sessions, 1)   // Friday
        XCTAssertEqual(week.days.map(\.sessions).reduce(0, +), 2)
    }

    func testASessionBelongsToTheDayItBeganOn() {
        // Starts 11:30 PM Tuesday, runs into Wednesday.
        let late = row(at: date(2026, 10, 6, 23, 30), minutes: 90)
        let week = WorkoutWeekSummary.make(rows: [late], now: now, calendar: calendar)
        XCTAssertEqual(week.days[2].sessions, 1)   // Tuesday
        XCTAssertEqual(week.days[3].sessions, 0)   // Wednesday
    }

    func testAverageStrainCountsOnlyNoopsOwnScores() throws {
        let noopA = row(at: date(2026, 10, 5, 7), source: "manual", strain: 40, version: 2)
        let noopB = row(at: date(2026, 10, 6, 7), source: "my-whoop-noop", strain: 60, version: 2)
        // An imported WHOOP number is shown on its row, never averaged into a NOOP score.
        let whoop = row(at: date(2026, 10, 7, 7), source: "whoop", strain: 90, version: nil)
        let unscored = row(at: date(2026, 10, 8, 7), source: "manual", strain: 80, version: nil)
        let week = WorkoutWeekSummary.make(rows: [noopA, noopB, whoop, unscored], now: now, calendar: calendar)
        XCTAssertEqual(try XCTUnwrap(week.averageStrainStored), 50, accuracy: 0.0001)
        XCTAssertEqual(week.sessionCount, 4)
    }

    func testAWeekOfImportedWhoopSessionsHasNoAverage() {
        let whoop = row(at: date(2026, 10, 5, 7), source: "whoop", strain: 70, version: nil)
        let week = WorkoutWeekSummary.make(rows: [whoop], now: now, calendar: calendar)
        XCTAssertTrue(week.hasSessions)
        XCTAssertNil(week.averageStrainStored)
    }

    func testADayWithNoRecordedLengthDrawsNoBar() {
        let week = WorkoutWeekSummary.make(rows: [row(at: date(2026, 10, 5, 7), minutes: 0)], now: now, calendar: calendar)
        XCTAssertEqual(week.days[1].sessions, 1)
        XCTAssertFalse(week.days[1].hasWorkouts)
    }

    // MARK: Strain display

    func testStrainBadgeNamesWhoseNumberItIs() throws {
        let noop = row(at: date(2026, 10, 5, 7), source: "manual", strain: 50, version: 2)
        let whoop = row(at: date(2026, 10, 5, 8), source: "whoop", strain: 50, version: nil)
        XCTAssertEqual(WorkoutStrainBadge.make(for: noop), .noop("10.5"))
        XCTAssertEqual(WorkoutStrainBadge.make(for: whoop), .whoop("10.5"))
        XCTAssertTrue(try XCTUnwrap(WorkoutStrainBadge.make(for: whoop)).isWhoop)
    }

    func testStrainBadgeIsAbsentWhenNothingWasScored() {
        let manual = row(at: date(2026, 10, 5, 7), source: "manual", strain: 50, version: nil)
        let whoopNoStrain = row(at: date(2026, 10, 5, 8), source: "whoop", strain: nil, version: nil)
        XCTAssertNil(WorkoutStrainBadge.make(for: manual))
        XCTAssertNil(WorkoutStrainBadge.make(for: whoopNoStrain))
    }

    // MARK: Row presentation

    func testADistanceSessionLeadsWithDistanceAndDoesNotRepeatIt() {
        let run = row(at: date(2026, 10, 8, 18), minutes: 34, kcal: 402, avgHr: 157, distanceM: 5_800)
        let shown = WorkoutRowPresentation.make(
            run, unitSystem: .metric, when: .dayAndTime, detail: .full, includesSource: true, now: now, calendar: calendar)
        XCTAssertEqual(shown.primary, UnitFormatter.distanceFromMeters(5_800, system: .metric))
        XCTAssertEqual(shown.title, "Running")
        XCTAssertEqual(shown.lines.count, 2)
        // First line: when and where from. Second: what it came to, the distance not repeated.
        XCTAssertEqual(shown.lines[0].count, 3)
        XCTAssertTrue(shown.lines[1].contains(WorkoutFormat.unbreakable(WorkoutFormat.duration(34 * 60))))
        XCTAssertTrue(shown.lines[1].contains(WorkoutFormat.unbreakable(WorkoutFormat.energy(402))))
        XCTAssertFalse(shown.facts.contains(WorkoutFormat.unbreakable(shown.primary ?? "#")))
    }

    func testASessionWithNoDistanceLeadsWithItsLength() {
        let lift = row(at: date(2026, 10, 9, 7), minutes: 52, sport: "Strength Training", kcal: 338)
        let shown = WorkoutRowPresentation.make(lift, unitSystem: .metric, when: .day, detail: .compact, now: now, calendar: calendar)
        XCTAssertEqual(shown.primary, WorkoutFormat.duration(52 * 60))
        // Compact: one line, when and the one fact that says most. The length is the lead, so it is not repeated.
        XCTAssertEqual(shown.lines.count, 1)
        XCTAssertEqual(shown.lines[0].count, 2)
        XCTAssertEqual(shown.lines[0][1], WorkoutFormat.unbreakable(WorkoutFormat.energy(338)))
    }

    func testFactsNeverBreakAcrossLines() {
        let shown = WorkoutRowPresentation.make(
            row(at: date(2026, 10, 8, 18), kcal: 402, avgHr: 157), unitSystem: .metric,
            when: .dayAndTime, detail: .full, includesSource: true, now: now, calendar: calendar)
        for fact in shown.facts { XCTAssertFalse(fact.contains(" "), "\(fact) can break across lines") }
    }

    func testTheDayViewStartsItsRowsWithTheClock() {
        let shown = WorkoutRowPresentation.make(
            row(at: date(2026, 10, 9, 18)), unitSystem: .metric, when: .time, detail: .full, now: now, calendar: calendar)
        XCTAssertEqual(shown.lines[0], [WorkoutFormat.unbreakable(AppClock.hourMinute(date(2026, 10, 9, 18)))])
    }

    func testTheSpokenRowReadsEveryFactTitleFirst() {
        let strained = row(at: date(2026, 10, 9, 7), source: "manual", strain: 50, version: 2)
        let shown = WorkoutRowPresentation.make(strained, unitSystem: .metric, when: .day, detail: .compact, now: now, calendar: calendar)
        XCTAssertTrue(shown.accessibilityLabel.hasPrefix("Running, "))
        XCTAssertTrue(shown.accessibilityLabel.contains("10.5"))
    }

    func testARowWithNothingToLeadWithHasNoPrimary() {
        let bare = WorkoutRow(startTs: 1_000, endTs: 1_000, sport: "Yoga", source: "manual", durationS: nil,
                              energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                              zonesJSON: nil, notes: nil, strainVersion: nil)
        XCTAssertNil(WorkoutFacts.lead(for: bare))
        XCTAssertNil(WorkoutFacts.activeSeconds(bare))
    }

    // MARK: Days

    func testDayKindIsRelativeToTheCalendarDayNotTwentyFourHours() {
        let lateLastNight = date(2026, 10, 8, 23, 59)
        let earlyThisMorning = date(2026, 10, 9, 0, 1)
        XCTAssertEqual(WorkoutFormat.dayKind(of: lateLastNight, now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(WorkoutFormat.dayKind(of: earlyThisMorning, now: now, calendar: calendar), .today)
        XCTAssertEqual(WorkoutFormat.dayKind(of: date(2026, 10, 6, 12), now: now, calendar: calendar), .other)
    }

    // MARK: Row trace

    func testATraceIsAveragedDownToTheWidthItIsDrawnAt() throws {
        let values = (0..<120).map(Double.init)
        let drawn = WorkoutTrace.downsampled(values, to: 26)
        XCTAssertEqual(drawn.count, 26)
        XCTAssertEqual(drawn.reduce(0, +) / Double(drawn.count), values.reduce(0, +) / Double(values.count), accuracy: 2)
        XCTAssertEqual(drawn, drawn.sorted(), "a rising trace stays rising")
        XCTAssertLessThan(try XCTUnwrap(drawn.first), try XCTUnwrap(drawn.last))
    }

    func testAShortOrEmptyTraceIsLeftAlone() {
        XCTAssertEqual(WorkoutTrace.downsampled([], to: 26), [])
        XCTAssertEqual(WorkoutTrace.downsampled([100, 120, 110], to: 26), [100, 120, 110])
        XCTAssertEqual(WorkoutTrace.downsampled([1, 2, 3], to: 0), [1, 2, 3])
    }

    func testAnOscillationTooFastForTheWidthFlattensOut() {
        // A set every four samples, drawn at one point per eight: each point holds two whole sets, so it sits at the
        // mean instead of zig-zagging.
        let sets = (0..<96).map { Double($0 % 4 < 2 ? 100 : 140) }
        let drawn = WorkoutTrace.downsampled(sets, to: 12)
        XCTAssertEqual(drawn.count, 12)
        XCTAssertTrue(drawn.allSatisfy { abs($0 - 120) < 0.001 })
    }

    // MARK: Pace

    func testPaceIsPerKilometreOrMileAndRefusesAnImplausibleOne() {
        let run = row(at: date(2026, 10, 8, 18), minutes: 30, distanceM: 5_000)
        XCTAssertEqual(WorkoutPace.perUnit(run, system: .metric), "6:00")
        XCTAssertNotNil(WorkoutPace.perUnit(run, system: .imperial))
        XCTAssertNil(WorkoutPace.perUnit(row(at: date(2026, 10, 8, 18), distanceM: nil), system: .metric))
        XCTAssertNil(WorkoutPace.perUnit(row(at: date(2026, 10, 8, 18), minutes: 600, distanceM: 100), system: .metric))
    }

    func testPaceIsOnlyForSportsPeoplePaceOnFoot() {
        let when = date(2026, 10, 8, 18)
        for onFoot in ["Running", "Walking", "Hiking", "Treadmill run", "Treadmill walk"] {
            XCTAssertEqual(WorkoutPace.perUnit(row(at: when, sport: onFoot, distanceM: 5_000), system: .metric), "6:00", onFoot)
        }
        // A ride is read in speed and a swim or a row per 100 m or 500 m: a per-kilometre pace would mislead.
        for other in ["Cycling", "Open-water swim", "Rowing", "Skiing", "Yoga"] {
            XCTAssertNil(WorkoutPace.perUnit(row(at: when, sport: other, distanceM: 5_000), system: .metric), other)
        }
    }

    func testARideRowDoesNotCarryAPaceFact() {
        let ride = row(at: date(2026, 10, 8, 18), minutes: 60, sport: "Cycling", kcal: 600, avgHr: 130, distanceM: 28_000)
        let shown = WorkoutRowPresentation.make(ride, unitSystem: .metric, when: .day, detail: .full, now: now, calendar: calendar)
        XCTAssertFalse(shown.lines.flatMap { $0 }.contains { $0.contains("/km") })
        let run = row(at: date(2026, 10, 8, 18), minutes: 30, sport: "Running", kcal: 300, avgHr: 150, distanceM: 5_000)
        let runShown = WorkoutRowPresentation.make(run, unitSystem: .metric, when: .day, detail: .full, now: now, calendar: calendar)
        XCTAssertTrue(runShown.lines.flatMap { $0 }.contains { $0.contains("/km") })
    }

    // MARK: Review fixes

    func testAWeekStaysOnMidnightsWhenADaylightSavingGapSwallowsOne() {
        // Chile puts its clocks forward at midnight, so Sunday 6 September 2026 has no 00:00 (it starts at 01:00).
        var chile = Calendar(identifier: .gregorian)
        chile.timeZone = TimeZone(identifier: "America/Santiago")!
        chile.firstWeekday = 1   // Sunday
        chile.locale = Locale(identifier: "en_US")
        let wednesday = chile.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 12))!
        let week = WorkoutWeekSummary.make(rows: [], now: wednesday, calendar: chile)
        XCTAssertEqual(week.days.map { chile.component(.day, from: $0.start) }, [6, 7, 8, 9, 10, 11, 12])
        for day in week.days {
            XCTAssertEqual(day.start, chile.startOfDay(for: day.start), "a day starts at its own midnight")
        }
        XCTAssertEqual(week.days.filter(\.isToday).map { chile.component(.day, from: $0.start) }, [9])
        // A workout in the first hour of Wednesday belongs to Wednesday, not to Tuesday.
        let earlyWednesday = chile.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 0, minute: 30))!
        let early = row(at: earlyWednesday, minutes: 20)
        let withRow = WorkoutWeekSummary.make(rows: [early], now: wednesday, calendar: chile)
        XCTAssertEqual(withRow.days[3].sessions, 1)
        XCTAssertEqual(withRow.days[2].sessions, 0)
    }

    func testAnOlderDateNamesItsYearAndThisYearsDoesNot() {
        let lastYear = WorkoutFormat.day(date(2025, 10, 6, 12), now: now, calendar: calendar)
        let thisYear = WorkoutFormat.day(date(2026, 10, 6, 12), now: now, calendar: calendar)
        XCTAssertTrue(lastYear.contains("2025"), lastYear)
        XCTAssertFalse(thisYear.contains("2026"), thisYear)
    }

    func testTheSpokenRowWritesDurationsPaceAndHeartRateOut() {
        let run = row(at: date(2026, 10, 8, 18), minutes: 45, sport: "Running", kcal: 400, avgHr: 150, distanceM: 8_000)
        let shown = WorkoutRowPresentation.make(run, unitSystem: .metric, when: .day, detail: .full, now: now, calendar: calendar)
        let spoken = shown.accessibilityLabel
        XCTAssertTrue(spoken.contains("45 minutes"), spoken)
        XCTAssertTrue(spoken.contains("per kilometer"), spoken)
        XCTAssertTrue(spoken.contains("150 beats per minute"), spoken)
        XCTAssertFalse(spoken.contains("45m"), "a narrow duration is read as metres")
        XCTAssertFalse(spoken.contains("/km"), "a unit slash is read letter by letter")
        // What is drawn stays short.
        XCTAssertTrue(shown.lines.flatMap { $0 }.contains(WorkoutFormat.unbreakable("45m")))
    }

    func testAWeekOfSessionsWithoutALengthIsNotAMinuteOfActivity() {
        let noLength = WorkoutRow(startTs: Int(date(2026, 10, 7, 9).timeIntervalSince1970),
                                  endTs: Int(date(2026, 10, 7, 9).timeIntervalSince1970), sport: "Yoga", source: "manual",
                                  durationS: nil, energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil, distanceM: nil,
                                  zonesJSON: nil, notes: nil, strainVersion: nil)
        let week = WorkoutWeekSummary.make(rows: [noLength], now: now, calendar: calendar)
        XCTAssertEqual(week.sessionCount, 1)
        XCTAssertEqual(week.activeSeconds, 0)
        XCTAssertFalse(week.days[3].hasWorkouts)
        XCTAssertEqual(week.days[3].sessions, 1)
    }

    // MARK: Zone rows

    func testZoneRowsCarryTheBandInTheirOwnWordsAndAWrittenOutLabel() throws {
        let set = HRZones.zones(maxHR: 187)
        let zones = WorkoutZoneRows.zones(minutes: [1, 2, 3, 20, 0], zoneSet: set)
        XCTAssertEqual(zones.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(zones[3].range, "150–168 bpm")
        XCTAssertEqual(zones[4].range, "169+ bpm")
        let hard = try XCTUnwrap(zones[3].accessibilityLabel)
        XCTAssertTrue(hard.hasPrefix("Zone 4, Hard, 150 to 168 beats per minute, 20 minutes"), hard)
        XCTAssertFalse(hard.contains("20m"))
        let maximum = try XCTUnwrap(zones[4].accessibilityLabel)
        XCTAssertTrue(maximum.contains("169 or more beats per minute"), maximum)
        XCTAssertTrue(maximum.contains("no time"), maximum)
        // Without a zone set there is no band to name.
        XCTAssertNil(WorkoutZoneRows.zones(minutes: [1, 2, 3, 4, 5], zoneSet: nil)[0].range)
    }

    func testAZoneVisitedForUnderAMinuteIsNotReadAsNoTime() throws {
        // 22 seconds in zone 1: the row reads "<1m" beside its 1%, so it is spoken as a visit, not as none.
        let zones = WorkoutZoneRows.zones(minutes: [22.0 / 60, 0, 0, 30, 0], zoneSet: nil)
        let warmUp = try XCTUnwrap(zones[0].accessibilityLabel)
        XCTAssertTrue(warmUp.contains("less than a minute"), warmUp)
        XCTAssertFalse(warmUp.contains("no time"), warmUp)
        XCTAssertTrue(warmUp.contains("%"), warmUp)
        XCTAssertEqual(zones[0].seconds, 22, accuracy: 0.001)
        let unvisited = try XCTUnwrap(zones[1].accessibilityLabel)
        XCTAssertTrue(unvisited.contains("no time"), unvisited)
    }

    // MARK: Glance rows (the redesigned list)

    func testAGlanceRowIsOneLineAndStillSpeaksEveryFact() {
        let run = row(at: date(2026, 10, 8, 18), minutes: 45, sport: "Running", kcal: 400, avgHr: 150, distanceM: 8_000)
        let glance = WorkoutRowPresentation.make(
            run, unitSystem: .metric, when: .time, detail: .glance, includesSource: true, now: now, calendar: calendar)
        XCTAssertEqual(glance.lines.count, 1)
        XCTAssertTrue(glance.lines[0].contains(WorkoutFormat.unbreakable("45m")))
        // What the line leaves out is still read to VoiceOver.
        XCTAssertTrue(glance.accessibilityLabel.contains("150 beats per minute"), glance.accessibilityLabel)
        XCTAssertTrue(glance.accessibilityLabel.contains("per kilometer"), glance.accessibilityLabel)
    }

    func testOnlyAGlanceRowCarriesTheZoneBar() {
        let zoned = WorkoutRow(startTs: 1_000, endTs: 2_800, sport: "Running", source: "manual", durationS: 1_800,
                               energyKcal: 200, avgHr: 140, maxHr: nil, strain: nil, distanceM: nil,
                               zonesJSON: #"{"z1":10,"z2":40,"z3":30,"z4":15,"z5":5}"#, notes: nil, strainVersion: nil)
        XCTAssertNotNil(WorkoutRowPresentation.make(zoned, unitSystem: .metric, when: .time, detail: .glance).zones)
        XCTAssertNil(WorkoutRowPresentation.make(zoned, unitSystem: .metric, when: .time, detail: .full).zones)
        XCTAssertNil(WorkoutRowPresentation.make(row(at: date(2026, 10, 8, 18)), unitSystem: .metric, when: .time,
                                                 detail: .glance).zones)
    }

    func testZoneSharesAreFractionsOfTheSessionWithTheRemainderBelowZoneOne() throws {
        let shares = try XCTUnwrap(WorkoutZoneShares.make(zonesJSON: #"{"z1":10,"z2":40,"z3":30,"z4":15,"z5":0}"#))
        for (share, expected) in zip(shares.zones, [0.10, 0.40, 0.30, 0.15, 0.0]) {
            XCTAssertEqual(share, expected, accuracy: 0.0001)
        }
        XCTAssertEqual(shares.belowZone1, 0.05, accuracy: 0.0001)
        // An empty zone and a sliver draw nothing.
        XCTAssertEqual(shares.segments.map(\.zone), [0, 1, 2, 3, 4])
        let sliver = try XCTUnwrap(WorkoutZoneShares.make(zonesJSON: #"{"z1":0.5,"z2":99.5}"#))
        XCTAssertEqual(sliver.segments.map(\.zone), [2])
    }

    func testAZoneSplitAddingToMoreThanTheSessionIsScaledBack() throws {
        let shares = try XCTUnwrap(WorkoutZoneShares.make(zonesJSON: #"{"z1":50,"z2":50,"z3":50,"z4":0,"z5":0}"#))
        XCTAssertEqual(shares.zones.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(shares.belowZone1, 0, accuracy: 0.0001)
        XCTAssertNil(WorkoutZoneShares.make(zonesJSON: nil))
        XCTAssertNil(WorkoutZoneShares.make(zonesJSON: "not json"))
    }

    func testWeekStatsAddUpSessionsEnergyAndTheAverageOfScoredStrain() throws {
        let hard = row(at: date(2026, 10, 5, 7), kcal: 300, strain: 60, version: 2)
        let easy = row(at: date(2026, 10, 6, 7), kcal: 100, strain: 20, version: 2)
        let unscored = row(at: date(2026, 10, 7, 7), kcal: nil, strain: nil)
        let stats = WorkoutWeekStats.make(rows: [hard, easy, unscored])
        XCTAssertEqual(stats.sessions, 3)
        XCTAssertEqual(stats.energyKcal, 400)
        XCTAssertEqual(try XCTUnwrap(stats.averageStrainStored), 40, accuracy: 0.0001)
        XCTAssertNil(WorkoutWeekStats.make(rows: [unscored]).averageStrainStored)
    }
}

