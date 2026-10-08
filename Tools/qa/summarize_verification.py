#!/usr/bin/env python3
"""Summarize logs produced by run_integration_verification.sh without hiding raw evidence."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return ""


def last_xctest_totals(text: str) -> tuple[int | None, int | None, int | None]:
    matches = list(re.finditer(
        r"Executed\s+(\d+)\s+tests?,\s+with\s+(\d+)\s+failures?"
        r"(?:\s+\((\d+)\s+unexpected\))?",
        text,
        re.IGNORECASE,
    ))
    if not matches:
        passed = re.search(r"Test run with\s+(\d+)\s+tests? passed", text, re.IGNORECASE)
        if passed:
            return int(passed.group(1)), 0, 0
        return None, None, None
    match = matches[-1]
    total = int(match.group(1))
    failed = int(match.group(2))
    skipped_matches = re.findall(r"(\d+)\s+tests? skipped", text, re.IGNORECASE)
    skipped = int(skipped_matches[-1]) if skipped_matches else 0
    return max(0, total - failed - skipped), failed, skipped


def xcresult_totals(path: Path) -> tuple[int | None, int | None, int | None]:
    try:
        data = json.loads(read(path))
    except (json.JSONDecodeError, OSError):
        return None, None, None

    def first_int(keys: tuple[str, ...]) -> int | None:
        stack = [data]
        while stack:
            node = stack.pop()
            if isinstance(node, dict):
                for key in keys:
                    value = node.get(key)
                    if isinstance(value, int):
                        return value
                stack.extend(node.values())
            elif isinstance(node, list):
                stack.extend(node)
        return None

    passed = first_int(("passedTests", "passedTestCount"))
    failed = first_int(("failedTests", "failedTestCount"))
    skipped = first_int(("skippedTests", "skippedTestCount"))
    return passed, failed, skipped


def status_rows(path: Path) -> list[tuple[str, int]]:
    rows: list[tuple[str, int]] = []
    for line in read(path).splitlines()[1:]:
        pieces = line.split("\t")
        if len(pieces) == 2:
            try:
                rows.append((pieces[0], int(pieces[1])))
            except ValueError:
                pass
    return rows


def format_totals(totals: tuple[int | None, int | None, int | None]) -> str:
    passed, failed, skipped = totals
    if passed is None or failed is None or skipped is None:
        return "not parsed; inspect raw log"
    return f"{passed} passed / {failed} failed / {skipped} skipped"


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: summarize_verification.py <artifact-directory>")
    root = Path(sys.argv[1])
    metadata = dict(
        line.split("=", 1) for line in read(root / "integration-metadata.txt").splitlines() if "=" in line
    )
    statuses = status_rows(root / "command-status.tsv")
    status_map = dict(statuses)

    print("# NOOP integration verification")
    print()
    print(f"- Integration SHA: `{metadata.get('integration_sha', 'unknown')}`")
    print(f"- Branch: `{metadata.get('branch', 'unknown')}`")
    print(f"- Captured UTC: `{metadata.get('captured_at_utc', 'unknown')}`")
    print(f"- Xcode: `{read(root / 'xcode-version.txt').strip() or 'unavailable'}`")
    print(f"- Simulator: `{read(root / 'selected-simulator.txt').strip() or 'unavailable'}`")
    warning_count = read(root / "compiler-warning-count.txt").strip() or "unknown"
    print(f"- Compiler warning lines: **{warning_count}**")
    print()

    print("## Gate status")
    print()
    print("| Gate | Result | Exit |")
    print("|---|---:|---:|")
    for gate, code in statuses:
        print(f"| `{gate}` | {'PASS' if code == 0 else 'FAIL'} | {code} |")
    print()

    ios_totals = xcresult_totals(root / "xcode-test-summary.json")
    if ios_totals[0] is None:
        ios_totals = last_xctest_totals(read(root / "xcodebuild-test.txt"))
    print("## Test totals")
    print()
    print(f"- `NOOPiOSTests`: {format_totals(ios_totals)}")
    for package_log in sorted((root / "packages").glob("*.txt")):
        package = package_log.stem
        totals = last_xctest_totals(read(package_log))
        state = "PASS" if status_map.get(f"package:{package}") == 0 else "FAIL"
        print(f"- `{package}`: {format_totals(totals)} — {state}")
    print()

    print("## Commands")
    print()
    print("```text")
    print(read(root / "build-command.txt").strip())
    print(read(root / "test-command.txt").strip())
    print("```")
    print()
    print("Raw audit, build, test, xcresult, simulator, package, warning, and Git-status evidence remains in this directory.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
