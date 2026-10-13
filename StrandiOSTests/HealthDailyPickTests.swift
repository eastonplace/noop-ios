import XCTest
import WhoopStore
@testable import NOOP

/// The trend pages open on the number their Today card showed, so the order of sources is pinned here. Calories are
/// TOTAL energy for the whole day (resting + active) on the card and on the page, never active energy alone.
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

    // MARK: one day

    func testPhoneCaloriesAreActivePlusRestingEnergy() throws {
        let both = try XCTUnwrap(HealthDailyPick.calories(phoneActiveKcal: 141, phoneBasalKcal: 1_650, strapTotalKcal: 2_227))
        XCTAssertEqual(both.value, 1_791)
        XCTAssertFalse(both.isStrapEstimate)
    }

    func testPhoneActiveEnergyAloneNeverStandsInForCalories() throws {
        // No resting energy from the phone: the strap's whole-day total is the number, said to be an estimate.
        let strap = try XCTUnwrap(HealthDailyPick.calories(phoneActiveKcal: 480, phoneBasalKcal: nil, strapTotalKcal: 2_250))
        XCTAssertEqual(strap.value, 2_250)
        XCTAssertTrue(strap.isStrapEstimate)
        // And with no strap total either, active energy alone is not shown as "calories".
        XCTAssertNil(HealthDailyPick.calories(phoneActiveKcal: 480, phoneBasalKcal: nil, strapTotalKcal: nil))
        XCTAssertNil(HealthDailyPick.calories(phoneActiveKcal: nil, phoneBasalKcal: 1_650, strapTotalKcal: nil))
    }

    func testCaloriesFallBackToTheStrapTotalAndSayItIsAnEstimate() throws {
        let strapOnly = try XCTUnwrap(HealthDailyPick.calories(phoneActiveKcal: nil, phoneBasalKcal: nil, strapTotalKcal: 2_227))
        XCTAssertEqual(strapOnly.value, 2_227)
        XCTAssertTrue(strapOnly.isStrapEstimate)
    }

    func testCaloriesWithNoSourceReadNothing() {
        XCTAssertNil(HealthDailyPick.calories(phoneActiveKcal: nil, phoneBasalKcal: nil, strapTotalKcal: nil))
    }

    func testAZeroActiveDayFromThePhoneStillAddsItsRestingEnergy() throws {
        let rest = try XCTUnwrap(HealthDailyPick.calories(phoneActiveKcal: 0, phoneBasalKcal: 1_650, strapTotalKcal: 2_227))
        XCTAssertEqual(rest.value, 1_650)
        XCTAssertFalse(rest.isStrapEstimate)
    }

    // MARK: many days (the page)

    func testEveryDayOnThePageIsTotalEnergyFromItsOwnBestSource() {
        let days = HealthDailyPick.caloriesByDay(
            strap: [strapDay("2026-10-09", total: 2_100), strapDay("2026-10-10", total: 2_200), strapDay("2026-10-11", total: nil)],
            phone: [phoneDay("2026-10-10", active: 400, basal: 1_700), phoneDay("2026-10-11", active: 300, basal: nil),
                    phoneDay("2026-10-12", active: 500, basal: 1_650)])
        XCTAssertEqual(days, [
            .init(day: "2026-10-09", value: 2_100, isStrapEstimate: true),     // strap total
            .init(day: "2026-10-10", value: 2_100, isStrapEstimate: false),    // phone active + resting beats the strap
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
            phone: [phoneDay("2026-10-09", active: 520, basal: 1_650)])
        XCTAssertEqual(card.value, 2_140)
        XCTAssertTrue(card.isStrapEstimate)
    }

    func testAStrapOnlyUserSeesANumberOnTheCardNotADash() {
        let card = HealthDailyPick.caloriesCard(dayKey: "2026-10-12", strap: [strapDay("2026-10-12", total: 2_140)], phone: [])
        XCTAssertEqual(card.value, 2_140)
    }

    func testTheCardAndThePageNameTheSameNumberForTheSameDay() throws {
        let strap = [strapDay("2026-10-10", total: 2_200), strapDay("2026-10-11", total: 2_300), strapDay("2026-10-12", total: 2_400)]
        let phone = [phoneDay("2026-10-11", active: 350, basal: 1_700)]
        let page = HealthDailyPick.caloriesByDay(strap: strap, phone: phone)
        for day in ["2026-10-10", "2026-10-11", "2026-10-12"] {
            let card = HealthDailyPick.caloriesCard(dayKey: day, strap: strap, phone: phone)
            XCTAssertEqual(card.value, page.first(where: { $0.day == day })?.value, day)
        }
        XCTAssertEqual(HealthDailyPick.caloriesCard(dayKey: "2026-10-11", strap: strap, phone: phone).value, 2_050)
    }

    func testTheSparklineEndsAtTheDayShownAndKeepsTheLatestWindow() {
        let strap = (1...20).map { strapDay(String(format: "2026-09-%02d", $0), total: Double(2_000 + $0)) }
        let card = HealthDailyPick.caloriesCard(dayKey: "2026-09-18", strap: strap, phone: [], window: 14)
        XCTAssertEqual(card.sparkline.count, 14)
        XCTAssertEqual(card.sparkline.last, 2_018)                        // not the newest day (Sep 20)
        XCTAssertEqual(card.sparkline.first, 2_005)
    }

    func testADayWithNoNumberLeavesTheCardEmptyButKeepsItsHistory() {
        let card = HealthDailyPick.caloriesCard(
            dayKey: "2026-10-12", strap: [strapDay("2026-10-10", total: 2_000)], phone: [])
        XCTAssertNil(card.value)
        XCTAssertEqual(card.sparkline, [2_000])
    }

    // MARK: Steps

    func testStepsTakeTheStrapThenThePhoneThenTheEstimate() {
        XCTAssertEqual(HealthDailyPick.steps(strap: 5000, phone: 6000, estimate: 7000), 5000)
        XCTAssertEqual(HealthDailyPick.steps(strap: nil, phone: 6000, estimate: 7000), 6000)
        XCTAssertEqual(HealthDailyPick.steps(strap: nil, phone: nil, estimate: 7000), 7000)
        XCTAssertNil(HealthDailyPick.steps(strap: nil, phone: nil, estimate: nil))
    }
}
