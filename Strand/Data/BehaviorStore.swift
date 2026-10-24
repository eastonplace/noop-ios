import Foundation
import Combine
import StrandAnalytics

/// Settings for the strap's physical inputs and the coaching/automation behaviors built on top of the
/// live event and biometric stream. UserDefaults-backed, single-user, and on-device.
@MainActor
final class BehaviorStore: ObservableObject {

    // MARK: Double-tap action
    @Published var doubleTapAction: DeviceActionKind {
        didSet { d.set(doubleTapAction.rawValue, forKey: K.dtAction) }
    }
    @Published var doubleTapShortcut: String {
        didSet { d.set(doubleTapShortcut, forKey: K.dtShortcut) }
    }

    // MARK: Wear automation
    /// Legacy preference retained so an existing defaults domain remains readable. iPhone cannot lock itself.
    @Published var autoLockOnWristOff: Bool {
        didSet { d.set(autoLockOnWristOff, forKey: K.autoLock) }
    }
    /// Run a Shortcut when the strap comes off (presence automation: Focus, pause media, set away…).
    @Published var wristOffShortcut: String {
        didSet { d.set(wristOffShortcut, forKey: K.wristOffShortcut) }
    }
    /// Run a Shortcut when the strap goes back on the wrist.
    @Published var wristOnShortcut: String {
        didSet { d.set(wristOnShortcut, forKey: K.wristOnShortcut) }
    }

    // MARK: HR-zone haptic coaching
    @Published var zoneCoaching: Bool {
        didSet { d.set(zoneCoaching, forKey: K.zoneCoaching) }
    }

    // MARK: Haptic biofeedback — Stress check-ins
    @Published var stressCheckIn: Bool { didSet { d.set(stressCheckIn, forKey: K.stressCheckIn) } }
    @Published var stressAutoNudge: Bool { didSet { d.set(stressAutoNudge, forKey: K.stressAutoNudge) } }
    @Published var stressQuietHours: Bool { didSet { d.set(stressQuietHours, forKey: K.stressQuietHours) } }
    @Published var stressUseResonancePace: Bool {
        didSet { d.set(stressUseResonancePace, forKey: K.stressUseResonance) }
    }

    // MARK: Smart alarm
    @Published private(set) var wakeAlarms: [WakeAlarm] {
        didSet { WakeAlarmPersistence.save(wakeAlarms, to: d) }
    }

    // Existing callers edit the first saved alarm. Runtime and list UI use the full collection.
    var smartAlarmEnabled: Bool {
        get { wakeAlarms.first?.enabled ?? false }
        set { updatePrimaryAlarm { $0.enabled = newValue } }
    }
    var smartAlarmMinutes: Int {
        get { wakeAlarms.first?.minutes ?? 420 }
        set { updatePrimaryAlarm { $0.minutes = newValue } }
    }
    var smartAlarmMode: SmartAlarmEvaluator.Mode {
        get { wakeAlarms.first?.mode ?? .exactTime }
        set { updatePrimaryAlarm { $0.mode = newValue } }
    }
    var smartAlarmWeekdays: Set<Int> {
        get { wakeAlarms.first?.weekdays ?? [] }
        set { updatePrimaryAlarm { $0.weekdays = newValue } }
    }
    var hasEnabledWakeAlarms: Bool { wakeAlarms.contains(where: \.enabled) }

    @discardableResult
    func saveWakeAlarm(_ alarm: WakeAlarm) -> Bool {
        var updated = wakeAlarms
        if let index = updated.firstIndex(where: { $0.id == alarm.id }) {
            updated[index] = alarm.normalized
        } else {
            guard updated.count < WakeAlarmPlan.maximumAlarms else { return false }
            updated.append(alarm.normalized)
        }
        wakeAlarms = updated
        return true
    }

    func deleteWakeAlarm(id: UUID) {
        wakeAlarms = wakeAlarms.filter { $0.id != id }
    }

    func setWakeAlarmEnabled(id: UUID, enabled: Bool) {
        guard var alarm = wakeAlarms.first(where: { $0.id == id }) else { return }
        alarm.enabled = enabled
        saveWakeAlarm(alarm)
    }

    private func updatePrimaryAlarm(_ edit: (inout WakeAlarm) -> Void) {
        var first = wakeAlarms.first ?? WakeAlarm(id: WakeAlarmPersistence.legacyID, enabled: false)
        edit(&first)
        saveWakeAlarm(first)
    }

    // MARK: Illness early-warning
    var illnessWatch: Bool {
        get { NotificationPreferences.shared.illnessWatch }
        set { objectWillChange.send(); NotificationPreferences.shared.illnessWatch = newValue }
    }

    // MARK: Strap battery alerts
    var batteryAlerts: Bool {
        get { NotificationPreferences.shared.batteryAlerts }
        set { objectWillChange.send(); NotificationPreferences.shared.batteryAlerts = newValue }
    }
    var batteryPredictiveAlerts: Bool {
        get { NotificationPreferences.shared.batteryPredictiveAlerts }
        set { objectWillChange.send(); NotificationPreferences.shared.batteryPredictiveAlerts = newValue }
    }

    private let d: UserDefaults
    private var phonePreferenceObservation: AnyCancellable?

    private enum K {
        static let dtAction = "behavior.doubleTapAction"
        static let dtShortcut = "behavior.doubleTapShortcut"
        static let autoLock = "behavior.autoLockOnWristOff"
        static let wristOffShortcut = "behavior.wristOffShortcut"
        static let wristOnShortcut = "behavior.wristOnShortcut"
        static let zoneCoaching = "behavior.zoneCoaching"
        static let stressCheckIn = "biofeedback.stressCheckIn"
        static let stressAutoNudge = "biofeedback.stressAutoNudge"
        static let stressQuietHours = "biofeedback.stressQuietHours"
        static let stressUseResonance = "biofeedback.stressUseResonancePace"
        static let illness = "behavior.illnessWatch"
        static let batteryAlerts = "behavior.batteryAlerts"
        static let batteryPredictiveAlerts = "behavior.batteryPredictiveAlerts"
    }

    init(defaults: UserDefaults = .standard) {
        d = defaults
        #if DEBUG
        // Reset before loading the store. The asynchronous demo seeder runs after AppModel construction.
        if defaults === UserDefaults.standard, AppleDemoSeeder.requested,
           !CommandLine.arguments.contains("--noop-qa-preserve-preferences") {
            WakeAlarmPersistence.save([WakeAlarm(id: WakeAlarmPersistence.legacyID, enabled: false)], to: defaults)
            defaults.set(SmartAlarmEvaluator.Mode.exactTime.rawValue, forKey: "smartAlarm.runtime.adaptiveMode")
        }
        #endif
        wakeAlarms = WakeAlarmPersistence.load(from: defaults)
        doubleTapAction = DeviceActionKind(rawValue: d.string(forKey: K.dtAction) ?? "") ?? .none
        doubleTapShortcut = d.string(forKey: K.dtShortcut) ?? ""
        autoLockOnWristOff = d.object(forKey: K.autoLock) as? Bool ?? false
        wristOffShortcut = d.string(forKey: K.wristOffShortcut) ?? ""
        wristOnShortcut = d.string(forKey: K.wristOnShortcut) ?? ""
        zoneCoaching = d.object(forKey: K.zoneCoaching) as? Bool ?? false
        stressCheckIn = d.object(forKey: K.stressCheckIn) as? Bool ?? false
        stressAutoNudge = d.object(forKey: K.stressAutoNudge) as? Bool ?? false
        stressQuietHours = d.object(forKey: K.stressQuietHours) as? Bool ?? true
        stressUseResonancePace = d.object(forKey: K.stressUseResonance) as? Bool ?? true
        phonePreferenceObservation = NotificationPreferences.shared.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: Charge baseline recalibration

    var chargeBaselineEpoch: Double { Baselines.recoveryBaselineEpoch(d) }
    var didRecalibrateCharge: Bool { chargeBaselineEpoch > 0 }

    /// Restart the approximately four-night Charge build-up without deleting stored history.
    func recalibrateChargeBaseline(now: Double = Date().timeIntervalSince1970) {
        Baselines.recalibrateRecoveryBaselines(now: now, defaults: d)
    }
}
