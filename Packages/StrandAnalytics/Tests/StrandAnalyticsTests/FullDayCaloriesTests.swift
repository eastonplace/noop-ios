import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// N2-11 (D3b): the daily total covers the whole civil day. Seconds without a valid heart-rate sample
/// (off-wrist, no data, 0-bpm rows) get resting BMR; worn seconds keep the per-sample model; no second
/// gets both.
final class FullDayCaloriesTests: XCTestCase {

    private let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")
    private let maxHR = 190.0
    private let dayStart = 1_781_481_600   // 2026-06-15T00:00:00Z
    private let day = "2026-06-15"
    private var utcDay: Range<Int> { dayStart..<(dayStart + 86_400) }

    /// The resting rate the engine uses for this profile (revised Harris–Benedict BMR ÷ 86,400 s).
    private var bmrPerSecond: Double {
        Calories.restingKcalPerS(Calories.male, weightKg: 75, heightCm: 178, age: 30)
    }

    private func worn(_ range: Range<Int>, step: Int = 1) -> [HRSample] {
        stride(from: range.lowerBound, to: range.upperBound, by: step).map { ts in
            // An hour of exercise-level HR in the afternoon, resting HR otherwise.
            let hourOfDay = (ts - dayStart) / 3_600
            return HRSample(ts: ts, bpm: hourOfDay == 17 ? 150 : 64 + ts % 5)
        }
    }

    private func offWrist(_ range: Range<Int>, step: Int = 1) -> [HRSample] {
        stride(from: range.lowerBound, to: range.upperBound, by: step).map { HRSample(ts: $0, bpm: 0) }
    }

    private func perSample(_ samples: [HRSample]) -> Double {
        Calories.estimateDayCalories(samples, profile: profile, hrmax: maxHR, restingHR: nil)
    }

    private func total(dayHr: [HRSample], dayInterval: Range<Int>? = nil, nowTs: Int? = nil,
                       day: String? = nil) throws -> Double {
        let result = AnalyticsEngine.analyzeDay(day: day ?? self.day, dayHr: dayHr, profile: profile,
                                                maxHROverride: maxHR, dayInterval: dayInterval ?? utcDay,
                                                nowTs: nowTs)
        return try XCTUnwrap(result.daily.activeKcalEst)
    }

    /// 16 h worn and 8 h off-wrist: the old per-sample total plus BMR for the 8 hours.
    func testSixteenHoursWornAddsBMRForTheEightHoursOff() throws {
        let wornHr = worn((dayStart + 7 * 3_600)..<(dayStart + 23 * 3_600))
        let expected = perSample(wornHr) + bmrPerSecond * 8 * 3_600
        XCTAssertEqual(try total(dayHr: wornHr), expected, accuracy: 1e-6)
        XCTAssertEqual(bmrPerSecond * 8 * 3_600, 592, accuracy: 1, "8 h of BMR for this profile")
    }

    /// A day the strap spent off-wrist (0-bpm rows only) is BMR × 24 h, with no active energy.
    func testFullyOffWristDayIsBMRForTwentyFourHours() throws {
        let kcal = try total(dayHr: offWrist(utcDay, step: 10))
        XCTAssertEqual(kcal, bmrPerSecond * 86_400, accuracy: 1e-6)
        XCTAssertEqual(kcal, 1_777, accuracy: 1, "this profile's BMR")
        XCTAssertEqual(try total(dayHr: []), kcal, accuracy: 1e-6, "no rows at all fills the same way")
    }

    /// The fall-back day is 25 hours long, and the fill covers all of it.
    func testFallBackDayFillsTwentyFiveHours() throws {
        let tz = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let civil = try XCTUnwrap(AnalyticsEngine.civilDayInterval(day: "2026-11-01", timeZone: tz))
        XCTAssertEqual(civil.count, 25 * 3_600)
        let offOnly = try total(dayHr: offWrist(civil, step: 30), dayInterval: civil, day: "2026-11-01")
        XCTAssertEqual(offOnly, bmrPerSecond * 25 * 3_600, accuracy: 1e-6)

        let wornHr = stride(from: civil.lowerBound + 3_600, to: civil.lowerBound + 3 * 3_600, by: 1)
            .map { HRSample(ts: $0, bpm: 66) }
        let mixed = try total(dayHr: wornHr, dayInterval: civil, day: "2026-11-01")
        XCTAssertEqual(mixed, perSample(wornHr) + bmrPerSecond * Double(25 * 3_600 - 7_200), accuracy: 1e-6)
    }

    /// Today is filled only up to now, not to midnight.
    func testTodayFillsOnlyUpToNow() throws {
        let now = dayStart + 10 * 3_600
        let wornHr = worn((dayStart + 8 * 3_600)..<(dayStart + 9 * 3_600))
        let today = try total(dayHr: wornHr, nowTs: now)
        XCTAssertEqual(today, perSample(wornHr) + bmrPerSecond * Double(10 * 3_600 - 3_600), accuracy: 1e-6)
        XCTAssertEqual(try total(dayHr: wornHr, nowTs: dayStart + 30 * 3_600), try total(dayHr: wornHr),
                       accuracy: 1e-6, "a past day (now after its end) fills all 24 hours")
        // A reading stamped after `now` still counts its own energy, and is not filled twice.
        let late = wornHr + [HRSample(ts: now + 60, bpm: 66)]
        XCTAssertEqual(try total(dayHr: late, nowTs: now), today + perSample([HRSample(ts: now + 60, bpm: 66)]),
                       accuracy: 1e-6)
    }

    /// The 0-bpm rows HRValidity drops are filled once, and a second carried twice counts once.
    func testDroppedOffWristRowsAndDuplicateSecondsAreNotDoubleCounted() throws {
        let wornRange = (dayStart + 8 * 3_600)..<(dayStart + 24 * 3_600)
        let wornHr = worn(wornRange)
        let duplicates = worn((dayStart + 8 * 3_600)..<(dayStart + 9 * 3_600)).map {
            HRSample(ts: $0.ts, bpm: $0.bpm - 2)
        }
        let rows = offWrist(dayStart..<(dayStart + 8 * 3_600)) + wornHr + duplicates
        XCTAssertEqual(try total(dayHr: rows), perSample(wornHr) + bmrPerSecond * 8 * 3_600, accuracy: 1e-6)

        // A day worn at rest from midnight to midnight is exactly BMR × 24 h: each second counted once.
        let restingAllDay = utcDay.map { HRSample(ts: $0, bpm: 62) }
        let doubled = restingAllDay + restingAllDay.prefix(3_600)
        XCTAssertEqual(try total(dayHr: doubled), bmrPerSecond * 86_400, accuracy: 1e-6)
    }
}
