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
}
