#!/usr/bin/env python3
"""Reject tracked local device extraction artifacts.

These files can contain physical-device identifiers, app-container paths, and health data.
The audit reads Git's index, so ignored but untracked local evidence remains allowed.
"""
from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def tracked_paths() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    return [item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def main() -> int:
    violations = [
        path for path in tracked_paths()
        if "/raw-extraction/" in f"/{path}" or path.endswith("/raw-extraction")
    ]
    if violations:
        print("privacy_artifact_contract_audit: FAIL", file=sys.stderr)
        for path in violations:
            print(f"- tracked device extraction: {path}", file=sys.stderr)
        return 1
    print("privacy_artifact_contract_audit: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
