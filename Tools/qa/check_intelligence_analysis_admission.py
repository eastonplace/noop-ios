#!/usr/bin/env python3
"""Fail when production code bypasses IntelligenceEngine's serialized analysis admission.

The implementation keeps one four-argument ``analyzeRecent`` body in ``IntelligenceEngine.swift``.
Every production call using one or more defaults must resolve through the admitted overloads in
``IntelligenceAnalysisCoordinator.swift``. One full-signature invocation belongs to serialized live work.
One exact-work invocation belongs to ``ExactDayAnalysisIntegration.swift`` and its durable historical
pipeline. Any other full call can reintroduce the post-backfill missing-Recovery race.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import Iterator

CALL_NAME = "analyzeRecent"
REQUIRED_LABELS = ("maxDays", "startOffset", "force", "refreshRepository")
ADMISSION = Path("Strand/Data/IntelligenceAnalysisCoordinator.swift")
EXACT_ADMISSION = Path("Strand/Data/ExactDayAnalysisIntegration.swift")
FORBIDDEN_DUPLICATES = (
    Path("Strand/Data/IntelligenceAnalysisAdmission.swift"),
    Path("Strand/Data/IntelligenceEngine+AnalysisAdmission.swift"),
)
SEARCH_ROOTS = (Path("Strand"), Path("StrandiOS"), Path("StrandiOSShared"))


def mask_comments_and_strings(source: str) -> str:
    """Replace comments and string contents with spaces while preserving newlines/offsets."""
    out = list(source)
    i = 0
    block_depth = 0
    state = "code"
    triple = False

    def blank(index: int) -> None:
        if out[index] != "\n":
            out[index] = " "

    while i < len(source):
        if state == "line_comment":
            if source[i] == "\n":
                state = "code"
            else:
                blank(i)
            i += 1
            continue

        if state == "block_comment":
            if source.startswith("/*", i):
                blank(i)
                if i + 1 < len(source):
                    blank(i + 1)
                block_depth += 1
                i += 2
            elif source.startswith("*/", i):
                blank(i)
                if i + 1 < len(source):
                    blank(i + 1)
                block_depth -= 1
                i += 2
                if block_depth == 0:
                    state = "code"
            else:
                blank(i)
                i += 1
            continue

        if state == "string":
            if triple and source.startswith('"""', i):
                for offset in range(3):
                    blank(i + offset)
                i += 3
                state = "code"
                triple = False
            elif not triple and source[i] == '"':
                blank(i)
                i += 1
                state = "code"
            elif source[i] == "\\" and not triple:
                blank(i)
                if i + 1 < len(source):
                    blank(i + 1)
                i += 2
            else:
                blank(i)
                i += 1
            continue

        if source.startswith("//", i):
            blank(i)
            blank(i + 1)
            i += 2
            state = "line_comment"
        elif source.startswith("/*", i):
            blank(i)
            blank(i + 1)
            i += 2
            state = "block_comment"
            block_depth = 1
        elif source.startswith('"""', i):
            for offset in range(3):
                blank(i + offset)
            i += 3
            state = "string"
            triple = True
        elif source[i] == '"':
            blank(i)
            i += 1
            state = "string"
            triple = False
        else:
            i += 1

    return "".join(out)


def matching_paren(masked: str, opening: int) -> int | None:
    depth = 0
    for index in range(opening, len(masked)):
        char = masked[index]
        if char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    return None


def previous_word(masked: str, index: int) -> str | None:
    prefix = masked[:index]
    match = re.search(r"([A-Za-z_][A-Za-z0-9_]*)\s*$", prefix)
    return match.group(1) if match else None


def direct_full_calls(path: Path) -> Iterator[tuple[int, str]]:
    source = path.read_text(encoding="utf-8")
    masked = mask_comments_and_strings(source)
    pattern = re.compile(rf"\b{CALL_NAME}\s*\(")

    for match in pattern.finditer(masked):
        if previous_word(masked, match.start()) == "func":
            continue
        opening = masked.find("(", match.start(), match.end())
        closing = matching_paren(masked, opening)
        if closing is None:
            line = source.count("\n", 0, match.start()) + 1
            yield line, "unterminated analyzeRecent call"
            continue
        arguments = masked[opening + 1 : closing]
        if all(re.search(rf"\b{re.escape(label)}\s*:", arguments) for label in REQUIRED_LABELS):
            line = source.count("\n", 0, match.start()) + 1
            yield line, "direct four-argument analyzeRecent call bypasses admission"


def swift_files(repository_root: Path) -> Iterator[Path]:
    for relative_root in SEARCH_ROOTS:
        root = repository_root / relative_root
        if not root.exists():
            continue
        yield from root.rglob("*.swift")


def main() -> int:
    parser = argparse.ArgumentParser()
    script_path = Path(__file__).resolve()
    try:
        default_root = script_path.parents[2]
    except IndexError:
        default_root = Path.cwd()
    parser.add_argument(
        "repository_root",
        nargs="?",
        type=Path,
        default=default_root,
    )
    args = parser.parse_args()
    repository_root = args.repository_root.resolve()

    violations: list[tuple[Path, int, str]] = []
    allowed_calls: list[tuple[int, str]] = []
    admission_path = repository_root / ADMISSION

    if not admission_path.is_file():
        violations.append((ADMISSION, 0, "serialized admission source is missing"))
    for forbidden in FORBIDDEN_DUPLICATES:
        if (repository_root / forbidden).exists():
            violations.append((forbidden, 0, "duplicate analysis coordinator/wrapper must not exist"))

    for path in swift_files(repository_root):
        calls = list(direct_full_calls(path))
        relative = path.relative_to(repository_root)
        if relative in (ADMISSION, EXACT_ADMISSION):
            allowed_calls.extend(calls)
        else:
            violations.extend((relative, line, reason) for line, reason in calls)

    if len(allowed_calls) != 2:
        violations.append(
            (
                ADMISSION,
                allowed_calls[0][0] if allowed_calls else 0,
                f"expected exactly one serialized and one exact-work engine invocation, found {len(allowed_calls)}",
            )
        )

    if violations:
        print("Intelligence analysis admission audit FAILED:", file=sys.stderr)
        for path, line, reason in violations:
            where = f"{path}:{line}" if line > 0 else str(path)
            print(f"  {where}: {reason}", file=sys.stderr)
        print(
            f"Use an admitted overload, or route the call through {ADMISSION} or {EXACT_ADMISSION}.",
            file=sys.stderr,
        )
        return 1

    print(
        "Intelligence analysis admission audit passed; serialized and exact-work engine calls are admitted."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
