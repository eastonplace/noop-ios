import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

/// The trend pages open on the number their Today card showed, so the order of sources is pinned here. Calories are
/// TOTAL energy for the whole day (resting + active) on the card and on the page, never active energy alone, and the
/// order of sources is `DailyCalories`'s: this file checks the hand-off, not a second copy of the rule.
final class HealthDailyPickTests: XCTestCase {
    private func strapDay(_ day: String, total: Double?) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: nil, efficiency: nil, deepMin: nil, remMin: nil, lightMin: nil,
                    disturbances: nil, restingHr: nil, avgHrv: nil, recovery: nil, strain: nil, exerciseCount: nil,
                    activeKcalEst: total)
    }

    private func phoneDay(_ day: String, active: Double?, basal: Double?) -> AppleDaily {
        AppleDaily(day: day, steps: nil, activeKcal: active, basalKcal: basal, vo2max: nil, avgHr: nil, maxHr: nil,
                   walkingHr: nil, weightKg: nil)
    }

    /// Every test day is a finished day: "now" is 2026-10-20 12:00 UTC, in UTC. `worn` is the strap's worn seconds
    /// per day; a day with no entry counts as covered (a total stored before coverage was).
    private func context(
        worn: [String: Double] = [:], bmr: Double? = nil, now: TimeInterval = 1_792_497_600
    ) -> HealthDailyPick.CalorieContext {
        HealthDailyPick.CalorieContext(
            strapWornSecondsByDay: worn, bmrKcalPerDay: bmr, timeZone: TimeZone(identifier: "UTC")!,
            now: Date(timeIntervalSince1970: now))
    }

    private let shortStrapDay: Double = 3 * 3_600
    private let coveredStrapDay: Double = 14 * 3_600

    private func calories(
        _ day: String = "2026-10-12", strap: Double?, active: Double?, basal: Double?,
        context: HealthDailyPick.CalorieContext
    ) -> (value: Double, isStrapEstimate: Bool)? {
        HealthDailyPick.calories(
            day: day, strapKcal: strap, phoneActiveKcal: active, phoneBasalKcal: basal, context: context)
    }

    // MARK: one day

    func testPhoneCaloriesAreActivePlusRestingEnergyWhenTheStrapDidNotCoverTheDay() throws {
        let both = try XCTUnwrap(calories(
            strap: 2_227, active: 141, basal: 1_650, context: context(worn: ["2026-10-12": shortStrapDay])))
        XCTAssertEqual(both.value, 1_791)
        XCTAssertFalse(both.isStrapEstimate)
    }

    func testAStrapThatCoveredTheDayIsTheNumberAndIsSaidToBeAnEstimate() throws {
        let strap = try XCTUnwrap(calories(
            strap: 2_227, active: 141, basal: 1_650, context: context(worn: ["2026-10-12": coveredStrapDay])))
        XCTAssertEqual(strap.value, 2_227)
        XCTAssertTrue(strap.isStrapEstimate)
    }

    func testPhoneActiveEnergyAloneNeverStandsInForCalories() throws {
        // No resting energy from the phone: the strap's whole-day total is the number, said to be an estimate.
        let strap = try XCTUnwrap(calories(strap: 2_250, active: 480, basal: nil, context: context()))
        XCTAssertEqual(strap.value, 2_250)
        XCTAssertTrue(strap.isStrapEstimate)
        // With no strap total and no resting energy to add, active energy alone is not shown as "calories".
        XCTAssertNil(calories(strap: nil, active: 480, basal: nil, context: context()))
        XCTAssertNil(calories(strap: nil, active: nil, basal: 1_650, context: context()))
        // With the profile's resting energy, the phone's active energy is completed to a total, not shown alone.
        let completed = try XCTUnwrap(calories(strap: nil, active: 480, basal: nil, context: context(bmr: 1_700)))
        XCTAssertEqual(completed.value, 2_180)
        XCTAssertFalse(completed.isStrapEstimate)
    }

    func testCaloriesFallBackToTheStrapTotalAndSayItIsAnEstimate() throws {
        let strapOnly = try XCTUnwrap(calories(strap: 2_227, active: nil, basal: nil, context: context()))
        XCTAssertEqual(strapOnly.value, 2_227)
        XCTAssertTrue(strapOnly.isStrapEstimate)
    }

    func testCaloriesWithNoSourceReadNothing() {
        XCTAssertNil(calories(strap: nil, active: nil, basal: nil, context: context(bmr: 1_700)))
    }

    func testAZeroActiveDayFromThePhoneStillAddsItsRestingEnergy() throws {
        let rest = try XCTUnwrap(calories(
            strap: 2_227, active: 0, basal: 1_650, context: context(worn: ["2026-10-12": shortStrapDay])))
        XCTAssertEqual(rest.value, 1_650)
        XCTAssertFalse(rest.isStrapEstimate)
    }

    /// Today is a partial day: the strap's total is trusted from half the elapsed day, as everywhere else.
    func testTodayTrustsTheStrapOnlyFromHalfTheElapsedDay() throws {
        let tenAM: TimeInterval = 1_791_799_200   // 2026-10-12 10:00 UTC
        let enough = try XCTUnwrap(calories(
            strap: 1_200, active: 300, basal: 700, context: context(worn: ["2026-10-12": 5 * 3_600], now: tenAM)))
        XCTAssertEqual(enough.value, 1_200)
        XCTAssertTrue(enough.isStrapEstimate)
        let short = try XCTUnwrap(calories(
            strap: 1_200, active: 300, basal: 700, context: context(worn: ["2026-10-12": 4 * 3_600], now: tenAM)))
        XCTAssertEqual(short.value, 1_000)
        XCTAssertFalse(short.isStrapEstimate)
    }

    /// There is no second precedence here: for every mix of sources the day's number is `DailyCalories`'s, and it is
    /// called a strap estimate exactly when `DailyCalories` says the strap was the source.
    func testTheNumberAndItsLabelAreDailyCaloriesOwn() {
        let strapValues: [Double?] = [nil, 2_227]
        let worn: [Double?] = [nil, shortStrapDay, coveredStrapDay]
        let actives: [Double?] = [nil, 0, 480]
        let basals: [Double?] = [nil, 1_650]
        let bmrs: [Double?] = [nil, 1_700]
        for strap in strapValues { for wornSeconds in worn { for active in actives { for basal in basals {
            for bmr in bmrs {
                let ctx = context(worn: wornSeconds.map { ["2026-10-12": $0] } ?? [:], bmr: bmr)
                let rule = DailyCalories.resolve(
                    strapKcal: strap, strapWornSeconds: wornSeconds, appleActiveKcal: active, appleBasalKcal: basal,
                    bmrKcalPerDay: bmr, daySeconds: 86_400, elapsedSeconds: nil)
                let picked = calories(strap: strap, active: active, basal: basal, context: ctx)
                let label = "strap \(String(describing: strap)) worn \(String(describing: wornSeconds)) " +
                    "active \(String(describing: active)) basal \(String(describing: basal)) bmr \(String(describing: bmr))"
                XCTAssertEqual(picked?.value, rule?.kcal, label)
                XCTAssertEqual(picked?.isStrapEstimate, rule.map { $0.source == .strap }, label)
            }
        } } } }
    }

    // MARK: many days (the page)

    func testEveryDayOnThePageIsTotalEnergyFromItsOwnBestSource() {
        let days = HealthDailyPick.caloriesByDay(
            strap: [strapDay("2026-10-09", total: 2_100), strapDay("2026-10-10", total: 2_200), strapDay("2026-10-11", total: nil)],
            phone: [phoneDay("2026-10-10", active: 400, basal: 1_700), phoneDay("2026-10-11", active: 300, basal: nil),
                    phoneDay("2026-10-12", active: 500, basal: 1_650)],
            context: context(worn: ["2026-10-10": shortStrapDay]))
        XCTAssertEqual(days, [
            .init(day: "2026-10-09", value: 2_100, isStrapEstimate: true),     // strap total
            .init(day: "2026-10-10", value: 2_100, isStrapEstimate: false),    // the strap wore 3 h: the phone's total wins
            // 10-11: the phone has active energy only and the strap has no total, so the day has no number
            .init(day: "2026-10-12", value: 2_150, isStrapEstimate: false),
        ])
    }

    func testTheEstimateNoteCoversEveryDayTheRangeShowsNotOnlyTheLast() {
        let phoneNewest = [HealthDailyPick.CaloriesDay(day: "2026-10-12", value: 2_150, isStrapEstimate: false)]
        let mixed = [
            HealthDailyPick.CaloriesDay(day: "2026-09-20", value: 2_100, isStrapEstimate: true),
            HealthDailyPick.CaloriesDay(day: "2026-10-12", value: 2_150, isStrapEstimate: false),
        ]
        let dayDate = BodyVitalSigns.localDate(fromDayKey:)
        XCTAssertFalse(HealthDailyPick.usesStrapEstimate(in: phoneNewest, window: 180, dayDate: dayDate))
        // The newest day is the phone's, yet the 30-day average includes a strap estimate: the note shows.
        XCTAssertTrue(HealthDailyPick.usesStrapEstimate(in: mixed, window: 180, dayDate: dayDate))
        // An estimate older than the range the page shows does not count.
        XCTAssertFalse(HealthDailyPick.usesStrapEstimate(in: mixed, window: 10, dayDate: dayDate))
        XCTAssertFalse(HealthDailyPick.usesStrapEstimate(in: [], window: 180, dayDate: dayDate))
    }

    // MARK: Today's card

    func testTheCardIsKeyedToTheDayShownNotTheNewestPhoneRow() {
        // The newest phone row is Oct 9; the day on screen is Oct 12 and only the strap has a number for it.
        let card = HealthDailyPick.caloriesCard(
            dayKey: "2026-10-12",
            strap: [strapDay("2026-10-12", total: 2_140)],
            phone: [phoneDay("2026-10-09", active: 520, basal: 1_650)],
            context: context())
        XCTAssertEqual(card.value, 2_140)
        XCTAssertTrue(card.isStrapEstimate)
    }

    func testAStrapOnlyUserSeesANumberOnTheCardNotADash() {
        let card = HealthDailyPick.caloriesCard(
            dayKey: "2026-10-12", strap: [strapDay("2026-10-12", total: 2_140)], phone: [], context: context())
        XCTAssertEqual(card.value, 2_140)
    }

    func testTheCardAndThePageNameTheSameNumberForTheSameDay() throws {
        let strap = [strapDay("2026-10-10", total: 2_200), strapDay("2026-10-11", total: 2_300), strapDay("2026-10-12", total: 2_400)]
        let phone = [phoneDay("2026-10-11", active: 350, basal: 1_700)]
        let ctx = context(worn: ["2026-10-11": shortStrapDay])
        let page = HealthDailyPick.caloriesByDay(strap: strap, phone: phone, context: ctx)
        for day in ["2026-10-10", "2026-10-11", "2026-10-12"] {
            let card = HealthDailyPick.caloriesCard(dayKey: day, strap: strap, phone: phone, context: ctx)
            XCTAssertEqual(card.value, page.first(where: { $0.day == day })?.value, day)
        }
        XCTAssertEqual(
            HealthDailyPick.caloriesCard(dayKey: "2026-10-11", strap: strap, phone: phone, context: ctx).value, 2_050)
    }

    func testTheSparklineEndsAtTheDayShownAndKeepsTheLatestWindow() {
        let strap = (1...20).map { strapDay(String(format: "2026-09-%02d", $0), total: Double(2_000 + $0)) }
        let card = HealthDailyPick.caloriesCard(
            dayKey: "2026-09-18", strap: strap, phone: [], context: context(), window: 14)
        XCTAssertEqual(card.sparkline.count, 14)
        XCTAssertEqual(card.sparkline.last, 2_018)                        // not the newest day (Sep 20)
        XCTAssertEqual(card.sparkline.first, 2_005)
    }

    func testADayWithNoNumberLeavesTheCardEmptyButKeepsItsHistory() {
        let card = HealthDailyPick.caloriesCard(
            dayKey: "2026-10-12", strap: [strapDay("2026-10-10", total: 2_000)], phone: [], context: context())
        XCTAssertNil(card.value)
        XCTAssertEqual(card.sparkline, [2_000])
    }

    // MARK: the same total on every screen

    /// The Health Calories row and the All metrics / Trends Calories series are the same TOTAL energy for the same
    /// days, whatever the mix of sources: a strap sliver loses to Apple's active + basal, a day Apple only half
    /// covers is completed with the profile's resting energy (prorated today), and a day with neither is blank.
    func testTheHealthRowAndTheAllMetricsSeriesShowTheSameTotal() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let reference = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 6)))
        let strap = [strapDay("2026-07-19", total: 1_780), strapDay("2026-07-20", total: nil),
                     strapDay("2026-07-21", total: nil), strapDay("2026-07-22", total: nil)]
        let phone = [phoneDay("2026-07-19", active: 900, basal: 1_750), phoneDay("2026-07-20", active: 500, basal: 1_700),
                     phoneDay("2026-07-21", active: 450, basal: nil), phoneDay("2026-07-22", active: 300, basal: nil)]
        let worn = ["2026-07-19": 120.0]
        let bmr = 1_728.0

        let loaded = TrendsLoadedData(
            revision: 13, anchorDay: "2026-07-22", timeZoneIdentifier: "UTC", canonicalDays: strap,
            sleepPerfByDay: [:], stressByDay: [:], appleDays: phone, strapWornSecondsByDay: worn, bmrKcalPerDay: bmr)
        let allMetrics = try XCTUnwrap(TrendsScreenSnapshot.build(
            key: TrendsScreenSnapshotKey(
                revision: 13, anchorDay: "2026-07-22", timeZoneIdentifier: "UTC", metric: "Calories", range: "M",
                weekOffset: 0),
            data: loaded, metric: .calories, range: .week, weekOffset: 0, referenceDate: reference,
            calendar: calendar, effortDisplayFactor: 1)).selectedPoints.map(\.value)

        let health = HealthDailyPick.caloriesByDay(
            strap: strap, phone: phone,
            context: HealthDailyPick.CalorieContext(
                strapWornSecondsByDay: worn, bmrKcalPerDay: bmr, timeZone: try XCTUnwrap(TimeZone(identifier: "UTC")),
                now: reference)).map(\.value)

        XCTAssertEqual(health, [2_650, 2_200, 2_178, 300 + 1_728 / 4])
        XCTAssertEqual(allMetrics, health)
    }

    // MARK: All metrics (Explore) Calories row

    /// The All metrics "Calories" row is the Health row's number for every day Health has one: a day the strap covered,
    /// a day only Apple Health has, a day the strap barely wore, and a day Apple has active energy only. Imported
    /// export history that has no daily row is kept on top. "Active Energy" stays its own active-only Apple row.
    func testTheAllMetricsCaloriesRowEqualsTheHealthRowDayForDay() throws {
        let covered = "2026-10-09", appleOnly = "2026-10-10", partialStrap = "2026-10-11", activeOnly = "2026-10-12"
        let importOnly = "2026-10-05"
        let dailyRows = [strapDay(covered, total: 2_400), strapDay(partialStrap, total: 1_780)]
        let phone = [phoneDay(covered, active: 900, basal: 1_750), phoneDay(appleOnly, active: 500, basal: 1_700),
                     phoneDay(partialStrap, active: 900, basal: 1_750), phoneDay(activeOnly, active: 450, basal: nil)]
        let ctx = context(worn: [covered: coveredStrapDay, partialStrap: 120], bmr: 1_700)

        let health = HealthDailyPick.caloriesByDay(strap: dailyRows, phone: phone, context: ctx)
        let allMetrics = Repository.exploreCaloriesSeries(
            layeredStrapKcal: [covered: 2_400, partialStrap: 1_780, importOnly: 2_300], dailyRows: dailyRows, apple: phone,
            context: ctx, from: "0000-01-01", to: "9999-12-31")

        // The three cases the owner named, plus a day with Apple's active energy only: the total, never active alone.
        func value(_ day: String, in rows: [(day: String, value: Double)]) -> Double? { rows.first { $0.day == day }?.value }
        XCTAssertEqual(value(covered, in: allMetrics), 2_400)        // the strap covered the day: its total
        XCTAssertEqual(value(appleOnly, in: allMetrics), 2_200)      // Apple only: active + resting
        XCTAssertEqual(value(partialStrap, in: allMetrics), 2_650)   // 2 min of strap: Apple's total wins
        XCTAssertEqual(value(activeOnly, in: allMetrics), 2_150)     // 450 active + the profile's 1,700 resting
        for day in health {
            XCTAssertEqual(value(day.day, in: allMetrics), day.value, day.day)
        }
        // Imported WHOOP export history with no daily row stays in the series.
        XCTAssertEqual(value(importOnly, in: allMetrics), 2_300)
        XCTAssertEqual(allMetrics.map(\.day), allMetrics.map(\.day).sorted())

        let ids = Set(MetricCatalog.all.map(\.id))
        XCTAssertTrue(ids.contains("my-whoop:energy_kcal"), "the Calories row")
        XCTAssertTrue(ids.contains("apple-health:active_kcal"), "Active Energy is its own row")
    }

    /// A window narrower than the history leaves out the days before it, as every other Explore series does.
    func testTheAllMetricsCaloriesRowHonoursTheWindow() {
        let rows = Repository.exploreCaloriesSeries(
            layeredStrapKcal: [:], dailyRows: [strapDay("2026-10-01", total: 2_000), strapDay("2026-10-09", total: 2_100)],
            apple: [], context: context(), from: "2026-10-05", to: "2026-10-10")
        XCTAssertEqual(rows.map(\.day), ["2026-10-09"])
    }

    // MARK: Steps

    func testStepsTakeTheStrapThenThePhoneThenTheEstimate() {
        XCTAssertEqual(HealthDailyPick.steps(strap: 5000, phone: 6000, estimate: 7000), 5000)
        XCTAssertEqual(HealthDailyPick.steps(strap: nil, phone: 6000, estimate: 7000), 6000)
        XCTAssertEqual(HealthDailyPick.steps(strap: nil, phone: nil, estimate: 7000), 7000)
        XCTAssertNil(HealthDailyPick.steps(strap: nil, phone: nil, estimate: nil))
    }
}
