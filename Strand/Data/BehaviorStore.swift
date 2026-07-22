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
    @Published var smartAlarmEnabled: Bool { didSet { d.set(smartAlarmEnabled, forKey: K.alarmOn) } }
    /// Target wake time, minutes since local midnight.
    @Published var smartAlarmMinutes: Int { didSet { d.set(smartAlarmMinutes, forKey: K.alarmTime) } }
    /// Exact is firmware-only. Conditional modes may wake up to 30 minutes early when iOS is running;
    /// their configured latest endpoint is still armed on the strap as the fail-safe.
    @Published var smartAlarmMode: SmartAlarmEvaluator.Mode {
        didSet { d.set(smartAlarmMode.rawValue, forKey: K.alarmMode) }
    }
    /// Calendar weekday numbers: 1 = Sun … 7 = Sat. Empty means every day.
    @Published var smartAlarmWeekdays: Set<Int> {
        didSet { d.set(Array(smartAlarmWeekdays).sorted(), forKey: K.alarmWeekdays) }
    }

    // MARK: Illness early-warning
    @Published var illnessWatch: Bool { didSet { d.set(illnessWatch, forKey: K.illness) } }

    // MARK: Strap battery alerts
    @Published var batteryAlerts: Bool { didSet { d.set(batteryAlerts, forKey: K.batteryAlerts) } }
    @Published var batteryPredictiveAlerts: Bool {
        didSet { d.set(batteryPredictiveAlerts, forKey: K.batteryPredictiveAlerts) }
    }

    private let d = UserDefaults.standard

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
        static let alarmOn = "behavior.smartAlarmEnabled"
        static let alarmTime = "behavior.smartAlarmMinutes"
        static let alarmMode = "behavior.smartAlarmMode"
        static let alarmWeekdays = "behavior.smartAlarmWeekdays"
        static let illness = "behavior.illnessWatch"
        static let batteryAlerts = "behavior.batteryAlerts"
        static let batteryPredictiveAlerts = "behavior.batteryPredictiveAlerts"
    }

    init() {
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
        smartAlarmEnabled = d.object(forKey: K.alarmOn) as? Bool ?? false
        smartAlarmMinutes = d.object(forKey: K.alarmTime) as? Int ?? 7 * 60
        smartAlarmMode = SmartAlarmEvaluator.Mode(rawValue: d.string(forKey: K.alarmMode) ?? "") ?? .exactTime
        smartAlarmWeekdays = Set(
            (d.array(forKey: K.alarmWeekdays) as? [Int] ?? []).filter { (1...7).contains($0) }
        )
        illnessWatch = d.object(forKey: K.illness) as? Bool ?? false
        batteryAlerts = d.object(forKey: K.batteryAlerts) as? Bool ?? true
        batteryPredictiveAlerts = d.object(forKey: K.batteryPredictiveAlerts) as? Bool ?? true
    }

    // MARK: Charge baseline recalibration

    var chargeBaselineEpoch: Double { Baselines.recoveryBaselineEpoch(d) }
    var didRecalibrateCharge: Bool { chargeBaselineEpoch > 0 }

    /// Restart the approximately four-night Charge build-up without deleting stored history.
    func recalibrateChargeBaseline(now: Double = Date().timeIntervalSince1970) {
        Baselines.recalibrateRecoveryBaselines(now: now, defaults: d)
    }
}
