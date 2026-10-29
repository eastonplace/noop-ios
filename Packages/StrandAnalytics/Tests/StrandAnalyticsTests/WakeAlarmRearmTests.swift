import XCTest
@testable import StrandAnalytics

final class WakeAlarmRearmTests: XCTestCase {
    private var cal: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }

    private func date(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: hour, minute: minute, second: second))!
    }

    private let sevenAndSevenTen = [WakeAlarm(enabled: true, minutes: 420), WakeAlarm(enabled: true, minutes: 430)]

    func testSecondAlarmIsChosenWhenStrapFiresBeforeThePhoneClockReachesTheEndpoint() throws {
        // The strap's RTC can run a few seconds ahead of the phone. Its fire event then arrives while the
        // phone still reads 06:59:58, and "next after now" would hand the strap the 07:00 that just fired.
        XCTAssertEqual(WakeAlarmPlan.next(in: sevenAndSevenTen, after: date(6, 59, 58), calendar: cal)?.date,
                       date(7, 0), "control: the plain lookup repeats the fired endpoint")
        let next = try XCTUnwrap(WakeAlarmPlan.next(in: sevenAndSevenTen, afterFiring: date(7, 0),
                                                    now: date(6, 59, 58), calendar: cal))
        XCTAssertEqual(next.date, date(7, 10))
    }

    func testFiredEndpointInThePastDoesNotChangeTheLookup() throws {
        let yesterday = date(7, 0).addingTimeInterval(-86_400)
        let next = try XCTUnwrap(WakeAlarmPlan.next(in: sevenAndSevenTen, afterFiring: yesterday,
                                                    now: date(7, 5), calendar: cal))
        XCTAssertEqual(next.date, date(7, 10))
        XCTAssertEqual(WakeAlarmPlan.next(in: sevenAndSevenTen, afterFiring: nil,
                                          now: date(7, 5), calendar: cal)?.date, date(7, 10))
    }

    func testSimultaneousAlarmsAreConsumedTogether() throws {
        let alarms = [WakeAlarm(enabled: true, minutes: 420), WakeAlarm(enabled: true, minutes: 420)]
        let next = try XCTUnwrap(WakeAlarmPlan.next(in: alarms, afterFiring: date(7, 0),
                                                    now: date(6, 59, 58), calendar: cal))
        XCTAssertEqual(next.date, date(7, 0).addingTimeInterval(86_400))
    }

    func testLastAlarmOfTheDayRollsToTomorrow() throws {
        let next = try XCTUnwrap(WakeAlarmPlan.next(in: sevenAndSevenTen, afterFiring: date(7, 10),
                                                    now: date(7, 9, 59), calendar: cal))
        XCTAssertEqual(next.date, date(7, 0).addingTimeInterval(86_400))
    }

    func testReceiptsKeepOnlyTheNewestEntriesInOrderAndSurviveReload() throws {
        let suite = "WakeAlarmRearmTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for index in 0..<(WakeAlarmChainReceipts.limit + 5) {
            WakeAlarmChainReceipts.record("event-\(index)", endpoint: date(7, 0),
                                          at: date(6, 0).addingTimeInterval(Double(index)), to: defaults)
        }
        let loaded = WakeAlarmChainReceipts.load(from: defaults)
        XCTAssertEqual(loaded.count, WakeAlarmChainReceipts.limit)
        XCTAssertEqual(loaded.first?.event, "event-5")
        XCTAssertEqual(loaded.last?.event, "event-\(WakeAlarmChainReceipts.limit + 4)")
        XCTAssertEqual(loaded.last?.endpoint, date(7, 0))
    }

    func testRepeatedIdenticalReceiptsCollapseToOne() throws {
        let suite = "WakeAlarmRearmTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for second in 0..<3 {
            WakeAlarmChainReceipts.record("armed", endpoint: date(7, 0), at: date(6, 0, second), to: defaults)
        }
        WakeAlarmChainReceipts.record("armed", endpoint: date(7, 10), at: date(7, 0, 5), to: defaults)
        XCTAssertEqual(WakeAlarmChainReceipts.load(from: defaults).map(\.endpoint), [date(7, 0), date(7, 10)])
    }

    func testReceiptsIgnoreCorruptStorageAndRenderReadableLines() throws {
        let suite = "WakeAlarmRearmTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: WakeAlarmChainReceipts.key)
        XCTAssertTrue(WakeAlarmChainReceipts.load(from: defaults).isEmpty)
        WakeAlarmChainReceipts.record("strap-fired", endpoint: date(7, 0), at: date(7, 0, 3), to: defaults)
        WakeAlarmChainReceipts.record("armed", endpoint: date(7, 10), at: date(7, 0, 4), to: defaults)
        let lines = WakeAlarmChainReceipts.lines(from: defaults, calendar: cal)
        XCTAssertEqual(lines, ["07:00:03 strap-fired → 07:00", "07:00:04 armed → 07:10"])
    }
}
