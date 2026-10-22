#!/usr/bin/env python3
"""Exercise production WHOOP5 enqueue/issue and permission bindings without Bluetooth or SwiftUI.

Only the peripheral, command framing, callback completion, and view shell are substituted. The queue
record, enqueue method, issue method, enable method, cancellation method, and binding setters are
extracted unchanged. This includes delayed writes waiting behind a slow, unrelated ATT operation.
"""
from pathlib import Path
import argparse
import plistlib
import subprocess
import tempfile

from deep_data_permission_harness import ROOT, source


def declaration(text, prefix):
    start = text.find(prefix)
    if start < 0:
        return None
    opening = text.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (text[cursor] == "{") - (text[cursor] == "}")
        cursor += 1
    return text[start:cursor]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision")
    args = parser.parse_args()
    ble = source("Strand/BLE/BLEManager.swift", args.revision)
    settings = source("Strand/Screens/SettingsView.swift", args.revision)
    centre = source("Strand/Screens/TestCentreView.swift", args.revision)
    chunks = [declaration(ble, f"    {prefix}") for prefix in [
        "private struct QueuedWhoop5ConfirmedWrite",
        "private func writeValue(",
        "private func issueNextWhoop5ConfirmedWriteIfPossible(",
        "public func enableWhoop5DeepData(",
        "public func reconcileWhoop5DeepDataPermission(",
    ]]
    assert all(chunks), "A production queue/deep-data declaration was not found"
    fallback = "private var deepDataPermissionBinding: Binding<Bool> { Binding(get: { self.deepDataEnabled }, set: { self.deepDataEnabled = $0 }) }"
    binding_prefix = "    private var deepDataPermissionBinding: Binding<Bool>"
    settings_binding = declaration(settings, binding_prefix) or fallback
    centre_binding = declaration(centre, binding_prefix) or fallback
    swift = r'''
import Foundation
struct Flag { let name: String; let value: UInt8 }
enum Whoop5Config {
    static let enableR22Sequence = (0..<16).map { Flag(name: "flag\($0)", value: 0x32) }
    static func payloadBody(name: String, value: UInt8) -> [UInt8] { [value] }
}
struct Whoop5SecureSessionID: Equatable {
    let peripheralID: UUID; let connectGeneration: Int; let attemptEpoch: UInt64
}
struct Whoop5R22Attempt { let sessionID: Whoop5SecureSessionID }
enum Family { case whoop4, whoop5 }
struct Model { var deviceFamily = Family.whoop5 }
final class State {
    var connected = true; var worn = true; var r22FlagsAccepted = 0; var lastSyncError: String?
}
enum WhoopCommand: UInt8 { case setConfig = 0x78 }
enum CBCharacteristicWriteType { case withResponse, withoutResponse }
final class CBCharacteristic { let uuid: UUID; init(_ uuid: UUID) { self.uuid = uuid } }
final class CBPeripheral {
    let identifier = UUID()
    var issued: [Data] = []
    var onWrite: (() -> Void)?
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType) {
        issued.append(data); onWrite?()
    }
}
final class Central { func cancelPeripheralConnection(_ peripheral: CBPeripheral) {} }
enum HistoricalTransportTrace { static func ackIssued() {} }
enum ConfirmedWritePurpose { case genericCommand, historicalAck }
struct ConfirmedCommandWrite {
    let id: UUID; let peripheralID: UUID; let connectGeneration: Int
    let secureAttemptEpoch: UInt64?; let purpose: ConfirmedWritePurpose
    let command: UInt8; let requestSequence: UInt8
}
final class Manager {
    static let whoop5CmdWriteChar = UUID()
    static let whoop5ConfirmedWriteTimeout: TimeInterval = 8
    var selectedModel = Model()
    var state = State()
    var whoop5SecureReady = true
    var currentWhoop5SecureSessionID: Whoop5SecureSessionID?
    var whoop5R22Attempt: Whoop5R22Attempt?
    var whoop5DeepDataEnableGeneration: UInt64 = 0
    var confirmedCommandWrites: [ConfirmedCommandWrite] = []
    private var queuedWhoop5ConfirmedWrites: [QueuedWhoop5ConfirmedWrite] = []
    var activeWhoop5ConfirmedWriteID: UUID?
    var whoop5ConfirmedWriteTimeout: DispatchWorkItem?
    var pendingWhoop5HapticResponses: Set<UInt8> = []
    let hardware = CBPeripheral()
    var peripheral: CBPeripheral?
    var cmdCharacteristic: CBCharacteristic?
    let central = Central()
    var autoComplete = true
    var sentCommands: [UInt8] { hardware.issued.compactMap { $0.first } }
    var queueCount: Int { queuedWhoop5ConfirmedWrites.count }
    init() {
        peripheral = hardware
        cmdCharacteristic = CBCharacteristic(Self.whoop5CmdWriteChar)
        currentWhoop5SecureSessionID = Whoop5SecureSessionID(
            peripheralID: hardware.identifier, connectGeneration: 1, attemptEpoch: 1)
        hardware.onWrite = { [weak self] in
            if self?.autoComplete == true { DispatchQueue.main.async { self?.completeActive() } }
        }
    }
    func log(_ text: String) {}
    func failWhoop5SecureSession(_ id: Whoop5SecureSessionID, reason: String) {}
    func invalidateHistoricalBackfill(reason: String) {}
    func makeConfirmedCommandWrite(purpose: ConfirmedWritePurpose, peripheral: CBPeripheral,
                                   characteristic: CBCharacteristic, command: UInt8,
                                   requestSequence: UInt8) -> ConfirmedCommandWrite {
        ConfirmedCommandWrite(id: UUID(), peripheralID: peripheral.identifier,
            connectGeneration: currentWhoop5SecureSessionID?.connectGeneration ?? 0,
            secureAttemptEpoch: currentWhoop5SecureSessionID?.attemptEpoch, purpose: purpose,
            command: command, requestSequence: requestSequence)
    }
    func send(_ command: WhoopCommand, payload: [UInt8], writeType: CBCharacteristicWriteType,
              responseLabel: String?) {
        // Framing/initial send admission are separately covered; no hardware write occurs here.
        guard PuffinExperiment.deepDataEnabled else { return }
        enqueue(command.rawValue, payload: payload)
    }
    func enqueue(_ command: UInt8, payload: [UInt8] = []) {
        writeValue(Data([command] + payload), to: cmdCharacteristic!, on: hardware, type: .withResponse,
                   confirmedPurpose: command == 0x17 ? .historicalAck : .genericCommand,
                   command: command, requestSequence: UInt8(truncatingIfNeeded: hardware.issued.count))
    }
    func completeActive() {
        if let id = activeWhoop5ConfirmedWriteID { confirmedCommandWrites.removeAll { $0.id == id } }
        activeWhoop5ConfirmedWriteID = nil
        whoop5ConfirmedWriteTimeout?.cancel()
        whoop5ConfirmedWriteTimeout = nil
        issueNextWhoop5ConfirmedWriteIfPossible()
    }
    func drainQueue() {
        for _ in 0..<100 where activeWhoop5ConfirmedWriteID != nil || queueCount > 0 { completeActive() }
    }
''' + "\n".join(chunks) + r'''
}
struct Binding<Value> {
    let get: () -> Value; let set: (Value) -> Void
    var wrappedValue: Value { get { get() } nonmutating set { set(newValue) } }
}
struct AppModel { let ble: Manager }
class ViewHost {
    let model: AppModel
    init(_ manager: Manager) { model = AppModel(ble: manager) }
    var deepDataEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: PuffinExperiment.deepDataKey) }
        set { UserDefaults.standard.set(newValue, forKey: PuffinExperiment.deepDataKey) }
    }
}
final class SettingsHost: ViewHost {
''' + settings_binding + r'''
    func setPermission(_ value: Bool) { deepDataPermissionBinding.wrappedValue = value }
}
final class CentreHost: ViewHost {
''' + centre_binding + r'''
    func setPermission(_ value: Bool) { deepDataPermissionBinding.wrappedValue = value }
}
@main struct Harness {
    static func main() {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        func consent(_ value: Bool) { defaults.set(value, forKey: PuffinExperiment.deepDataKey) }
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            print("\(condition ? "PASS" : "FAIL") \(label)")
            if !condition { failures += 1 }
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(1.4)) }
        for malformed: Any in ["true", "YES", 1, 2, 1.0] {
            defaults.set(malformed, forKey: PuffinExperiment.deepDataKey)
            check(!PuffinExperiment.deepDataEnabled, "malformed consent rejected: \(malformed)")
        }
        defaults.removeObject(forKey: PuffinExperiment.deepDataKey)
        defaults.register(defaults: [PuffinExperiment.deepDataKey: true])
        check(!PuffinExperiment.deepDataEnabled, "registered fallback does not authorize config")
        consent(false)
        let disabled = Manager(); disabled.enableWhoop5DeepData(); settle()
        check(disabled.sentCommands.isEmpty, "permission OFF emits no config")
        consent(true)
        let otherFamily = Manager(); otherFamily.selectedModel.deviceFamily = .whoop4
        otherFamily.enableWhoop5DeepData(); settle()
        check(otherFamily.sentCommands.isEmpty, "WHOOP4 stays outside deep-data experiment")
        let earlyRevoked = Manager()
        earlyRevoked.enableWhoop5DeepData()
        consent(false); earlyRevoked.reconcileWhoop5DeepDataPermission(false); consent(true); settle()
        check(earlyRevoked.sentCommands.isEmpty, "OFF to ON cancels delayed pre-enqueue callbacks")
        let normal = Manager()
        normal.enableWhoop5DeepData(); settle()
        check(normal.sentCommands.filter { $0 == 0x78 }.count == 16, "normal sequence traverses actual serial queue")

        let blocked = Manager(); blocked.autoComplete = false
        blocked.enqueue(0x17) // Unrelated active history ACK holds the ATT lane.
        blocked.enableWhoop5DeepData(); settle()
        check(blocked.queueCount == 16, "enable writes wait behind existing ATT operation")
        blocked.enqueue(0x77); blocked.enqueue(0x42); blocked.enqueue(0x17)
        consent(false); blocked.reconcileWhoop5DeepDataPermission(false); consent(true)
        check(blocked.queueCount == 3, "OFF removes only unsent deep-data queue entries")
        blocked.drainQueue()
        check(blocked.sentCommands == [0x17, 0x77, 0x42, 0x17], "broadcast alarm and history writes survive revocation")

        let strict = Manager(); strict.autoComplete = false
        strict.enqueue(0x17); strict.enableWhoop5DeepData(); settle()
        consent(false) // Deliberately bypass UI cancellation: issue-time guard must still stop writes.
        strict.drainQueue()
        check(strict.sentCommands == [0x17], "issue time rechecks strict permission")
        consent(true)

        let replaced = Manager(); replaced.autoComplete = false
        replaced.enqueue(0x17); replaced.enableWhoop5DeepData(); settle()
        replaced.enableWhoop5DeepData(); settle(); replaced.drainQueue()
        check(replaced.sentCommands.filter { $0 == 0x78 }.count == 16, "issue time rejects older queued enable generation")

        let insecure = Manager(); insecure.autoComplete = false
        insecure.enqueue(0x17); insecure.enableWhoop5DeepData(); settle()
        insecure.whoop5SecureReady = false; insecure.drainQueue()
        check(insecure.sentCommands == [0x17], "issue time rechecks secure readiness")

        let stale = Manager(); stale.autoComplete = false
        stale.enqueue(0x17); stale.enableWhoop5DeepData(); settle()
        stale.currentWhoop5SecureSessionID = Whoop5SecureSessionID(
            peripheralID: stale.hardware.identifier, connectGeneration: 2, attemptEpoch: 2)
        stale.drainQueue()
        check(stale.sentCommands == [0x17], "existing secure owner fence rejects stale queue")

        let issued = Manager(); issued.autoComplete = false
        issued.enableWhoop5DeepData(); settle()
        check(issued.sentCommands == [0x78], "first deep-data ATT write is already issued")
        consent(false); issued.reconcileWhoop5DeepDataPermission(false); issued.drainQueue()
        check(issued.sentCommands == [0x78], "OFF leaves issued write irreversible and prevents remainder")
        consent(true)

        let settingsManager = Manager(); let settingsHost = SettingsHost(settingsManager)
        settingsHost.setPermission(false); settingsHost.setPermission(true)
        check(settingsManager.whoop5DeepDataEnableGeneration == 1, "Settings binding revokes synchronously before coalesced ON")
        let centreManager = Manager(); let centreHost = CentreHost(centreManager)
        centreHost.setPermission(false); centreHost.setPermission(true)
        check(centreManager.whoop5DeepDataEnableGeneration == 1, "Test Centre binding revokes synchronously before coalesced ON")
''' + f'''        check({str(settings.count("isOn: deepDataPermissionBinding") == 2).lower()}, "both Settings toggles use synchronous binding")
        check({str(centre.count("isOn: deepDataPermissionBinding") == 1).lower()}, "Test Centre toggle uses synchronous binding")
''' + r'''
        print("Confirmed queue harness: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="noop-confirmed-queue-") as scratch:
        directory = Path(scratch)
        contents = directory / "QueueHarness.app/Contents"
        binary = contents / "MacOS/QueueHarness"
        binary.parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": f"com.noop.confirmed-queue.{directory.name}",
            "CFBundleExecutable": "QueueHarness",
        }))
        (directory / "PuffinExperiment.swift").write_text(source("Strand/BLE/PuffinExperiment.swift", args.revision))
        (directory / "Harness.swift").write_text(swift)
        subprocess.run(["swiftc", "-module-cache-path", str(directory / "module-cache"),
                        str(directory / "PuffinExperiment.swift"), str(directory / "Harness.swift"),
                        "-o", str(binary)], check=True)
        return subprocess.run([str(binary)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
