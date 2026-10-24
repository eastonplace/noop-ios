#!/usr/bin/env python3
"""Run exact alarm backup methods against an isolated notification center.

Production alarm dependencies and extracted runtime members compile verbatim. Only
platform resources and unrelated runtime collaborators are fixtures. The positive
probe retains all 19 ownership assertions; two compiled mutations must fail the
stale-cleanup assertions. No preferences or permissions change.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import tempfile


EXPECTED_CHECKS = 19


def member(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=pathlib.Path, default=pathlib.Path(__file__).resolve().parents[2])
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    output = args.output or pathlib.Path(tempfile.mkdtemp(prefix="noop-alarm-ownership-"))
    output.mkdir(parents=True, exist_ok=True)
    source_path = repo / "StrandiOS/App/SmartAlarmRuntimeController.swift"
    source = source_path.read_text()
    type_signatures = ["struct SmartAlarmRuntimeSnapshot:", "struct SmartAlarmRuntimeGeneration:"]
    signatures = [
        "static func backupIdentifiers(",
        "private static func backupIdentifiers(snapshot:",
        "private var currentSnapshot:",
        "private func configurationMayHaveChanged()",
        "private func schedule(_ snapshot:",
        "func reconcileImmediately(trigger:",
        "private func cancelGenerationWork()",
        "private func applyDisabled(snapshot:",
        "private func apply(\n",
        "private func scheduleEndpointRearm(snapshot:",
        "private func scheduleBackupNotifications(snapshot:",
        "private func refreshBackupStatus()",
        "private func removeAllBackupNotifications(snapshot:",
        "private func removeAllBackupNotificationsIfCurrent(\n",
    ]
    extracted = {key: member(source, key) for key in type_signatures + signatures}
    template = pathlib.Path(__file__).with_name("smart_alarm_backup_ownership_fixture.swift").read_text()
    generated = template.replace("/* PRODUCTION_TYPES */", "\n\n".join(extracted[key] for key in type_signatures))
    generated = generated.replace("/* PRODUCTION_MEMBERS */", "\n\n".join(extracted[key] for key in signatures))

    # Compile exact pure production dependencies instead of mirroring their behavior in the fixture.
    dependency_paths = [
        "Packages/StrandAnalytics/Sources/StrandAnalytics/SmartAlarmEvaluator.swift",
        "Packages/StrandAnalytics/Sources/StrandAnalytics/SmartAlarmSchedule.swift",
        "Packages/StrandAnalytics/Sources/StrandAnalytics/WakeAlarmPlan.swift",
    ]
    dependency_directory = output / "production_dependencies"
    dependency_directory.mkdir(exist_ok=True)
    dependencies = []
    dependency_metadata = {}
    for path in dependency_paths:
        text = (repo / path).read_text()
        destination = dependency_directory / pathlib.Path(path).name
        destination.write_text(text)
        dependencies.append(destination)
        dependency_metadata[path] = hashlib.sha256(text.encode()).hexdigest()
    threshold_path = repo / "Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift"
    threshold = next(line.strip() for line in threshold_path.read_text().splitlines()
                     if line.strip().startswith("public static let bandYellowMax:"))
    threshold_file = dependency_directory / "RecoveryScorerThreshold.swift"
    threshold_file.write_text("enum RecoveryScorer {\n    " + threshold + "\n}\n")
    dependencies.append(threshold_file)
    metadata = {
        "source": str(source_path),
        "sha256": hashlib.sha256(source.encode()).hexdigest(),
        "verbatim_members": {key: hashlib.sha256(value.encode()).hexdigest() for key, value in extracted.items()},
        "production_dependencies": dependency_metadata,
        "dependency_swift_language_version": 5,
        "runtime_swift_language_version": 6,
        "production_recovery_threshold": {
            "source": str(threshold_path), "member": threshold,
            "sha256": hashlib.sha256(threshold.encode()).hexdigest(),
        },
        "collaborators": "fixture notification center, in-memory settings, BLE arm sink, background scheduler, evidence IO",
    }
    (output / "source.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Exact source: {source_path}", flush=True)
    print(f"SHA256: {metadata['sha256']}", flush=True)
    print(f"Verbatim production members: {len(extracted)}; dependencies: {len(dependencies)}", flush=True)
    print(f"Evidence directory: {output}", flush=True)

    # StrandAnalytics's tools-version 5.9 package compiles in Swift 5 mode. Keep the app runtime
    # strict Swift 6 while importing a real Swift 5 dependency module, as the native build does.
    module_compilation = subprocess.run([
        "swiftc", "-swift-version", "5", "-parse-as-library", "-emit-library", "-emit-module",
        "-module-name", "StrandAnalytics", "-module-cache-path", str(output / "compiler-cache"),
        "-emit-module-path", str(dependency_directory / "StrandAnalytics.swiftmodule"),
        *(str(path) for path in dependencies), "-o", str(dependency_directory / "libStrandAnalytics.dylib"),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
    (output / "production_dependencies.compiler.log").write_text(module_compilation.stdout)
    if module_compilation.returncode:
        print("Production dependency module compilation failed")
        print(module_compilation.stdout, end="")
        return 1

    def compile_and_run(name: str, program: str) -> tuple[bool, subprocess.CompletedProcess[str] | None]:
        swift_file = output / f"{name}.swift"
        swift_file.write_text(program)
        binary = output / name
        compilation = subprocess.run([
            "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
            "-parse-as-library", "-module-cache-path", str(output / "compiler-cache"),
            "-I", str(dependency_directory), "-L", str(dependency_directory), "-lStrandAnalytics",
            "-Xlinker", "-rpath", "-Xlinker", str(dependency_directory),
            str(swift_file), "-o", str(binary),
        ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
        (output / f"{name}.compiler.log").write_text(compilation.stdout)
        if compilation.returncode:
            print(f"{name}: compilation failed; this is not a valid negative control")
            print(compilation.stdout, end="")
            return False, None
        result = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=60)
        (output / f"{name}.run.log").write_text(result.stdout)
        return True, result

    compiled, result = compile_and_run("SmartAlarmBackupOwnershipProbe", generated)
    if not compiled or result is None:
        return 1
    print(result.stdout, end="")
    expected_summary = f"{EXPECTED_CHECKS} checks; 0 failures"
    if result.returncode or expected_summary not in result.stdout:
        print(f"Positive probe must execute every assertion and report {expected_summary!r}")
        return 1

    generation_line = r'if let generation { generationBase += "-g\(generation)" }'
    cleanup_line = "center.removePendingNotificationRequests(withIdentifiers: operationIdentifiers)"
    current_generation_cleanup = (
        "center.removePendingNotificationRequests(withIdentifiers: Self.backupIdentifiers("
        "snapshot: self.currentSnapshot, configurationID: self.configurationID, generation: self.generation.value))"
    )
    if generated.count(generation_line) != 1 or generated.count(cleanup_line) != 2:
        raise AssertionError("The production mutation boundaries changed; update explicit negative controls")
    controls = {
        "negative_without_generation_ids": (
            generated.replace(generation_line, "_ = generation").replace("var generationBase =", "let generationBase =", 1),
            "FAIL: stale add completion cannot delete the replacement backup",
        ),
        "negative_cleanup_uses_current_generation": (
            generated.replace(cleanup_line, current_generation_cleanup),
            "FAIL: stale pending callback cannot delete the replacement backup",
        ),
    }
    control_results = {}
    for name, (program, expected_failure) in controls.items():
        compiled, result = compile_and_run(name, program)
        summary = re.search(r"(\d+) checks; (\d+) failures", result.stdout) if result else None
        caught = (compiled and result is not None and result.returncode == 1 and summary is not None
                  and int(summary.group(1)) == EXPECTED_CHECKS and int(summary.group(2)) > 0
                  and expected_failure in result.stdout)
        control_results[name] = {
            "compiled": compiled, "caught": caught,
            "returncode": result.returncode if result else None,
            "expected_failed_assertion": expected_failure,
        }
        if not caught:
            print(f"FAIL: {name} must compile, execute all assertions, and expose its stale-cleanup regression")
            if result:
                print(result.stdout, end="")
            (output / "negative_controls.json").write_text(json.dumps(control_results, indent=2) + "\n")
            return 1
        print(f"PASS: compiled negative control {name} was caught by {expected_failure.removeprefix('FAIL: ')}")
    (output / "negative_controls.json").write_text(json.dumps(control_results, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
