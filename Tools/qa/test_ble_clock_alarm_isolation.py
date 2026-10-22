#!/usr/bin/env python3
"""Run exact BLE source-change/reset methods against small hardware-free dependencies.

The real protocol transaction is retained. Method extraction fails closed; this
fixture does not maintain a second implementation of the production control flow.
Requires the macOS Swift toolchain, so CI runs it in the native job.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def method(source, declaration, required=True):
    if declaration not in source and not required:
        return ""
    if source.count(declaration) != 1:
        raise ValueError(f"Expected one declaration: {declaration}")
    start = source.index(declaration)
    opening = source.index("{", start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1]
    raise ValueError(f"Unclosed declaration: {declaration}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", type=Path)
    args = parser.parse_args()
    ble = (ROOT / "Strand/BLE/BLEManager.swift").read_text()
    clock = (ROOT / "Strand/Collect/ClockCorrelation.swift").read_text()
    methods = "\n".join([
        method(ble, "public func setActiveDeviceId("),
        method(ble, "private func resetClockRecoveryForConnection("),
        # Before the repair this helper is absent; the actual source-change path
        # still compiles, so behavioral assertions can establish the regression.
        method(ble, "private func resetClockRecoveryState(", required=False),
        method(ble, "private func cancelWhoop4AlarmTransaction("),
    ])
    policy = method(clock, "static func canRetainReferenceForSourceChange(")
    fixture = r'''
import Foundation
import WhoopProtocol

struct ClockRef: Equatable { let device: Int; let wall: Int }
enum Family { case whoop4, whoop5 }
struct Model { var deviceFamily: Family = .whoop4 }
enum LinkState { case connected, disconnected }
struct Peripheral { let identifier: UUID; var state: LinkState = .connected }
final class LiveState {
    var connected = true
    func clearBatterySamples() {}
}
final class Sink { var clockRef: ClockRef?; var deviceId = "original" }
struct Recovery { var resets = 0; mutating func reset() { resets += 1 } }
struct Request { let id: UUID }
enum SmartAlarmEvidenceStore { static func invalidateReadback(requestID: UUID) {} }
final class Router { var clears = 0; func clearAlarmReadback() { clears += 1 } }
enum ClockCorrelation { __POLICY__ }

final class Harness {
    var deviceId = "original"
    var selectedModel = Model()
    var state = LiveState()
    var peripheral: Peripheral?
    var preferredPeripheralUUID: UUID?
    var clockRef: ClockRef?
    var clockRefPeripheralID: UUID?
    var clockRefIsApproximate = false
    var collector: Sink? = Sink()
    var backfiller: Sink? = Sink()
    var historicalSourceEpoch = 0
    var clockRecoveryTimeout: DispatchWorkItem?
    var clockRecovery = Recovery()
    var clockRequested = true
    var whoop4AlarmTimer: DispatchWorkItem?
    var whoop4AlarmTransaction: Whoop4AlarmTransaction?
    var whoop4AlarmRequest: Request?
    var router = Router()

    __METHODS__

    func resetConnection() { resetClockRecoveryForConnection() }
}

var failures = 0
@MainActor
func check(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}
let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
@MainActor
func makeHarness() -> Harness {
    let h = Harness()
    h.peripheral = Peripheral(identifier: a)
    h.preferredPeripheralUUID = a
    let owner = Whoop4AlarmTransaction.Owner(peripheralID: a, connectGeneration: 7)
    var alarm = Whoop4AlarmTransaction(owner: owner, clockEpoch: 1_792_612_800, wakeEpoch: 1_792_641_600)
    check(alarm.issue(owner: owner, requestSequence: 5) != nil, "arm is in flight")
    h.whoop4AlarmTransaction = alarm
    h.whoop4AlarmRequest = Request(id: owner.id)
    return h
}

do {
    let h = makeHarness()
    let alarm = h.whoop4AlarmTransaction
    h.setActiveDeviceId("adopted")
    check(h.whoop4AlarmTransaction == alarm, "same physical adoption without a clock keeps in-flight owner and state")
    check(h.whoop4AlarmRequest?.id == alarm?.owner.id, "adoption keeps readback ownership")
    check(h.clockRecovery.resets == 1 && !h.clockRequested, "adoption resets missing clock recovery")
    check(h.router.clears == 0, "adoption does not clear alarm readback")
}
do {
    let h = makeHarness()
    let alarm = h.whoop4AlarmTransaction
    h.clockRef = ClockRef(device: 10, wall: 20)
    h.clockRefPeripheralID = b
    h.backfiller?.clockRef = h.clockRef
    h.setActiveDeviceId("adopted")
    check(h.clockRef == nil && h.clockRefPeripheralID == nil, "foreign clock is discarded")
    check(h.backfiller?.clockRef == nil, "foreign backfill clock is discarded")
    check(h.whoop4AlarmTransaction == alarm, "discarding foreign clock keeps current physical alarm")
}
do {
    let h = makeHarness()
    h.clockRef = ClockRef(device: 10, wall: 20)
    h.clockRefPeripheralID = a
    h.clockRefIsApproximate = true
    h.resetConnection()
    check(h.whoop4AlarmTransaction == nil && h.whoop4AlarmRequest == nil, "connection reset cancels alarm and readback")
    check(h.router.clears == 1, "connection reset clears router readback")
    check(h.clockRef == nil && !h.clockRequested, "connection reset clears approximate clock recovery")
}
do {
    let h = makeHarness()
    // SourceCoordinator tears down the old link before changing physical target.
    h.resetConnection()
    h.preferredPeripheralUUID = b
    h.setActiveDeviceId("different-strap")
    check(h.whoop4AlarmTransaction == nil, "physical switch cannot revive the old alarm")
    check(h.deviceId == "different-strap", "physical switch updates persistence owner")
}
do {
    let h = makeHarness()
    let alarm = h.whoop4AlarmTransaction
    h.clockRef = ClockRef(device: 10, wall: 20)
    h.clockRefPeripheralID = a
    h.setActiveDeviceId("adopted")
    check(h.clockRef != nil && h.clockRecovery.resets == 0, "matching physical clock is retained")
    check(h.whoop4AlarmTransaction == alarm, "matching-clock adoption also keeps the alarm")
}
print("Clock/alarm isolation: 5 scenarios, \(failures) failed assertions")
if failures != 0 { exit(1) }
'''.replace("__METHODS__", methods).replace("__POLICY__", policy)

    with tempfile.TemporaryDirectory(prefix="noop-clock-alarm-") as temporary:
        package = Path(temporary)
        source = package / "Sources/ClockAlarmIsolation"
        source.mkdir(parents=True)
        (source / "main.swift").write_text(fixture)
        protocol = json.dumps(str(ROOT / "Packages/WhoopProtocol"))
        (package / "Package.swift").write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ClockAlarmIsolation", platforms: [.macOS(.v14)],
    dependencies: [.package(path: {protocol})],
    targets: [.executableTarget(name: "ClockAlarmIsolation",
        dependencies: [.product(name: "WhoopProtocol", package: "WhoopProtocol")])])
''')
        command = ["swift", "run", "--package-path", str(package), "--build-system", "native", "--jobs", "2"]
        if args.scratch_path:
            command += ["--scratch-path", str(args.scratch_path)]
        return subprocess.run(command).returncode


if __name__ == "__main__":
    raise SystemExit(main())
