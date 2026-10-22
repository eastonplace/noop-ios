#if DEBUG && os(iOS)
import Foundation
import WhoopProtocol
import StrandAnalytics

/// Explicit, local physical verification. The saved wake time is read, never edited. The temporary
/// firmware alarm is restored on success, timeout, or cancellation; normal startup also re-arms the
/// unchanged saved schedule if the process is interrupted. No immediate buzz command is used.
@MainActor
enum DebugWhoop4AlarmProbe {
    private static var started = false

    static func run(model: AppModel) async {
        guard !started else { return }
        started = true
        let defaults = UserDefaults.standard
        var report: [String: Any] = ["startedAt": Date().timeIntervalSince1970]
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        func save(_ stage: String) {
            report["stage"] = stage
            report["updatedAt"] = Date().timeIntervalSince1970
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: documents.appendingPathComponent("noop-alarm-physical-probe.json"), options: .atomic)
            }
            model.live.append(log: "Alarm physical test: \(stage)")
        }
        save("waitingForBond")
        for _ in 0..<90 {
            if model.live.connected && model.live.bonded && model.ble.connectedPeripheralUUID != nil { break }
            if Task.isCancelled { save("cancelledBeforeArm"); return }
            try? await Task.sleep(for: .seconds(1))
        }
        guard model.live.connected, model.live.bonded, !model.whoop5Detected,
              let source = model.ble.connectedPeripheralUUID,
              model.behavior.smartAlarmEnabled, model.behavior.smartAlarmMinutes == 420,
              let restoreWake = SmartAlarmSchedule.nextDate(
                minutes: model.behavior.smartAlarmMinutes,
                weekdays: model.behavior.smartAlarmWeekdays, after: Date(), calendar: .current)
        else { save("refusedWrongDeviceOrSchedule"); return }
        let savedConfiguration = defaults.data(forKey: "smartAlarm.runtime.configuration")
        // Let the normal startup/settled-connect reconciliation finish before taking the temporary
        // firmware slot. Saved preferences remain unchanged and a replacement is detected below.
        try? await Task.sleep(for: .seconds(3))
        let testWake = Date(timeIntervalSince1970: ceil((Date().timeIntervalSince1970 + 90) / 60) * 60)
        report["sourceID"] = source
        report["testWakeEpoch"] = Int(testWake.timeIntervalSince1970)
        report["restoreWakeEpoch"] = Int(restoreWake.timeIntervalSince1970)
        report["savedMinutesBefore"] = model.behavior.smartAlarmMinutes
        report["savedConfigurationBefore"] = savedConfiguration.flatMap { String(data: $0, encoding: .utf8) }
        save("prepared")
        var actualRestoreWake = restoreWake
        var restoreRequestID: String?
        var restoreSentAt: TimeInterval?
        var testSentAt: TimeInterval?
        func arm(isTest: Bool) {
            guard model.ble.connectedPeripheralUUID == source else {
                report["sourceChanged"] = true
                save("armRefusedSourceChanged")
                return
            }
            guard defaults.data(forKey: "smartAlarm.runtime.configuration") == savedConfiguration else {
                // A person's new choice owns the register; never overwrite it with our old snapshot.
                report["configurationChanged"] = true
                save("armRefusedConfigurationChanged")
                return
            }
            if !isTest {
                // A test crossing 07:00 must restore the next occurrence, never a past alarm.
                guard let nextWake = SmartAlarmSchedule.nextDate(
                    minutes: model.behavior.smartAlarmMinutes,
                    weekdays: model.behavior.smartAlarmWeekdays, after: Date(), calendar: .current)
                else { save("restoreRefusedInvalidSchedule"); return }
                actualRestoreWake = nextWake
                report["restoreWakeEpoch"] = Int(nextWake.timeIntervalSince1970)
            }
            let sentAt = Date().timeIntervalSince1970
            let armResult = model.ble.armStrapAlarm(at: isTest ? testWake : actualRestoreWake)
            guard case .sentAwaitingReadback = armResult else {
                save(isTest ? "testArmNotSent" : "restoreNotSent")
                return
            }
            if isTest {
                report["testRequestID"] = defaults.string(forKey: "alarm.lastArmRequestID")
                testSentAt = sentAt
            } else {
                restoreRequestID = defaults.string(forKey: "alarm.lastArmRequestID")
                restoreSentAt = sentAt
                report["restoreRequestID"] = restoreRequestID
            }
            save(isTest ? "testArmRequested" : "restoreRequested")
        }
        let result = await Whoop4AlarmPhysicalTest.run(
            armTest: { arm(isTest: true) },
            observeFire: {
                while Date() < testWake.addingTimeInterval(35), !Task.isCancelled {
                    guard model.ble.connectedPeripheralUUID == source,
                          defaults.data(forKey: "smartAlarm.runtime.configuration") == savedConfiguration
                    else { save("testInterrupted"); return false }
                    if let testSentAt,
                       defaults.integer(forKey: "alarm.lastReportedEpoch") == Int(testWake.timeIntervalSince1970),
                       defaults.string(forKey: "alarm.lastReportedRequestID") == report["testRequestID"] as? String,
                       defaults.string(forKey: "alarm.lastReportedDeviceID") == source,
                       let reportedAt = defaults.object(forKey: "alarm.lastReportedAt") as? TimeInterval,
                       reportedAt >= testSentAt {
                        report["testReadbackConfirmed"] = true
                    }
                    if let firedAt = defaults.object(forKey: "alarm.lastFiredAt") as? TimeInterval,
                       firedAt >= testWake.timeIntervalSince1970 - 2,
                       firedAt <= testWake.timeIntervalSince1970 + 35 {
                        report["firedAt"] = firedAt
                        save("scheduledEventObserved")
                        return true
                    }
                    guard defaults.integer(forKey: "alarm.lastArmSentEpoch") == Int(testWake.timeIntervalSince1970),
                          defaults.string(forKey: "alarm.lastArmRequestID") == report["testRequestID"] as? String
                    else { save("testSupersededByNormalSchedule"); return false }
                    try? await Task.sleep(for: .seconds(1))
                }
                save("fireNotObserved")
                return false
            },
            restore: { arm(isTest: false) },
            restoreConfirmed: {
                // Restoration still runs after task cancellation; do not leave the temporary time set.
                for _ in 0..<15 {
                    if model.ble.connectedPeripheralUUID != source
                        || defaults.data(forKey: "smartAlarm.runtime.configuration") != savedConfiguration { return false }
                    if let restoreRequestID, let restoreSentAt,
                       defaults.integer(forKey: "alarm.lastReportedEpoch") == Int(actualRestoreWake.timeIntervalSince1970),
                       defaults.string(forKey: "alarm.lastReportedDeviceID") == source,
                       defaults.string(forKey: "alarm.lastReportedRequestID") == restoreRequestID,
                       let reportedAt = defaults.object(forKey: "alarm.lastReportedAt") as? TimeInterval,
                       reportedAt >= restoreSentAt {
                        report["restoredReadbackEpoch"] = defaults.integer(forKey: "alarm.lastReportedEpoch")
                        return true
                    }
                    // Detached sleep remains bounded even if SwiftUI cancelled the caller's task.
                    await Task.detached { try? await Task.sleep(for: .seconds(1)) }.value
                }
                return false
            })
        report["fireObserved"] = result.fireObserved
        report["restoreConfirmed"] = result.restoreConfirmed
        report["savedMinutesAfter"] = model.behavior.smartAlarmMinutes
        report["savedConfigurationUnchanged"] = defaults.data(forKey: "smartAlarm.runtime.configuration") == savedConfiguration
        save("finished")
        await model.live.flushLogPersistence()
    }
}
#endif
