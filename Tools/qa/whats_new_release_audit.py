#!/usr/bin/env python3
"""Every app version ships a What's New entry, and every user-facing PR ships a new version.

Checks (see AGENTS.md, "Versions and releases"):
1. The newest release in `Strand/System/AppChangelog.swift` is a `.fork(...)` entry whose version equals
   `MARKETING_VERSION` in `project.yml`, and it has at least one `Feature`.
2. The `AppChangelog.currentVersion` fallback literal equals `MARKETING_VERSION`.
3. On a pull request (GITHUB_BASE_REF set) that changes app or package source, `MARKETING_VERSION` and
   `CURRENT_PROJECT_VERSION` are both higher than on the base branch.
"""
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHANGELOG = ROOT / "Strand/System/AppChangelog.swift"
PROJECT = ROOT / "project.yml"
SOURCE_PREFIXES = ("Strand/", "StrandiOS/", "StrandiOSShared/", "StrandiOSWidgets/", "Packages/")
SKIP_PARTS = ("/Tests/", "Tests/", "UITests/")

failures = []


def setting(text, key):
    match = re.search(rf'^\s*{key}:\s*"?([^"\n]+)"?\s*$', text, re.M)
    return match.group(1).strip() if match else None


def version_tuple(value):
    return tuple(int(part) for part in re.findall(r"\d+", value))


project = PROJECT.read_text()
marketing = setting(project, "MARKETING_VERSION")
build = setting(project, "CURRENT_PROJECT_VERSION")
changelog = CHANGELOG.read_text()

releases = changelog[changelog.index("static let releases"):]
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
        subprocess.run(["git", "fetch", "--quiet", "--depth=50", "origin", base_ref], cwd=ROOT, check=True)
        changed = subprocess.run(["git", "diff", "--name-only", f"origin/{base_ref}...HEAD"], cwd=ROOT,
                                 check=True, capture_output=True, text=True).stdout.split()
        base_project = subprocess.run(["git", "show", f"origin/{base_ref}:project.yml"], cwd=ROOT,
                                      check=True, capture_output=True, text=True).stdout
    except subprocess.CalledProcessError as error:
        print(f"warning: could not compare with origin/{base_ref} ({error}); skipping the bump check")
    else:
        touches_app = any(path.startswith(SOURCE_PREFIXES) and not any(part in path for part in SKIP_PARTS)
                          for path in changed)
        base_marketing = setting(base_project, "MARKETING_VERSION")
        base_build = setting(base_project, "CURRENT_PROJECT_VERSION")
        # The base still on upstream numbering (9.x) is the one-time renumbering to 1.x: nothing to compare.
        base_is_upstream = version_tuple(base_marketing)[0] >= 9
        if touches_app and not base_is_upstream:
            if version_tuple(marketing) <= version_tuple(base_marketing):
                failures.append(f"This PR changes app source but MARKETING_VERSION ({marketing}) is not above "
                                f"{base_ref}'s ({base_marketing}). Bump it and add a What's New entry.")
            if int(build) <= int(base_build):
                failures.append(f"CURRENT_PROJECT_VERSION ({build}) must be above {base_ref}'s ({base_build}).")

if failures:
    print("What's New release audit FAILED (see AGENTS.md, 'Versions and releases'):")
    for failure in failures:
        print(f"  - {failure}")
    sys.exit(1)
print(f"What's New release audit passed: {marketing} (build {build}) has its What's New entry.")
