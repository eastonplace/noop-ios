import XCTest
@testable import StrandAnalytics

final class AutoFactorsTests: XCTestCase {

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func day(_ offset: Int) -> String { CorrelationEngine.shiftDay("2026-03-01", by: offset)! }

    /// Unix seconds at `hour:minute` UTC on the day `offset` days after 2026-03-01.
    private func ts(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Int {
        let base = utc.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        return Int(base.timeIntervalSince1970) + offset * 86_400 + hour * 3600 + minute * 60
    }

    /// A night that starts on the evening of `offset` at `minutesAfterMidnight` (may be ≥ 1440)
    /// and lasts 7 hours, keyed by the wake day.
    private func night(_ offset: Int, onset minutesAfterMidnight: Int) -> AutoFactorNight {
        let onset = ts(offset, 0) + minutesAfterMidnight * 60
        let end = onset + 7 * 3600
        return AutoFactorNight(wakeDay: day(offset + 1), onsetTs: onset, endTs: end)
    }

    private func split(_ r: AutoFactorResult, _ f: AutoFactor) -> AutoFactorSplit { r.splits[f]! }

    // MARK: - Bedtime threshold

    func testBedtimeThresholdIsTheMedianRoundedToTheHalfHour() {
        // Onsets 22:50, 23:05, 23:20, 23:35, 23:50, 00:10, 00:40 → median 23:35 → rounds to 23:30.
        let onsets = [1370, 1385, 1400, 1415, 1430, 1450, 1480]
        let nights = onsets.enumerated().map { night($0.offset, onset: $0.element) }
        let r = AutoFactors.derive(nights: nights, days: [], workouts: [], calendar: utc)
        XCTAssertEqual(r.bedtimeThresholdMinutes, 1410)
        let s = split(r, .earlyBedtime)
        // Before 23:30: 22:50, 23:05, 23:20 → wake days 1, 2, 3.
        XCTAssertEqual(s.yes, [day(1), day(2), day(3)])
        XCTAssertEqual(s.no, [day(4), day(5), day(6), day(7)])
    }

    func testAfterMidnightOnsetsCountAsLateNotEarly() {
        XCTAssertEqual(AutoFactors.onsetClockMinutes(ts(0, 0, 30), calendar: utc), 1470)
        XCTAssertEqual(AutoFactors.onsetClockMinutes(ts(0, 23, 0), calendar: utc), 1380)
        XCTAssertEqual(AutoFactors.onsetClockMinutes(ts(0, 21, 15), calendar: utc), 1275)
    }

    func testTooFewNightsHaveNoBedtimeFactor() {
        let nights = (0..<6).map { night($0, onset: 1380) }
        let r = AutoFactors.derive(nights: nights, days: [], workouts: [], calendar: utc)
        XCTAssertNil(r.bedtimeThresholdMinutes)
        XCTAssertNil(r.splits[.earlyBedtime])
    }

    func testNapsAreNotTheMainSleep() {
        var nights = (0..<7).map { night($0, onset: 1380) }
        // A 1-hour afternoon nap on wake day 3 must not replace that night.
        nights.append(AutoFactorNight(wakeDay: day(3), onsetTs: ts(3, 14), endTs: ts(3, 15)))
        let main = AutoFactors.mainNights(nights)
        XCTAssertEqual(main.count, 7)
        XCTAssertEqual(main.first { $0.wakeDay == day(3) }?.onsetTs, nights[2].onsetTs)
    }

    // MARK: - Consistency

    func testConsistencyUsesTheTrailingFourteenDayMedian() {
        // Ten nights at 23:00, then one at 23:20 (within 30 min) and one at 00:10 (70 min late).
        var nights = (0..<10).map { night($0, onset: 1380) }
        nights.append(night(10, onset: 1400))
        nights.append(night(11, onset: 1450))
        let s = split(AutoFactors.derive(nights: nights, days: [], workouts: [], calendar: utc), .consistentBedtime)
        XCTAssertTrue(s.yes.contains(day(11)))
        XCTAssertTrue(s.no.contains(day(12)))
        // The first seven nights have fewer than seven prior nights and take no part.
        for i in 1...7 { XCTAssertFalse(s.yes.contains(day(i)) || s.no.contains(day(i))) }
        XCTAssertTrue(s.yes.contains(day(8)))
    }

    // MARK: - Sleep length and debt

    func testSevenHoursSplitsOnTheWakeDayRow() {
        let days = [AutoFactorDay(day: day(1), totalSleepMin: 420, strain: nil, steps: nil),
                    AutoFactorDay(day: day(2), totalSleepMin: 419, strain: nil, steps: nil),
                    AutoFactorDay(day: day(3), totalSleepMin: nil, strain: nil, steps: nil)]
        let s = split(AutoFactors.derive(nights: [], days: days, workouts: [], calendar: utc), .sevenHours)
        XCTAssertEqual(s.yes, [day(1)])
        XCTAssertEqual(s.no, [day(2)])
        XCTAssertFalse(AutoFactor.sevenHours.isTested(againstOutcomeKey: "sleep_performance"))
        XCTAssertTrue(AutoFactor.sevenHours.isTested(againstOutcomeKey: "recovery"))
    }

    func testSleepDebtReadsOnlyThePriorThreeNights() {
        // Need 8 h (480). Nights 1–3 at 420 → −180 ≤ −120 → day 4 carries debt, whatever day 4 slept.
        // Nights 2–4 = 420, 420, 540 → −60 → day 5 does not.
        let mins: [Double] = [420, 420, 420, 540, 540]
        let days = mins.enumerated().map {
            AutoFactorDay(day: day($0.offset + 1), totalSleepMin: $0.element, strain: nil, steps: nil)
        }
        let needs = Dictionary(uniqueKeysWithValues: days.map { ($0.day, 480.0) })
        let s = split(AutoFactors.derive(nights: [], days: days, workouts: [], calendar: utc,
                                         sleepLedgerNeedsByDay: needs), .sleepDebt)
        XCTAssertTrue(s.yes.contains(day(4)))
        XCTAssertTrue(s.no.contains(day(5)))
        XCTAssertTrue(s.no.contains(day(6)))   // 420 + 540 + 540 − 1440 = 60 surplus
        // Days 1–3 lack three prior nights and take no part.
        for i in 1...3 { XCTAssertFalse(s.yes.contains(day(i)) || s.no.contains(day(i))) }
    }

    func testSleepDebtNeedsThreeConsecutivePriorNights() {
        let days = [1, 2, 4].map { AutoFactorDay(day: day($0), totalSleepMin: 300, strain: nil, steps: nil) }
        let needs = Dictionary(uniqueKeysWithValues: days.map { ($0.day, 480.0) })
        let s = AutoFactors.derive(nights: [], days: days, workouts: [], calendar: utc,
                                   sleepLedgerNeedsByDay: needs).splits[.sleepDebt]
        XCTAssertFalse(s?.yes.contains(day(5)) ?? false, "a gap night means the debt is unknown")
    }

    func testSleepDebtUsesEachNightsTargetInsteadOfEightHours() {
        let days = (1...4).map { AutoFactorDay(day: day($0), totalSleepMin: 420, strain: nil, steps: nil) }
        let sevenHours = Dictionary(uniqueKeysWithValues: days.map { ($0.day, 420.0) })
        let noDebt = AutoFactors.derive(nights: [], days: days, workouts: [], calendar: utc,
                                        sleepLedgerNeedsByDay: sevenHours)
        XCTAssertTrue(noDebt.splits[.sleepDebt]?.no.contains(day(4)) == true)
        var changing = sevenHours
        changing[day(2)] = 540
        let debt = AutoFactors.derive(nights: [], days: days, workouts: [], calendar: utc,
                                     sleepLedgerNeedsByDay: changing)
        XCTAssertTrue(debt.splits[.sleepDebt]?.yes.contains(day(4)) == true)
        let ledger = SleepDebt.ledger(nightlyNeeds: days.prefix(3).map {
            (day: $0.day, totalSleepMin: $0.totalSleepMin, needMin: changing[$0.day])
        }, window: 3)
        XCTAssertEqual(ledger.balanceMin, -120)
    }

    func testSleepDebtSkipsMissingAndInvalidExactNightTargets() {
        let days = (1...3).map { AutoFactorDay(day: day($0), totalSleepMin: 300, strain: nil, steps: nil) }
        for missing in [nil, Double.nan, Double.infinity, 0, -1] as [Double?] {
            var needs = Dictionary(uniqueKeysWithValues: days.map { ($0.day, 480.0) })
            needs[day(2)] = missing
            let result = AutoFactors.derive(nights: [], days: days, workouts: [], calendar: utc,
                                            sleepLedgerNeedsByDay: needs)
            XCTAssertNil(result.splits[.sleepDebt])
        }
        XCTAssertNil(AutoFactors.derive(nights: [], days: days, workouts: [], calendar: utc).splits[.sleepDebt])
    }

    // MARK: - Late workout

    func testLateWorkoutMeansEndedWithinThreeHoursBeforeOnset() {
        let nights = [night(0, onset: 1380), night(1, onset: 1380), night(2, onset: 1380)]
        let workouts = [
            AutoFactorWorkout(startTs: ts(0, 20), endTs: ts(0, 21)),       // 2 h before 23:00 → late
            AutoFactorWorkout(startTs: ts(1, 18), endTs: ts(1, 19, 30)),   // 3.5 h before → not late
        ]
        let s = split(AutoFactors.derive(nights: nights, days: [], workouts: workouts, calendar: utc), .lateWorkout)
        XCTAssertEqual(s.yes, [day(1)])          // attributed to the morning after
        XCTAssertEqual(s.no, [day(2), day(3)])
    }

    // MARK: - Top third, attributed to D+1

    func testHighStrainIsTheTopThirdAndLandsOnTheNextMorning() {
        let days = (0..<15).map { AutoFactorDay(day: day($0), totalSleepMin: nil, strain: Double($0 + 1), steps: Double(1000 * ($0 + 1))) }
        let r = AutoFactors.derive(nights: [], days: days, workouts: [], calendar: utc)
        let strain = split(r, .highStrain)
        // Top third of 15 = 5 values (11…15), on days 10…14, keyed to days 11…15.
        XCTAssertEqual(strain.yes, Set((11...15).map(day)))
        XCTAssertEqual(strain.no, Set((1...10).map(day)))
        XCTAssertEqual(split(r, .highSteps).yes, strain.yes)
    }

    func testTopThirdNeedsTwoWeeksOfDays() {
        let days = (0..<13).map { AutoFactorDay(day: day($0), totalSleepMin: nil, strain: Double($0), steps: nil) }
        XCTAssertNil(AutoFactors.derive(nights: [], days: days, workouts: [], calendar: utc).splits[.highStrain])
        XCTAssertEqual(AutoFactors.topThirdThreshold([1, 2, 3, 4, 5, 6]), 5)
        XCTAssertNil(AutoFactors.topThirdThreshold([1, 2]))
    }
}
