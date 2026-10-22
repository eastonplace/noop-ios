#!/usr/bin/env python3
"""Fail-closed validation of a plan and actual app/package execution evidence.

This gate stays shadow during rollout. Loading protected policy does not make a
PR's proposed workflow trusted; CI-policy changes still need independent review.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

LEGACY_PACKAGES = (
    "NoopPhase34Core", "WhoopProtocol", "OuraProtocol", "WhoopStore",
    "StrandAnalytics", "StrandImport", "StrandDesign", "NoopLocalAccess",
)
APP_BUILD_PACKAGES = {"CoachPresentation", "ReceiptLiftActivity", "ReceiptLiftFeature"}
PACKAGE_WORKFLOW = ".github/workflows/swift-packages.yml"
SHA = re.compile(r"[0-9a-f]{40}\Z")
PACKAGE = re.compile(r"[A-Za-z][A-Za-z0-9_]*\Z")


def plan_digest(plan: dict) -> str:
    return hashlib.sha256(json.dumps(
        {key: value for key, value in plan.items() if key != "plan_hash"},
        sort_keys=True, separators=(",", ":"),
    ).encode("utf-8")).hexdigest()


def validate_plan(plan: dict, *, head_sha: str, tested_sha: str, base_sha: str | None = None) -> list[str]:
    errors = []
    if not isinstance(plan, dict):
        return ["change plan is not an object"]
    if plan.get("schema_version") != 1:
        errors.append("unsupported change-plan schema")
    for key in ("base_sha", "head_sha", "tested_sha", "policy_sha"):
        if not isinstance(plan.get(key), str) or not SHA.fullmatch(plan[key]):
            errors.append(f"invalid plan {key}")
    if plan.get("head_sha") != head_sha or plan.get("tested_sha") != tested_sha:
        errors.append("plan head/tested SHA differs from the current source")
    if base_sha is not None and plan.get("base_sha") != base_sha:
        errors.append("plan base SHA differs from the exact event base")
    if plan.get("policy_sha") != plan.get("base_sha"):
        # Bootstrap records the exact base too; absence of protected policy is a reason.
        errors.append("plan policy SHA is not the exact base")
    if plan.get("plan_hash") != plan_digest(plan):
        errors.append("change-plan hash does not match its contents")
    mode = plan.get("mode")
    if mode not in {"docs", "ui", "high", "full"}:
        errors.append("invalid change-plan mode")
    if type(plan.get("run_app")) is not bool or plan.get("run_app") != (mode != "docs"):
        errors.append("run_app is inconsistent with the validated mode")
    expected_native = {"docs": "none", "ui": "smoke", "high": "full", "full": "full"}.get(mode)
    if plan.get("native_level") != expected_native:
        errors.append("native level is inconsistent with the validated mode")
    for field in ("native_tests", "ui_tests", "host_packages", "reasons"):
        if not isinstance(plan.get(field), list) or any(not isinstance(item, str) for item in plan[field]):
            errors.append(f"invalid plan {field}")
    if any(not isinstance(plan.get(field), list) or any(not isinstance(item, str) for item in plan[field])
           for field in ("native_tests", "ui_tests", "host_packages", "reasons")):
        return errors
    if mode == "docs" and (plan["native_tests"] or plan["ui_tests"]):
        errors.append("docs plan contains unplanned native/UI work")
    if mode in {"high", "full"} and plan["native_tests"] != ["NOOPiOSTests"]:
        errors.append("high/full plan does not select the complete native suite")
    if mode == "ui" and not plan["native_tests"]:
        errors.append("UI plan has no native safety coverage")
    if mode == "full":
        available = plan.get("ui_inventory")
        if (not isinstance(available, list) or not available or
                any(not isinstance(item, str) for item in available) or
                set(plan["ui_tests"]) != set(available)):
            errors.append("full plan does not select the complete UI inventory")
    if not plan.get("reasons"):
        errors.append("plan has no classification reason")
    matrix, inventory = plan.get("host_matrix"), plan.get("package_validation")
    if not isinstance(matrix, list) or not isinstance(inventory, list):
        return errors + ["missing package matrix or validation inventory"]
    lanes, affected_hosts = {}, set()
    for item in inventory:
        if not isinstance(item, dict) or not isinstance(item.get("package"), str) or not PACKAGE.fullmatch(item["package"]):
            errors.append("invalid package validation entry")
            continue
        name, lane = item["package"], item.get("lane")
        if name in lanes:
            errors.append(f"duplicate package validation entry: {name}")
        lanes[name] = lane
        if type(item.get("affected")) is not bool:
            errors.append(f"package affected flag is not boolean: {name}")
        if lane == "host_test" and item.get("affected"):
            affected_hosts.add(name)
        if lane not in {"host_test", "app_build"}:
            errors.append(f"unvalidated package lane: {name}")
        if lane == "app_build" and name not in APP_BUILD_PACKAGES:
            errors.append(f"unknown app-build package requires a reviewed lane: {name}")
        if item.get("affected") and lane == "app_build" and not plan.get("run_app"):
            errors.append(f"affected app-build package has no app validation: {name}")
    names, selected = set(), set()
    for item in matrix:
        if not isinstance(item, dict) or not isinstance(item.get("package"), str) or not PACKAGE.fullmatch(item["package"]):
            errors.append("invalid package matrix entry")
            continue
        name = item["package"]
        if name in names:
            errors.append(f"duplicate matrix package: {name}")
        names.add(name)
        if type(item.get("run")) is not bool:
            errors.append(f"package run flag is not boolean: {name}")
        if item.get("run"):
            selected.add(name)
            if lanes.get(name) != "host_test":
                errors.append(f"selected package has no host-test lane: {name}")
        elif name not in LEGACY_PACKAGES and name not in lanes:
            errors.append(f"matrix package has no validation lane: {name}")
        expected_runner = "macos-26" if item.get("run") else "ubuntu-latest"
        if item.get("runner") != expected_runner:
            errors.append(f"package runner differs from test/skip plan: {name}")
    missing = set(LEGACY_PACKAGES) - names
    if missing:
        errors.append(f"missing legacy package contexts: {', '.join(sorted(missing))}")
    hosts = {name for name, lane in lanes.items() if lane == "host_test"}
    if not hosts <= names:
        errors.append("host-test package missing from matrix")
    if selected != set(plan.get("host_packages", [])):
        errors.append("selected package list differs from matrix")
    if not affected_hosts <= selected:
        errors.append("affected host-test package is incorrectly marked as a planned skip")
    if mode == "docs" and selected:
        errors.append("docs plan selects package tests")
    if mode == "full" and selected != hosts:
        errors.append("full mode does not select every host-test package")
    return errors


def _step_errors(job: dict, expected: dict[str, str]) -> list[str]:
    errors = []
    steps = job.get("steps", [])
    if not isinstance(steps, list):
        return [f"{job.get('name')}: missing steps"]
    for name, conclusion in expected.items():
        matches = [step for step in steps if isinstance(step, dict) and step.get("name") == name]
        if len(matches) != 1:
            errors.append(f"{job.get('name')}: missing or duplicate step {name}")
        elif matches[0].get("status") != "completed" or matches[0].get("conclusion") != conclusion:
            errors.append(f"{job.get('name')}: {name} expected {conclusion}, got {matches[0].get('conclusion')}")
    return errors


def validate_packages(plan: dict, packages: dict, *, head_sha: str, tested_sha: str,
                      event: str, repository: str, workflow_path: str = PACKAGE_WORKFLOW,
                      job_prefix: str = "", allow_in_progress: bool = False) -> list[str]:
    errors = []
    if not isinstance(packages, dict):
        return ["missing package execution evidence"]
    if packages.get("repository") != repository:
        errors.append("package evidence is from a different repository")
    if packages.get("workflow_path") != workflow_path or packages.get("job_prefix") != job_prefix:
        errors.append("package evidence has an unexpected workflow or job prefix")
    run = packages.get("run", {})
    if not isinstance(run, dict):
        return errors + ["missing package workflow run"]
    for key, expected in (("head_sha", head_sha), ("event", event), ("path", workflow_path)):
        actual = run.get(key)
        if key == "path" and isinstance(actual, str):
            actual = actual.split("@", 1)[0]
        if actual != expected:
            errors.append(f"package run has wrong {key}: {run.get(key)!r}")
    for key in ("id", "run_attempt"):
        if type(run.get(key)) is not int or run[key] < 1:
            errors.append(f"package run has invalid {key}")
    if not allow_in_progress and (run.get("status") != "completed" or run.get("conclusion") != "success"):
        errors.append(f"package workflow did not succeed: {run.get('status')}/{run.get('conclusion')}")
    if allow_in_progress and run.get("status") not in {"in_progress", "completed"}:
        errors.append("full workflow run is not active or completed")
    if allow_in_progress and run.get("status") == "completed" and run.get("conclusion") != "success":
        errors.append("full workflow failed or was cancelled")
    expected_endpoint = f"/repos/{repository}/actions/runs/{run.get('id')}/attempts/{run.get('run_attempt')}/jobs"
    if packages.get("jobs_run_attempt") != run.get("run_attempt") or packages.get("jobs_endpoint") != expected_endpoint:
        errors.append("package jobs were not queried from the expected run attempt")
    jobs = packages.get("jobs")
    if not isinstance(jobs, list):
        return errors + ["missing package job inventory"]
    expected_jobs = {job_prefix + "plan": None}
    for item in plan.get("host_matrix", []):
        if isinstance(item, dict) and isinstance(item.get("package"), str):
            expected_jobs[job_prefix + f"test ({item['package']})"] = item
    matrix_pattern = re.compile(re.escape(job_prefix) + r"test \([^)]+\)\Z")
    actual_names = [job.get("name") for job in jobs if isinstance(job, dict)]
    for name in actual_names:
        if isinstance(name, str) and matrix_pattern.fullmatch(name) and name not in expected_jobs:
            errors.append(f"unexpected package matrix job: {name}")
    for name, item in expected_jobs.items():
        matches = [job for job in jobs if isinstance(job, dict) and job.get("name") == name]
        if len(matches) != 1:
            errors.append(f"missing or duplicate package job: {name}")
            continue
        job = matches[0]
        if job.get("run_id") != run.get("id") or job.get("run_attempt", packages.get("jobs_run_attempt")) != run.get("run_attempt"):
            errors.append(f"{name}: job is from the wrong run or attempt")
        if job.get("status") != "completed" or job.get("conclusion") != "success":
            errors.append(f"{name}: expected success, got {job.get('status')}/{job.get('conclusion')}")
        if item is None:
            errors.extend(_step_errors(job, {f"Tested source {tested_sha}": "success"}))
        else:
            chosen = item.get("run") is True
            errors.extend(_step_errors(job, {
                f"Tested source {tested_sha}": "success" if chosen else "skipped",
                "Test selected package": "success" if chosen else "skipped",
                "Record planned package skip": "skipped" if chosen else "success",
            }))
    return errors


def validate_gate(plan: dict, packages: dict, app: dict, *, head_sha: str, tested_sha: str,
                  event: str, repository: str, workflow_path: str = PACKAGE_WORKFLOW,
                  job_prefix: str = "", allow_in_progress: bool = False,
                  base_sha: str | None = None, app_run_id: int | None = None,
                  app_run_attempt: int | None = None,
                  app_workflow_path: str = ".github/workflows/app-build.yml") -> list[str]:
    errors = validate_plan(plan, head_sha=head_sha, tested_sha=tested_sha, base_sha=base_sha)
    if errors:
        return errors
    errors.extend(validate_packages(plan, packages, head_sha=head_sha, tested_sha=tested_sha,
                  event=event, repository=repository, workflow_path=workflow_path,
                  job_prefix=job_prefix, allow_in_progress=allow_in_progress))
    if not isinstance(app, dict):
        return errors + ["missing app execution evidence"]
    for key, expected in (("run_id", app_run_id), ("run_attempt", app_run_attempt), ("workflow_path", app_workflow_path)):
        if expected is not None and app.get(key) != expected:
            errors.append(f"app evidence has wrong {key}")
    for key, expected in (("head_sha", head_sha), ("tested_sha", tested_sha),
                          ("event", event), ("plan_hash", plan["plan_hash"])):
        if app.get(key) != expected:
            errors.append(f"app evidence has wrong {key}")
    jobs, steps = app.get("jobs", {}), app.get("steps", {})
    if not isinstance(jobs, dict) or not isinstance(steps, dict):
        return errors + ["missing app job or step results"]
    for name in ("change-plan", "source-audits", "build-and-test"):
        if jobs.get(name) != "success":
            errors.append(f"app job {name}: expected success, got {jobs.get(name)}")
    for name in ("build", "native", "ui", "safety"):
        applicable = plan["run_app"] and (name != "ui" or bool(plan["ui_tests"]))
        expected = "success" if applicable else "skipped"
        if steps.get(name) != expected:
            errors.append(f"app stage {name}: expected {expected}, got {steps.get(name)}")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--packages", required=True)
    parser.add_argument("--app-results", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--app-run-id", required=True, type=int)
    parser.add_argument("--app-run-attempt", required=True, type=int)
    parser.add_argument("--app-workflow-path", default=".github/workflows/app-build.yml")
    parser.add_argument("--tested-sha", required=True)
    parser.add_argument("--event", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--workflow-path", default=PACKAGE_WORKFLOW)
    parser.add_argument("--job-prefix", default="")
    parser.add_argument("--allow-in-progress", action="store_true")
    args = parser.parse_args()
    try:
        plan, packages, app = [json.loads(Path(path).read_text()) for path in (args.plan, args.packages, args.app_results)]
        errors = validate_gate(plan, packages, app, head_sha=args.head_sha, tested_sha=args.tested_sha,
                              event=args.event, repository=args.repository, workflow_path=args.workflow_path,
                              job_prefix=args.job_prefix, allow_in_progress=args.allow_in_progress,
                              base_sha=args.base_sha, app_run_id=args.app_run_id, app_run_attempt=args.app_run_attempt,
                              app_workflow_path=args.app_workflow_path)
    except (OSError, ValueError, TypeError) as exc:
        errors = [f"cannot validate execution evidence: {exc}"]
    if errors:
        for error in errors:
            print(f"CI GATE FAIL: {error}", file=sys.stderr)
        return 1
    print(f"CI GATE PASS: {args.head_sha} (tested {args.tested_sha}); validated app and package execution")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
