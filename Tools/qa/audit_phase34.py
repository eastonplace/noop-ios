#!/usr/bin/env python3
"""Release-blocking static audit for the combined NOOP Phase 3/4 architecture.

Usage:
    python3 tools/qa/audit_phase34.py /path/to/noop

Exit 1 when a blocker remains. Warnings are printed but do not fail unless --strict is supplied.
This is intentionally narrow: it enforces removal of superseded production paths, not general Swift style.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class Rule:
    code: str
    severity: str
    paths: tuple[str, ...]
    pattern: str
    message: str
    flags: int = re.MULTILINE | re.DOTALL


@dataclass(frozen=True)
class Finding:
    code: str
    severity: str
    path: str
    line: int
    excerpt: str
    message: str


RULES: tuple[Rule, ...] = (
    Rule(
        "P34-001", "error", ("Strand/Data/RepositoryRefreshIntent.swift",),
        r"(?:initialLoad|currentDay|postBackfill)[\s\S]{0,300}?4_?000",
        "Launch/current-day/post-backfill still maps to a 4,000-day Repository read.",
    ),
    Rule(
        "P34-002", "error", ("Strand/Data/HistoricalReceiptAnalysisPlanner.swift",),
        r"insertedRows\s*\.\s*total\s*>\s*0",
        "Analysis obligation is still based on inserted rows instead of decoded evidence.",
        re.MULTILINE,
    ),
    Rule(
        "P34-003", "error", ("Strand/Data/CommittedAnalysisWindow.swift",),
        r"minimumTs[\s\S]{0,800}?maximumTs[\s\S]{0,800}?(?:while|0\.\.\.|days\()",
        "Receipt work still expands a global minimum/maximum into contiguous days.",
    ),
    Rule(
        "P34-004", "error", ("Strand/Screens/TrendsView.swift",),
        r"exploreSeries\s*\(\s*key:\s*\"sleep_performance\"",
        "Trends still bypasses the canonical production Sleep score model.",
        re.MULTILINE,
    ),
    Rule(
        "P34-005", "error", ("Strand/Screens/SleepView.swift",),
        r"allSleepSessions\s*\(\s*\)",
        "Sleep still reloads all history on Repository revisions; use recent/paged session groups.",
        re.MULTILINE,
    ),
    Rule(
        "P34-006", "error", ("Strand/Data/HistoricalReceiptAnalysisConsumer.swift",),
        r"actor\s+HistoricalReceiptAnalysisConsumer|final\s+class\s+HistoricalReceiptAnalysisConsumer",
        "The checkpoint-only historical consumer is still present after durable work migration.",
        re.MULTILINE,
    ),
    Rule(
        "P34-007", "error", ("Strand/Data/HistoricalReceiptAnalysisConsumer.swift",),
        r"catch\s*\{[\s\S]{0,250}?deferred",
        "Historical pipeline still collapses errors into generic deferred state.",
    ),
    Rule(
        "P34-008", "error", ("Strand/App/AppModel.swift",),
        r"refresh\s*\(\s*\.postBackfill\s*\)",
        "Post-analysis publication still invokes a broad legacy refresh.",
        re.MULTILINE,
    ),
    Rule(
        "P34-009", "error", ("StrandiOS/App/StrandiOSApp.swift",),
        r"ExternalSurfaceDayProjection[\s\S]{0,1600}?repo(?:sitory)?\.days",
        "External surfaces still rebuild health state independently from Repository arrays.",
    ),
    Rule(
        "P34-010", "error", ("Packages/WhoopStore/Sources/WhoopStore/HistoricalDataCommitJournal.swift",),
        r"HistoricalReceivedFrameFingerprintEnvelope[\s\S]{0,700}?(?:minReceivedTs|maxReceivedTs)",
        "Fingerprint replay identity still includes parser/clock-derived range values.",
    ),
    Rule(
        "P34-011", "error", ("Packages/WhoopStore/Sources/WhoopStore/HistoricalDataCommitJournal.swift",),
        r"watermarkGeneration\s*=\s*MAX\([\s\S]{0,150}?excluded\.watermarkGeneration",
        "Cursor upsert may accept an equal-generation edge without proving exact idempotency.",
    ),
    Rule(
        "P34-012", "warning", ("Strand/Data/*.swift", "Strand/Screens/*.swift"),
        r"86_?400",
        "Fixed day-duration arithmetic remains in a health-day path; verify it is elapsed duration only.",
        re.MULTILINE,
    ),
    Rule(
        "P34-013", "warning", ("Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift",),
        r"ON\s+CONFLICT[\s\S]{0,120}?DO\s+NOTHING",
        "Raw batch conflict is silently ignored; validate existing payload identity.",
    ),
    Rule(
        "P34-014", "warning", ("Strand/Screens/SleepView.swift",),
        r"AnalyticsEngine\.Rest\.composite",
        "SleepView still computes a Rest composite; ensure it is diagnostic/provisional only.",
        re.MULTILINE,
    ),
    Rule(
        "P34-015", "error", ("Strand/Data/Repository.swift",),
        r"publishTodayHealthSnapshot\s*\(\s*resolved[\s\S]{0,1200}?saveTodayHealthSnapshot\s*\(\s*resolved",
        "Today publishes an uncommitted candidate before SQLite save/read-back verification.",
    ),
    Rule(
        "P34-016", "error", ("Strand/Data/*Historical*.swift",),
        r"receipt\s*\.\s*touchedDays",
        "Legacy UTC-derived receipt.touchedDays is still used as local exact-day authority.",
        re.MULTILINE,
    ),
    Rule(
        "P34-017", "error", ("Strand/Screens/TrendsView.swift",),
        r"async\s+let[\s\S]{0,1000}?(?:exploreSeries|appleDailyRows)\s*\(",
        "Trends still combines independent SQLite/WAL reads instead of one canonical Repository generation.",
    ),
    Rule(
        "P34-018", "error", ("Strand/Data/IntelligenceAnalysisCoordinator.swift",),
        r"submitStablePostBackfillAnalysis[\s\S]{0,1800}?maxDays\s*:\s*21",
        "The legacy forced 21-day post-backfill analysis owner is still active.",
    ),
    Rule(
        "P34-019", "error", ("Strand/Data/HistoricalAnalysisWorkStore.swift", "Packages/WhoopStore/Sources/WhoopStore/HistoricalAnalysisWorkStore.swift"),
        r"workKindJSON\s*=\s*\?",
        "Durable work identity still compares JSON payload bytes instead of a stable workKindKey.",
        re.MULTILINE,
    ),
    Rule(
        "P34-020", "error", ("Strand/BLE/BLEManager.swift",),
        r"didWriteValueFor[\s\S]{0,800}?guard[\s\S]{0,300}?peripheral\.identifier[\s\S]{0,300}?return",
        "Confirmed-write callbacks may return on a stale link before retiring the exact old token generation.",
    ),
    Rule(
        "P34-021", "error", ("Strand/Data/*Historical*.swift", "Packages/WhoopStore/Sources/WhoopStore/*Historical*.swift"),
        r"requiresAnalysis[\s\S]{0,500}?timestampBuckets[\s\S]{0,100}?isEmpty",
        "Timestamp range evidence alone still creates analysis work for metadata-only chunks.",
    ),
    Rule(
        "P34-022", "error", ("Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift",),
        r"UPDATE\s+pairedDevice[\s\S]{0,300}?status\s*=\s*'paired'[\s\S]{0,500}?UPDATE\s+pairedDevice[\s\S]{0,200}?WHERE\s+id\s*=",
        "Device activation still demotes the active row before proving the target exists.",
    ),
    Rule(
        "P34-023", "error", ("Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift",),
        r"func\s+unpackFrames[\s\S]{0,1200}?guard[\s\S]{0,300}?else\s*\{\s*break\s*\}",
        "Durable raw replay still accepts a successfully decoded prefix of a corrupt frame blob.",
    ),
    Rule(
        "P34-024", "error", ("Strand/Screens/SleepView.swift",),
        r"AnalyticsEngine\.Rest\.composite[\s\S]{0,800}?(?:performance|sleepScore|score)",
        "Sleep still uses a local composite as a production score path.",
    ),
    Rule(
        "P34-025", "error", ("Strand/Data/Repository.swift",),
        r"(?:nDays|days)\s*\*\s*86_?400",
        "Repository still constructs calendar-day query bounds with fixed 86,400-second arithmetic.",
        re.MULTILINE,
    ),
    Rule(
        "P34-026", "error", ("Packages/WhoopStore/Sources/WhoopStore/*External*Outbox*.swift",),
        r"existing(?:Payload)?\s*==\s*payload",
        "Projection replay identity still compares JSON bytes instead of decoded semantic equality.",
        re.MULTILINE,
    ),
    Rule(
        "P34-027", "error", ("Strand/Data/Repository.swift",),
        r"Array\s*\(\s*Set\s*\(\s*(?:importedReadIds|computedReadIds)",
        "Repository source authority is collapsed through unordered Set iteration.",
        re.MULTILINE,
    ),
    Rule(
        "P34-028", "error", (
            "Packages/WhoopStore/Sources/WhoopStore/*External*Outbox*.swift",
            "Packages/WhoopStore/Sources/WhoopStore/Database.swift",
        ),
        r'uniqueKey\s*\(\s*\[\s*"contextId"\s*,\s*"snapshotGeneration"\s*,\s*"destination"',
        "HealthKit outbox identity is still limited to snapshot generation and can drop historical mutations.",
    ),
    Rule(
        "P34-029", "error", ("Packages/WhoopStore/Sources/WhoopStore/*External*Outbox*.swift",),
        r"ORDER\s+BY\s+snapshotGeneration\s+ASC",
        "Latest-state surfaces still drain oldest snapshot generations before the newest state.",
        re.MULTILINE,
    ),
    Rule(
        "P34-030", "error", ("StrandiOS/**/*.swift", "Strand/**/*.swift"),
        r"publishHealthKitWriteOnly\s*\(\s*projection\s*\)",
        "HealthKit publication lacks the exact analysis generation and changed-day set.",
        re.MULTILINE,
    ),
    Rule(
        "P34-031", "error", (
            "Packages/WhoopStore/Sources/WhoopStore/HistoricalAnalysisWorkStore.swift",
            "Strand/Data/HistoricalAnalysisWorkStore.swift",
        ),
        r"workKindKey[\s\S]{0,700}?state\s+IN\s*\([^\)]*pending[^\)]*retryable[^\)]*\)[\s\S]{0,300}?LIMIT\s+1",
        "Pending exact work checks only one merge candidate and can strand a bounded backlog.",
    ),
    Rule(
        "P34-032", "error", (
            "Packages/WhoopStore/Sources/WhoopStore/*External*Outbox*.swift",
            "Packages/WhoopStore/Sources/WhoopStore/Database.swift",
        ),
        r"state\s+IN\s*\((?![^\)]*superseded)[^\)]*succeeded[^\)]*quarantined[^\)]*\)",
        "External outbox schema does not represent superseded latest-state work.",
    ),
)


def expand_paths(root: Path, patterns: Iterable[str]) -> Iterable[Path]:
    seen: set[Path] = set()
    for pattern in patterns:
        for path in root.glob(pattern):
            if path.is_file() and path not in seen:
                seen.add(path)
                yield path


def line_number(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def excerpt(text: str, start: int, end: int, limit: int = 180) -> str:
    value = " ".join(text[start:end].split())
    return value if len(value) <= limit else value[: limit - 1] + "…"


def scan(root: Path) -> list[Finding]:
    findings: list[Finding] = []
    for rule in RULES:
        for path in expand_paths(root, rule.paths):
            text = path.read_text(encoding="utf-8", errors="replace")
            for match in re.finditer(rule.pattern, text, rule.flags):
                findings.append(Finding(
                    code=rule.code,
                    severity=rule.severity,
                    path=str(path.relative_to(root)),
                    line=line_number(text, match.start()),
                    excerpt=excerpt(text, match.start(), match.end()),
                    message=rule.message,
                ))
    return findings


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--strict", action="store_true", help="Treat warnings as failures")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    if not root.is_dir():
        parser.error(f"not a directory: {root}")

    findings = scan(root)
    if args.json:
        print(json.dumps([asdict(item) for item in findings], indent=2))
    else:
        for item in findings:
            print(f"{item.severity.upper()} {item.code} {item.path}:{item.line}")
            print(f"  {item.message}")
            print(f"  {item.excerpt}")
        print(f"\n{len(findings)} finding(s): "
              f"{sum(f.severity == 'error' for f in findings)} error, "
              f"{sum(f.severity == 'warning' for f in findings)} warning")

    has_error = any(item.severity == "error" for item in findings)
    has_warning = any(item.severity == "warning" for item in findings)
    return 1 if has_error or (args.strict and has_warning) else 0


if __name__ == "__main__":
    sys.exit(main())
