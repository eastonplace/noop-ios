#!/usr/bin/env python3
"""Run real deep-data scheduling methods with a recording transport, without CoreBluetooth.

The method bodies and preference reader come from the selected source revision. The test double
models an already-ready secure link. It records outbound commands and never accesses hardware.
"""
from pathlib import Path
import argparse
import plistlib
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def source(path, revision):
    if revision:
        return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


def method(text, name):
    start = text.find(f"    public func {name}(")
    if start < 0:
        return None
    opening = text.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        if text[cursor] == "{":
            depth += 1
        elif text[cursor] == "}":
            depth -= 1
        cursor += 1
    return text[start:cursor]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision", help="Test an immutable Git revision instead of the working tree")
    args = parser.parse_args()
    ble = source("Strand/BLE/BLEManager.swift", args.revision)
    preference = source("Strand/BLE/PuffinExperiment.swift", args.revision)
    enable = method(ble, "enableWhoop5DeepData")
    assert enable, "Production enable method was not found"
    revoke = method(ble, "reconcileWhoop5DeepDataPermission")
    # Before the repair, switching OFF had no callback. A no-op represents that existing behavior.
    revoke = revoke or "public func reconcileWhoop5DeepDataPermission(_ enabled: Bool) {}"
    swift = r'''
import Foundation
struct Flag { let name: String; let value: UInt8 }
enum Whoop5Config {
    // Byte encoding and the actual flag allowlist are tested by WhoopProtocol golden tests.
    static let enableR22Sequence = (0..<16).map { Flag(name: "flag\($0)", value: 0x32) }
    static func payloadBody(name: String, value: UInt8) -> [UInt8] { [value] }
}
struct Whoop5R22Attempt { let sessionID: String }
enum Family { case whoop4, whoop5 }
struct Model { var deviceFamily = Family.whoop5 }
final class State { var connected = true; var worn = true; var r22FlagsAccepted = 0 }
enum Command { case setConfig }
enum WriteType { case withResponse }
final class Manager {
    var selectedModel = Model()
    var state = State()
    var whoop5SecureReady = true
    var currentWhoop5SecureSessionID: String? = "session-a"
    var whoop5R22Attempt: Whoop5R22Attempt?
    var whoop5DeepDataEnableGeneration: UInt64 = 0
    var sent: [String] = []
    func log(_ text: String) {}
    func send(_ command: Command, payload: [UInt8], writeType: WriteType, responseLabel: String?) {
        // The production send allowlist rechecks consent immediately before writing.
        if PuffinExperiment.deepDataEnabled { sent.append(responseLabel ?? "") }
    }
''' + enable + "\n" + revoke + r'''
}
@main struct Harness {
    static func main() {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        let key = PuffinExperiment.deepDataKey
        defaults.removePersistentDomain(forName: domain)
        defer { defaults.removePersistentDomain(forName: domain) }
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failures += 1 }
        }
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(1.6)) }
        for malformed: Any in ["true", "YES", 1, 2, 1.0] {
            defaults.set(malformed, forKey: key)
            check(!PuffinExperiment.deepDataEnabled, "malformed preference rejected: \(malformed)")
        }
        defaults.removeObject(forKey: key)
        defaults.register(defaults: [key: true])
        check(!PuffinExperiment.deepDataEnabled, "registered fallback is not explicit consent")
        defaults.set(false, forKey: key)
        let disabled = Manager()
        disabled.enableWhoop5DeepData()
        settle()
        check(disabled.sent.isEmpty, "OFF sends no config commands")
        defaults.set(true, forKey: key)
        let normal = Manager()
        normal.enableWhoop5DeepData()
        settle()
        check(normal.sent.count == 16, "explicit ON still permits the existing sequence")
        let revoked = Manager()
        revoked.enableWhoop5DeepData()
        defaults.set(false, forKey: key)
        revoked.reconcileWhoop5DeepDataPermission(false)
        defaults.set(true, forKey: key)
        settle()
        check(revoked.sent.isEmpty, "OFF cancels queued sequence even if permission is granted again")
        let replaced = Manager()
        replaced.enableWhoop5DeepData()
        replaced.enableWhoop5DeepData()
        settle()
        check(replaced.sent.count == 16, "new attempt replaces old queued sequence")
        let staleSession = Manager()
        staleSession.enableWhoop5DeepData()
        staleSession.currentWhoop5SecureSessionID = "session-b"
        settle()
        check(staleSession.sent.isEmpty, "old session cannot emit queued config commands")
        let otherFamily = Manager()
        otherFamily.selectedModel.deviceFamily = .whoop4
        otherFamily.enableWhoop5DeepData()
        settle()
        check(otherFamily.sent.isEmpty, "WHOOP4 stays outside the experiment")
        print("Deep-data harness: \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="noop-deep-data-harness-") as scratch:
        directory = Path(scratch)
        contents = directory / "ConsentHarness.app/Contents"
        binary = contents / "MacOS/ConsentHarness"
        binary.parent.mkdir(parents=True)
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": f"com.noop.deep-data-harness.{directory.name}",
            "CFBundleExecutable": "ConsentHarness",
        }))
        (directory / "PuffinExperiment.swift").write_text(preference)
        (directory / "Harness.swift").write_text(swift)
        cache = str(directory / "module-cache")
        subprocess.run(["swiftc", "-module-cache-path", cache,
                        str(directory / "PuffinExperiment.swift"), str(directory / "Harness.swift"),
                        "-o", str(binary)], check=True)
        return subprocess.run([str(binary)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
