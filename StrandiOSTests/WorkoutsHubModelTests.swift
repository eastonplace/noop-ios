import XCTest
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
}
