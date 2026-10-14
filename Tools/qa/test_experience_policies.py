#!/usr/bin/env python3
"""Run the actual Foundation-only presentation policies without an Apple SDK.

This is a supplemental test lane. It does not build SwiftUI or replace NOOPiOSTests.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [ROOT / "StrandiOS/Coach/CoachExperiencePolicy.swift",
           ROOT / "Strand/Screens/WorkoutTimelinePolicy.swift"]
TESTS = [ROOT / "StrandiOSTests/CoachExperiencePolicyTests.swift",
         ROOT / "StrandiOSTests/WorkoutTimelinePolicyTests.swift"]


def main() -> int:
    for path in SOURCES + TESTS:
        if not path.is_file():
            print(f"FAIL: required production/test source is missing: {path.relative_to(ROOT)}")
            return 1
    with tempfile.TemporaryDirectory(prefix="noop-experience-") as temp:
        package = Path(temp)
        source = package / "Sources/ExperiencePolicyHarness"
        tests = package / "Tests/ExperiencePolicyHarnessTests"
        source.mkdir(parents=True)
        tests.mkdir(parents=True)
        for path in SOURCES:
            shutil.copy2(path, source / path.name)
        for path in TESTS:
            shutil.copy2(path, tests / path.name)
        (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ExperiencePolicyHarness", targets: [
    .target(name: "ExperiencePolicyHarness"),
    .testTarget(name: "ExperiencePolicyHarnessTests", dependencies: ["ExperiencePolicyHarness"])
])
''')
        return subprocess.run(["swift", "test", "--package-path", str(package)], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
