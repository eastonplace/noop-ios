#!/usr/bin/env python3
"""Run real debug-export paths with real thermal analytics and persisted model labels.

Only the async Repository/store boundary and unrelated REM/source sections are fixtures.
The diagnostic methods, model enum, thermal funnel, conversion, and anchor are exact source.
Preferences use a process-only volatile domain; no app settings or strap state are written.
"""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def block(source, marker):
    start = source.index(marker)
    cursor = source.index("{", start) + 1
    depth = 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--revision", help="Read the diagnostic from this Git revision")
    parser.add_argument("--scratch-path", type=Path)
    args = parser.parse_args()
    path = "Strand/System/DebugDataDiagnostics.swift"
    diagnostic = (subprocess.check_output(["git", "show", f"{args.revision}:{path}"],
                                         cwd=ROOT, text=True)
                  if args.revision else (ROOT / path).read_text())
    read = lambda path: (ROOT / path).read_text()
    streams = read("Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift")
    analytics = read("Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift")
    sleep = read("Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStager.swift")
    methods = [block(diagnostic, marker) for marker in [
        "static func strapStateLines()", "@MainActor static func dynamicLines(repo:",
        "private static func relTime(", "private static func tzLine()",
        "private static func dayStamp(",
    ]]
    helper = "private static func selectedModel()"
    if helper in diagnostic:
        methods.append(block(diagnostic, helper))
    constants = "\n".join(re.search(r"^\s*(?:public )?static let " + name + r"\b[^\n]*",
                                    analytics, re.MULTILINE).group()
                          for name in ["minSkinTempSamples", "skinTempMinC", "skinTempMaxC"])
    production = [
        "import Foundation\nimport CoreBluetooth",
        block(read("Packages/WhoopProtocol/Sources/WhoopProtocol/DeviceFamily.swift"),
              "public enum DeviceFamily:"),
        block(read("Strand/BLE/WhoopModel.swift"), "public enum WhoopModel:"),
        *[block(streams, marker) for marker in ["public struct HRSample:",
            "public struct SkinTempSample:", "public struct GravitySample:",
            "public struct RespSample:", "public func skinTempCelsius(",
            "public enum Whoop4SkinTemp"]],
        block(sleep, "public struct StageSegment:"),
        block(sleep, "public struct SleepSession:"),
        block(read("Packages/StrandAnalytics/Sources/StrandAnalytics/HRValidity.swift"),
              "public enum HRValidity"),
        "enum AnalyticsEngine {\n" + constants + "\n"
        + block(analytics, "public struct SkinTempFunnelDiagnostic:") + "\n"
        + block(analytics, "public static func skinTempFunnel(") + "\n}",
        "enum DebugDataDiagnostics {\n" + "\n".join(methods) + r'''
        @MainActor static func workoutSourceLines(repo: Repository) async -> [String] { [] }
        @MainActor static func dailyDataLines(repo: Repository) async -> [String] { [] }
        @MainActor static func recoveryReadinessLines(repo: Repository) async -> [String] { [] }
        static func alarmLines() -> [String] { [] }
        }
''',
    ]
    fixture = r'''
struct RemDiagnostic { let summary: String }
enum SleepStager {
    static func remFunnelDiagnostic(start: Int, end: Int, grav: [GravitySample],
                                   hr: [HRSample], rr: [Int], resp: [RespSample]) -> RemDiagnostic? { nil }
}
struct Day { let day: String; let totalSleepMin: Double?; let recovery: Double? }
struct Night {
    let startTs: Int; let endTs: Int; let efficiency: Double?
    let restingHr: Int?; let avgHrv: Double?
}
@MainActor final class FixtureStore {
    let samples: [SkinTempSample]
    var queriedDeviceIds: [String] = []
    init(_ samples: [SkinTempSample]) { self.samples = samples }
    func skinTempSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [SkinTempSample] {
        queriedDeviceIds.append(deviceId)
        return Array(samples.filter { from <= $0.ts && $0.ts <= to }.prefix(limit))
    }
    func gravitySamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [GravitySample] {
        queriedDeviceIds.append(deviceId); return []
    }
    func rrIntervals(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [Int] {
        queriedDeviceIds.append(deviceId); return []
    }
    func respSamples(deviceId: String, from: Int, to: Int, limit: Int) async throws -> [RespSample] {
        queriedDeviceIds.append(deviceId); return []
    }
}
@MainActor final class Repository {
    let deviceId = "history-owner-A"
    let days: [Day] = []
    let store: FixtureStore?
    let night: Night
    init(raw: Int, available: Bool = true) {
        let start = Int(Date().timeIntervalSince1970) - 3_600
        night = Night(startTs: start, endTs: start + 600, efficiency: 0.9, restingHr: 60, avgHrv: 40)
        store = available ? FixtureStore((0..<300).map { SkinTempSample(ts: start + $0, raw: raw) }) : nil
    }
    func storeHandle() async -> FixtureStore? { store }
    func sleepSessions(from: Int, to: Int, limit: Int) async -> [Night] { [night] }
    func hrSamples(from: Int, to: Int, limit: Int) async -> [HRSample] {
        (0..<300).map { HRSample(ts: night.startTs + $0, bpm: 60) }
    }
}
@main struct Run {
    @MainActor static func main() async {
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        var assertions = 0, failures = 0
        func check(_ ok: Bool, _ label: String) {
            assertions += 1
            if !ok { failures += 1; print("FAIL: \(label)") }
        }
        let cases: [(String?, Int, String, String, String?)] = [
            ("WHOOP 5.0 / MG", 3057, "WHOOP 5.0 / MG", "30.57°C", nil),
            ("WHOOP 4.0", 1290, "WHOOP 4.0", "33.00°C", "anchor=1290"),
            ("whoop5", 3057, "WHOOP 5.0 / MG", "30.57°C", nil),
            ("whoop4", 1290, "WHOOP 4.0", "33.00°C", "anchor=1290"),
            (nil, 1290, "unknown (never paired)", "33.00°C", "anchor=1290"),
            ("unrecognized-model", 1290, "unknown (never paired)", "33.00°C", "anchor=1290"),
            ("", 1290, "unknown (never paired)", "33.00°C", "anchor=1290"),
        ]
        for (raw, sample, model, mean, anchor) in cases {
            var domain: [String: Any] = ["lastSyncedAt": 0, "sync.lastWriteOkAt": 0,
                                       "sync.lastWriteStalledAt": 0, "backup.lastRestoreAt": 0]
            if let raw { domain["selectedWhoopModel"] = raw }
            defaults.setVolatileDomain(domain, forName: UserDefaults.argumentDomain)
            let label = raw.map { "'\($0)'" } ?? "missing"
            let repo = Repository(raw: sample)
            let lines = await DebugDataDiagnostics.dynamicLines(repo: repo)
            check(lines.contains("Model:       \(model)"), "\(label): export reports persisted model")
            let thermal = lines.first { $0.hasPrefix("skin-temp-funnel:") } ?? ""
            check(thermal.contains("kept 300/300 (mean=\(mean))"),
                  "\(label): export uses the correct conversion, got \(thermal)")
            check(anchor.map { thermal.contains($0) } ?? !thermal.contains("anchor="),
                  "\(label): only WHOOP4 uses a learned ADC anchor")
            check(repo.store?.queriedDeviceIds.count == 5
                    && repo.store?.queriedDeviceIds.allSatisfy { $0 == "history-owner-A" } == true,
                  "\(label): diagnostic keeps Repository sample ownership")
        }
        defaults.setVolatileDomain(["selectedWhoopModel": "WHOOP 5.0 / MG"],
                                  forName: UserDefaults.argumentDomain)
        let offline = await DebugDataDiagnostics.dynamicLines(repo: Repository(raw: 3057, available: false))
        check(offline.contains("Model:       WHOOP 5.0 / MG")
              && offline.contains("(on-device store not open yet)"),
              "offline export reports canonical model without requiring a store")
        print("Debug diagnostic family: 8 scenarios, \(assertions) assertions, \(failures) failures")
        if failures != 0 { exit(1) }
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="noop-debug-family-") as temporary:
        scratch = args.scratch_path or Path(temporary)
        scratch.mkdir(parents=True, exist_ok=True)
        source = scratch / "DiagnosticFamily.swift"
        source.write_text("\n".join(production) + fixture)
        binary = scratch / "diagnostic-family"
        subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", "-j", "2",
                        "-module-cache-path", str(scratch / "module-cache"), str(source),
                        "-o", str(binary)], check=True)
        return subprocess.run([str(binary)]).returncode


if __name__ == "__main__":
    raise SystemExit(main())
