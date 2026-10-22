#!/usr/bin/env python3
"""Project hygiene checks that need no simulator (ORG-1, ORG-4, ORG-11).

1. ERROR: a top-level `*Tests` folder, or a tracked `*Tests.swift` file outside `Packages/`, that no
   test target in project.yml compiles. Such tests silently never run (StrandTests is allowlisted until
   its remaining files are ported).
2. WARN: `MARKETING_VERSION` in project.yml differs from the newest release in AppChangelog.swift.
3. ERROR: a project.yml source or package path whose case does not match the paths Git tracks. A
   case-insensitive disk hides this; a case-sensitive CI checkout fails on it.
4. ERROR: a tracked Linux capture-workbench private file (capture database, captures/, venv, JSON
   export), or a capture path that the ignore rules do not cover under both spellings of the tools
   folder. Captures carry the strap serial, session token and MAC.

project.yml is read with a small indentation-based reader for the XcodeGen layout used here, so the audit
runs on a bare Linux runner without PyYAML.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# Folders whose tests are known not to be in any target yet; remove an entry once the folder is gone.
ALLOWLISTED_ORPHAN_TEST_FOLDERS = {"StrandTests"}

CHANGELOG_PATH = "Strand/System/AppChangelog.swift"

PRIVATE_CAPTURE = re.compile(
    r"(^|/)linux-capture/(captures/|\.venv[^/]*/|(.*/)?[^/]*\.db(-wal|-shm)?$|(.*/)?[^/]*\.json$)",
    re.IGNORECASE)
# Paths that must be ignored under both spellings of the tools folder, including nested export and
# database outputs (`whoop_sync.py` creates the parent folders of --out and --db).
CAPTURE_PROBES = tuple(
    f"{folder}/linux-capture/{leaf}"
    for folder in ("tools", "Tools")
    for leaf in ("captures/whoop.db", "whoop.db", "whoop.db-wal", "export.json", ".venv/bin/python",
                 "exports/all.json", "runs/whoop.db", "runs/whoop.db-wal", "runs/whoop.db-shm")
)


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _strip_value(value: str) -> str:
    value = value.split(" #", 1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def parse_targets(text: str) -> dict[str, dict]:
    """Return {target: {"type": str, "sources": [path, ...]}} from an XcodeGen project.yml."""
    targets: dict[str, dict] = {}
    lines = text.splitlines()
    in_targets = False
    current: str | None = None
    target_indent = None
    in_sources = False
    sources_indent = 0
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = _indent(raw)
        line = raw.strip()
        if indent == 0:
            in_targets = line == "targets:"
            current = None
            in_sources = False
            continue
        if not in_targets:
            continue
        if target_indent is None:
            target_indent = indent
        if indent == target_indent and line.endswith(":"):
            current = line[:-1].strip()
            targets[current] = {"type": "", "sources": []}
            in_sources = False
            continue
        if current is None:
            continue
        if in_sources and indent <= sources_indent:
            in_sources = False
        if not in_sources and indent == target_indent + 2:
            if line.startswith("type:"):
                targets[current]["type"] = _strip_value(line[len("type:"):])
            elif line == "sources:":
                in_sources = True
                sources_indent = indent
            continue
        if in_sources and line.startswith("- "):
            item = line[2:].strip()
            if item.startswith("path:"):
                targets[current]["sources"].append(_strip_value(item[len("path:"):]))
            elif ":" not in item:
                targets[current]["sources"].append(_strip_value(item))
    return targets


def parse_package_paths(text: str) -> list[str]:
    """Local package paths (`packages: <Name>: path: <path>`)."""
    paths: list[str] = []
    in_packages = False
    for raw in text.splitlines():
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        if _indent(raw) == 0:
            in_packages = raw.strip() == "packages:"
            continue
        if in_packages and raw.strip().startswith("path:"):
            paths.append(_strip_value(raw.strip()[len("path:"):]))
    return paths


def parse_marketing_version(text: str) -> str | None:
    match = re.search(r"^\s*MARKETING_VERSION:\s*(.+)$", text, re.MULTILINE)
    return _strip_value(match.group(1)) if match else None


def newest_changelog_version(swift_text: str) -> str | None:
    marker = swift_text.find("static let releases")
    if marker < 0:
        return None
    match = re.search(r'(?:\.fork\("|version:\s*")([^"]+)"', swift_text[marker:])
    return match.group(1) if match else None


def tracked_files(root: Path) -> list[str]:
    result = subprocess.run(["git", "ls-files", "-z"], cwd=root, check=True, stdout=subprocess.PIPE)
    return [item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def _under(path: str, prefix: str) -> bool:
    prefix = prefix.rstrip("/")
    return path == prefix or path.startswith(prefix + "/")


def check_test_membership(targets: dict[str, dict], files: list[str],
                          allowlist: set[str] = ALLOWLISTED_ORPHAN_TEST_FOLDERS) -> list[str]:
    test_sources = [
        source for target in targets.values() if target["type"].startswith("bundle.")
        for source in target["sources"]
    ]
    errors: list[str] = []
    top_level_test_folders = sorted({
        path.split("/", 1)[0] for path in files
        if "/" in path and path.split("/", 1)[0].endswith("Tests")
    })
    for folder in top_level_test_folders:
        if folder in allowlist:
            continue
        if not any(_under(folder, source) or _under(source, folder) for source in test_sources):
            errors.append(f"test folder `{folder}/` is not a source of any test target in project.yml")
    for path in files:
        if not path.endswith("Tests.swift") or path.startswith("Packages/"):
            continue
        if path.split("/", 1)[0] in allowlist:
            continue
        if not any(_under(path, source) for source in test_sources):
            errors.append(f"`{path}` is outside every test target in project.yml, so it never runs")
    return errors


def check_version_drift(project_text: str, changelog_text: str | None) -> list[str]:
    marketing = parse_marketing_version(project_text)
    newest = newest_changelog_version(changelog_text) if changelog_text is not None else None
    if marketing and newest and marketing != newest:
        return [f"MARKETING_VERSION {marketing} differs from AppChangelog's newest release {newest}"]
    return []


def check_path_case(paths: list[str], files: list[str]) -> list[str]:
    errors: list[str] = []
    for declared in paths:
        exact = [path for path in files if _under(path, declared)]
        if exact:
            continue
        folded = [path for path in files if _under(path.lower(), declared.lower())]
        if folded:
            actual = folded[0][: len(declared.rstrip("/"))]
            errors.append(f"project.yml path `{declared}` does not match Git's case `{actual}`")
    return errors


def check_private_captures(root: Path, files: list[str]) -> list[str]:
    errors = [f"private capture file is tracked: `{path}`" for path in files if PRIVATE_CAPTURE.search(path)]
    # Evaluate the ROOT .gitignore alone, as a case-sensitive (Linux) checkout would: a folder's own
    # .gitignore only exists under one spelling there, while a case-insensitive disk would find it under
    # both and hide the gap. So the probes run in a scratch repo holding just a copy of the root rules,
    # hermetic: no inherited GIT_* variables, no global or system config, and no global excludes file
    # (a developer's ~/.config/git/ignore listing `*.db` would otherwise pass a missing root rule).
    root_rules = (root / ".gitignore").read_text(encoding="utf-8") if (root / ".gitignore").is_file() else ""
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    with tempfile.TemporaryDirectory() as scratch:
        subprocess.run(["git", "init", "-q"], cwd=scratch, env=env, check=True)
        (Path(scratch) / ".gitignore").write_text(root_rules, encoding="utf-8")
        for probe in CAPTURE_PROBES:
            ignored = subprocess.run(
                ["git", "-c", "core.ignorecase=false", "-c", f"core.excludesFile={os.devnull}",
                 "check-ignore", "-q", "--no-index", probe],
                cwd=scratch, env=env).returncode == 0
            if not ignored:
                errors.append(f"capture path `{probe}` is not covered by the root .gitignore")
    return errors


def audit(root: Path = ROOT) -> tuple[list[str], list[str]]:
    project_text = (root / "project.yml").read_text(encoding="utf-8")
    changelog = root / CHANGELOG_PATH
    changelog_text = changelog.read_text(encoding="utf-8") if changelog.is_file() else None
    files = tracked_files(root)
    targets = parse_targets(project_text)
    declared_paths = [source for target in targets.values() for source in target["sources"]]
    declared_paths += parse_package_paths(project_text)
    errors = (check_test_membership(targets, files) + check_path_case(declared_paths, files)
              + check_private_captures(root, files))
    warnings = check_version_drift(project_text, changelog_text)
    return errors, warnings


def main() -> int:
    errors, warnings = audit()
    for line in warnings:
        print(f"project_hygiene_audit: WARN {line}")
    if errors:
        print("project_hygiene_audit: FAIL", file=sys.stderr)
        for line in errors:
            print(f"- {line}", file=sys.stderr)
        return 1
    print("project_hygiene_audit: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
