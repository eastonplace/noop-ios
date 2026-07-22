#!/usr/bin/env python3
"""Fast source-level guardrails for NOOP's iPhone-only performance branch.

This is intentionally a pre-build audit, not a replacement for Xcode. It catches regressions that are
cheap and deterministic to identify from source before package resolution and simulator compilation.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def swift_sources() -> list[Path]:
    roots = [ROOT / "Strand", ROOT / "StrandiOS", ROOT / "StrandiOSShared", ROOT / "StrandiOSWidgets", ROOT / "Packages"]
    files: list[Path] = []
    for root in roots:
        if root.exists():
            files.extend(path for path in root.rglob("*.swift") if ".build" not in path.parts)
    return sorted(files)


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []

    trace_interpolation = re.compile(
        r'PerformanceTrace\.begin\s*\(\s*"(?:(?:\\.)|[^"\\])*\\\(',
        re.MULTILINE,
    )
    zero_argument_refresh = re.compile(r"\b(?:self\.)?repo\.refresh\(\s*\)")
    direct_days_refresh = re.compile(r"\b(?:self\.)?repo\.refresh\(\s*days\s*:")
    active_workout_value = re.compile(r"\bstruct\s+ActiveWorkout\b")
    active_workout_reference = re.compile(r"\bfinal\s+class\s+ActiveWorkout\b")

    sources = swift_sources()
    intent_definitions: dict[str, list[str]] = {
        "BuzzStrapIntent": [],
        "MarkMomentIntent": [],
        "NOOPShortcuts": [],
    }

    for path in sources:
        text = path.read_text(encoding="utf-8")
        name = relative(path)

        for symbol in intent_definitions:
            if re.search(rf"\b(?:struct|class|enum)\s+{re.escape(symbol)}\b", text):
                intent_definitions[symbol].append(name)

        if trace_interpolation.search(text):
            errors.append(
                f"{name}: PerformanceTrace.begin requires a compile-time StaticString; "
                "map dynamic states to literal trace names instead of interpolating."
            )

        if "WorkoutLiveProjectionAccumulator: Sendable" in text:
            errors.append(
                f"{name}: mutable workout projection must not claim Sendable while it stores "
                "non-Sendable sample values."
            )

        if name != "Strand/Data/RepositoryRefreshIntent.swift":
            for match in direct_days_refresh.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                warnings.append(
                    f"{name}:{line}: direct refresh(days:) bypasses typed refresh coalescing."
                )

        for line_number, line_text in enumerate(text.splitlines(), start=1):
            if line_text.lstrip().startswith("//"):
                continue
            if zero_argument_refresh.search(line_text):
                errors.append(
                    f"{name}:{line_number}: zero-argument refresh bypasses explicit intent ownership."
                )

        if active_workout_value.search(text):
            warnings.append(
                f"{name}: ActiveWorkout is still a growing value type; long sessions can trigger copy-on-write."
            )
        if name == "Strand/App/AppModel.swift" and not active_workout_reference.search(text):
            errors.append(
                f"{name}: ActiveWorkout must remain reference-owned so live HR appends do not copy the full session."
            )

    plist = ROOT / "StrandiOS/Resources/Info.plist"
    if not plist.exists():
        errors.append("StrandiOS/Resources/Info.plist is missing.")
    elif "UISupportedInterfaceOrientations~ipad" in plist.read_text(encoding="utf-8"):
        errors.append("StrandiOS/Resources/Info.plist still contains iPad-only orientation configuration.")

    project = ROOT / "project.yml"
    if not project.exists():
        errors.append("project.yml is missing.")
    else:
        project_text = project.read_text(encoding="utf-8")
        if project_text.count('TARGETED_DEVICE_FAMILY: "1"') < 2:
            errors.append("project.yml must target iPhone for both the app and widget extension.")

    refresh_contract = ROOT / "Strand/Data/RepositoryRefreshIntent.swift"
    if "inferredLegacyIntent" in refresh_contract.read_text(encoding="utf-8"):
        errors.append("RepositoryRefreshIntent must not restore the deleted heuristic compatibility router.")

    intents = ROOT / "StrandiOS/System/NOOPAppIntents.swift"
    if not intents.exists():
        errors.append("iPhone Siri/Shortcuts intents were removed from the iOS source tree.")
    else:
        intent_text = intents.read_text(encoding="utf-8")
        for symbol in ("BuzzStrapIntent", "MarkMomentIntent", "NOOPShortcuts"):
            locations = intent_definitions[symbol]
            if locations != [relative(intents)]:
                errors.append(
                    f"{symbol} must have exactly one iPhone definition at {relative(intents)}; "
                    f"found {locations or 'none'}."
                )
        for required_contract in (
            "enum PendingIntents",
            "PendingIntents.append(.markMoment",
            "PendingIntents.append(.buzz)",
            "static var openAppWhenRun = true",
        ):
            if required_contract not in intent_text:
                errors.append(
                    f"{relative(intents)} is missing the foreground-safe intent contract: "
                    f"{required_contract}."
                )

        drain = ROOT / "StrandiOS/App/AppModel+iOS.swift"
        if not drain.exists() or "PendingIntents.drain()" not in drain.read_text(encoding="utf-8"):
            errors.append(
                "StrandiOS/App/AppModel+iOS.swift must drain queued iPhone intents through the "
                "existing AppModel lifecycle."
            )

    print("NOOP iPhone source contract audit")
    print(f"Scanned {len(sources)} Swift files")
    for warning in warnings:
        print(f"WARNING: {warning}")
    for error in errors:
        print(f"ERROR: {error}")

    if errors:
        print(f"RESULT: FAIL ({len(errors)} blocking issue(s), {len(warnings)} warning(s))")
        return 1

    print(f"RESULT: PASS ({len(warnings)} architecture warning(s) remain)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
