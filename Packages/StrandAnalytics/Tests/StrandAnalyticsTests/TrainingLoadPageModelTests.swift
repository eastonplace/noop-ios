import Foundation
import XCTest
@testable import StrandAnalytics

final class TrainingLoadPageModelTests: XCTestCase {

    // MARK: Fixtures

    private func calendar(firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = firstWeekday
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ day: String, _ calendar: Calendar) -> Date {
        let p = day.split(separator: "-").map { Int($0)! }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))!
    }

    private func dayString(offset: Int, from start: String, _ calendar: Calendar) -> String {
        let d = calendar.date(byAdding: .day, value: offset, to: date(start, calendar))!
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Daily stored loads (nil = no observation) from `start`, run through the real engine, as the page would be fed.
    private func model(loads: [Double?], start: String = "2026-06-01", workouts: [TrainingLoadPageModel.Workout] = [],
                       calendar: Calendar? = nil) -> (TrainingLoadPageModel, TrainingLoadEngine.Result) {
        let cal = calendar ?? self.calendar()
        let input = loads.enumerated().map {
            TrainingLoadEngine.DailyLoad(day: dayString(offset: $0.offset, from: start, cal), load: $0.element)
        }
        let result = TrainingLoadEngine.evaluate(days: input)
        let days = result.points.map {
            TrainingLoadPageModel.Day(date: date($0.day, cal), acute: $0.acuteLoad, chronic: $0.chronicLoad, load: $0.load)
        }
        return (TrainingLoadPageModel(days: days, workouts: workouts, calendar: cal), result)
    }

    /// The page's own feed: the engine's modeled days plus every recorded day of the run, the six before the seed day
    /// included. Also returns the same model built from the modeled days alone, to show what the wider feed changes.
    private func pageModels(loads: [Double?], start: String, calendar cal: Calendar)
        -> (full: TrainingLoadPageModel, modeledOnly: TrainingLoadPageModel) {
        let input = loads.enumerated().map {
            TrainingLoadEngine.DailyLoad(day: dayString(offset: $0.offset, from: start, cal), load: $0.element)
        }
        let result = TrainingLoadEngine.evaluate(days: input)
        let days = result.points.map {
            TrainingLoadPageModel.Day(date: date($0.day, cal), acute: $0.acuteLoad, chronic: $0.chronicLoad, load: $0.load)
        }
        let recorded: [TrainingLoadPageModel.Recorded] = input.compactMap { item in
            guard let load = item.load, let first = result.startDay, item.day >= first else { return nil }
            return .init(date: date(item.day, cal), load: load)
        }
        return (TrainingLoadPageModel(days: days, workouts: [], calendar: cal, recorded: recorded),
                TrainingLoadPageModel(days: days, workouts: [], calendar: cal))
    }

    private func workout(_ day: String, hour: Int = 9, sport: String = "Running", strain: Double? = 50,
                         _ calendar: Calendar) -> TrainingLoadPageModel.Workout {
        let start = calendar.date(byAdding: .hour, value: hour, to: date(day, calendar))!
        return .init(start: start, sport: sport, strain: strain, durationSeconds: 3_600, energyKcal: 400)
    }

    // MARK: Ratio, bands, zones, gauge

    func testRatioGuardsABaseThatIsNearlyZero() {
        XCTAssertNil(TrainingLoadPageModel.ratio(acute: 5, chronic: 0))
        XCTAssertNil(TrainingLoadPageModel.ratio(acute: 5, chronic: 0.05))
        XCTAssertNil(TrainingLoadPageModel.ratio(acute: .nan, chronic: 40))
        XCTAssertEqual(TrainingLoadPageModel.ratio(acute: 48, chronic: 40)!, 1.2, accuracy: 1e-12)
    }

    func testHeadlineBandsCutAtTheDocumentedRatios() {
        let h = TrainingLoadPageModel.headline(forRatio:)
        XCTAssertEqual(h(0.50), .easing)
        XCTAssertEqual(h(0.79), .easing)
        XCTAssertEqual(h(0.80), .holding)
        XCTAssertEqual(h(0.99), .holding)
        XCTAssertEqual(h(1.00), .building)
        XCTAssertEqual(h(1.29), .building)
        XCTAssertEqual(h(1.30), .spiking)
        XCTAssertEqual(h(2.40), .spiking)
    }

    /// The band reads the ratio as it is printed (two decimals): a "1.30×" is never drawn under a sweet-spot headline.
    func testBandsReadThePrintedRatio() {
        XCTAssertEqual(TrainingLoadPageModel.headline(forRatio: 1.2996), .spiking)
        XCTAssertEqual(TrainingLoadPageModel.zone(forRatio: 1.2996), .spike)
        XCTAssertEqual(TrainingLoadPageModel.headline(forRatio: 0.9951), .building)
        XCTAssertEqual(TrainingLoadPageModel.zone(forRatio: 0.7951), .sweetSpot)
        XCTAssertEqual(TrainingLoadPageModel.zone(forRatio: 0.7949), .easing)
    }

    func testTomorrowZonesCutAtPointEightOnePointTwoFiveAndOnePointThree() {
        let z = TrainingLoadPageModel.zone(forRatio:)
        XCTAssertEqual(z(0.79), .easing)
        XCTAssertEqual(z(0.80), .sweetSpot)
        XCTAssertEqual(z(1.24), .sweetSpot)
        XCTAssertEqual(z(1.25), .nearSpike)
        XCTAssertEqual(z(1.29), .nearSpike)
        XCTAssertEqual(z(1.30), .spike)
    }

    func testGaugeFractionIsClampedToTheGauge() {
        let f = TrainingLoadPageModel.gaugeFraction(forRatio:)
        XCTAssertEqual(f(0.2), 0, accuracy: 1e-12)
        XCTAssertEqual(f(0.5), 0, accuracy: 1e-12)
        XCTAssertEqual(f(1.05), 0.5, accuracy: 1e-12)
        XCTAssertEqual(f(1.6), 1, accuracy: 1e-12)
        XCTAssertEqual(f(3.0), 1, accuracy: 1e-12)
    }

    func testPercentFromBaseIsSignedAndWhole() {
        XCTAssertEqual(TrainingLoadPageModel.percentFromBase(ratio: 1.204), 20)
        XCTAssertEqual(TrainingLoadPageModel.percentFromBase(ratio: 0.85), -15)
        XCTAssertEqual(TrainingLoadPageModel.percentFromBase(ratio: 1.003), 0)
    }

    // MARK: Display scale

    func testFiguresAreStoredValuesOnTheEffortScale() {
        let (m, result) = model(loads: Array(repeating: 50, count: 30) + Array(repeating: 100, count: 7))
        let last = result.points.last!
        XCTAssertEqual(m.recent!, last.acuteLoad * 0.21, accuracy: 1e-12)
        XCTAssertEqual(m.base!, last.chronicLoad * 0.21, accuracy: 1e-12)
        XCTAssertEqual(m.form!, (last.chronicLoad - last.acuteLoad) * 0.21, accuracy: 1e-12)
        XCTAssertEqual(m.ratio!, last.acuteLoad / last.chronicLoad, accuracy: 1e-12)
        XCTAssertEqual(m.formState, .aboveBase)
        XCTAssertGreaterThan(m.ratio!, 1)
    }

    func testFormStateSplitsOnWhatPrintsAsZero() {
        let level = TrainingLoadPageModel(
            days: [.init(date: Date(), acute: 40, chronic: 40.1, load: 40)], workouts: [], calendar: calendar())
        XCTAssertEqual(level.formState, .level)
        let fresher = TrainingLoadPageModel(
            days: [.init(date: Date(), acute: 30, chronic: 40, load: 20)], workouts: [], calendar: calendar())
        XCTAssertEqual(fresher.formState, .fresher)
    }

    // MARK: Tomorrow, with the engine's own step

    /// The "tomorrow" rows are not a second implementation: adding that day to the history and asking the engine gives the
    /// same recent load and fitness base the rows show.
    func testProjectionMatchesTheEngineEvaluatingTheImaginedDay() {
        let loads: [Double?] = (0..<60).map { 30 + Double($0 % 9) * 6 }
        let (m, _) = model(loads: loads)
        XCTAssertEqual(m.projections.map(\.scenario), [.rest, .moderate, .allOut])
        XCTAssertEqual(m.projections.map(\.effort), [0, 12, 19])
        for projection in m.projections {
            let stored = projection.effort / 0.21
            let extended = model(loads: loads + [stored]).1
            XCTAssertEqual(projection.recent, extended.acuteLoad! * 0.21, accuracy: 1e-9)
            XCTAssertEqual(projection.base, extended.chronicLoad! * 0.21, accuracy: 1e-9)
            XCTAssertEqual(projection.ratio!, extended.acuteLoad! / extended.chronicLoad!, accuracy: 1e-9)
        }
    }

    func testRestDayLowersAndAllOutRaisesTheRatio() {
        let (m, _) = model(loads: Array(repeating: 55, count: 50))
        let ratios = m.projections.map { $0.ratio! }
        XCTAssertLessThan(ratios[0], 1)
        XCTAssertGreaterThan(ratios[2], ratios[1])
        XCTAssertGreaterThan(ratios[2], 1)
        XCTAssertEqual(m.projections[0].zone, .sweetSpot)
    }

    // MARK: Changes since a week ago

    func testChangeSinceAWeekAgoUsesTheDayExactlyAWeekBack() {
        let (m, result) = model(loads: Array(repeating: 40, count: 30) + Array(repeating: 80, count: 7))
        let week = result.points[result.points.count - 8]
        let change = m.recentChange!
        XCTAssertEqual(change.daysAgo, 7)
        XCTAssertTrue(change.isWeek)
        XCTAssertEqual(change.delta, (result.points.last!.acuteLoad - week.acuteLoad) * 0.21, accuracy: 1e-12)
        XCTAssertGreaterThan(change.delta, 0)
        XCTAssertGreaterThan(m.baseChange!.delta, 0)
    }

    /// A missing day a week back moves the comparison point to the day before it and says so, rather than calling an
    /// eight-day change "this week".
    func testChangeFallsBackWithinTheTolerableGapAndSaysHowFarBack() {
        var loads: [Double?] = Array(repeating: 40, count: 30) + Array(repeating: 70, count: 7)
        loads[loads.count - 8] = nil // the day exactly seven days before the newest
        let (m, result) = model(loads: loads)
        XCTAssertFalse(result.points.contains { $0.day == dayString(offset: loads.count - 8, from: "2026-06-01", calendar()) })
        XCTAssertEqual(m.recentChange?.daysAgo, 8)
        XCTAssertEqual(m.recentChange?.isWeek, false)
    }

    func testNoChangeWhenTheWeekBackIsOutsideTheTolerableGap() {
        let d = calendar()
        let days = [
            TrainingLoadPageModel.Day(date: date("2026-10-01", d), acute: 30, chronic: 30, load: 30),
            TrainingLoadPageModel.Day(date: date("2026-10-19", d), acute: 40, chronic: 32, load: 40),
        ]
        XCTAssertNil(TrainingLoadPageModel(days: days, workouts: [], calendar: d).recentChange)
    }

    // MARK: Weeks

    func testSixCalendarWeeksRespectTheFirstWeekday() {
        // 2026-10-19 is a Monday; 2026-10-21 a Wednesday.
        let loads: [Double?] = Array(repeating: 50, count: 129)
        var monday = calendar(firstWeekday: 2)
        let (m, _) = model(loads: loads, start: "2026-06-15", calendar: monday)
        // Newest day: 2026-06-15 + 128 = 2026-10-21 (Wednesday).
        XCTAssertEqual(m.latest!.date, date("2026-10-21", monday))
        XCTAssertEqual(m.weeks.count, 6)
        XCTAssertEqual(m.weeks.last!.start, date("2026-10-19", monday), "Monday-first week")
        XCTAssertEqual(m.weeks.first!.start, date("2026-09-14", monday))
        XCTAssertEqual(m.weeks.filter(\.isCurrent).count, 1)
        XCTAssertTrue(m.weeks.last!.isCurrent)
        XCTAssertEqual(m.weeks.last!.observedDays, 3, "Mon, Tue, Wed so far")
        XCTAssertEqual(m.weeks[4].observedDays, 7)

        monday.firstWeekday = 1
        let (sunday, _) = model(loads: loads, start: "2026-06-15", calendar: monday)
        XCTAssertEqual(sunday.weeks.last!.start, date("2026-10-18", monday), "Sunday-first week")
        XCTAssertEqual(sunday.weeks.last!.observedDays, 4)
    }

    func testWeekAveragesCountObservedDaysOnlyAndBaseIsTheWeeksLastObservedDay() {
        let d = calendar()
        // Two weeks, Monday-first: 2026-10-12...18 and the current 2026-10-19...21.
        var days: [TrainingLoadPageModel.Day] = []
        for (index, load) in [10.0, 20, 30, 40, 50, 60, 70].enumerated() { // last week, Mon...Sun
            days.append(.init(date: date(dayString(offset: index, from: "2026-10-12", d), d),
                              acute: 40, chronic: 30 + Double(index), load: load))
        }
        days.append(.init(date: date("2026-10-19", d), acute: 45, chronic: 37.5, load: 100))
        days.append(.init(date: date("2026-10-21", d), acute: 46, chronic: 38, load: 50)) // Tuesday had no observation
        let m = TrainingLoadPageModel(days: days, workouts: [], calendar: d)
        let last = m.weeks[m.weeks.count - 2]
        XCTAssertEqual(last.averageEffort!, 40 * 0.21, accuracy: 1e-12)
        XCTAssertEqual(last.baseAtEnd!, 36 * 0.21, accuracy: 1e-12)
        let current = m.weeks.last!
        XCTAssertEqual(current.observedDays, 2)
        XCTAssertEqual(current.averageEffort!, 75 * 0.21, accuracy: 1e-12, "a mean over the two observed days, not over seven")
        XCTAssertEqual(current.baseAtEnd!, 38 * 0.21, accuracy: 1e-12)
        XCTAssertNil(m.weeks.first!.averageEffort)
        XCTAssertNil(m.weeks.first!.baseAtEnd)
    }

    // MARK: Drivers

    func testDriversAreTheThreeHardestScoredWorkoutsOfTheSevenDaysEndingOnTheDay() {
        let d = calendar()
        let workouts = [
            workout("2026-10-12", strain: 99, d),                       // eight days before: outside
            workout("2026-10-13", sport: "Running", strain: 60, d),     // first day of the window
            workout("2026-10-15", sport: "Cycling", strain: 72, d),
            workout("2026-10-15", hour: 18, sport: "Strength", strain: 40, d),
            workout("2026-10-17", sport: "Running", strain: 85, d),
            workout("2026-10-18", sport: "Yoga", strain: nil, d),       // unscored: a training day, never ranked
            workout("2026-10-20", sport: "Running", strain: 95, d),     // after the day: outside
        ]
        let (m, _) = model(loads: Array(repeating: 50, count: 40), start: "2026-09-12", workouts: workouts)
        let week = m.driverWeek(endingOn: date("2026-10-19", d))
        XCTAssertEqual(week.first, date("2026-10-13", d))
        XCTAssertEqual(week.last, date("2026-10-19", d))
        XCTAssertEqual(week.drivers.map(\.workout.sport), ["Running", "Cycling", "Running"])
        XCTAssertEqual(week.drivers.map(\.effort), [85 * 0.21, 72 * 0.21, 60 * 0.21])
        XCTAssertEqual(week.drivers[0].fraction, 85 * 0.21 / 21, accuracy: 1e-12)
        XCTAssertEqual(week.trainingDays, 4, "13th, 15th, 17th, 18th")
    }

    func testDriversTieBreakToTheLaterWorkoutAndTheEmptyWeekIsEmpty() {
        let d = calendar()
        let a = workout("2026-10-14", sport: "A", strain: 50, d)
        let b = workout("2026-10-16", sport: "B", strain: 50, d)
        let m = TrainingLoadPageModel(days: [.init(date: date("2026-10-19", d), acute: 1, chronic: 1, load: 1)],
                                      workouts: [a, b], calendar: d)
        XCTAssertEqual(m.driverWeek(endingOn: date("2026-10-19", d)).drivers.map(\.workout.sport), ["B", "A"])
        let empty = m.driverWeek(endingOn: date("2026-08-01", d))
        XCTAssertTrue(empty.drivers.isEmpty)
        XCTAssertEqual(empty.trainingDays, 0)
    }

    // MARK: Sport mix

    func testMixIsTheTopThreeSportsAndOtherAndSumsToOneHundred() {
        let d = calendar()
        let workouts = [
            workout("2026-10-18", sport: "Running", strain: 50, d),
            workout("2026-10-17", sport: "running", strain: 30, d),   // same sport, different case
            workout("2026-10-16", sport: "Cycling", strain: 40, d),
            workout("2026-10-15", sport: "Strength", strain: 30, d),
            workout("2026-10-14", sport: "Yoga", strain: 9, d),
            workout("2026-10-13", sport: "Golf", strain: 8, d),
            workout("2026-10-12", sport: "Other", strain: 3, d),      // a sport literally named Other joins the bucket
            workout("2026-10-11", sport: "Hiking", strain: nil, d),   // unscored: not counted
            workout("2026-08-01", sport: "Rowing", strain: 500, d),   // outside the six weeks
        ]
        let m = TrainingLoadPageModel(days: [.init(date: date("2026-10-19", d), acute: 1, chronic: 1, load: 1)],
                                      workouts: workouts, calendar: d)
        let mix = m.sportMix()
        XCTAssertEqual(mix.map(\.name), ["Running", "Cycling", "Strength", "Other"])
        XCTAssertEqual(mix.map(\.isOther), [false, false, false, true])
        // Totals: Running 80, Cycling 40, Strength 30, Other 9 + 8 + 3 = 20; sum 170.
        XCTAssertEqual(mix[0].fraction, 80.0 / 170, accuracy: 1e-12)
        XCTAssertEqual(mix[3].fraction, 20.0 / 170, accuracy: 1e-12)
        XCTAssertEqual(mix.map(\.percent).reduce(0, +), 100)
        XCTAssertEqual(mix.map(\.percent), [47, 23, 18, 12])
    }

    func testMixHasNoOtherBucketWhenThreeSportsOrFewerAndNothingWithoutScoredWorkouts() {
        let d = calendar()
        let newest = TrainingLoadPageModel.Day(date: date("2026-10-19", d), acute: 1, chronic: 1, load: 1)
        let two = TrainingLoadPageModel(days: [newest], workouts: [
            workout("2026-10-18", sport: "Running", strain: 60, d),
            workout("2026-10-17", sport: "Cycling", strain: 40, d),
        ], calendar: d)
        XCTAssertEqual(two.sportMix().map(\.name), ["Running", "Cycling"])
        XCTAssertEqual(two.sportMix().map(\.percent), [60, 40])

        let none = TrainingLoadPageModel(days: [newest], workouts: [workout("2026-10-18", strain: nil, d)], calendar: d)
        XCTAssertTrue(none.sportMix().isEmpty)
    }

    func testLargestRemainderAlwaysSumsToOneHundred() {
        for fractions in [[1.0 / 3, 1.0 / 3, 1.0 / 3], [0.125, 0.125, 0.25, 0.5], [0.999, 0.001], [1.0]] {
            XCTAssertEqual(TrainingLoadPageModel.largestRemainder(fractions).reduce(0, +), 100, "\(fractions)")
        }
        XCTAssertEqual(TrainingLoadPageModel.largestRemainder([1.0 / 3, 1.0 / 3, 1.0 / 3]), [34, 33, 33])
    }

    // MARK: Comparison

    func testComparisonSetsTheLastFourWeeksAgainstTheFourBefore() {
        let d = calendar()
        // 60 observed days ending 2026-10-19: the earlier 28-day window averages 20, the latest 28 days 30, one big day.
        var loads: [Double?] = Array(repeating: 20, count: 32) + Array(repeating: 30, count: 28)
        loads[loads.count - 3] = 90
        let workouts = [
            workout("2026-10-18", d), workout("2026-10-12", d), workout("2026-10-12", hour: 17, d),
            workout("2026-09-10", d),
        ]
        let (m, _) = model(loads: loads, start: "2026-08-21", workouts: workouts, calendar: d)
        XCTAssertEqual(m.latest!.date, date("2026-10-19", d))
        let c = m.comparison!
        // Compare the engine's own points: the first six observed days are the seed and are never emitted.
        let recentDays = m.days.filter { $0.date >= date("2026-09-22", d) }
        XCTAssertEqual(recentDays.count, 28)
        XCTAssertEqual(c.averageEffort, recentDays.reduce(0) { $0 + $1.load } / 28 * 0.21, accuracy: 1e-12)
        XCTAssertGreaterThan(c.averageDelta, 0)
        XCTAssertEqual(c.biggestDay.date, date("2026-10-17", d))
        XCTAssertEqual(c.biggestDay.effort, 90 * 0.21, accuracy: 1e-12)
        XCTAssertEqual(c.trainingDays, 2, "the 12th and the 18th")
        XCTAssertEqual(c.previousTrainingDays, 1, "the 10th of September")
        XCTAssertEqual(c.trainingDaysDelta, 1)
    }

    func testComparisonIsHiddenWithoutAWeekOfEarlierHistoryAndTrainingDaysNeedWorkouts() {
        let d = calendar()
        let (short, _) = model(loads: Array(repeating: 40, count: 30), start: "2026-09-20", calendar: d)
        XCTAssertNil(short.comparison, "a 30-day history leaves under a week before the latest 28 days")

        let (long, _) = model(loads: Array(repeating: 40, count: 60), start: "2026-08-21", calendar: d)
        XCTAssertNotNil(long.comparison)
        XCTAssertNil(long.comparison?.trainingDays)
        XCTAssertNil(long.comparison?.trainingDaysDelta)
    }

    /// The engine emits no point for the first six recorded days (they only seed it), but they were recorded: the week
    /// they fall in and the window they fall in average them rather than pretending the week or window is shorter.
    func testWeeksAndComparisonCountTheRecordedDaysBeforeTheSeedDay() throws {
        let d = calendar()
        // 40 recorded days ending Monday 2026-10-19. The first two weeks' worth of seed days (09-10...09-15) are hard.
        var loads: [Double?] = Array(repeating: 40, count: 40)
        for index in 0..<6 { loads[index] = 100 }
        let (full, modeledOnly) = pageModels(loads: loads, start: "2026-09-10", calendar: d)
        XCTAssertEqual(full.latest!.date, date("2026-10-19", d))
        XCTAssertEqual(full.days.count, 34, "34 modeled points: the seed day is the 7th recorded day")

        // The week of 09-14 holds recorded days 09-14...09-20: two of 100 and five of 40.
        let oldest = full.weeks.first!
        XCTAssertEqual(oldest.start, date("2026-09-14", d))
        XCTAssertEqual(oldest.observedDays, 7)
        XCTAssertEqual(oldest.averageEffort!, 400.0 / 7 * 0.21, accuracy: 1e-12)
        XCTAssertNotNil(oldest.baseAtEnd, "the week still ends on a modeled day")
        XCTAssertEqual(modeledOnly.weeks.first!.observedDays, 5, "the modeled days alone drop 09-14 and 09-15")
        XCTAssertEqual(modeledOnly.weeks.first!.averageEffort!, 40 * 0.21, accuracy: 1e-12)

        // 12 recorded days (6 of 100, 6 of 40) sit before the latest 28; only 6 of them are modeled.
        XCTAssertNil(modeledOnly.comparison, "6 modeled days is under the week the comparison needs")
        let comparison = try XCTUnwrap(full.comparison)
        XCTAssertEqual(comparison.previousAverageEffort, 70 * 0.21, accuracy: 1e-12)
        XCTAssertEqual(comparison.averageEffort, 40 * 0.21, accuracy: 1e-12)
    }

    func testAWeekWhollyBeforeTheSeedDayHasAnAverageButNoBase() {
        let d = calendar()
        // 35 recorded days from Tue 2026-09-15 to Mon 2026-10-19. The seed day is the 7th, Mon 09-21, so the first
        // Monday-first week (09-14...09-20) holds six recorded days and not one modeled day.
        var loads: [Double?] = Array(repeating: 40, count: 35)
        for index in 0..<6 { loads[index] = 80 }
        let (full, modeledOnly) = pageModels(loads: loads, start: "2026-09-15", calendar: d)
        XCTAssertEqual(full.weeks.first!.start, date("2026-09-14", d))
        let preSeedWeek = full.weeks.first!
        XCTAssertEqual(preSeedWeek.observedDays, 6)
        XCTAssertEqual(preSeedWeek.averageEffort!, 80 * 0.21, accuracy: 1e-12)
        XCTAssertNil(preSeedWeek.baseAtEnd, "no acute or chronic value exists before the seed day")
        XCTAssertNil(modeledOnly.weeks.first!.averageEffort, "the modeled days alone leave that week empty")
        XCTAssertEqual(modeledOnly.weeks.first!.observedDays, 0)
    }

    func testBiggestDayTieGoesToTheNewestDay() {
        let d = calendar()
        let days = (0..<45).map { offset in
            TrainingLoadPageModel.Day(date: date(dayString(offset: offset, from: "2026-09-05", d), d),
                                      acute: 1, chronic: 1, load: offset == 20 || offset == 30 ? 80 : 10)
        }
        let m = TrainingLoadPageModel(days: days, workouts: [], calendar: d)
        XCTAssertEqual(m.comparison?.biggestDay.date, date(dayString(offset: 30, from: "2026-09-05", d), d))
    }

    // MARK: When there is no model

    private func history(_ loads: [Double?], start: String = "2026-09-01") -> [TrainingLoadEngine.DailyLoad] {
        let cal = calendar()
        return loads.enumerated().map {
            TrainingLoadEngine.DailyLoad(day: dayString(offset: $0.offset, from: start, cal), load: $0.element)
        }
    }

    func testGapNamesAnEmptyHistory() {
        let none = TrainingLoadEngine.evaluate(days: [])
        XCTAssertEqual(TrainingLoadPageModel.gap(result: none, history: [], targetDay: "2026-10-19"), .noHistory)
        let blank = history([nil, nil, nil])
        let result = TrainingLoadEngine.evaluate(days: blank, through: "2026-09-03")
        XCTAssertEqual(TrainingLoadPageModel.gap(result: result, history: blank, targetDay: "2026-09-03"), .noHistory)
    }

    func testGapCountsTheDaysStillNeededAgainstTheEngineMinimum() {
        let days = history(Array(repeating: 40, count: 9))
        let result = TrainingLoadEngine.evaluate(days: days)
        XCTAssertEqual(result.unavailableReason, .notEnoughContiguousDays)
        XCTAssertEqual(TrainingLoadPageModel.gap(result: result, history: days, targetDay: "2026-09-09"),
                       .needsMoreDays(remaining: 5))
        let almost = history(Array(repeating: 40, count: 13))
        XCTAssertEqual(TrainingLoadPageModel.gap(result: TrainingLoadEngine.evaluate(days: almost),
                                                 history: almost, targetDay: "2026-09-13"),
                       .needsMoreDays(remaining: 1))
        let custom = TrainingLoadEngine.Configuration(minimumDays: 20)
        XCTAssertEqual(TrainingLoadPageModel.gap(result: TrainingLoadEngine.evaluate(days: days, configuration: custom),
                                                 history: days, targetDay: "2026-09-09", configuration: custom),
                       .needsMoreDays(remaining: 11))
    }

    /// The engine calls a target day with no Effort "not enough days" with a count of zero, however much history sits
    /// behind it. That is not "needs 14 more days".
    func testATargetDayWithoutEffortIsNotReadyEvenWithMonthsOfHistory() {
        var loads: [Double?] = Array(repeating: 40, count: 90)
        loads.append(nil)
        let days = history(loads)
        let target = "2026-11-30" // 2026-09-01 + 90
        let result = TrainingLoadEngine.evaluate(days: days, through: target)
        XCTAssertEqual(result.unavailableReason, .notEnoughContiguousDays, "what the engine reports")
        XCTAssertEqual(result.contiguousDays, 0)
        XCTAssertEqual(TrainingLoadPageModel.gap(result: result, history: days, targetDay: target), .effortNotReady)
    }

    func testAvailableAndMalformedHistories() {
        let days = history(Array(repeating: 40, count: 20))
        XCTAssertNil(TrainingLoadPageModel.gap(result: TrainingLoadEngine.evaluate(days: days), history: days,
                                               targetDay: "2026-09-20"))
        let bad = [TrainingLoadEngine.DailyLoad(day: "2026-09-01", load: -3)]
        XCTAssertEqual(TrainingLoadPageModel.gap(result: TrainingLoadEngine.evaluate(days: bad), history: bad,
                                                 targetDay: "2026-09-01"), .unusable)
    }

    // MARK: Day span

    func testDaySpanCountsCalendarDaysAcrossMonthsAndLeapDays() {
        XCTAssertEqual(TrainingLoadPageModel.daySpan(from: "2026-10-01", to: "2026-10-19"), 18)
        XCTAssertEqual(TrainingLoadPageModel.daySpan(from: "2026-09-08", to: "2026-10-19"), 41)
        XCTAssertEqual(TrainingLoadPageModel.daySpan(from: "2028-02-28", to: "2028-03-01"), 2)
        XCTAssertEqual(TrainingLoadPageModel.daySpan(from: "2026-10-19", to: "2026-10-01"), -18)
        XCTAssertNil(TrainingLoadPageModel.daySpan(from: "nope", to: "2026-10-01"))
    }

    /// The Trends sparkline holds the last 42 OBSERVED days; with a gap in them the first sits more than 41 days back.
    func testSparklineSpanIsCalendarDaysNotPointCount() {
        var loads: [Double?] = Array(repeating: 40, count: 80)
        loads[70] = nil
        let result = TrainingLoadEngine.evaluate(days: history(loads))
        let spark = Array(result.points.suffix(42))
        XCTAssertEqual(spark.count, 42)
        XCTAssertEqual(TrainingLoadPageModel.daySpan(from: spark.first!.day, to: spark.last!.day), 42)
    }
}
