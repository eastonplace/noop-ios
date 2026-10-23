#!/usr/bin/env python3
"""Collect and validate the single authoritative package pass with read-only API calls.

Uses the exact run-attempt jobs endpoint, never a dispatch run as PR evidence.
The JSON includes raw run/jobs evidence and the queried attempt for API versions
that do not repeat run_attempt on individual jobs. Waiting is bounded; API errors,
missing completed work and timeouts fail instead of becoming planned skips.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# Script entry points and importlib-based tests both use this sibling module.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from validate_gate import PACKAGE_WORKFLOW, validate_packages, validate_plan


class PackageWaitError(RuntimeError):
    def __init__(self, message: str, evidence: dict | None = None):
        super().__init__(message)
        self.evidence = evidence


def select_run(runs: list, *, head_sha: str, event: str, workflow_path: str) -> dict | None:
    matching = [run for run in runs if isinstance(run, dict)
                and run.get("head_sha") == head_sha and run.get("event") == event
                and str(run.get("path", "")).split("@", 1)[0] == workflow_path
                and type(run.get("id")) is int and type(run.get("run_attempt")) is int]
    return max(matching, key=lambda run: (run["id"], run["run_attempt"]), default=None)


def _jobs(fetch, repository: str, run: dict) -> tuple[list, str]:
    endpoint = f"/repos/{repository}/actions/runs/{run['id']}/attempts/{run['run_attempt']}/jobs"
    jobs = []
    for page in range(1, 11):
        data = fetch(endpoint + f"?per_page=100&page={page}")
        batch = data.get("jobs")
        if not isinstance(batch, list) or type(data.get("total_count")) is not int:
            raise PackageWaitError("GitHub returned an invalid package jobs response")
        jobs.extend(batch)
        if len(jobs) >= data["total_count"]:
            return jobs, endpoint
        if not batch:
            raise PackageWaitError("GitHub returned an incomplete package job inventory")
    raise PackageWaitError("Package job inventory exceeded the bounded 1,000-job limit")


def wait_for_packages(*, repository: str, head_sha: str, tested_sha: str, event: str,
                      plan: dict, fetch, sleep=time.sleep, monotonic=time.monotonic,
                      timeout_seconds: float = 3300, workflow_path: str = PACKAGE_WORKFLOW,
                      run_id: int | None = None, job_prefix: str = "", report=None, base_sha: str | None = None) -> dict:
    plan_errors = validate_plan(plan, head_sha=head_sha, tested_sha=tested_sha, base_sha=base_sha)
    if plan_errors:
        raise PackageWaitError("Invalid plan: " + "; ".join(plan_errors))
    if timeout_seconds <= 0 or timeout_seconds > 3300:
        raise PackageWaitError("Timeout must be greater than zero and at most 3300 seconds")
    started, delay, last_state = monotonic(), 5.0, None
    last_evidence = None
    while True:
        elapsed = monotonic() - started
        if elapsed >= timeout_seconds:
            raise PackageWaitError(f"Timed out after {timeout_seconds:g}s waiting for {workflow_path} at {head_sha}; last state: {last_state}", last_evidence)
        if run_id is None:
            query = urllib.parse.urlencode({"head_sha": head_sha, "event": event, "per_page": 100})
            response = fetch(f"/repos/{repository}/actions/workflows/{Path(workflow_path).name}/runs?{query}")
            if not isinstance(response.get("workflow_runs"), list):
                raise PackageWaitError("GitHub returned an invalid workflow-run response")
            run = select_run(response["workflow_runs"], head_sha=head_sha, event=event, workflow_path=workflow_path)
        else:
            run = fetch(f"/repos/{repository}/actions/runs/{run_id}")
            if run.get("id") != run_id:
                raise PackageWaitError("GitHub returned the wrong requested workflow run")
        if run:
            if type(run.get("run_attempt")) is not int or run["run_attempt"] < 1:
                raise PackageWaitError("GitHub returned a workflow run with no valid attempt")
            jobs, endpoint = _jobs(fetch, repository, run)
            last_evidence = {"repository": repository, "workflow_path": workflow_path,
                             "job_prefix": job_prefix, "run": run, "jobs": jobs,
                             "jobs_run_attempt": run["run_attempt"], "jobs_endpoint": endpoint}
            errors = validate_packages(plan, last_evidence, head_sha=head_sha, tested_sha=tested_sha,
                       event=event, repository=repository, workflow_path=workflow_path,
                       job_prefix=job_prefix, allow_in_progress=run_id is not None)
            state = f"run {run['id']} attempt {run['run_attempt']} {run.get('status')}/{run.get('conclusion')}: " + ("; ".join(errors[:3]) if errors else "all package jobs qualified")
            if not errors:
                return last_evidence
            if run.get("status") == "completed":
                raise PackageWaitError("Package validation failed: " + "; ".join(errors), last_evidence)
            # A wrong source/event/path cannot be fixed by waiting on this exact run.
            if run_id is not None and any(run.get(key) != value for key, value in (("head_sha", head_sha), ("event", event))):
                raise PackageWaitError("Package validation failed: " + "; ".join(errors), last_evidence)
        else:
            state = "no package workflow run found for the current head/event"
        if report and state != last_state:
            report(state)
        last_state = state
        remaining = timeout_seconds - (monotonic() - started)
        if remaining > 0:
            sleep(min(delay, remaining))
        delay = min(delay * 2, 30.0)


def api_fetcher(token: str):
    api_url = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    if not api_url.startswith("https://"):
        raise PackageWaitError("GitHub API URL must use HTTPS")
    def fetch(path):
        request = urllib.request.Request(api_url + path, headers={
            "Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "noop-ci-package-gate",
        })
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                result = json.load(response)
        except urllib.error.HTTPError as exc:
            raise PackageWaitError(f"GitHub package API HTTP {exc.code} for {path.split('?')[0]}") from exc
        except (OSError, ValueError) as exc:
            raise PackageWaitError(f"GitHub package API failed: {type(exc).__name__}") from exc
        if not isinstance(result, dict):
            raise PackageWaitError("GitHub returned a non-object API response")
        return result
    return fetch


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--head-sha", required=True)
    parser.add_argument("--base-sha", required=True)
    parser.add_argument("--tested-sha", required=True)
    parser.add_argument("--event", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout-seconds", type=float, default=3300)
    parser.add_argument("--workflow-path", default=PACKAGE_WORKFLOW)
    parser.add_argument("--run-id", type=int)
    parser.add_argument("--job-prefix", default="")
    args = parser.parse_args()
    output = Path(args.output)
    evidence = None
    try:
        if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", args.repository):
            raise PackageWaitError("Invalid repository name")
        token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
        if not token:
            raise PackageWaitError("Read-only GitHub token is missing")
        plan = json.loads(Path(args.plan).read_text())
        evidence = wait_for_packages(repository=args.repository, head_sha=args.head_sha,
            tested_sha=args.tested_sha, event=args.event, plan=plan, fetch=api_fetcher(token),
            timeout_seconds=args.timeout_seconds, workflow_path=args.workflow_path,
            run_id=args.run_id, job_prefix=args.job_prefix, base_sha=args.base_sha, report=lambda value: print(value, flush=True))
        status = 0
    except (PackageWaitError, OSError, ValueError, TypeError) as exc:
        evidence = getattr(exc, "evidence", None) or {"error": str(exc)}
        print(f"PACKAGE GATE FAIL: {exc}", file=sys.stderr)
        status = 1
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(evidence, sort_keys=True, indent=2) + "\n")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
