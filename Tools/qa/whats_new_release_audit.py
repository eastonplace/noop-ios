#!/usr/bin/env python3
"""Every app build has matching release metadata; shared 2.0 staging is explicit.

Checks (see AGENTS.md, "Versions and releases"):
1. The newest release in `Strand/System/AppChangelog.swift` is a `.fork(...)` entry whose version equals
   `MARKETING_VERSION` in `project.yml`, and it has at least one `Feature`.
2. The `AppChangelog.currentVersion` fallback literal equals `MARKETING_VERSION`.
3. On a pull request (GITHUB_BASE_REF set) that changes app or package source, `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` are higher than on the exact PR base, except the one-time fork version reset
   and the owner-authorized shared 2.0 batch. A batch still requires increasing builds and cumulative notes.
"""
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHANGELOG = ROOT / "Strand/System/AppChangelog.swift"
PROJECT = ROOT / "project.yml"
BATCH_PATH = "docs/releases/2.0-batch.json"
SOURCE_PREFIXES = ("Strand/", "StrandiOS/", "StrandiOSShared/", "StrandiOSWidgets/", "Packages/")
SKIP_PARTS = ("/Tests/", "Tests/", "UITests/")

failures = []


def setting(text, key):
    match = re.search(rf'^\s*{key}:\s*"?([^"\n]+)"?\s*$', text, re.M)
    return match.group(1).strip() if match else None


def version_tuple(value):
    return tuple(int(part) for part in re.findall(r"\d+", value))


def staging_20_batch(text):
    """Only the named held batch can reuse 2.0.0; absent/malformed policy grants nothing."""
    try:
        policy = json.loads(text)
    except (TypeError, ValueError):
        return False
    return isinstance(policy, dict) and all(policy.get(key) == value for key, value in {
        "version": "2.0.0", "status": "staging", "phone_installs": "hold",
        "release_publication": "hold",
    }.items())


def active_20_notes(text, *, swift):
    if not swift:
        match = re.search(r'^## 2\.0\.0(?:[ \t][^\n]*)?\n.*?(?=^## |\Z)', text, re.M | re.S)
        return match.group(0).strip() if match and match.group(0).split("\n", 1)[1].strip() else None
    match = re.search(r'\.fork\("2\.0\.0"', text)
    if not match:
        return None
    depth, quoted, escaped = 0, False, False
    for index in range(text.index("(", match.start()), len(text)):
        char = text[index]
        if quoted:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                quoted = False
        elif char == '"':
            quoted = True
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return text[match.start():index + 1]
    return None


project = PROJECT.read_text()
marketing = setting(project, "MARKETING_VERSION")
build = setting(project, "CURRENT_PROJECT_VERSION")
changelog = CHANGELOG.read_text()
batch_file = ROOT / BATCH_PATH
head_staging_batch = staging_20_batch(batch_file.read_text() if batch_file.is_file() else None)
if head_staging_batch and marketing != "2.0.0":
    failures.append("The active shared 2.0 batch must keep MARKETING_VERSION at 2.0.0 until owner signoff.")

releases = changelog[changelog.index("static let releases"):]
if len(re.findall(r'\.fork\("' + re.escape(marketing or "") + r'"', releases)) > 1:
    failures.append(f"Keep one cumulative What's New entry for {marketing}, not duplicate release entries.")
first = re.search(r'(\.fork\("([^"]+)"|version:\s*"([^"]+)")', releases)
if not first or not first.group(2):
    failures.append("The newest release in AppChangelog.releases must be a `.fork(...)` entry with Features.")
elif first.group(2) != marketing:
    failures.append(f"MARKETING_VERSION is {marketing} but the newest What's New entry is {first.group(2)}. "
                    "Add a `.fork(\"" + str(marketing) + "\", ...)` entry at the top of AppChangelog.releases.")
else:
    block = releases[first.start():]
    end = block.find(".fork(", 1)
    block = block[: end if end > 0 else block.find("Release(")]
    if "Feature(" not in block:
        failures.append(f"The What's New entry for {marketing} has no Feature rows.")

fallback = re.search(r'CFBundleShortVersionString"\] as\? String\) \?\? "([^"]+)"', changelog)
if not fallback or fallback.group(1) != marketing:
    failures.append(f"AppChangelog.currentVersion's fallback literal must be {marketing}.")

base_ref = os.environ.get("GITHUB_BASE_REF")
if base_ref:
    try:
        # CI provides immutable PR refs and a full checkout. Never turn missing history or a moving branch
        # into an exemption: local PR checks can use an already-fetched origin/<base> and HEAD instead.
        base = os.environ.get("GITHUB_BASE_SHA") or f"origin/{base_ref}"
        head = os.environ.get("GITHUB_HEAD_SHA") or "HEAD"
        subprocess.run(["git", "merge-base", base, head], cwd=ROOT, check=True, capture_output=True, text=True)
        changed = subprocess.run(["git", "diff", "--name-only", f"{base}...{head}"], cwd=ROOT,
                                 check=True, capture_output=True, text=True).stdout.split()
        base_project = subprocess.run(["git", "show", f"{base}:project.yml"], cwd=ROOT,
                                      check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as error:
        failures.append(f"Could not compare the exact PR base/head ({error}). Fetch complete PR history and retry.")
    else:
        touches_app = any(path.startswith(SOURCE_PREFIXES) and not any(part in path for part in SKIP_PARTS)
                          for path in changed)
        base_marketing = setting(base_project, "MARKETING_VERSION")
        base_build = setting(base_project, "CURRENT_PROJECT_VERSION")
        # Only marketing numbering resets from upstream 9.x to this fork's 1.x. Build numbers stay monotonic.
        fork_renumbering = version_tuple(base_marketing)[0] >= 9 and version_tuple(marketing)[0] == 1
        # An incoming PR cannot authorize its own same-version exemption. The exact base must already
        # contain the owner-authorized held batch, and the head must retain that same staging contract.
        base_batch = subprocess.run(["git", "show", f"{base}:{BATCH_PATH}"], cwd=ROOT,
                                    capture_output=True, text=True)
        same_staging_batch = (marketing == base_marketing == "2.0.0" and head_staging_batch
                              and base_batch.returncode == 0 and staging_20_batch(base_batch.stdout))
        if touches_app:
            if not fork_renumbering and not same_staging_batch and version_tuple(marketing) <= version_tuple(base_marketing):
                failures.append(f"This PR changes app source but MARKETING_VERSION ({marketing}) is not above "
                                f"{base_ref}'s ({base_marketing}). Bump it and add a What's New entry.")
            if same_staging_batch:
                for notes_path in ("Strand/System/AppChangelog.swift", "CHANGELOG.md"):
                    base_notes = subprocess.run(["git", "show", f"{base}:{notes_path}"], cwd=ROOT,
                                                capture_output=True, text=True)
                    head_notes = ROOT / notes_path
                    swift = notes_path.endswith(".swift")
                    prior = active_20_notes(base_notes.stdout, swift=swift)
                    current = active_20_notes(head_notes.read_text(), swift=swift) if head_notes.is_file() else None
                    if base_notes.returncode != 0 or not prior or not current or current == prior:
                        failures.append(f"A shared 2.0 app change must update the cumulative 2.0 notes in {notes_path}.")
            if int(build) <= int(base_build):
                failures.append(f"CURRENT_PROJECT_VERSION ({build}) must be above {base_ref}'s ({base_build}).")

if failures:
    print("What's New release audit FAILED (see AGENTS.md, 'Versions and releases'):")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print(f"What's New release audit passed: {marketing} (build {build}) has its What's New entry.")
