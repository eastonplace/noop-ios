import XCTest
@testable import StrandAnalytics

final class WakeAlarmPlanTests: XCTestCase {
    private var cal: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }

    private func date(_ hour: Int, _ minute: Int) -> Date { date(2026, 10, 24, hour, minute) }

    private func date(_ year: Int, _ month: Int, _ day: Int,
                      _ hour: Int, _ minute: Int) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testLegacyAlarmMigratesWithOriginalSettingsAndStableIdentity() throws {
        let suite = "WakeAlarmPlanTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "behavior.smartAlarmEnabled")
        defaults.set(430, forKey: "behavior.smartAlarmMinutes")
        defaults.set([2, 4, 6], forKey: "behavior.smartAlarmWeekdays")
        defaults.set(SmartAlarmEvaluator.Mode.sleepGoal.rawValue, forKey: "behavior.smartAlarmMode")

        let alarms = WakeAlarmPersistence.load(from: defaults)
        XCTAssertEqual(alarms.count, 1, "The existing wake alarm must survive migration")
        let alarm = try XCTUnwrap(alarms.first)
        XCTAssertTrue(alarm.enabled)
        XCTAssertEqual(alarm.minutes, 430)
        XCTAssertEqual(alarm.weekdays, [2, 4, 6])
        XCTAssertEqual(alarm.mode, .sleepGoal)
        XCTAssertEqual(WakeAlarmPersistence.load(from: defaults).first?.id, alarm.id)
    }
    func testNearestEnabledOccurrenceAdvancesThroughMorningAlarms() throws {
        let alarms = [WakeAlarm(enabled: true, minutes: 420), WakeAlarm(enabled: false, minutes: 425),
                      WakeAlarm(enabled: true, minutes: 430), WakeAlarm(enabled: true, minutes: 440)]
        for (now, expected) in [(date(6, 59), date(7, 0)), (date(7, 0), date(7, 10)),
                                (date(7, 10), date(7, 20))] {
            XCTAssertEqual(WakeAlarmPlan.next(in: alarms, after: now, calendar: cal)?.date, expected)
        }
        XCTAssertNil(WakeAlarmPlan.next(in: alarms.map { var a = $0; a.enabled = false; return a },
                                        after: date(6, 0), calendar: cal))
    }

    func testWeekdaysAndDSTRemainCivilTimeForEachAlarm() throws {
        let alarms = [WakeAlarm(enabled: true, minutes: 420, weekdays: [2]),
                      WakeAlarm(enabled: true, minutes: 430, weekdays: [1])]
        for now in [date(2026, 3, 7, 20, 0), date(2026, 10, 31, 20, 0)] {
            let next = try XCTUnwrap(WakeAlarmPlan.next(in: alarms, after: now, calendar: cal))
            XCTAssertEqual(cal.component(.weekday, from: next.date), 1)
            XCTAssertEqual(cal.component(.hour, from: next.date), 7)
            XCTAssertEqual(cal.component(.minute, from: next.date), 10)
        }
    }

    func testEditedDeletedAndDisabledAlarmsRoundTripWithoutResurrectingLegacy() throws {
        let suite = "WakeAlarmPlanTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = WakeAlarm(enabled: true, minutes: 420, mode: .sleepGoal)
        var second = WakeAlarm(enabled: true, minutes: 430, weekdays: [2, 4])
        second.enabled = false
        second.minutes = 440
        WakeAlarmPersistence.save([first, second], to: defaults)
        XCTAssertEqual(WakeAlarmPersistence.load(from: defaults), [first, second])
        WakeAlarmPersistence.save([second], to: defaults)
        XCTAssertEqual(WakeAlarmPersistence.load(from: defaults), [second])
        WakeAlarmPersistence.save([], to: defaults)
        XCTAssertEqual(WakeAlarmPersistence.load(from: defaults), [])
    }

    func testEveryEnabledScheduleHasItsOwnBackupsAndLimitLeavesReminderCapacity() {
        let alarms = (0..<5).map { WakeAlarm(enabled: true, minutes: 420 + 10 * $0, weekdays: Set(1...7)) }
        let backups = WakeAlarmPlan.backups(for: alarms)
        XCTAssertEqual(backups.count, 35)
        XCTAssertEqual(Set(backups.map(\.alarmID)).count, 5)
        XCTAssertTrue(WakeAlarmPlan.backups(for: [WakeAlarm(enabled: false, minutes: 420)]).isEmpty)
        XCTAssertEqual(WakeAlarmPlan.backups(for: [WakeAlarm(enabled: true, minutes: 420)]).count, 1)
    }

    func testPersistenceBoundsCountAndNormalizesClockWithoutChangingIdentity() throws {
        let suite = "WakeAlarmPlanTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let alarms = (0..<6).map { WakeAlarm(enabled: true, minutes: -1 - $0) }
        WakeAlarmPersistence.save(alarms, to: defaults)
        let loaded = WakeAlarmPersistence.load(from: defaults)
        XCTAssertEqual(loaded.count, 5)
        XCTAssertEqual(loaded.first?.minutes, 1439)
        XCTAssertEqual(loaded.first?.id, alarms.first?.id)
    }
}
