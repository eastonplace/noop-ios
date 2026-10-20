#!/usr/bin/env python3
"""Validate the design catalog. This does not execute Noop's Swift notification code."""
from __future__ import annotations

import collections
import json
import re
import string
import sys
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parents[1]
DOMAINS = {"Sleep", "Recovery", "Workouts", "Strength", "Training", "Habits", "Stress", "Coaching", "Device", "Data"}
PHASES = {"P1", "P2", "P3", "Deferred"}
PRESETS = {"essentials_candidate", "opt_in", "in_app_only"}
READINESS = {"existing_data_new_rule", "upstream_port", "pr62_dependency", "new_data_dependency"}
CHANNELS = {"local_notification", "in_app", "digest"}
DESTINATIONS = {"today.summary", "recovery.detail", "sleep.detail", "sleep.plan", "training.day", "training.load", "workout.detail", "workout.active", "lift.active", "lift.history", "journal.today", "insights.detail", "stress.detail", "coach.thread", "devices.detail", "settings.notifications", "settings.sources", "settings.sleep", "settings.habits", "weekly.review"}
SCOPES = {"logical_day", "sleep_episode", "workout", "plan_revision", "week", "device_episode", "journal_entry", "user_request"}
FAMILY_REQUIRED = {"family_id", "name", "domain", "purpose", "phase", "preset", "readiness", "required_data", "existing_code", "dependencies", "source_urls", "cooldown_hours", "ttl_minutes", "dedupe_scope"}
SCENARIO_REQUIRED = {"id", "family_id", "scenario", "trigger", "context", "title", "body_template", "example_values", "action_label", "destination", "delivery", "delivery_window", "priority", "suppression", "acceptance"}


def validate() -> tuple[dict, list[str]]:
    catalog = json.loads((ROOT / "catalog" / "notification_catalog.json").read_text())
    families = catalog["families"]
    cases = catalog["scenarios"]
    errors: list[str] = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    require(len(families) == 54, f"Expected 54 families; found {len(families)}")
    require(len(cases) == 540, f"Expected 540 positive scenarios; found {len(cases)}")
    require(len({x.get("family_id") for x in families}) == len(families), "Duplicate family IDs")
    require(len({x.get("id") for x in cases}) == len(cases), "Duplicate scenario IDs")
    family_by_id = {x["family_id"]: x for x in families}

    for f in families:
        fid = f["family_id"]
        require(FAMILY_REQUIRED <= f.keys(), f"{fid}: missing fields {FAMILY_REQUIRED - f.keys()}")
        for key, allowed in (("domain", DOMAINS), ("phase", PHASES), ("preset", PRESETS), ("readiness", READINESS), ("dedupe_scope", SCOPES)):
            require(f.get(key) in allowed, f"{fid}: invalid {key}: {f.get(key)}")
        require(isinstance(f.get("required_data"), list) and bool(f["required_data"]), f"{fid}: data requirements missing")
        require(isinstance(f.get("cooldown_hours"), int) and f["cooldown_hours"] >= 0, f"{fid}: invalid cooldown")
        require(isinstance(f.get("ttl_minutes"), int) and f["ttl_minutes"] > 0, f"{fid}: invalid TTL")
        require(bool(f.get("source_urls")), f"{fid}: source links missing")
        for url in f.get("source_urls", []):
            require(urlparse(url).scheme == "https" and bool(urlparse(url).hostname), f"{fid}: invalid source URL")
        if f.get("readiness") == "new_data_dependency":
            require(f.get("phase") == "Deferred", f"{fid}: new data dependency is not Deferred")
            require(bool(f.get("dependencies")), f"{fid}: deferred dependency is not named")
        if f.get("readiness") == "pr62_dependency":
            require(any("62" in d for d in f.get("dependencies", [])), f"{fid}: PR62 dependency not named")

    normalized_triggers = collections.defaultdict(list)
    rendered = []
    for s in cases:
        sid = s["id"]
        require(SCENARIO_REQUIRED <= s.keys(), f"{sid}: missing fields {SCENARIO_REQUIRED - s.keys()}")
        require(bool(re.fullmatch(r"(SR|WT|HC)\d{3}", sid)), f"{sid}: invalid ID")
        require(s.get("family_id") in family_by_id, f"{sid}: unknown family")
        require(s.get("delivery") in CHANNELS, f"{sid}: invalid delivery")
        require(s.get("destination") in DESTINATIONS, f"{sid}: unknown destination")
        require(isinstance(s.get("priority"), int) and 0 <= s["priority"] <= 100, f"{sid}: invalid priority")
        for key, cap in (("title", 60), ("body_template", 240), ("action_label", 32)):
            require(isinstance(s.get(key), str) and 0 < len(s[key]) <= cap, f"{sid}: {key} length {len(s.get(key, ''))} exceeds {cap}")
        require(isinstance(s.get("suppression"), list) and len(s["suppression"]) >= 3, f"{sid}: fewer than three suppression cases")
        require(isinstance(s.get("example_values"), dict), f"{sid}: example values must be an object")
        required_placeholders = {field for _, field, _, _ in string.Formatter().parse(s.get("body_template", "")) if field}
        require(all(re.fullmatch(r"[a-z][a-z0-9_]*", p) for p in required_placeholders), f"{sid}: invalid placeholder name")
        require(required_placeholders <= s.get("example_values", {}).keys(), f"{sid}: unresolved example placeholders")
        try:
            body = s["body_template"].format(**s["example_values"])
            require(len(body) <= 320, f"{sid}: rendered detailed body too long")
            rendered.append({"id": sid, "title": s["title"], "body": body})
        except (KeyError, ValueError, TypeError) as error:
            errors.append(f"{sid}: rendering error: {error}")
        for key in ("scenario", "trigger", "context", "title", "body_template", "action_label", "delivery_window", "acceptance"):
            require(isinstance(s.get(key), str) and bool(s[key].strip()), f"{sid}: empty {key}")
            require("\u2014" not in s.get(key, ""), f"{sid}: em dash in {key}")
        normalized_triggers[re.sub(r"\s+", " ", s.get("trigger", "").strip().lower())].append(sid)
        require(all(word in s.get("acceptance", "").lower() for word in ("given", "when", "then")), f"{sid}: acceptance lacks Given/When/Then")
        if "public_title" in s:
            require(len(s["public_title"]) <= 60 and len(s["public_body"]) <= 180, f"{sid}: private-preview limits exceeded")
            require("{" not in s["public_body"], f"{sid}: private preview has metric placeholders")

    duplicate_triggers = {k: v for k, v in normalized_triggers.items() if len(v) > 1}
    require(not duplicate_triggers, f"Exact normalized duplicate triggers: {duplicate_triggers}")
    per_family = collections.Counter(s["family_id"] for s in cases)
    require(all(per_family[fid] == 10 for fid in family_by_id), "Every family must have exactly ten scenarios")
    for prefix in ("SR", "WT", "HC"):
        actual = {s["id"] for s in cases if s["id"].startswith(prefix)}
        expected = {f"{prefix}{n:03d}" for n in range(1, 181)}
        require(actual == expected, f"{prefix}: IDs are not contiguous 001..180")

    failures_file = ROOT / "validation" / "failure_matrix.json"
    failure_cases = json.loads(failures_file.read_text())["cases"] if failures_file.exists() else []
    require(len(failure_cases) >= 80, "Expected at least 80 separate failure/platform cases")
    require(len({x["id"] for x in failure_cases}) == len(failure_cases), "Duplicate failure-case IDs")
    require(not ({x["id"] for x in cases} & {x["id"] for x in failure_cases}), "Failure cases counted as positive scenarios")

    report = {
        "status": "passed" if not errors else "failed",
        "scope": "Catalog structure, references, exact duplicate triggers, example rendering, and separate QA inventory only.",
        "positive_scenarios": len(cases),
        "families": len(families),
        "cases_per_family": dict(sorted(per_family.items())),
        "delivery_counts": dict(collections.Counter(s["delivery"] for s in cases)),
        "phase_counts": dict(collections.Counter(family_by_id[s["family_id"]]["phase"] for s in cases)),
        "domain_counts": dict(collections.Counter(family_by_id[s["family_id"]]["domain"] for s in cases)),
        "readiness_counts": dict(collections.Counter(family_by_id[s["family_id"]]["readiness"] for s in cases)),
        "rendered_examples": len(rendered),
        "exact_duplicate_triggers": len(duplicate_triggers),
        "separate_failure_platform_cases": len(failure_cases),
        "production_swift_build": "not_run",
        "production_swift_tests": "not_run",
        "physical_iphone_tests": "not_run",
        "real_notification_delivery": "not_run",
        "errors": errors,
    }
    (ROOT / "validation" / "VALIDATION_REPORT.json").write_text(json.dumps(report, indent=2) + "\n")
    (ROOT / "catalog" / "rendered_examples.json").write_text(json.dumps(rendered, indent=2, ensure_ascii=False) + "\n")
    return report, errors


if __name__ == "__main__":
    result, problems = validate()
    print(json.dumps(result, indent=2))
    sys.exit(bool(problems))
