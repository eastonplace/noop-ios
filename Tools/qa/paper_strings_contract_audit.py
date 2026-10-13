#!/usr/bin/env python3
"""Reject legacy Paper pillar keys (Charge / Effort) in the localization catalogs.

ORG-8: this check used to be an XCTest that always skipped on iOS, because the raw .xcstrings sources are
not bundled into the test host. It only reads the catalogs, so it runs here instead, with no simulator.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

CATALOGS = (
    "Strand/Resources/Localizable.xcstrings",
    "Packages/StrandDesign/Sources/StrandDesign/Resources/Localizable.xcstrings",
)

LEGACY_PILLAR = re.compile(r"(^|[^A-Za-z])(Charge|Effort|EFFORT)([^A-Za-z]|$)")


def violations_in(root: Path, relative_path: str) -> list[str]:
    path = root / relative_path
    if not path.is_file():
        return [f"missing localization catalog: {relative_path}"]
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        return [f"unreadable localization catalog {relative_path}: {error}"]
    strings = catalog.get("strings") if isinstance(catalog, dict) else None
    if not isinstance(strings, dict) or not strings:
        return [f"empty localization catalog: {relative_path}"]
    return [
        f"legacy Paper pillar key in {relative_path}: {key!r}"
        for key in sorted(strings)
        if LEGACY_PILLAR.search(key)
    ]


def audit(root: Path = ROOT) -> list[str]:
    found: list[str] = []
    for relative_path in CATALOGS:
        found.extend(violations_in(root, relative_path))
    return found


def main() -> int:
    found = audit()
    if found:
        print("paper_strings_contract_audit: FAIL", file=sys.stderr)
        for line in found:
            print(f"- {line}", file=sys.stderr)
        return 1
    print("paper_strings_contract_audit: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
