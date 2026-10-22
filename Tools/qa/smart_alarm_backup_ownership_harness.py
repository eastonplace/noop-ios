#!/usr/bin/env python3
"""Run exact alarm backup methods against an isolated, controllable notification center.

This deliberately imports no native app, UserNotifications, BLE, or BGTask runtime.
The extracted production members are inserted verbatim; collaborators and unrelated
alarm evaluation/evidence methods are fixtures. No preferences or permissions change.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile


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
        "private var currentSnapshot:",
        "private func configurationMayHaveChanged()",
        "private func schedule(_ snapshot:",
        "func reconcileImmediately(trigger:",
        "private func cancelGenerationWork()",
        "private func applyDisabled(snapshot:",
        "private func apply(\n",
        "private func scheduleBackupNotifications(snapshot:",
        "private func refreshBackupStatus()",
        "private func removeAllBackupNotifications(snapshot:",
        "private func removeAllBackupNotificationsIfCurrent(\n",
    ]
    extracted = {key: member(source, key) for key in type_signatures + signatures}
    template = pathlib.Path(__file__).with_name("smart_alarm_backup_ownership_fixture.swift").read_text()
    generated = template.replace("/* PRODUCTION_TYPES */", "\n\n".join(extracted[key] for key in type_signatures))
    generated = generated.replace("/* PRODUCTION_MEMBERS */", "\n\n".join(extracted[key] for key in signatures))
    swift_file = output / "SmartAlarmBackupOwnershipProbe.swift"
    swift_file.write_text(generated)
    metadata = {
        "source": str(source_path),
        "sha256": hashlib.sha256(source.encode()).hexdigest(),
        "verbatim_members": {key: hashlib.sha256(value.encode()).hexdigest() for key, value in extracted.items()},
        "collaborators": "fixture notification center, BLE arm sink, background scheduler, evidence/evaluator",
    }
    (output / "source.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(f"Exact source: {source_path}", flush=True)
    print(f"SHA256: {metadata['sha256']}", flush=True)
    print(f"Verbatim production members: {len(extracted)}", flush=True)
    binary = output / "smart-alarm-backup-ownership"
    compilation = subprocess.run([
        "swiftc", "-swift-version", "6", "-strict-concurrency=complete", "-warnings-as-errors",
        "-parse-as-library", "-module-cache-path", str(output / "compiler-cache"),
        str(swift_file), "-o", str(binary),
    ], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / "compiler.log").write_text(compilation.stdout)
    if compilation.returncode:
        print(compilation.stdout, end="")
        return compilation.returncode
    result = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / "run.log").write_text(result.stdout)
    print(result.stdout, end="")
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
