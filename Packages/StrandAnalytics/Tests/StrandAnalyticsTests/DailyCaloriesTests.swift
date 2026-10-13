import XCTest
import WhoopProtocol
@testable import StrandAnalytics

/// Review round 4 (5): the one calorie resolver every surface shows.
final class DailyCaloriesTests: XCTestCase {

    private func total(strap: Double? = nil, worn: Double? = nil, active: Double? = nil, basal: Double? = nil,
                       bmr: Double? = 1_700, elapsed: Double? = nil) -> Double? {
        DailyCalories.total(strapKcal: strap, strapWornSeconds: worn, appleActiveKcal: active,
                            appleBasalKcal: basal, bmrKcalPerDay: bmr, daySeconds: 86_400, elapsedSeconds: elapsed)
    }

    func testAStrapThatCoveredTheDayWins() {
        XCTAssertEqual(total(strap: 2_400, worn: 12 * 3_600, active: 900, basal: 1_750), 2_400)
    }

    func testAppleActivePlusBasalWinsOverAStrapSliver() {
        // Two minutes of strap after midnight, then an Apple Watch all day.
        XCTAssertEqual(total(strap: 1_780, worn: 120, active: 900, basal: 1_750), 2_650)
    }

    func testAShortStrapDayWithoutBothAppleValuesKeepsTheStrapTotal() {
        XCTAssertEqual(total(strap: 1_900, worn: 3 * 3_600, active: 450, basal: nil), 1_900)
        XCTAssertEqual(total(strap: 1_900, worn: 3 * 3_600), 1_900)
    }

    func testAppleActiveWithoutBasalAddsTheProfileRestingEnergy() {
        XCTAssertEqual(total(active: 450, basal: nil, bmr: 1_700), 2_150)
        XCTAssertNil(total(active: 450, basal: nil, bmr: nil), "never an active-only number")
    }

    func testNothingToShowIsNil() {
        XCTAssertNil(total())
        XCTAssertNil(total(basal: 1_700))
    }

    func testTodayTrustsTheStrapForHalfTheElapsedDay() {
        let tenAM: Double = 10 * 3_600
        XCTAssertEqual(total(strap: 1_200, worn: 5 * 3_600, active: 300, basal: 700, elapsed: tenAM), 1_200)
        XCTAssertEqual(total(strap: 1_200, worn: 4 * 3_600, active: 300, basal: 700, elapsed: tenAM), 1_000)
    }

    func testTodaysProfileRestingEnergyIsProrated() throws {
        let value = try XCTUnwrap(total(active: 300, basal: nil, bmr: 1_728, elapsed: 6 * 3_600))
        XCTAssertEqual(value, 300 + 1_728 / 4, accuracy: 1e-9)
    }

    /// Review round 5 (3): resting energy is per real second, so a daylight-saving day is not a 24 h day.
    func testRestingEnergyFollowsTheRealLengthOfADaylightSavingDay() throws {
        func value(daySeconds: Double, elapsed: Double?) throws -> Double {
            try XCTUnwrap(DailyCalories.total(strapKcal: nil, strapWornSeconds: nil, appleActiveKcal: 300,
                                              appleBasalKcal: nil, bmrKcalPerDay: 1_728,
                                              daySeconds: daySeconds, elapsedSeconds: elapsed))
        }
        XCTAssertEqual(try value(daySeconds: 25 * 3_600, elapsed: nil), 300 + 1_728 * 25 / 24, accuracy: 1e-9)
        XCTAssertEqual(try value(daySeconds: 23 * 3_600, elapsed: nil), 300 + 1_728 * 23 / 24, accuracy: 1e-9)
        XCTAssertEqual(try value(daySeconds: 23 * 3_600, elapsed: 22.5 * 3_600), 300 + 1_728 * 22.5 / 24,
                       accuracy: 1e-9)
        XCTAssertEqual(try value(daySeconds: 25 * 3_600, elapsed: 12 * 3_600), 300 + 1_728 / 2, accuracy: 1e-9)
        XCTAssertEqual(try value(daySeconds: 23 * 3_600, elapsed: 30 * 3_600), 300 + 1_728 * 23 / 24,
                       accuracy: 1e-9, "never past the day's end")
    }

    func testATotalStoredBeforeCoverageCountsAsCovered() {
        XCTAssertEqual(total(strap: 2_100, worn: nil, active: 900, basal: 1_750), 2_100)
    }

    func testWornSecondsCountMinutesWithAPlausibleReading() {
        let samples = [HRSample(ts: 0, bpm: 60), HRSample(ts: 30, bpm: 61), HRSample(ts: 60, bpm: 62),
                       HRSample(ts: 125, bpm: 0), HRSample(ts: 190, bpm: 300), HRSample(ts: 250, bpm: 70)]
        XCTAssertEqual(DailyCalories.wornSeconds(samples), 3 * 60)
    }

    func testBmrMatchesTheStrapFillRate() {
        let profile = UserProfile(weightKg: 80, heightCm: 180, age: 40, sex: "male")
        let perSecond = Calories.restingKcalPerS(Calories.resolveCoeffs("male"), weightKg: 80, heightCm: 180, age: 40)
        XCTAssertEqual(DailyCalories.bmrKcalPerDay(profile: profile), perSecond * 86_400, accuracy: 1e-9)
        XCTAssertGreaterThan(DailyCalories.bmrKcalPerDay(profile: profile), 1_000)
    }

    func testDayTimingKnowsTodayAndDaylightSavingLength() throws {
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let sevenAM = Date(timeIntervalSince1970: 1_772_366_400)   // 2026-03-01 07:00 EST
        let today = try XCTUnwrap(DailyCalories.dayTiming(day: "2026-03-01", timeZone: newYork, now: sevenAM))
        XCTAssertEqual(today.daySeconds, 86_400)
        XCTAssertEqual(today.elapsedSeconds, 7 * 3_600)
        let springForward = try XCTUnwrap(DailyCalories.dayTiming(day: "2026-03-08", timeZone: newYork, now: sevenAM))
        XCTAssertEqual(springForward.daySeconds, 23 * 3_600)
        XCTAssertNil(springForward.elapsedSeconds)
    }
}
