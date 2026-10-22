#!/usr/bin/env python3
"""Run exact central connection-result callbacks against recording Bluetooth objects.

Only OS transport and unrelated session setup are stubbed. The entire production
didConnect/didFailToConnect callbacks, pin test, and admission policy are extracted.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

from test_ble_data_range_integrity import block

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision")
    args = parser.parse_args()
    path = "Strand/BLE/BLEManager.swift"
    source = subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=ROOT, text=True) if args.revision else (ROOT / path).read_text()
    declarations = [
        "public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral)",
        re.search(r"public func centralManager\(_ central: CBCentralManager,\s+didFailToConnect peripheral: CBPeripheral,\s+error: Error\?\)", source).group(),
        "private func isPreferredPeripheral(_ p: CBPeripheral)",
    ]
    if "nonisolated static func shouldAcceptConnectionResult(" in source:
        declarations.append("nonisolated static func shouldAcceptConnectionResult(")
    methods = "\n".join(block(source, marker) for marker in declarations)
    fixture = r'''
import Foundation
enum Domain { case connection }
enum TestCentre { static func active(_ domain: Domain) -> Bool { false } }
enum Family { case whoop4, whoop5 }
struct Model { var deviceFamily: Family = .whoop4 }
enum RadioState { case connected, connecting, disconnected }
@MainActor final class CBPeripheral {
    let identifier: UUID
    var state: RadioState
    init(_ id: UUID, _ state: RadioState = .connected) { identifier = id; self.state = state }
}
@MainActor final class CBCentralManager {
    var canceled: [UUID] = []
    func cancelPeripheralConnection(_ p: CBPeripheral) { canceled.append(p.identifier) }
}
struct CBError: Error {
    enum Code { case peerRemovedPairingInformation }
    let code: Code
}
struct Epitaph { mutating func connected(nowUptimeNanoseconds: UInt64) {} }
struct PostBondLoop {
    var tripped = false
    let quickTimeoutWindow: TimeInterval = 10
    mutating func reset() { tripped = false }
}
struct Policy {
    enum Event { case failedConnect }
    enum Action { case retry(after: TimeInterval), connectNow, connectNowHoldingHandshake(for: TimeInterval), pause }
    var attempts = 0
    mutating func action(after: Event, appActive: Bool, knownTarget: Bool, forcedDelay: TimeInterval?) -> Action {
        attempts += 1; return .retry(after: 3)
    }
}
@MainActor final class State {
    var connected = false
    var lastSyncError: String? = "existing"
    var reconnectGuide: String?
    func markConnected() { connected = true }
    func append(log: String, domain: Domain) {}
}
@MainActor final class BLEManager {
    var peripheral: CBPeripheral?
    var restoredPeripheral: CBPeripheral?
    var preferredPeripheralUUID: UUID?
    var intentionalDisconnect = false
    var autoReconnectPaused = false
    var state = State()
    var connectGeneration = 0
    var connectedPeripheralUUID: String?
    var linkUpAt: Date?
    var linkAcknowledgedHistory = false
    var linkEpitaphState = Epitaph()
    var strapNewestTs: Int? = 42
    var postBondLoop = PostBondLoop()
    var lastDataAt: Date?
    var connectAttemptStartedAt: Date?
    var selectedModel = Model()
    var connReconnectCount = 0
    var reconnectPolicy = Policy()
    var isAppActive = true
    var admissions = 0
    var discoveries = 0
    var reconnects = 0
    var scanCancels = 0
    var retryCancels = 0
    var clockResets = 0
    func cancelScanFallback() { scanCancels += 1 }
    func cancelPendingReconnect() { retryCancels += 1 }
    func preparePeripheral(_ p: CBPeripheral) { peripheral = p }
    func admitConnectionGeneration(_ p: CBPeripheral) { admissions += 1; connectGeneration += 1 }
    func resetClockRecoveryForConnection() { clockResets += 1 }
    func log(_ message: String) {}
    func discoverPrimaryServices(on p: CBPeripheral) { discoveries += 1 }
    func startWhoop5DiscoveryIfNeeded(on p: CBPeripheral) { discoveries += 1 }
    func connErrorToken(_ error: Error?) -> String { "unknown" }
    func pendingReconnectTarget(dropped: CBPeripheral) -> CBPeripheral? { peripheral }
    func performReconnect(_ action: Policy.Action, target: CBPeripheral?, secureRecovery: Bool) { reconnects += 1 }
    __METHODS__
}
var failures = 0
@MainActor func check(_ ok: Bool, _ message: String) {
    if !ok { failures += 1; print("FAIL: \(message)") }
}
let a = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
let b = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
@MainActor func prepared(_ id: UUID, pin: UUID? = nil, radio: RadioState = .connected) -> BLEManager {
    let h = BLEManager(); h.peripheral = CBPeripheral(id, radio); h.preferredPeripheralUUID = pin
    return h
}
do {
    let h = prepared(a); let c = CBCentralManager()
    h.centralManager(c, didConnect: h.peripheral!)
    check(h.admissions == 1 && h.discoveries == 1 && h.state.connected, "first unbound prepared target is accepted")
}
do {
    let h = prepared(b, pin: b); let c = CBCentralManager()
    h.centralManager(c, didConnect: h.peripheral!)
    check(h.admissions == 1 && h.connectedPeripheralUUID == b.uuidString, "pinned reconnect target is accepted")
}
do {
    let h = prepared(b, pin: b); h.state.connected = true; h.connectedPeripheralUUID = b.uuidString
    let c = CBCentralManager(); h.centralManager(c, didConnect: CBPeripheral(a))
    check(h.peripheral?.identifier == b && h.connectedPeripheralUUID == b.uuidString, "late other-target connect cannot replace active identity")
    check(h.admissions == 0 && h.discoveries == 0 && h.clockResets == 0, "late other-target connect cannot replace generation, clock, or discovery")
    check(h.scanCancels == 0 && h.retryCancels == 0, "late other-target connect cannot cancel current work")
    check(c.canceled == [a], "late other-target connect cancels only stale transport")
}
do {
    let h = prepared(a, pin: b); let c = CBCentralManager()
    h.centralManager(c, didConnect: h.peripheral!)
    check(h.admissions == 0 && !h.state.connected && c.canceled == [a], "pin changed during connect revokes old target")
}
do {
    let h = prepared(a); h.intentionalDisconnect = true; let c = CBCentralManager()
    h.centralManager(c, didConnect: h.peripheral!)
    check(h.admissions == 0 && !h.state.connected && c.canceled == [a], "late connect cannot undo user disconnect")
}
do {
    let h = prepared(b, pin: b, radio: .connecting); let c = CBCentralManager()
    h.centralManager(c, didFailToConnect: CBPeripheral(a, .disconnected), error: nil)
    check(h.reconnects == 0 && h.reconnectPolicy.attempts == 0, "other-target failure cannot schedule current retry")
}
do {
    let h = prepared(b, pin: b); h.state.connected = true; let c = CBCentralManager()
    h.centralManager(c, didFailToConnect: CBPeripheral(a, .disconnected), error: CBError(code: .peerRemovedPairingInformation))
    check(h.state.reconnectGuide == nil, "other-target failure cannot publish stale pairing guide")
}
do {
    let h = prepared(b, pin: b); h.state.connected = true; let c = CBCentralManager()
    h.centralManager(c, didFailToConnect: h.peripheral!, error: CBError(code: .peerRemovedPairingInformation))
    check(h.state.reconnectGuide == nil && h.reconnects == 0, "late failure cannot change healthy same-target link")
}
do {
    let h = prepared(b, pin: b, radio: .disconnected); let c = CBCentralManager()
    h.centralManager(c, didFailToConnect: h.peripheral!, error: nil)
    check(h.reconnects == 1 && h.reconnectPolicy.attempts == 1, "current failed attempt retains retry path")
}
do {
    let h = prepared(b, pin: b, radio: .disconnected); let c = CBCentralManager()
    h.centralManager(c, didFailToConnect: h.peripheral!, error: CBError(code: .peerRemovedPairingInformation))
    check(h.state.reconnectGuide != nil && h.reconnects == 0, "current pairing failure retains its guide")
}
print("BLE connection ownership: 10 scenarios, \(failures) failed assertions")
if failures != 0 { exit(1) }
'''.replace("__METHODS__", methods)
    with tempfile.TemporaryDirectory(prefix="noop-ble-connection-") as temporary:
        directory = Path(temporary)
        swift = directory / "main.swift"
        swift.write_text(fixture)
        binary = directory / "BLEConnectionOwnership"
        compile_result = subprocess.run(["swiftc", "-swift-version", "6", "-module-cache-path", "/private/tmp/noop-review-ble-module-cache", str(swift), "-o", str(binary)])
        return compile_result.returncode or subprocess.run([str(binary)]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
