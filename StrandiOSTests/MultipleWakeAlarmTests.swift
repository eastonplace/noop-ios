import XCTest
import StrandAnalytics
@testable import NOOP

final class MultipleWakeAlarmTests: XCTestCase {
    @MainActor
    func testBehaviorStoreEditsPersistAndDeletingLastAlarmStaysEmpty() throws {
        let suite = "MultipleWakeAlarmTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "behavior.smartAlarmEnabled")
        defaults.set(420, forKey: "behavior.smartAlarmMinutes")
        let store = BehaviorStore(defaults: defaults)
        let original = try XCTUnwrap(store.wakeAlarms.first)
        let later = WakeAlarm(minutes: 430, weekdays: [2, 4])
        XCTAssertTrue(store.saveWakeAlarm(later))
        store.setWakeAlarmEnabled(id: later.id, enabled: false)
        let reopened = BehaviorStore(defaults: defaults)
        XCTAssertEqual(reopened.wakeAlarms.map(\.minutes), [420, 430])
        XCTAssertEqual(reopened.wakeAlarms.map(\.enabled), [true, false])
        reopened.deleteWakeAlarm(id: original.id)
        reopened.deleteWakeAlarm(id: later.id)
        let mode = SmartAlarmAdaptiveModeStore(legacy: reopened, defaults: defaults)
        mode.mode = .sleepGoal
        XCTAssertTrue(BehaviorStore(defaults: defaults).wakeAlarms.isEmpty)
    }

    @MainActor
    func testAdaptiveModeUsesInjectedDefaults() throws {
        let suite = "MultipleWakeAlarmTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BehaviorStore(defaults: defaults)
        let mode = SmartAlarmAdaptiveModeStore(legacy: store, defaults: defaults)
        mode.mode = .inTheGreen
        XCTAssertEqual(defaults.string(forKey: "smartAlarm.runtime.adaptiveMode"), "inTheGreen")
        XCTAssertEqual(BehaviorStore(defaults: defaults).smartAlarmMode, .inTheGreen)
    }

    func testEditingAnotherAlarmInvalidatesGenerationAndBackgroundPayload() throws {
        let first = WakeAlarm(minutes: 420, mode: .sleepGoal)
        let later = WakeAlarm(minutes: 430)
        let before = SmartAlarmRuntimeSnapshot(enabled: true, mode: .sleepGoal, minutes: 420,
                                               weekdays: [], alarms: [first, later])
        var edited = later
        edited.enabled = false
        let after = SmartAlarmRuntimeSnapshot(enabled: true, mode: .sleepGoal, minutes: 420,
                                              weekdays: [], alarms: [first, edited])
        var generation = SmartAlarmRuntimeGeneration()
        let token = generation.advance()
        XCTAssertFalse(generation.accepts(token, request: before, current: after))
        let request = SmartAlarmBackgroundRequest(configurationID: UUID(), endpoint: Date(), snapshot: before)
        let restored = try JSONDecoder().decode(SmartAlarmBackgroundRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(restored.snapshot, before)
        XCTAssertNotEqual(restored.snapshot, after)
    }

    func testNextExactAlarmDoesNotInheritPrimaryAdaptiveMode() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let today = calendar.startOfDay(for: Date())
        let seven = try XCTUnwrap(calendar.date(bySettingHour: 7, minute: 0, second: 0, of: today))
        let snapshot = SmartAlarmRuntimeSnapshot(enabled: true, mode: .sleepGoal, minutes: 420,
            weekdays: [], alarms: [WakeAlarm(minutes: 420, mode: .sleepGoal), WakeAlarm(minutes: 430)])
        let next = try XCTUnwrap(snapshot.next(after: seven))
        XCTAssertEqual(calendar.component(.minute, from: next.date), 10)
        XCTAssertEqual(snapshot.mode(for: next.date), .exactTime)
        XCTAssertEqual(snapshot.mode(for: seven), .sleepGoal)
    }

    func testRepeatPickerCannotTurnFinalDayIntoEveryDay() {
        XCTAssertEqual(SmartAlarmView.alarmToggledWeekday(2, in: [2]), [2])
    }
}
