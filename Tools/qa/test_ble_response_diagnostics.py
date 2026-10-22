#!/usr/bin/env python3
"""Run the exact reboot response branch with real family-aware frame decoding."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from test_ble_data_range_integrity import block

ROOT = Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision")
    parser.add_argument("--scratch-path", type=Path)
    args = parser.parse_args()
    path = "Strand/BLE/FrameRouter.swift"
    source = subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=ROOT, text=True) if args.revision else (ROOT / path).read_text()
    branch = block(source, 'if let cmd = parsed.cmdName, cmd.hasPrefix("REBOOT_STRAP")')
    result_reader = block(source, "static func commandResultByte(in frame:")
    # Retain the real handler's admission guards. The other routing branches and
    # platform state are irrelevant to this diagnostic branch and are not copied.
    guard_start = source.index("guard parsed.ok else { return }")
    guard_end = source.index("// #987:", guard_start)
    guards = source[guard_start:guard_end]
    fixture = r'''
import Foundation
import WhoopProtocol
final class State {
    var logs: [String] = []
    func append(log: String) { logs.append(log) }
}
final class FrameRouter {
    var family: DeviceFamily = .whoop4
    let state = State()
    static let whoop4InnerOffset = 4
    __READER__
    func receive(_ frame: [UInt8]) {
        let parsed = parseFrame(frame, family: family)
        __GUARDS__
        __BRANCH__
    }
}
func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let a = hex.index(hex.startIndex, offsetBy: $0)
        let b = hex.index(a, offsetBy: 2)
        return UInt8(hex[a..<b], radix: 16)!
    }
}
var failures = 0
@MainActor
func check(_ ok: Bool, _ message: String) {
    if !ok { failures += 1; print("FAIL: \(message)") }
}
@MainActor
func response(_ family: DeviceFamily, _ frame: [UInt8], result: String, label: String) {
    let r = FrameRouter(); r.family = family; r.receive(frame)
    check(r.state.logs.count == 1, "\(label) produces one reboot response diagnostic")
    check(r.state.logs.first?.contains("result=\(result)") == true, "\(label) reads its actual result byte")
    check(!r.state.logs.contains { $0.contains("accepted") || $0.contains("REJECTED") },
          "\(label) does not invent command success semantics")
}
response(.whoop4, frameFromPayload([7, 0], type: 36, cmd: 29), result: "0x00", label: "WHOOP 4 reboot")
response(.whoop5, puffinCommandFrame(cmd: 29, seq: 1, payload: [7, 1], type: 36),
         result: "0x01", label: "WHOOP 5 base response")
response(.whoop5, puffinCommandFrame(cmd: 29, seq: 1, payload: [7, 3], type: 38),
         result: "0x03", label: "MG puffin response")
response(.whoop4, frameFromPayload([7, 2], type: 36, cmd: 32), result: "0x02", label: "WHOOP 4 power cycle")
response(.whoop5, puffinCommandFrame(cmd: 29, seq: 1, payload: [], type: 36),
         result: "none", label: "short WHOOP 5 response")
do {
    let r = FrameRouter(); r.family = .whoop5
    // Token-free real battery reply from Whoop5CommandResponseTests. A captured
    // other-command response must retain its own meaning and never log a reboot.
    let battery = bytes("aa0110000100208124931a02012f000000000000f1c132cb")
    let parsed = parseFrame(battery, family: .whoop5)
    check(parsed.payloadCRCOK == true && parsed.cmdName?.hasPrefix("GET_BATTERY_LEVEL") == true,
          "captured battery fixture retains valid command matching")
    r.receive(battery)
    check(r.state.logs.isEmpty, "captured other-command response cannot become reboot diagnostic")
}
do {
    let r = FrameRouter(); r.family = .whoop5
    r.receive(puffinCommandFrame(cmd: 29, seq: 1, payload: [7, 1], type: 40))
    check(r.state.logs.isEmpty, "non-response packet with the same byte cannot become reboot diagnostic")
}
do {
    let r = FrameRouter(); r.family = .whoop5
    var corrupt = puffinCommandFrame(cmd: 29, seq: 1, payload: [7, 1], type: 36)
    corrupt[corrupt.count - 1] ^= 1
    r.receive(corrupt)
    r.receive(Array(corrupt.prefix(8)))
    check(r.state.logs.isEmpty, "CRC-invalid and truncated replies produce no reboot result")
}
print("Reboot response diagnostics: 8 scenarios, \(failures) failed assertions")
if failures != 0 { exit(1) }
'''.replace("__READER__", result_reader).replace("__GUARDS__", guards).replace("__BRANCH__", branch)
    with tempfile.TemporaryDirectory(prefix="noop-ble-response-") as temporary:
        package = Path(temporary)
        source_dir = package / "Sources/BLEResponseDiagnostics"
        source_dir.mkdir(parents=True)
        (source_dir / "main.swift").write_text(fixture)
        protocol = json.dumps(str(ROOT / "Packages/WhoopProtocol"))
        (package / "Package.swift").write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BLEResponseDiagnostics", platforms: [.macOS(.v14)],
    dependencies: [.package(path: {protocol})],
    targets: [.executableTarget(name: "BLEResponseDiagnostics",
        dependencies: [.product(name: "WhoopProtocol", package: "WhoopProtocol")])])
''')
        command = ["swift", "run", "--package-path", str(package), "--disable-sandbox", "--build-system", "native", "--jobs", "2"]
        if args.scratch_path:
            command += ["--scratch-path", str(args.scratch_path)]
        return subprocess.run(command).returncode


if __name__ == "__main__":
    raise SystemExit(main())
