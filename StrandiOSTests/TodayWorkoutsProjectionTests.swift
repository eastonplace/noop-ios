import XCTest
import WhoopStore
@testable import NOOP

final class TodayWorkoutsProjectionTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func row(at date: Date, sport: String = "Run") -> WorkoutRow {
        let start = Int(date.timeIntervalSince1970)
        return WorkoutRow(startTs: start, endTs: start + 1_800, sport: sport, source: "apple_health",
                          durationS: 1_800, energyKcal: 200, avgHr: 140, maxHr: 170,
                          strain: 8.4, distanceM: nil, zonesJSON: nil, notes: nil, strainVersion: 2)
    }

    func testIncludesStartOfDayAndExcludesNextMidnight() {
        let target = date(2026, 7, 18, 12)
        let start = row(at: date(2026, 7, 18))
        let lastMinute = row(at: date(2026, 7, 18, 23, 59))
        let nextDay = row(at: date(2026, 7, 19))
        XCTAssertEqual(TodayWorkoutsProjection.rows([nextDay, lastMinute, start], on: target, calendar: calendar),
                       [lastMinute, start])
    }

    func testMultipleWorkoutsSortNewestFirst() {
        let morning = row(at: date(2026, 7, 18, 8), sport: "Run")
        let evening = row(at: date(2026, 7, 18, 18), sport: "Cycling")
        XCTAssertEqual(TodayWorkoutsProjection.rows([morning, evening], on: date(2026, 7, 18), calendar: calendar),
                       [evening, morning])
    }

    func testRestDayReturnsEmpty() {
        XCTAssertTrue(TodayWorkoutsProjection.rows([row(at: date(2026, 7, 17, 23, 59))],
                                                    on: date(2026, 7, 18), calendar: calendar).isEmpty)
    }
}
