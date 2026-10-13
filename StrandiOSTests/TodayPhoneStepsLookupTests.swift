import XCTest
import WhoopStore
@testable import NOOP

/// Perf 6: Today scanned `appleDays` (up to 4,000 rows) with `last(where: { $0.day == selectedDayKey })`, and
/// `selectedDayKey` builds Dates, Calendars and a String(format:) on every read, so the main thread paid that per
/// element. The key is now read once and handed to a pure lookup that must answer exactly as the closure did.
final class TodayPhoneStepsLookupTests: XCTestCase {
    private func row(_ day: String, steps: Int?) -> AppleDaily {
        AppleDaily(day: day, steps: steps, activeKcal: nil, basalKcal: nil, vo2max: nil, avgHr: nil, maxHr: nil,
                   walkingHr: nil, weightKg: nil)
    }

    private func history() -> [AppleDaily] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.date(from: DateComponents(year: 2015, month: 6, day: 1))!
        return (0..<4_000).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start)!
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            return row(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!),
                       steps: offset % 9 == 0 ? nil : 2_000 + offset)
        }
    }

    func testTheLookupAnswersExactlyAsTheClosureScanDid() {
        let rows = history()
        let keys = [rows[0].day, rows[1].day, rows[1_999].day, rows[3_999].day, rows[4].day, rows[9].day,
                    "2099-01-01", "1999-01-01", "", "not-a-day"]
        for key in keys {
            XCTAssertEqual(TodayView.phoneSteps(on: key, in: rows), rows.last(where: { $0.day == key })?.steps, key)
        }
        XCTAssertNil(TodayView.phoneSteps(on: "2099-01-01", in: rows), "a day with no phone row has no phone steps")
        XCTAssertEqual(TodayView.phoneSteps(on: rows[1].day, in: rows), 2_001)
        XCTAssertNil(TodayView.phoneSteps(on: rows[9].day, in: rows), "a row that has no step count has none")
        XCTAssertNil(TodayView.phoneSteps(on: "2026-10-12", in: []))
    }

    func testTheLastRowForADayWinsEvenWhenAnEarlierOneHadSteps() {
        let rows = [row("2026-10-12", steps: 4_000), row("2026-10-11", steps: 1_000), row("2026-10-12", steps: nil)]
        XCTAssertNil(TodayView.phoneSteps(on: "2026-10-12", in: rows))
        let later = rows + [row("2026-10-12", steps: 8_000)]
        XCTAssertEqual(TodayView.phoneSteps(on: "2026-10-12", in: later), 8_000)
    }
}
