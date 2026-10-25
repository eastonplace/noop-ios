#!/usr/bin/env python3
"""Exercise the exact WHOOP 4 BLE range-update block with real protocol validation.

The notification block is extracted without changing its control flow. Small sinks
record marker, clock-fallback, historical-window, and visible-state mutations. This
does not require CoreBluetooth, Xcode, a Simulator, or a physical strap.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def block(source, marker):
    if source.count(marker) != 1:
        raise ValueError(f"Expected one range block: {marker}")
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    for end in range(opening + 1, len(source)):
        depth += (source[end] == "{") - (source[end] == "}")
        if depth == 0:
            return source[start:end + 1]
    raise ValueError(f"Unclosed range block: {marker}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Read BLE source from an immutable Git revision")
    parser.add_argument("--scratch-path", type=Path)
    args = parser.parse_args()
    path = "Strand/BLE/BLEManager.swift"
    ble = subprocess.check_output(["git", "show", f"{args.revision}:{path}"], cwd=ROOT, text=True) if args.revision else (ROOT / path).read_text()
    range_block = block(ble, "if frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue")
    methods = "\n".join([
        block(ble, "static func dataRangeNewestUnix(from frame:"),
        block(ble, "static func dataRangeOldestUnix(from frame:"),
    ])
    fixture = r'''
import Foundation
import WhoopProtocol

enum Domain { case connection }
enum TestCentre { static func active(_ domain: Domain) -> Bool { false } }
enum ConnectionTrace {
    static func clockDriftLine(oldestUnix: Int?, newestUnix: Int, wallNowUnix: Int) -> String { "" }
}
final class Backfiller {
    var sessionNewestUnix: Int?
    var sessionOldestUnix: Int?
}
final class LiveState {
    var rangeWrites = 0
    func setStrapRange(newestUnix: Int, oldestUnix: Int?) { rangeWrites += 1 }
    func append(log: String, domain: Domain) {}
}
final class BLEManager {
    var strapNewestTs: Int?
    var backfiller: Backfiller? = Backfiller()
    var state = LiveState()
    var fallbackChecks = 0
    var backgroundStateChanges = 0
    func notifyHistoricalSyncBackgroundStateDidChange() { backgroundStateChanges += 1 }
    func applyClockFallbackIfReady() { fallbackChecks += 1 }
    func log(_ message: String) {}
    __METHODS__
    func receive(_ frame: [UInt8]) {
        let parsed = parseFrame(frame, family: .whoop4)
        _ = parsed
        __RANGE_BLOCK__
    }
}

func bytes(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map {
        let a = hex.index(hex.startIndex, offsetBy: $0)
        let b = hex.index(a, offsetBy: 2)
        return UInt8(hex[a..<b], radix: 16)!
    }
}
func littleEndian(_ value: UInt32) -> [UInt8] {
    (0..<4).map { UInt8((value >> ($0 * 8)) & 0xff) }
}
var failures = 0
@MainActor
func check(_ ok: Bool, _ message: String) {
    if !ok { failures += 1; print("FAIL: \(message)") }
}
@MainActor
func assertRejected(_ frame: [UInt8], _ label: String) {
    let h = BLEManager()
    h.receive(frame)
    check(h.strapNewestTs == nil, "\(label) cannot become newest banked marker")
    check(h.backfiller?.sessionNewestUnix == nil && h.backfiller?.sessionOldestUnix == nil,
          "\(label) cannot change historical timestamp window")
    check(h.fallbackChecks == 0, "\(label) cannot trigger approximate clock fallback")
    check(h.state.rangeWrites == 0, "\(label) cannot publish strap range")
    check(h.backgroundStateChanges == 0, "\(label) cannot refresh background scheduling")
}

// Constructed command response uses the production builder and validator. No new
// firmware body layout is inferred: the test only needs a plausible scanner word.
let valid = frameFromPayload([7, 1, 0] + littleEndian(1_783_785_625),
                             type: 36, seq: 3, cmd: WhoopCommand.getDataRange.rawValue)
let parsed = parseFrame(valid, family: .whoop4)
check(parsed.envelopeOK && parsed.headerCRCOK == true && parsed.payloadCRCOK == true,
      "valid response fixture passes full integrity")
do {
    let h = BLEManager(); h.receive(valid)
    check(h.strapNewestTs != nil && h.backfiller?.sessionNewestUnix != nil,
          "valid response still updates range and history")
    check(h.fallbackChecks == 1 && h.state.rangeWrites == 1, "valid response still drives fallback and visible range")
    check(h.backgroundStateChanges == 1, "valid response refreshes background scheduling once")
}
var corrupt = valid
corrupt[corrupt.count - 1] ^= 1
check(parseFrame(corrupt, family: .whoop4).payloadCRCOK == false, "corrupt trailer fails payload integrity")
var reassembler = Reassembler(family: .whoop4)
check(reassembler.feed(corrupt) == [corrupt],
      "real reassembler emits CRC-invalid payload, so the BLE range seam must reject it")
assertRejected(corrupt, "payload CRC mismatch")
var header = valid
header[3] ^= 1
check(parseFrame(header, family: .whoop4).headerCRCOK == false, "corrupt header fails header integrity")
assertRejected(header, "header CRC mismatch")
let trailing = valid + [0]
check(!parseFrame(trailing, family: .whoop4).envelopeOK, "trailing byte fails envelope boundary")
assertRejected(trailing, "wrong envelope boundary")
assertRejected(Array(valid.dropLast(4)), "unverifiable payload")

// Preserve the repository's existing captured-range interpretation. Its type-48
// provenance requires a separate wire audit; this repair changes integrity only.
let captured = bytes("aa100057305d22009968526a083900001d2e2263")
let captureParsed = parseFrame(captured, family: .whoop4)
check(captureParsed.envelopeOK && captureParsed.headerCRCOK == true && captureParsed.payloadCRCOK == true,
      "existing captured fixture passes full integrity")
do {
    let h = BLEManager(); h.receive(captured)
    check(h.strapNewestTs == 1_783_785_625, "existing captured range keeps its decoded marker")
    check(h.backgroundStateChanges == 1, "captured valid range refreshes background scheduling once")
}
print("BLE range integrity: 6 scenarios, \(failures) failed assertions")
if failures != 0 { exit(1) }
'''.replace("__METHODS__", methods).replace("__RANGE_BLOCK__", range_block)
    with tempfile.TemporaryDirectory(prefix="noop-ble-range-") as temporary:
        package = Path(temporary)
        source = package / "Sources/BLERangeIntegrity"
        source.mkdir(parents=True)
        (source / "main.swift").write_text(fixture)
        protocol = json.dumps(str(ROOT / "Packages/WhoopProtocol"))
        (package / "Package.swift").write_text(f'''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "BLERangeIntegrity", platforms: [.macOS(.v14)],
    dependencies: [.package(path: {protocol})],
    targets: [.executableTarget(name: "BLERangeIntegrity",
        dependencies: [.product(name: "WhoopProtocol", package: "WhoopProtocol")])])
''')
        command = ["swift", "run", "--package-path", str(package), "--disable-sandbox", "--build-system", "native", "--jobs", "2"]
        if args.scratch_path:
            command += ["--scratch-path", str(args.scratch_path)]
        return subprocess.run(command).returncode


if __name__ == "__main__":
    raise SystemExit(main())
