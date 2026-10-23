import Foundation

// These types own no platform resources. Production methods below are inserted
// verbatim by smart_alarm_backup_ownership_harness.py from the chosen checkout.
enum SmartAlarmEvaluator {
    static let adaptiveWindowMinutes = 30
    enum Mode: String, Codable, Sendable { case exactTime, sleepGoal, inTheGreen }
    enum Trigger: Sendable { case configured, foreground }
}

/* PRODUCTION_TYPES */

enum UNAuthorizationStatus { case authorized, provisional, ephemeral, notDetermined, denied }
struct UNNotificationSettings { var authorizationStatus: UNAuthorizationStatus }
enum UNAuthorizationOptions: Hashable { case alert, sound }
enum UNNotificationSound { case `default` }
@MainActor
final class UNMutableNotificationContent {
    var title = ""
    var body = ""
    var sound: UNNotificationSound?
}
struct UNCalendarNotificationTrigger: Sendable {
    var dateMatching: DateComponents
    var repeats: Bool
}
struct UNNotificationRequest: Sendable {
    var identifier: String
    var content: UNMutableNotificationContent
    var trigger: UNCalendarNotificationTrigger
}

@MainActor
final class UNUserNotificationCenter {
    static var fixture = UNUserNotificationCenter()
    static func current() -> UNUserNotificationCenter { fixture }
    struct Stored {
        var request: UNNotificationRequest
        var acceptedOrdinal: Int
    }
    var stored: [String: Stored] = [:]
    var ordinal = 0
    var authorizationStatus = UNAuthorizationStatus.authorized
    var permissionRequests = 0
    var holdNextPending = false
    var pendingWaiter: CheckedContinuation<[UNNotificationRequest], Never>?
    var pendingSnapshot: [UNNotificationRequest] = []
    var holdNextAdd = false
    var addWaiter: CheckedContinuation<Void, Never>?

    func notificationSettings() async -> UNNotificationSettings {
        .init(authorizationStatus: authorizationStatus)
    }
    func requestAuthorization(options: Set<UNAuthorizationOptions>) async throws -> Bool {
        permissionRequests += 1
        return true
    }
    func add(_ request: UNNotificationRequest) async throws {
        ordinal += 1
        stored[request.identifier] = .init(request: request, acceptedOrdinal: ordinal)
        if holdNextAdd {
            holdNextAdd = false
            await withCheckedContinuation { addWaiter = $0 }
        }
    }
    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        let snapshot = stored.values.map(\.request)
        if holdNextPending {
            holdNextPending = false
            pendingSnapshot = snapshot
            return await withCheckedContinuation { pendingWaiter = $0 }
        }
        return snapshot
    }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        for identifier in identifiers { stored[identifier] = nil }
    }
    func releasePending() {
        let continuation = pendingWaiter
        pendingWaiter = nil
        continuation?.resume(returning: pendingSnapshot)
    }
    func releaseAdd() {
        let continuation = addWaiter
        addWaiter = nil
        continuation?.resume()
    }
}

@MainActor
final class BehaviorStore {
    var smartAlarmEnabled = true
    var smartAlarmMinutes = 420
    var smartAlarmWeekdays: Set<Int> = []
}
@MainActor
final class SmartAlarmAdaptiveModeStore { var mode = SmartAlarmEvaluator.Mode.exactTime }
@MainActor
final class FixtureBLE {
    func disableStrapAlarm() {}
    func armStrapAlarm(at endpoint: Date) -> Bool { true }
}
@MainActor
final class AppModel { let ble = FixtureBLE() }
enum SmartAlarmSchedule {
    static func nextDate(minutes: Int, weekdays: Set<Int>, after: Date, calendar: Calendar) -> Date? {
        after.addingTimeInterval(3600)
    }
}
@MainActor
enum SmartAlarmRuntimeBackgroundScheduler {
    static func cancel() {}
    static func persistConfiguration(id: UUID, snapshot: SmartAlarmRuntimeSnapshot) {}
}

@MainActor
final class SmartAlarmRuntimeController {
    static let backupBaseIdentifier = "smart-alarm-wake-backup"
    let behavior = BehaviorStore()
    let modeStore = SmartAlarmAdaptiveModeStore()
    let model = AppModel()
    var observedSnapshot: SmartAlarmRuntimeSnapshot?
    var generation = SmartAlarmRuntimeGeneration()
    var configurationID = UUID()
    var debounceTask: Task<Void, Never>?
    var notificationTask: Task<Void, Never>?
    var backupStatusTask: Task<Void, Never>?
    var evaluationTask: Task<Void, Never>?
    var evidenceTask: Task<Void, Never>?
    var deliveryStatus = "Off"
    var backupStatus = "Off"
    var evidence: String?

    init() { observedSnapshot = currentSnapshot }

    /* PRODUCTION_MEMBERS */

    // Unrelated collaborators perform no IO in this harness. All generation,
    // reconciliation, cancellation, add/remove and status logic above is real.
    private func persistEndpointEvidence(endpoint: Date, mode: SmartAlarmEvaluator.Mode, arm: Bool) {}
    private func updateDeliveryStatus(endpoint: Date, arm: Bool, snapshot: SmartAlarmRuntimeSnapshot) {}
    private func scheduleEvidenceRefresh(snapshot: SmartAlarmRuntimeSnapshot, endpoint: Date, token: UInt64) {}
    private func scheduleBackgroundRequest(endpoint: Date, snapshot: SmartAlarmRuntimeSnapshot) {}
    private func beginEvaluation(snapshot: SmartAlarmRuntimeSnapshot, endpoint: Date, token: UInt64,
                                 trigger: SmartAlarmEvaluator.Trigger) {}

    func change(minutes: Int? = nil, weekdays: Set<Int>? = nil, enabled: Bool? = nil) {
        if let minutes { behavior.smartAlarmMinutes = minutes }
        if let weekdays { behavior.smartAlarmWeekdays = weekdays }
        if let enabled { behavior.smartAlarmEnabled = enabled }
        configurationMayHaveChanged()
    }
    func refreshFixtureStatus() async {
        refreshBackupStatus()
        await backupStatusTask?.value
    }
}

@MainActor
final class Checks {
    var failures = 0
    var checks = 0
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if condition() { print("PASS: \(message)") }
        else { failures += 1; print("FAIL: \(message)") }
    }
    func until(_ predicate: () -> Bool) async {
        for _ in 0..<100_000 {
            if predicate() { return }
            await Task.yield()
        }
        fatalError("The production task never reached the requested fixture boundary")
    }

    func sameConfigurationStalePending() async {
        let center = UNUserNotificationCenter()
        UNUserNotificationCenter.fixture = center
        center.holdNextPending = true
        let runtime = SmartAlarmRuntimeController()
        runtime.reconcileImmediately(trigger: .foreground)
        let oldOperation = runtime.notificationTask!
        await until { center.pendingWaiter != nil }
        let configuration = runtime.configurationID
        runtime.reconcileImmediately(trigger: .foreground)
        let replacement = runtime.notificationTask!
        await replacement.value
        let accepted = center.stored
        expect(runtime.configurationID == configuration, "same-config refresh keeps the persisted configuration identity")
        expect(accepted.count == 1 && accepted.values.first?.acceptedOrdinal == 2,
               "same-config replacement was accepted before old pending lookup resumed")
        center.releasePending()
        await oldOperation.value
        expect(center.stored.keys.sorted() == accepted.keys.sorted(),
               "stale pending callback cannot delete the replacement backup")
        await runtime.refreshFixtureStatus()
        expect(runtime.backupStatus == "Scheduled", "status still finds the replacement backup after stale callback")
        expect(center.permissionRequests == 0, "authorized race fixture makes no permission request")
    }

    func sameConfigurationStaleAdd() async {
        let center = UNUserNotificationCenter()
        UNUserNotificationCenter.fixture = center
        center.holdNextAdd = true
        let runtime = SmartAlarmRuntimeController()
        runtime.reconcileImmediately(trigger: .foreground)
        let oldOperation = runtime.notificationTask!
        await until { center.addWaiter != nil }
        runtime.reconcileImmediately(trigger: .foreground)
        await runtime.notificationTask?.value
        let accepted = Set(center.stored.keys)
        expect(center.stored.count == 1, "replacement retires the older accepted backup while old add is suspended")
        center.releaseAdd()
        await oldOperation.value
        expect(Set(center.stored.keys) == accepted && !accepted.isEmpty,
               "stale add completion cannot delete the replacement backup")
    }

    func sequentialRescheduleAndReconfigure() async {
        let center = UNUserNotificationCenter()
        UNUserNotificationCenter.fixture = center
        let runtime = SmartAlarmRuntimeController()
        runtime.reconcileImmediately(trigger: .foreground)
        await runtime.notificationTask?.value
        expect(center.stored.count == 1, "normal every-day backup schedules exactly one repeating request")
        expect(center.stored.values.first?.request.trigger.dateMatching.hour == 7
               && center.stored.values.first?.request.trigger.repeats == true,
               "normal backup retains chosen time and repeating delivery")
        runtime.reconcileImmediately(trigger: .foreground)
        await runtime.notificationTask?.value
        expect(center.stored.count == 1, "sequential same-config reschedule leaves exactly one backup")
        let previousIDs = Set(center.stored.keys)
        runtime.change(minutes: 480, weekdays: [2, 6])
        await runtime.debounceTask?.value
        await runtime.notificationTask?.value
        expect(center.stored.count == 2 && previousIDs.isDisjoint(with: Set(center.stored.keys)),
               "reconfiguration retires old IDs and schedules only the two chosen weekdays")
        let dates = center.stored.values.map { $0.request.trigger.dateMatching }
        expect(Set(dates.compactMap(\.weekday)) == [2, 6] && dates.allSatisfy { $0.hour == 8 && $0.minute == 0 },
               "reconfigured backups retain chosen weekday and time semantics")
        await runtime.refreshFixtureStatus()
        expect(runtime.backupStatus == "Scheduled", "status recognizes current reconfigured backups")
        runtime.change(enabled: false)
        await runtime.notificationTask?.value
        expect(center.stored.isEmpty && runtime.backupStatus == "Off", "disable removes all owned backup requests")
    }

    func reconfigureWhileOldPendingWaits() async {
        let center = UNUserNotificationCenter()
        UNUserNotificationCenter.fixture = center
        center.holdNextPending = true
        let runtime = SmartAlarmRuntimeController()
        runtime.reconcileImmediately(trigger: .foreground)
        let oldOperation = runtime.notificationTask!
        await until { center.pendingWaiter != nil }
        runtime.change(minutes: 540)
        await runtime.debounceTask?.value
        await runtime.notificationTask?.value
        center.releasePending()
        await oldOperation.value
        expect(center.stored.count == 1 && center.stored.values.first?.request.trigger.dateMatching.hour == 9,
               "different-config replacement survives old callback and removes the old wake time")
    }

    func cancelWhileOldPendingWaits() async {
        let center = UNUserNotificationCenter()
        UNUserNotificationCenter.fixture = center
        center.holdNextPending = true
        let runtime = SmartAlarmRuntimeController()
        runtime.reconcileImmediately(trigger: .foreground)
        let oldOperation = runtime.notificationTask!
        await until { center.pendingWaiter != nil }
        runtime.change(enabled: false)
        await runtime.notificationTask?.value
        center.releasePending()
        await oldOperation.value
        expect(center.stored.isEmpty, "disable during pending lookup leaves no resurrected backup")
        expect(runtime.backupStatus == "Off", "late cancelled task cannot replace the disabled status")
    }

    func retainedUnrelatedRequest() async {
        let center = UNUserNotificationCenter()
        UNUserNotificationCenter.fixture = center
        let content = UNMutableNotificationContent()
        let unrelated = UNNotificationRequest(identifier: "noop.notifications.unrelated", content: content,
            trigger: .init(dateMatching: DateComponents(hour: 10), repeats: true))
        try! await center.add(unrelated)
        let legacyID = "smart-alarm-wake-backup-00000000-0000-0000-0000-000000000001-d2"
        try! await center.add(.init(identifier: legacyID, content: content,
            trigger: .init(dateMatching: DateComponents(hour: 7), repeats: true)))
        let runtime = SmartAlarmRuntimeController()
        runtime.reconcileImmediately(trigger: .foreground)
        await runtime.notificationTask?.value
        expect(center.stored[legacyID] == nil && center.stored["noop.notifications.unrelated"] != nil,
               "replacement retires a legacy configuration-only backup without removing unrelated requests")
        runtime.reconcileImmediately(trigger: .foreground)
        await runtime.notificationTask?.value
        runtime.change(enabled: false)
        await runtime.notificationTask?.value
        expect(Set(center.stored.keys) == ["noop.notifications.unrelated"],
               "replacement and disable preserve unrelated notification requests")
    }
}

@main
struct Probe {
    @MainActor static func main() async {
        let checks = Checks()
        await checks.sameConfigurationStalePending()
        await checks.sameConfigurationStaleAdd()
        await checks.sequentialRescheduleAndReconfigure()
        await checks.reconfigureWhileOldPendingWaits()
        await checks.cancelWhileOldPendingWaits()
        await checks.retainedUnrelatedRequest()
        print("\(checks.checks) checks; \(checks.failures) failures")
        exit(checks.failures == 0 ? 0 : 1)
    }
}
