#!/usr/bin/env python3
"""Static contract audit for the PR #28 root-fix package.

The audit checks architecture contracts that ordinary unit tests can miss. It is
strict by design and exits non-zero on a regression.
"""
from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Finding:
    code: str
    message: str


def read(root: Path, rel: str) -> str:
    p = root / rel
    if not p.exists():
        raise FileNotFoundError(rel)
    return p.read_text(encoding="utf-8")


def scope(text: str, token: str) -> str:
    start = text.find(token)
    if start < 0:
        return ""
    brace = text.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    i = brace
    in_string = False
    escaped = False
    line_comment = False
    block = 0
    while i < len(text):
        c = text[i]
        n = text[i + 1] if i + 1 < len(text) else ""
        if line_comment:
            if c == "\n": line_comment = False
            i += 1; continue
        if block:
            if c == "/" and n == "*": block += 1; i += 2; continue
            if c == "*" and n == "/": block -= 1; i += 2; continue
            i += 1; continue
        if in_string:
            if escaped: escaped = False
            elif c == "\\": escaped = True
            elif c == '"': in_string = False
            i += 1; continue
        if c == "/" and n == "/": line_comment = True; i += 2; continue
        if c == "/" and n == "*": block = 1; i += 2; continue
        if c == '"': in_string = True; i += 1; continue
        if c == "{": depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    return ""


def require(findings: list[Finding], code: str, condition: bool, message: str) -> None:
    if not condition:
        findings.append(Finding(code, message))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?", default=".")
    args = parser.parse_args()
    root = Path(args.root).resolve()
    findings: list[Finding] = []

    work = read(root, "Packages/NoopPhase34Core/Sources/NoopPhase34Core/HistoricalAnalysisWork.swift")
    reducer = read(root, "Packages/NoopPhase34Core/Sources/NoopPhase34Core/HistoricalAnalysisWorkReducer.swift")
    coordinator = read(root, "Packages/NoopPhase34Core/Sources/NoopPhase34Core/HistoricalPipelineCoordinator.swift")
    outbox = read(root, "Packages/NoopPhase34Core/Sources/NoopPhase34Core/ExternalPublicationOutbox.swift")
    app = read(root, "Strand/App/AppModel.swift")
    exact = read(root, "Strand/Data/ExactDayAnalysisIntegration.swift")
    post = read(root, "Strand/Data/RepositoryPostAnalysisSnapshotBuilder.swift")
    errors = read(root, "Strand/App/PR28HistoricalPipelineErrors.swift")
    external = read(root, "StrandiOS/Health/HealthKitBridge.swift")

    require(findings, "P28-001", "HistoricalPipelineResumePhase" in work,
            "Durable work has no resume phase.")
    require(findings, "P28-002", re.search(r"case\s+blocked\b", work + reducer + outbox) is not None,
            "Environmental blocked state is missing.")
    require(findings, "P28-003", any(x in coordinator for x in ("leaseHealth", "leaseIsHealthy", "assertLease", "renewalFailed")),
            "Coordinator does not fence side effects after lease loss.")
    require(findings, "P28-004", any(x in reducer for x in ("doesNotConsumeAttempt", "consumeAttempt: false", "attemptCount")),
            "Reducer does not make blocked work retry-budget neutral.")
    require(findings, "P28-005", any(x in coordinator for x in ("resumePhase", "phaseAfter", "nextPhase")),
            "Coordinator does not resume from a durable phase.")

    make_runtime = scope(app, "private func makeHistoricalPipelineRuntime")
    require(findings, "P28-010", bool(make_runtime), "AppModel runtime factory is missing.")
    require(findings, "P28-011", "verifiedTodaySnapshotCandidate" not in make_runtime,
            "Pipeline still verifies a pre-analysis Repository cache candidate.")
    require(findings, "P28-012", any(x in make_runtime for x in ("postAnalysis", "buildPostAnalysis", "snapshotBuilder")),
            "Pipeline does not use the post-analysis SQLite snapshot builder.")
    require(findings, "P28-013", "registeredIds + importedIds + computedIds" not in make_runtime,
            "Receipt admission still scans registered, imported, and computed namespaces together.")
    require(findings, "P28-014", "PipelineFailureClassification" in make_runtime,
            "Typed pipeline error classification is not wired.")

    refresh_burst = scope(app, "private func refreshAfterBackfillBurst")
    completed_branch = re.search(r"if\s+pipeline\.completedWork\s*>\s*0\s*\{(?P<body>.*?)\n\s*\}", refresh_burst, re.S)
    require(findings, "P28-015", bool(completed_branch), "Completed durable work branch is missing.")
    if completed_branch:
        require(findings, "P28-016", "publishAfterCommittedHistoricalAnalysis" not in completed_branch.group("body"),
                "Receipt-backed work still triggers duplicate broad publication.")

    require(findings, "P28-020", "analyzeCommittedWork" in exact,
            "Exact-day analysis adapter is missing.")
    require(findings, "P28-021", any(x in exact for x in ("contiguous", "groupAdjacent", "runs", "dayGroups")),
            "Exact-day analysis does not group adjacent civil days.")
    require(findings, "P28-022", "fullHistoryRepair" in exact,
            "Unsupported full-history repair work is not handled explicitly.")
    require(findings, "P28-023", any(x in exact for x in ("unsupportedFullHistory", "unsupportedRepair", "permanent")),
            "Full-history repair does not fail with a stable typed error.")

    require(findings, "P28-030", "RepositoryPostAnalysisSnapshotBuilder" in post,
            "Post-analysis snapshot builder type is missing.")
    require(findings, "P28-031", any(x in post for x in ("read", "fetch", "load")) and "WhoopStore" in post,
            "Snapshot builder does not read the committed store.")
    require(findings, "P28-032", "todayHealthSnapshot" not in post,
            "Snapshot builder feeds old Repository presentation state back into verification.")

    require(findings, "P28-040", any(x in errors for x in ("protectedData", "authorization", "storeUnavailable")),
            "Environmental failure classes are incomplete.")
    require(findings, "P28-041", any(x in errors for x in ("blocked", "retryable: false", "consumeAttempt")),
            "Environmental failures are not separated from ordinary retry failures.")

    hk_scope = scope(external, "func publishExactHealthKit")
    require(findings, "P28-050", bool(hk_scope), "HealthKit exact-day publisher is missing.")
    require(findings, "P28-051", "Calendar.current" not in hk_scope,
            "HealthKit delivery still interprets exact days in the current travel timezone.")
    require(findings, "P28-052", any(x in hk_scope for x in ("recordedTimeZoneIdentifier", "TimeZone(identifier:")),
            "HealthKit delivery does not use the recorded timezone.")
    require(findings, "P28-053", "guard" in hk_scope and "throw" in hk_scope,
            "HealthKit delivery can acknowledge an unavailable sink as success.")

    require(findings, "P28-060", any(x in outbox for x in ("blocked", "rearm", "unblock")),
            "External outbox cannot retain blocked delivery work.")
    require(findings, "P28-061", any(x in outbox for x in ("lease", "owner")),
            "External outbox has no ownership fencing.")

    # Package hygiene.
    changed_sources = [
        work, reducer, coordinator, outbox, exact, post, errors, external,
    ]
    forbidden = ["<" + "#", "TODO(" + "PR28)", "IMPLEMENT" + " ME", "fatalError(" + '"PR28']
    for token in forbidden:
        require(findings, "P28-090", all(token not in s for s in changed_sources),
                f"Unfinished placeholder remains: {token}")

    if findings:
        for f in findings:
            print(f"ERROR {f.code}: {f.message}")
        print(f"PR #28 root-fix audit failed with {len(findings)} error(s).")
        return 1
    print("PR #28 root-fix audit passed: 0 errors.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
