import XCTest
import StrandAnalytics
import StrandDesign
import WhoopStore
@testable import NOOP

/// Perf 5: the Calories and Steps trend pages build their series, display filter, dates and estimate note once per
/// refresh, off the main actor (`HealthTrendPage.build`), instead of in `body`. The page must be the one the body
/// used to compute.
@MainActor
final class HealthTrendPageTests: XCTestCase {
    private func strapDay(_ day: String, steps: Int? = nil, kcal: Double? = nil, hrv: Double? = nil,
                          skin: Double? = nil) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: hrv, recovery: nil, strain: nil, exerciseCount: nil,
                    skinTempDevC: skin, steps: steps, activeKcalEst: kcal)
    }

    private func phoneDay(_ day: String, steps: Int? = nil, active: Double? = nil, basal: Double? = nil) -> AppleDaily {
        AppleDaily(day: day, steps: steps, activeKcal: active, basalKcal: basal, vo2max: nil, avgHr: nil, maxHr: nil,
                   walkingHr: nil, weightKg: nil)
    }

    private let context = HealthDailyPick.CalorieContext(
        strapWornSecondsByDay: [:], bmrKcalPerDay: 1_700, timeZone: TimeZone(identifier: "UTC")!,
        now: Date(timeIntervalSince1970: 1_792_497_600))

    private func inputs(
        _ metric: ProductionTrendMetric, days: [DailyMetric] = [], vitals: [SourcedDailyMetric] = [],
        apple: [AppleDaily] = [], estimates: [String: Double] = [:], unit: TemperatureUnit = .celsius
    ) -> HealthTrendPage.Inputs {
        HealthTrendPage.Inputs(
            metric: metric, vitalRows: vitals, days: days,
            appleByDay: Dictionary(apple.map { ($0.day, $0) }, uniquingKeysWith: { _, last in last }),
            stepsEstByDay: estimates, calorieContext: context, temperatureUnit: unit)
    }

    private func days(_ page: HealthTrendPage) -> [String] {
        page.observations.map { Repository.localDayKey($0.date) }
    }

    func testCaloriesPageIsTheCaloriesByDaySeriesWithTheDisplayRangeAndTheEstimateNote() {
        let strap = [strapDay("2026-10-10", kcal: 2_200), strapDay("2026-10-11", kcal: 250_000), strapDay("2026-10-12", kcal: 2_400)]
        let apple = [phoneDay("2026-10-12", active: 300, basal: 1_700), phoneDay("2026-10-13", active: 400, basal: 1_650)]
        let page = HealthTrendPage.build(inputs(.calories, days: strap, apple: apple))
        let series = HealthDailyPick.caloriesByDay(strap: strap, phone: apple, context: context)
        let shown = series.filter { ProductionTrendMetric.calories.acceptsForDisplay($0.value) }
        XCTAssertEqual(page.observations.compactMap(\.value), shown.map(\.value))
        XCTAssertEqual(days(page), shown.map(\.day))
        XCTAssertFalse(days(page).contains("2026-10-11"), "a corrupt 250,000 kcal day is kept out of the chart")
        XCTAssertEqual(page.showsStrapEstimate, HealthDailyPick.usesStrapEstimate(
            in: series, window: 180, dayDate: BodyVitalSigns.localDate(fromDayKey:)))
        XCTAssertTrue(page.showsStrapEstimate, "the strap's own totals are estimates")
    }

    func testCaloriesPageWithOnlyPhoneEnergyMakesNoEstimateNote() {
        let apple = [phoneDay("2026-10-12", active: 300, basal: 1_700)]
        let page = HealthTrendPage.build(inputs(.calories, apple: apple))
        XCTAssertEqual(page.observations.compactMap(\.value), [2_000])
        XCTAssertFalse(page.showsStrapEstimate)
    }

    func testStepsPageTakesTheStrapThenThePhoneThenTheEstimateForEachDayOldestFirst() {
        let strap = [strapDay("2026-10-12", steps: 5_000), strapDay("2026-10-10")]
        let apple = [phoneDay("2026-10-10", steps: 6_100), phoneDay("2026-10-12", steps: 9_999)]
        let page = HealthTrendPage.build(inputs(
            .steps, days: strap, apple: apple, estimates: ["2026-10-11": 4_321, "2026-10-12": 1_234]))
        XCTAssertEqual(days(page), ["2026-10-10", "2026-10-11", "2026-10-12"])
        XCTAssertEqual(page.observations.compactMap(\.value), [6_100, 4_321, 5_000])
        XCTAssertFalse(page.showsStrapEstimate, "the estimate note belongs to Calories only")
    }

    func testVitalPagesAreTheVitalSeriesAndSkinTemperatureIsNotRangeFiltered() {
        let rows = [
            SourcedDailyMetric(metric: strapDay("2026-10-10", hrv: 61, skin: 0.4), source: .localCache),
            SourcedDailyMetric(metric: strapDay("2026-10-11", hrv: 3_000, skin: -0.2), source: .localCache),
            SourcedDailyMetric(metric: strapDay("2026-10-12", hrv: 58, skin: 0.1), source: .localCache),
        ]
        let hrv = HealthTrendPage.build(inputs(.hrv, vitals: rows))
        XCTAssertEqual(hrv.observations.compactMap(\.value), [61, 58], "an HRV of 3,000 ms is not a display value")
        let skinC = HealthTrendPage.build(inputs(.skinTemp, vitals: rows, unit: .celsius))
        let expectedC = BodyVitalSigns.trendPoints(key: "skin", sourceRows: rows, temperatureUnit: .celsius)
        XCTAssertEqual(skinC.observations.compactMap(\.value), expectedC.map(\.value))
        let skinF = HealthTrendPage.build(inputs(.skinTemp, vitals: rows, unit: .fahrenheit))
        let expectedF = BodyVitalSigns.trendPoints(key: "skin", sourceRows: rows, temperatureUnit: .fahrenheit)
        XCTAssertEqual(skinF.observations.compactMap(\.value), expectedF.map(\.value))
        XCTAssertNotEqual(skinC.observations.compactMap(\.value), skinF.observations.compactMap(\.value))
    }

    func testTheOffMainActorBuildIsTheSamePageAsTheMainActorBuild() async {
        let strap = (1...28).map { strapDay(String(format: "2026-09-%02d", $0), steps: 4_000 + $0 * 10, kcal: 2_000 + Double($0)) }
        let apple = (5...20).map { phoneDay(String(format: "2026-09-%02d", $0), steps: 7_000 + $0, active: 300, basal: 1_700) }
        for metric in [ProductionTrendMetric.calories, .steps] {
            let input = inputs(metric, days: strap, apple: apple, estimates: ["2026-09-30": 3_000])
            let here = HealthTrendPage.build(input)
            let detached = await Task.detached(priority: .userInitiated) { HealthTrendPage.build(input) }.value
            XCTAssertEqual(here, detached)
            XCTAssertFalse(here.observations.isEmpty)
        }
    }

    // MARK: - The unit the page was built in

    /// The user switches °C to °F while a Skin Temp page is on screen. The next body pass reads the live unit for the
    /// label; the stored page still holds the °C numbers until the rebuild lands. Drawing it showed `36.4 °F`.
    func testASkinTempPageBuiltInTheOtherUnitIsNotDrawn() {
        let rows = [
            SourcedDailyMetric(metric: strapDay("2026-10-10", skin: 0.4), source: .localCache),
            SourcedDailyMetric(metric: strapDay("2026-10-12", skin: 0.1), source: .localCache),
        ]
        let celsius = HealthTrendPage.build(inputs(.skinTemp, vitals: rows, unit: .celsius))
        let fahrenheit = HealthTrendPage.build(inputs(.skinTemp, vitals: rows, unit: .fahrenheit))
        XCTAssertEqual(celsius.temperatureUnit, .celsius)
        XCTAssertEqual(fahrenheit.temperatureUnit, .fahrenheit)

        var fallbackBuilds = 0
        let drawn = HealthTrendPage.resolve(stored: celsius, temperature: .fahrenheit) {
            fallbackBuilds += 1
            return fahrenheit
        }
        XCTAssertEqual(drawn, fahrenheit, "the unit changed: the synchronous build is drawn, not the stale page")
        XCTAssertEqual(fallbackBuilds, 1)

        let current = HealthTrendPage.resolve(stored: fahrenheit, temperature: .fahrenheit) {
            fallbackBuilds += 1
            return celsius
        }
        XCTAssertEqual(current, fahrenheit)
        XCTAssertEqual(fallbackBuilds, 1, "a page in the live unit is drawn without a rebuild")

        let none = HealthTrendPage.resolve(stored: nil, temperature: .celsius) { celsius }
        XCTAssertEqual(none, celsius)
    }

    /// Only the temperature series depends on the unit: a Steps or Calories page stays drawn across a unit change.
    func testAPageWithNoTemperatureInItSurvivesAUnitChange() {
        let strap = [strapDay("2026-10-12", steps: 5_000)]
        let steps = HealthTrendPage.build(inputs(.steps, days: strap, unit: .celsius))
        XCTAssertNil(steps.temperatureUnit)
        var rebuilt = false
        let drawn = HealthTrendPage.resolve(stored: steps, temperature: .fahrenheit) {
            rebuilt = true
            return steps
        }
        XCTAssertEqual(drawn, steps)
        XCTAssertFalse(rebuilt)
    }

    // MARK: - What re-builds the page

    private let noon = Date(timeIntervalSince1970: 1_792_497_600)

    private func key(
        _ metric: ProductionTrendMetric = .calories, refreshSeq: Int = 1, unit: TemperatureUnit = .celsius,
        revision: Int64 = 5, bmr: Double? = 1_700, worn: [String: Double] = ["2026-10-12": 40_000],
        now: Date? = nil
    ) -> HealthTrendPageKey {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return HealthTrendPageKey(
            metric: metric, refreshSeq: refreshSeq, temperature: unit, canonicalRevision: revision,
            bmrKcalPerDay: bmr, strapWornSecondsByDay: worn, now: now ?? noon, calendar: calendar)
    }

    /// The old body re-read the strap's worn time, the profile's resting energy and the clock on every repository
    /// publish; the page is built once per task, so the task's key has to move with each of them or today's
    /// Calories figure goes stale (the strap comes off to charge, the coverage test flips, the page keeps the strap's
    /// number).
    func testTheCaloriesKeyMovesWithEveryInputTheOldBodyReRead() {
        let base = key()
        XCTAssertEqual(base, key(), "the same inputs, the same key")
        XCTAssertNotEqual(base, key(refreshSeq: 2))
        XCTAssertNotEqual(base, key(unit: .fahrenheit))
        XCTAssertNotEqual(base, key(revision: 6), "a canonical presentation change rebuilds the page")
        XCTAssertNotEqual(base, key(bmr: 1_650), "a profile edit changes the resting energy")
        XCTAssertNotEqual(base, key(worn: ["2026-10-12": 40_000, "2026-10-13": 600]),
                          "worn time that moved without a refresh")
        XCTAssertNotEqual(base, key(worn: ["2026-10-12": 41_000]))
        XCTAssertEqual(base, key(now: noon.addingTimeInterval(299)), "the same five minutes keep the build")
        XCTAssertNotEqual(base, key(now: noon.addingTimeInterval(300)), "the clock moves the figure every five minutes")
        XCTAssertNotEqual(base, key(now: noon.addingTimeInterval(3_600)))
        XCTAssertNotEqual(base, key(now: noon.addingTimeInterval(86_400)))
    }

    /// Today's Calories figure can change with nothing but the clock (strap coverage lapsing, resting energy
    /// accruing), and the page used to notice only once an hour. It notices within five minutes now, and an idle page
    /// whose repository keeps publishing still rebuilds no more than once per five minutes.
    func testTheCaloriesKeyNoticesTheClockWithinFiveMinutesWithoutChurningOnPublishes() {
        XCTAssertNotEqual(key(now: noon.addingTimeInterval(14 * 60)), key(now: noon.addingTimeInterval(16 * 60 + 40)),
                          "a change at 12:16 reaches a page built at 12:14 on its first pass after 12:15, not an hour later")
        // One hour of body passes every 7 seconds with nothing but the clock moving: one build per five minutes.
        var keys: [HealthTrendPageKey] = []
        for second in stride(from: 0, to: 3_600, by: 7) { keys.append(key(now: noon.addingTimeInterval(Double(second)))) }
        XCTAssertEqual(Set(keys).count, 12)
        var builds = 0
        var last: HealthTrendPageKey?
        for k in keys where k != last { builds += 1; last = k }
        XCTAssertEqual(builds, 12, "each bucket builds once, in order")
        // Repository publishes that move none of the inputs leave the key alone, whatever the second.
        let base = key(now: noon.addingTimeInterval(61))
        XCTAssertEqual(base, key(now: noon.addingTimeInterval(299)))
        XCTAssertEqual(base, key(refreshSeq: 1, revision: 5, now: noon.addingTimeInterval(120)))
    }

    /// Only Calories depends on the worn time, the resting energy and the clock; the other pages are not rebuilt
    /// every hour for inputs they never read.
    func testOtherPagesKeyOnlyOnTheRefreshTheUnitAndTheCanonicalRevision() {
        for metric in [ProductionTrendMetric.steps, .hrv, .skinTemp] {
            let base = key(metric)
            XCTAssertEqual(base, key(metric, bmr: 1_000, worn: [:], now: noon.addingTimeInterval(7_200)))
            XCTAssertNotEqual(base, key(metric, revision: 6))
            XCTAssertNotEqual(base, key(metric, refreshSeq: 2))
        }
    }
}
