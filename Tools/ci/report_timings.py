#!/usr/bin/env python3
"""Report observed GitHub job timings offline; never predict CI speed.

Input is a list of {run: ID, jobs: GitHub jobs response}. Combine all relevant
workflow jobs for a complete candidate measurement. A single workflow report
does not prove branch protection or merge readiness.
"""
import argparse
from datetime import datetime
import json
import math
from pathlib import Path
import statistics


def stamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None


def duration(start, end):
    a, b = stamp(start), stamp(end)
    if a is None or b is None:
        return None
    if b < a:
        raise ValueError("reversed GitHub timestamps")
    return (b - a).total_seconds()


def percentile(values, fraction):
    return sorted(values)[max(0, math.ceil(len(values) * fraction) - 1)] if values else None


def report(records):
    runs = []
    for record in records:
        raw = record["jobs"]
        jobs = raw.get("jobs", []) if isinstance(raw, dict) else raw
        if not jobs or (isinstance(raw, dict) and raw.get("total_count", len(jobs)) != len(jobs)):
            raise ValueError("empty or paginated job inventory; collect every page first")
        created = [stamp(j.get("created_at")) for j in jobs if j.get("created_at")]
        started = [stamp(j.get("started_at")) for j in jobs if j.get("started_at")]
        finished = [stamp(j.get("completed_at")) for j in jobs if j.get("completed_at")]
        complete = all(j.get("status") == "completed" and j.get("completed_at") for j in jobs)
        passed = complete and all(j.get("conclusion") == "success" for j in jobs)
        origin = min(created) if len(created) == len(jobs) else None
        first = min(started) if started else None
        last = max(finished) if complete else None
        audits = [stamp(j.get("completed_at")) for j in jobs if j.get("name", "").split(" / ")[-1] == "source-audits" and j.get("completed_at")]
        stages = []
        for job in jobs:
            for step in job.get("steps", []):
                if step.get("status") != "completed" or step.get("conclusion") == "skipped":
                    continue
                seconds = duration(step.get("started_at"), step.get("completed_at"))
                if seconds is not None:
                    stages.append({"job": job["name"], "step": step["name"], "conclusion": step.get("conclusion"), "seconds": seconds})
        runs.append({
            "run": record["run"], "jobs_complete": bool(complete), "all_reported_jobs_passed": bool(passed),
            "queue_to_first_start_seconds": (first - origin).total_seconds() if origin and first else None,
            "observed_execution_span_seconds": (last - first).total_seconds() if last and first else None,
            "first_source_feedback_seconds": (min(audits) - origin).total_seconds() if audits and origin else None,
            "successful_reported_jobs_wall_seconds": (last - origin).total_seconds() if passed and origin and last else None,
            "cache_hit_rate": None, "steps": stages,
        })
    values = [r["successful_reported_jobs_wall_seconds"] for r in runs if r["successful_reported_jobs_wall_seconds"] is not None]
    feedback = [r["first_source_feedback_seconds"] for r in runs if r["first_source_feedback_seconds"] is not None]
    return {"scope": "reported jobs only; no branch-protection or merge-ready proof", "runs": runs,
            "successful_run_count": len(values), "median_wall_seconds": statistics.median(values) if values else None,
            "p90_wall_seconds": percentile(values, .9), "median_first_feedback_seconds": statistics.median(feedback) if feedback else None,
            "cache_hit_rate": None}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = json.dumps(report(json.loads(args.input.read_text())), indent=2) + "\n"
    if args.output:
        args.output.write_text(result)
    else:
        print(result, end="")


if __name__ == "__main__":
    main()
