import Foundation
import Combine
import StrandAnalytics

extension Notification.Name {
    static let notificationPreferencesDidChange = Notification.Name("noop.notificationPreferencesDidChange")
}

/// One authority for phone delivery choices. Legacy keys remain live, so older clients and
/// backup restores cannot be overwritten by a stale BehaviorStore snapshot.
@MainActor
final class NotificationPreferences: ObservableObject {
    static let shared = NotificationPreferences()
    let objectWillChange = ObservableObjectPublisher()
    private let defaults: UserDefaults
    private let prefix = "notifications.v1."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrate()
    }

    private func migrate() {
        guard defaults.integer(forKey: "notifications.schemaVersion") < 1 else { return }
        // Keep installed legacy defaults and explicit values exactly as before. New groups are off.
        for group in NotificationGroup.allCases where ![.windDown, .chargeReminder, .batteryFull, .healthPattern].contains(group) {
            let key = prefix + "mode." + group.rawValue
            if defaults.object(forKey: key) == nil { defaults.set(NotificationDeliveryMode.off.rawValue, forKey: key) }
        }
        defaults.set(1, forKey: "notifications.schemaVersion")
    }

    private func bool(_ key: String, fallback: Bool) -> Bool { defaults.object(forKey: key) as? Bool ?? fallback }
    private func integer(_ key: String, fallback: Int) -> Int { defaults.object(forKey: key) as? Int ?? fallback }
    private func write(_ value: Any, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
        if key != prefix + "scheduleRevision" { defaults.set(scheduleRevision &+ 1, forKey: prefix + "scheduleRevision") }
        NotificationCenter.default.post(name: .notificationPreferencesDidChange, object: self)
    }
    private func minute(_ value: Int) -> Int { min(1439, max(0, value)) }

    var scheduleRevision: Int { integer(prefix + "scheduleRevision", fallback: 0) }
    func bumpScheduleRevision() { write(scheduleRevision &+ 1, prefix + "scheduleRevision") }

    var batteryAlerts: Bool {
        get { bool("behavior.batteryAlerts", fallback: true) }
        set { write(newValue, "behavior.batteryAlerts") }
    }
    var batteryPredictiveAlerts: Bool {
        get { bool("behavior.batteryPredictiveAlerts", fallback: true) }
        set { write(newValue, "behavior.batteryPredictiveAlerts") }
    }
    var illnessWatch: Bool {
        get { bool("behavior.illnessWatch", fallback: false) }
        set { write(newValue, "behavior.illnessWatch") }
    }
    var windDownEnabled: Bool {
        get { bool("windDown.enabled", fallback: false) }
        set { write(newValue, "windDown.enabled") }
    }
    var windDownWakeMinutes: Int {
        get { minute(integer("windDown.wakeMinutes", fallback: 420)) }
        set { write(minute(newValue), "windDown.wakeMinutes") }
    }
    var windDownLeadMinutes: Int {
        get { min(120, max(0, integer("windDown.leadMinutes", fallback: 30))) }
        set { write(min(120, max(0, newValue)), "windDown.leadMinutes") }
    }
    var windDownPerDayWakeMinutes: [Int: Int] {
        get {
            guard let data = defaults.data(forKey: "windDown.perDayWakeMinutes"),
                  let map = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
            return Dictionary(uniqueKeysWithValues: map.compactMap { key, value in
                guard let day = Int(key), (1...7).contains(day) else { return nil }
                return (day, minute(value))
            })
        }
        set {
            let map = Dictionary(uniqueKeysWithValues: newValue.filter { (1...7).contains($0.key) }.map { (String($0.key), minute($0.value)) })
            if let data = try? JSONEncoder().encode(map) { write(data, "windDown.perDayWakeMinutes") }
        }
    }
    func mode(for group: NotificationGroup) -> NotificationDeliveryMode {
        switch group {
        case .windDown: return windDownEnabled ? .notify : .off
        case .chargeReminder: return batteryAlerts || batteryPredictiveAlerts ? .notify : .off
        case .batteryFull: return batteryAlerts ? .notify : .off
        case .healthPattern: return illnessWatch ? .notify : .off
        default: return NotificationDeliveryMode(rawValue: defaults.string(forKey: prefix + "mode." + group.rawValue) ?? "") ?? .off
        }
    }
    func setMode(_ mode: NotificationDeliveryMode, for group: NotificationGroup) {
        switch group {
        case .windDown: windDownEnabled = mode == .notify
        case .chargeReminder: batteryAlerts = mode == .notify; batteryPredictiveAlerts = mode == .notify
        case .batteryFull: batteryAlerts = mode == .notify
        case .healthPattern: illnessWatch = mode == .notify
        default: write(mode.rawValue, prefix + "mode." + group.rawValue)
        }
    }
    var quietHoursEnabled: Bool {
        get { bool(prefix + "quietHoursEnabled", fallback: true) }
        set { write(newValue, prefix + "quietHoursEnabled") }
    }
    var quietStartMinutes: Int {
        get { minute(integer(prefix + "quietStartMinutes", fallback: 1260)) }
        set { write(minute(newValue), prefix + "quietStartMinutes") }
    }
    var quietEndMinutes: Int {
        get { minute(integer(prefix + "quietEndMinutes", fallback: 480)) }
        set { write(minute(newValue), prefix + "quietEndMinutes") }
    }
    var showHealthDetails: Bool {
        get { bool(prefix + "showHealthDetails", fallback: false) }
        set { write(newValue, prefix + "showHealthDetails") }
    }
    var proactiveEnabled: Bool {
        get { bool(prefix + "proactiveEnabled", fallback: true) }
        set { write(newValue, prefix + "proactiveEnabled") }
    }
    var dryRunEnabled: Bool {
        get { bool(prefix + "dryRunEnabled", fallback: false) }
        set { write(newValue, prefix + "dryRunEnabled") }
    }
    var journalMinutes: Int {
        get { minute(integer(prefix + "journalMinutes", fallback: 1200)) }
        set { write(minute(newValue), prefix + "journalMinutes") }
    }
    var journalWeekdays: Set<Int> {
        get { Set((defaults.array(forKey: prefix + "journalWeekdays") as? [Int] ?? []).filter { (1...7).contains($0) }) }
        set { write(newValue.filter { (1...7).contains($0) }.sorted(), prefix + "journalWeekdays") }
    }
    var weeklyReviewMinutes: Int {
        get { minute(integer(prefix + "weeklyReviewMinutes", fallback: 1080)) }
        set { write(minute(newValue), prefix + "weeklyReviewMinutes") }
    }
    var weeklyReviewWeekday: Int {
        get { min(7, max(1, integer(prefix + "weeklyReviewWeekday", fallback: 1))) }
        set { write(min(7, max(1, newValue)), prefix + "weeklyReviewWeekday") }
    }
    var workoutReminderLeadMinutes: Int {
        get { min(120, max(0, integer(prefix + "workoutReminderLeadMinutes", fallback: 30))) }
        set { write(min(120, max(0, newValue)), prefix + "workoutReminderLeadMinutes") }
    }
    var snapshot: NotificationPreferencesSnapshot {
        NotificationPreferencesSnapshot(modes: Dictionary(uniqueKeysWithValues: NotificationGroup.allCases.map { ($0, mode(for: $0)) }),
            quietHoursEnabled: quietHoursEnabled, quietStartMinutes: quietStartMinutes, quietEndMinutes: quietEndMinutes,
            showHealthDetails: showHealthDetails, proactiveEnabled: proactiveEnabled)
    }
}
