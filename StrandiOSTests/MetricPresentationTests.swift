import SwiftUI
import XCTest
@testable import NOOP
import StrandDesign

/// How the catalog looks: one tint per metric, one symbol per category, one word per correlation strength.
final class MetricPresentationTests: XCTestCase {
    private func metric(_ key: String, source: String = "my-whoop") throws -> MetricDescriptor {
        try XCTUnwrap(MetricCatalog.all.first { $0.key == key && $0.source == source }, "no catalog metric \(key)")
    }

    private func accent(_ tint: DomainTint) -> Color { tint.accent }

    func testSleepMetricsWearTheSleepTintNotTheActionAccent() throws {
        for key in ["sleep_performance", "sleep_total_min", "sleep_deep_min", "restorative_pct", "sleep_efficiency"] {
            XCTAssertEqual(accent(try metric(key).domainTint()), DomainTint.sleep.accent, key)
        }
    }

    func testStrainAndHeartMetricsFollowTheirDomains() throws {
        XCTAssertEqual(accent(try metric("strain").domainTint()), DomainTint.strain.accent)
        XCTAssertEqual(accent(try metric("hr_zones45_min").domainTint()), DomainTint.strain.accent)
        XCTAssertEqual(accent(try metric("rhr").domainTint()), DomainTint.heart.accent)
        XCTAssertEqual(accent(try metric("hrv").domainTint()), DomainTint.hrv.accent)
        XCTAssertEqual(accent(try metric("stress").domainTint()), DomainTint.stress.accent)
    }

    func testRecoveryFollowsItsBandOnceItHasAScoreAndNeverReadsAsGrey() throws {
        let recovery = try metric("recovery")
        XCTAssertEqual(accent(recovery.domainTint(latest: 85)), DomainTint.recovery(score: 85).accent)
        XCTAssertEqual(accent(recovery.domainTint(latest: 20)), DomainTint.recovery(score: 20).accent)
        XCTAssertNotEqual(accent(recovery.domainTint()), DomainTint.recovery(score: nil).accent)
    }

    /// Every metric wears a real domain colour (never the neutral grey a missing tint falls back to), and every
    /// category has a symbol of its own.
    func testEveryMetricResolvesATintAndEveryCategoryASymbol() {
        let grey = [DomainTint.neutral.accent, StrandPalette.textTertiary]
        for metric in MetricCatalog.all {
            XCTAssertFalse(grey.contains(accent(metric.domainTint())), "\(metric.key) has no tint of its own")
            XCTAssertFalse(grey.contains(accent(MetricCatalog.categoryTint(metric.category))), metric.category)
        }
        let symbols = MetricCatalog.categories.map(MetricCatalog.categorySymbol)
        XCTAssertFalse(symbols.contains("chart.xyaxis.line"), "a category fell through to the default symbol")
        XCTAssertEqual(Set(symbols).count, MetricCatalog.categories.count, "two categories share a symbol")
    }

    func testEveryCorrelationStrengthHasItsOwnWord() {
        let words = CorrelationStrength.allCases.map(\.word)
        XCTAssertEqual(Set(words).count, CorrelationStrength.allCases.count)
        XCTAssertFalse(words.contains(where: \.isEmpty))
    }

    func testExploreRowsStackFromTheLargestStandardTextSize() {
        XCTAssertFalse(ExploreRowLayout.stacks(.xxLarge))
        XCTAssertTrue(ExploreRowLayout.stacks(.xxxLarge))
        XCTAssertTrue(ExploreRowLayout.stacks(.accessibility5))
    }

    /// The Gregorian calendar for a time zone is made once and handed out again, still Gregorian and still in that zone.
    func testTheDayKeyCalendarIsCachedPerTimeZone() throws {
        let cairo = try XCTUnwrap(TimeZone(identifier: "Africa/Cairo"))
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let first = ExploreDayKey.calendar(timeZone: cairo)
        let again = ExploreDayKey.calendar(timeZone: cairo)
        let other = ExploreDayKey.calendar(timeZone: tokyo)
        XCTAssertEqual(first, again)
        XCTAssertEqual(first.identifier, .gregorian)
        XCTAssertEqual(first.timeZone, cairo)
        XCTAssertEqual(other.timeZone, tokyo)
        XCTAssertNotEqual(first, other)
        // Keys still read in the zone asked for.
        let date = try XCTUnwrap(ExploreDayKey.date(for: "2026-10-12", timeZone: tokyo))
        XCTAssertEqual(ExploreDayKey.key(for: date, timeZone: tokyo), "2026-10-12")
    }

    func testAWindowCountsWholeDaysOffDayNumbers() {
        let numbers = ["2026-03-01", "2026-03-05", "2026-03-09", "2026-03-10"].compactMap(ExploreDayKey.dayNumber)
        XCTAssertEqual(ExploreWindow.firstIndex(dayNumbers: numbers, days: 2), 2)
        XCTAssertEqual(ExploreWindow.firstIndex(dayNumbers: numbers, days: 10), 0)
        XCTAssertEqual(ExploreWindow.firstIndex(dayNumbers: numbers, days: 1), 3)
        XCTAssertNil(ExploreWindow.firstIndex(dayNumbers: [], days: 7))
        XCTAssertEqual(ExploreWindow.spanDays(dayNumbers: numbers), 9)
        XCTAssertEqual(ExploreWindow.spanDays(dayNumbers: [numbers[0]]), 0)
        XCTAssertEqual(ExploreWindow.spanDays(dayNumbers: []), 0)
    }

    /// Where the clocks change at midnight (Egypt on 24 April 2026) that day starts at 01:00. A window cut, or a span counted,
    /// from those moments comes out a day short; the day numbers do not care.
    func testAWindowAndASpanAreRightWhereAMidnightIsSkipped() throws {
        let cairo = try XCTUnwrap(TimeZone(identifier: "Africa/Cairo"))
        let calendar = ExploreDayKey.calendar(timeZone: cairo)
        let skipped = try XCTUnwrap(ExploreDayKey.date(for: "2026-04-24", timeZone: cairo))
        try XCTSkipUnless(calendar.component(.hour, from: skipped) == 1, "no midnight clock change for Cairo in this system's time zone data")

        // The latest reading is the day with no midnight: its week reaches back to 18 April.
        let week = (18...24).map { "2026-04-\($0)" }.compactMap(ExploreDayKey.dayNumber)
        XCTAssertEqual(ExploreWindow.firstIndex(dayNumbers: week, days: 7), 0)
        let eighteenth = try XCTUnwrap(ExploreDayKey.date(for: "2026-04-18", timeZone: cairo))
        let cutoff = try XCTUnwrap(calendar.date(byAdding: .day, value: -6, to: skipped))
        XCTAssertGreaterThan(cutoff, eighteenth, "Date arithmetic would have cut 18 April out of its own week")

        // The first reading is the day with no midnight: a week later is seven days on.
        let span = ["2026-04-24", "2026-05-01"].compactMap(ExploreDayKey.dayNumber)
        XCTAssertEqual(ExploreWindow.spanDays(dayNumbers: span), 7)
        let later = try XCTUnwrap(ExploreDayKey.date(for: "2026-05-01", timeZone: cairo))
        XCTAssertEqual(calendar.dateComponents([.day], from: skipped, to: later).day, 6, "Date arithmetic loses the day")
    }

    func testRangeTitlesNameTheirWindow() {
        XCTAssertEqual(ExploreRange.all.title, String(localized: "All time"))
        XCTAssertEqual(ExploreRange.week.title, String(localized: "Last \(7) days"))
        XCTAssertEqual(ExploreRange.year.title, String(localized: "Last \(365) days"))
    }

    // MARK: What a metric can be

    func testOnlyTrulyCappedPercentagesStopAtOneHundred() throws {
        for key in ["recovery", "sleep_performance", "spo2", "sleep_efficiency", "restorative_pct",
                    "sleep_consistency", "noop_sleep_performance_v2", "strain"] {
            XCTAssertEqual(try metric(key).validRange, 0...100, key)
        }
        XCTAssertEqual(try metric("body_fat", source: "apple-health").validRange, 0...100, "body_fat")
        // Hours vs Needed is a ratio: 112% is a long night, not an error.
        let hours = try metric("hours_vs_needed_pct").validRange
        XCTAssertEqual(hours.lowerBound, 0)
        XCTAssertTrue(hours.contains(112.5))
    }

    func testEveryOtherMetricHasAFloorAndSkinTemperatureHasNone() throws {
        XCTAssertEqual(try metric("mood", source: "noop-mood").validRange, 1...5)
        XCTAssertEqual(try metric("stress").validRange, 0...3)
        XCTAssertEqual(try metric("stress", source: "xiaomi-band").validRange, 0...100)
        XCTAssertEqual(try metric("sleep_debt_min").validRange.lowerBound, 0)
        XCTAssertTrue(try metric("skin_temp").validRange.contains(-4.2), "a deviation below baseline is valid")
        for metric in MetricCatalog.all where metric.key != "skin_temp" {
            XCTAssertGreaterThanOrEqual(metric.validRange.lowerBound, 0, metric.key)
        }
    }

    func testTheTypicalBandIsHeldInsideWhatTheMetricCanBe() throws {
        // Blood oxygen: a mean of 99 with a spread of 2 must not shade 101%.
        let spo2 = ExploreTypicalBand.clamped(baseline: 99, typical: 97...101, to: try metric("spo2").validRange)
        XCTAssertEqual(spo2.typical, 97...100)
        XCTAssertEqual(spo2.baseline, 99)
        // Sleep debt: a band that dips under zero starts at zero.
        let debt = ExploreTypicalBand.clamped(baseline: 10, typical: -20...40, to: try metric("sleep_debt_min").validRange)
        XCTAssertEqual(debt.typical, 0...40)
        // Mood out of five: neither end passes five, and a baseline above it is held.
        let mood = ExploreTypicalBand.clamped(baseline: 5.2, typical: 3.5...5.8, to: try metric("mood", source: "noop-mood").validRange)
        XCTAssertEqual(mood.typical, 3.5...5)
        XCTAssertEqual(mood.baseline, 5)
        // Inside the range, nothing moves.
        let steady = ExploreTypicalBand.clamped(baseline: 60, typical: 55...65, to: try metric("rhr").validRange)
        XCTAssertEqual(steady.typical, 55...65)
        XCTAssertEqual(steady.baseline, 60)
    }

    // MARK: A value and its unit

    func testAValueSplitsIntoItsNumberAndUnit() throws {
        let parts = { (key: String, source: String, value: Double, system: UnitSystem, effort: EffortScale) throws -> (number: String, unit: String) in
            try self.metric(key, source: source).displayParts(value, system: system, temperature: .celsius, effortScale: effort)
        }
        let rhr = try parts("rhr", "my-whoop", 61.4, .metric, .hundred)
        XCTAssertEqual(rhr.number, "61")
        XCTAssertEqual(rhr.unit, "bpm")
        let percent = try parts("recovery", "my-whoop", 88, .metric, .hundred)
        XCTAssertEqual(percent.number, "88")
        XCTAssertEqual(percent.unit, "%")
        let kilograms = try parts("weight", "apple-health", 74.2, .metric, .hundred)
        XCTAssertEqual(kilograms.number, "74.2")
        XCTAssertEqual(kilograms.unit, "kg")
        let pounds = try parts("weight", "apple-health", 74.2, .imperial, .hundred)
        XCTAssertEqual(pounds.unit, "lb")
        XCTAssertFalse(pounds.number.contains("lb"))
        let strain = try parts("strain", "my-whoop", 50, .metric, .whoop)
        XCTAssertEqual(strain.unit, "/21")
        XCTAssertFalse(strain.number.contains("/"))
        // A metric with no unit is a bare number and an empty unit, never a unit with no number.
        let vo2 = try parts("vo2max", "apple-health", 47.3, .metric, .hundred)
        XCTAssertEqual(vo2.number, "47.3")
        XCTAssertEqual(vo2.unit, "")
    }

    // MARK: Day keys

    func testADayKeyIsAGregorianLocalDayWhateverCalendarTheDeviceShows() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        let date = try XCTUnwrap(ExploreDayKey.date(for: "2026-10-12", timeZone: zone))
        let gregorian = ExploreDayKey.calendar(timeZone: zone)
        let parts = gregorian.dateComponents([.year, .month, .day, .hour], from: date)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 10)
        XCTAssertEqual(parts.day, 12)
        XCTAssertEqual(parts.hour, 0, "the start of that day in the person's own time zone")
        // The same instant is not year 2026 in another era's calendar, which is what parsing with the device calendar
        // would have produced on such a device.
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = zone
        XCTAssertEqual(buddhist.component(.year, from: date), 2569)
    }

    func testADayKeyThatIsNotARealDayHasNoDate() {
        XCTAssertNil(ExploreDayKey.date(for: "2026-13-01"))
        XCTAssertNil(ExploreDayKey.date(for: "2026-02-30"))
        XCTAssertNil(ExploreDayKey.date(for: "not-a-day"))
        XCTAssertNil(ExploreDayKey.date(for: "2026-10"))
        XCTAssertNotNil(ExploreDayKey.date(for: "2028-02-29"))
    }

    func testTheWindowMathsUseTheSameGregorianCalendarAsTheKeys() throws {
        let calendar = ExploreDayKey.calendar()
        XCTAssertEqual(calendar.identifier, .gregorian)
        let first = try XCTUnwrap(ExploreDayKey.date(for: "2026-01-01"))
        let last = try XCTUnwrap(ExploreDayKey.date(for: "2026-03-01"))
        XCTAssertEqual(calendar.dateComponents([.day], from: first, to: last).day, 59)
    }

    func testDayNumbersAreCalendarFreeAndRoundTrip() throws {
        XCTAssertEqual(ExploreDayKey.dayNumber(for: "1970-01-01"), 0)
        XCTAssertEqual(ExploreDayKey.dayNumber(for: "1970-01-02"), 1)
        XCTAssertEqual(ExploreDayKey.dayNumber(for: "1969-12-31"), -1)
        XCTAssertEqual(ExploreDayKey.dayNumber(for: "2000-03-01"), 11_017)
        let first = try XCTUnwrap(ExploreDayKey.dayNumber(for: "2026-01-01"))
        let last = try XCTUnwrap(ExploreDayKey.dayNumber(for: "2026-03-01"))
        XCTAssertEqual(last - first, 59)
        // A leap day counts; a missing one is rejected.
        XCTAssertEqual(try XCTUnwrap(ExploreDayKey.dayNumber(for: "2028-03-01")) - (try XCTUnwrap(ExploreDayKey.dayNumber(for: "2028-02-28"))), 2)
        XCTAssertNil(ExploreDayKey.dayNumber(for: "2027-02-29"))
        XCTAssertNil(ExploreDayKey.dayNumber(for: "2026-00-10"))
        // Every day of a few years reads back as itself.
        var number = try XCTUnwrap(ExploreDayKey.dayNumber(for: "2023-12-25"))
        for _ in 0..<1_500 {
            let key = ExploreDayKey.key(forDayNumber: number)
            XCTAssertEqual(ExploreDayKey.dayNumber(for: key), number, key)
            number += 1
        }
        XCTAssertEqual(ExploreDayKey.key(forDayNumber: 0), "1970-01-01")
        XCTAssertEqual(ExploreDayKey.key(forDayNumber: try XCTUnwrap(ExploreDayKey.dayNumber(for: "2026-10-12")) + 20), "2026-11-01")
    }

    func testADateBecomesItsKeyInThePersonsZone() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Pacific/Auckland"))
        let date = try XCTUnwrap(ExploreDayKey.date(for: "2026-10-12", timeZone: zone))
        XCTAssertEqual(ExploreDayKey.key(for: date, timeZone: zone), "2026-10-12")
        // The same instant is still the day before in a zone far behind.
        let behind = try XCTUnwrap(TimeZone(identifier: "Pacific/Honolulu"))
        XCTAssertEqual(ExploreDayKey.key(for: date, timeZone: behind), "2026-10-11")
    }

    // MARK: Cadence and change

    func testADailySeriesKeepsTheThreeDayGapLimit() {
        XCTAssertEqual(ExploreCadence.gapLimitDays(dayOffsets: Array(0..<30)), 3)
        // A few missing days do not move the usual spacing.
        XCTAssertEqual(ExploreCadence.gapLimitDays(dayOffsets: [0, 1, 2, 3, 8, 9, 10, 11]), 3)
        XCTAssertEqual(ExploreCadence.gapLimitDays(dayOffsets: []), 3)
        XCTAssertEqual(ExploreCadence.gapLimitDays(dayOffsets: [4]), 3)
    }

    func testAWeeklySeriesBridgesUpToThreeWeeks() {
        XCTAssertEqual(ExploreCadence.gapLimitDays(dayOffsets: [0, 7, 14, 21, 28, 35]), 21)
        // A missing week in a weekly series is still bridged.
        XCTAssertEqual(ExploreCadence.gapLimitDays(dayOffsets: [0, 7, 21, 28, 35]), 21)
        // Roughly every third day.
        XCTAssertEqual(ExploreCadence.gapLimitDays(dayOffsets: [0, 3, 6, 10, 13, 16]), 9)
    }

    func testAChangeIsSignedAndRoundedToOneDecimalPlace() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ExploreChange.signedPercent(4.2, locale: en), "+4.2%")
        XCTAssertEqual(ExploreChange.signedPercent(-1.54, locale: en), "\u{2212}1.5%")
        XCTAssertEqual(ExploreChange.signedPercent(12, locale: en), "+12%")
        // Rounds to nothing: no sign.
        XCTAssertEqual(ExploreChange.signedPercent(0.02, locale: en), "0%")
        XCTAssertEqual(ExploreChange.signedPercent(-0.02, locale: en), "0%")
    }

    func testAChangeFollowsTheLocalesDecimalMark() {
        let text = ExploreChange.signedPercent(4.2, locale: Locale(identifier: "de_DE"))
        XCTAssertTrue(text.hasPrefix("+4,2"), text)
        XCTAssertTrue(text.hasSuffix("%"), text)
    }
}
