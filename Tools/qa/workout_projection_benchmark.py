#!/usr/bin/env python3
"""Host microbenchmark of the actual workout projection cache and calculation sources.

This compiles production declarations, with only the app/ProfileStore object boundary
stubbed so it runs without UIKit. It measures a synthetic 1 Hz workout with a corrected
canonical tail before each projection, plus ten appended readings. It is not an iPhone,
UI, battery, Bluetooth, or whole-app benchmark. Every result is compared with a fresh
authoritative cache outside the measured interval. No real health data is used.

Usage:
  python3 Tools/qa/workout_projection_benchmark.py --swiftc /path/to/swiftc
  python3 Tools/qa/workout_projection_benchmark.py --ref <base-sha> --swiftc ...
"""

import argparse
import json
from pathlib import Path
import platform
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def source(path, ref):
    if ref:
        return subprocess.check_output(
            ["git", "show", f"{ref}:{path}"], cwd=ROOT, text=True
        )
    return (ROOT / path).read_text()


def declaration(text, marker):
    """Copy a balanced production declaration, never reimplement its arithmetic."""
    start = text.index(marker)
    opening = text.index("{", start)
    depth = 0
    for pos in range(opening, len(text)):
        if text[pos] == "{":
            depth += 1
        elif text[pos] == "}":
            depth -= 1
            if depth == 0:
                return text[start : pos + 1]
    raise ValueError(f"Unbalanced declaration: {marker}")


BOUNDARIES = r"""
public enum StrainBand { case light, moderate, high, allOut }
enum LiveStrainState { case building, scored(Double) }
@MainActor final class ProfileStore {
    var weightKg = 73.0
    var heightCm = 178.0
    var age = 36
    var sex = "nonbinary"
    var hrMax = 190
}
enum AppModel {
    @MainActor final class ActiveWorkout {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let sport = "Running"
        var samples: [HRSample] = []
        var pauseLedger = WorkoutPauseLedger()
        var liveStrainState = LiveStrainState.building
        var frozenAt: Date? = nil
        func clockEnd(at now: Date) -> Date { frozenAt ?? now }
    }
}
"""


BENCHMARK = r"""
@main struct Benchmark {
    @MainActor static func main() throws {
        var rows: [[String: Any]] = []
        let profile = ProfileStore()
        for count in [3_600, 21_600] {
            for withPauses in [false, true] {
                let workout = AppModel.ActiveWorkout()
                let origin = Int(workout.start.timeIntervalSince1970)
                // Two active stretches separated by a real three-minute pause.
                workout.samples = (0..<count).map { offset in
                    let gap = withPauses && offset >= count / 2 ? 180 : 0
                    return HRSample(ts: origin + offset + gap, bpm: 100 + offset % 80)
                }
                if withPauses {
                    workout.pauseLedger = WorkoutPauseLedger(intervals: [
                        .init(start: Double(origin + count / 2 - 1),
                              end: Double(origin + count / 2 + 180))
                    ])
                }
                let cache = WorkoutLiveProjectionCache()
                _ = cache.state(workout: workout, profile: profile)
                var times: [Double] = []
                var checksum = 0
                for iteration in 0..<220 {
                    let last = workout.samples.count - 1
                    let timestamp = workout.samples[last].ts
                    workout.samples[last] = HRSample(ts: timestamp, bpm: 180 - iteration % 70)
                    for offset in 1...10 {
                        workout.samples.append(HRSample(ts: timestamp + offset,
                                                       bpm: 105 + (iteration + offset) % 70))
                    }
                    let begin = DispatchTime.now().uptimeNanoseconds
                    let actual = cache.state(workout: workout, profile: profile)
                    let elapsed = DispatchTime.now().uptimeNanoseconds - begin
                    // Warm up 20 iterations; keep validation outside the timed interval.
                    if iteration >= 20 { times.append(Double(elapsed) / 1_000_000) }
                    let expected = WorkoutLiveProjectionCache().state(workout: workout, profile: profile)
                    precondition(actual.calories == expected.calories, "calorie mismatch")
                    precondition(actual.zoneSeconds == expected.zoneSeconds, "zone mismatch")
                    precondition(actual.hrTrace == expected.hrTrace, "trace mismatch")
                    checksum += actual.calories ?? 0
                }
                times.sort()
                rows.append([
                    "initial_samples": count, "paused": withPauses,
                    "measured_iterations": times.count, "warmup_iterations": 20,
                    "median_ms": (times[99] + times[100]) / 2,
                    "p95_ms": times[189], "checksum": checksum,
                    "equivalence_checks": 220
                ])
            }
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ref", help="Read production sources from this Git commit instead of working tree")
    parser.add_argument("--swiftc", default="swiftc")
    args = parser.parse_args()
    detector = source("Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutDetector.swift", args.ref)
    streams = source("Packages/WhoopProtocol/Sources/WhoopProtocol/Streams.swift", args.ref)
    pauses = source("Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutPauseLedger.swift", args.ref)
    scale = source("Packages/StrandDesign/Sources/StrandDesign/StrainScale.swift", args.ref)
    state = source("StrandiOS/Widgets/LiveActivityController.swift", args.ref)
    parts = [
        "import Foundation\nimport Dispatch",
        declaration(streams, "public struct HRSample:"),
        declaration(detector, "public struct UserProfile:"),
        declaration(detector, "public enum Calories {"),
        # Copy the actual gap constant without pulling in unrelated detection dependencies.
        "enum WorkoutDetector { " + next(
            line.strip() for line in detector.splitlines() if "public static let mergeGapS:" in line
        ) + " }",
        declaration(pauses, "public struct WorkoutPauseLedger:"),
        declaration(scale, "public enum StrainScale {"),
        declaration(state, "struct WorkoutLiveActivityState {"),
        BOUNDARIES,
    ]
    for path in [
        "Packages/StrandAnalytics/Sources/StrandAnalytics/HRZones.swift",
        "Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutLiveProjectionAccumulator.swift",
        "StrandiOS/Widgets/WorkoutLiveProjectionCache.swift",
    ]:
        text = source(path, args.ref)
        parts.append("\n".join(
            line for line in text.splitlines()
            if not line.startswith("import ") and line not in ("#if os(iOS)", "#endif")
        ))
    parts.append(BENCHMARK)
    version = subprocess.check_output([args.swiftc, "--version"], text=True).strip()
    with tempfile.TemporaryDirectory(prefix="noop-projection-benchmark-") as directory:
        swift = Path(directory) / "Benchmark.swift"
        binary = Path(directory) / "benchmark"
        swift.write_text("\n\n".join(parts))
        subprocess.run([
            args.swiftc, "-O", "-parse-as-library", "-module-cache-path", str(Path(directory) / "modules"),
            str(swift), "-o", str(binary),
        ], check=True)
        rows = json.loads(subprocess.check_output([str(binary)], text=True))
    print(json.dumps({
        "source_ref": args.ref or "working-tree", "compiler": version,
        "host": platform.platform(), "optimization": "-O",
        "scope": "production cache/accumulator host microbenchmark; synthetic app object boundary",
        "results": rows,
    }, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
