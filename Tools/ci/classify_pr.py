#!/usr/bin/env python3
"""Deterministic, fail-closed CI selection using Git objects, never PR imports.

Run through load_plan.py in CI so the protected base supplies this policy.
This parser deliberately accepts only literal SwiftPM dependency declarations.
It does not execute Package.swift, import repository modules, or modify sources.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys

SCHEMA_VERSION = 1
POLICY_PATH = "Tools/ci/classify_pr.py"
LEGACY_HOST_PACKAGES = (
    "NoopPhase34Core", "WhoopProtocol", "OuraProtocol", "WhoopStore",
    "StrandAnalytics", "StrandImport", "StrandDesign", "NoopLocalAccess",
)
APP_BUILD_PACKAGES = ("CoachPresentation", "ReceiptLiftActivity", "ReceiptLiftFeature")
TODAY_UI = "NOOPCoachUITests/ApprovedDashboardUITests/testTodayNormal"
HIGH_UI = (
    "NOOPCoachUITests/LiftRoutineSelectionTests/testSwitchingSavedRoutinesPreviewsThenStartsTheSelectedRoutine",
    "NOOPCoachUITests/LiftRoutineSelectionTests/testRoutineEditAndSaveRemainSeparateFromStarting",
    TODAY_UI,
    "NOOPCoachUITests/ApprovedDashboardUITests/testDashboardSettingsSelectionPersists",
    "NOOPCoachUITests/ApprovedDashboardUITests/testForkAboutAndWhatsNew",
    "NOOPCoachUITests/ApprovedDashboardUITests/testNewLiveEnrollmentOffersOnlyWHOOP",
    "NOOPCoachUITests/NotificationDestinationUITests/testWHOOPDeviceNormal",
    "NOOPCoachUITests/NotificationDestinationUITests/testSettingsQueuedDismissalNormal",
    "NOOPCoachUITests/SelectedScreenDirectionTests/testLiveHRNormal",
    "NOOPCoachUITests/ApprovedDashboardUITests/testSharedBatteryHeaderAndRecentUpdatesAccessibilityXXXL",
)
SAFETY_NATIVE = (
    "NOOPiOSTests/BLELinkEpitaphTests/testConnectedLinkEmitsOnceAndCountsInboundNotifications",
    "NOOPiOSTests/SleepImportWindowPolicyTests/testInvalidAndOverflowingWindowsFailClosed",
    "NOOPiOSTests/BackgroundFlushOwnershipTests/testExpiredFlushCannotEndOrReplaceANewerAssertion",
    "NOOPiOSTests/CollectorOwnershipTests/testBufferedFramesKeepTheirOriginalOwnerAndClock",
)

# Exact, value-fed display leaves. Mixed view/store/lifecycle files (including
# TodayView, AppHeaderChrome, SettingsView and CoachWelcomeView) stay high risk.
# An unlisted new file cannot enroll itself into the reduced lane.
PRESENTATION = {
    "Strand/Screens/WorkoutSportTitle.swift": "workout",
    "Strand/Screens/WorkoutZoneSummary.swift": "workout",
    "Strand/Screens/WorkoutHeartRateCurve.swift": "workout",
    "Strand/Screens/WorkoutRecentSportChips.swift": "workout",
    "Strand/Screens/WorkoutActivityGrid.swift": "workout",
    "Strand/Screens/LiveWorkoutFigures.swift": "workout",
    "Strand/Screens/LiveWorkoutGlance.swift": "workout",
    "Strand/Screens/ChargeBreakdownFormat.swift": "today",
    "Strand/Screens/LabBookDisclaimerView.swift": "today",
    "Strand/Screens/WhatsNewView.swift": "about",
    "StrandiOS/Coach/CoachProgressView.swift": "coach",
    "StrandiOS/Coach/CoachChatParts.swift": "coach",
}
RUNTIME_TOKENS = re.compile(
    r"\b(?:UserDefaults|AppStorage|Repository|BLEManager|HKHealthStore|HealthKit|"
    r"CoreBluetooth|FileManager|NotificationCenter|URLSession|Task|Timer|"
    r"BGTaskScheduler|ModelContext|SQLite|GRDB|AppModel|EnvironmentObject|"
    r"ObservedObject|StateObject|Observable|async|await)\b|"
    r"\b[A-Za-z_][A-Za-z0-9_]*(?:Store|Repository|Scheduler|Manager)\b|"
    r"\.(?:save|persist|schedule|syncNow|refresh)\s*\("
)
PRESENTATION_IMPORTS = {"Foundation", "SwiftUI", "StrandDesign", "StrandAnalytics", "MarkdownUI", "CoachPresentation"}
SHA_RE = re.compile(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\Z")
IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")


class PlanError(ValueError):
    pass


class UnsupportedLane(PlanError):
    pass


def git(repo, *args, check=True):
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True)
    if check and result.returncode:
        raise PlanError(f"git {args[0]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout if result.returncode == 0 else None


def commit_sha(repo, value):
    # Ref names and option-like inputs are forbidden at the external boundary.
    if not SHA_RE.fullmatch(value or ""):
        raise PlanError("base, head, tested and policy revisions must be exact commit SHAs")
    resolved = git(repo, "rev-parse", "--verify", f"{value}^{{commit}}").decode().strip()
    if resolved != value.lower():
        raise PlanError("revision does not identify the exact supplied commit")
    return resolved


def files_at(repo, sha):
    raw = git(repo, "ls-tree", "-rz", "--full-tree", sha)
    files = {}
    for entry in raw.split(b"\0"):
        if not entry:
            continue
        metadata, path = entry.split(b"\t", 1)
        mode, kind, oid = metadata.decode().split()
        name = path.decode("utf-8", errors="strict")
        if any(c in name for c in "\n\r\0"):
            raise PlanError("unsupported control character in repository path")
        files[name] = (mode, kind, oid)
    return files


def read_at(repo, sha, path):
    return git(repo, "show", f"{sha}:{path}").decode("utf-8", errors="strict")


def parse_diff(raw):
    tokens = raw.split(b"\0")
    if tokens[-1:] != [b""]:
        raise PlanError("unterminated name-status diff")
    changes, index = [], 0
    while index < len(tokens) - 1:
        status = tokens[index].decode("ascii", errors="strict")
        index += 1
        if not re.fullmatch(r"[ACDMRTUXB](?:\d{1,3})?", status):
            raise PlanError(f"unsupported diff status: {status!r}")
        if status[0] in "UXB":
            raise PlanError(f"unresolved diff status: {status}")
        count = 2 if status[0] in "RC" else 1
        if index + count > len(tokens) - 1:
            raise PlanError("truncated name-status diff")
        paths = [token.decode("utf-8", errors="strict") for token in tokens[index:index + count]]
        if any(not path or path.startswith("/") or ".." in PurePosixPath(path).parts or any(c in path for c in "\n\r") for path in paths):
            raise PlanError("unsupported diff path")
        changes.append({"status": status, "paths": paths})
        index += count
    return changes


def strip_comments(text):
    # Preserve string literals so dependency values can be checked; comments must
    # not create false dependencies or test-target declarations.
    pattern = r'"(?:\\.|[^"\\])*"|/\*[\s\S]*?\*/|//[^\n]*'
    return re.sub(pattern, lambda m: m[0] if m[0].startswith('"') else " ", text)


def code_only(text):
    return re.sub(r'"""[\s\S]*?"""|"(?:\\.|[^"\\])*"', '""', strip_comments(text))


def calls(text, expression):
    for match in re.finditer(expression + r"\s*\(", text):
        start = match.end()
        depth, quoted, escape = 1, False, False
        for index in range(start, len(text)):
            ch = text[index]
            if quoted:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == '"':
                    quoted = False
            elif ch == '"':
                quoted = True
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if not depth:
                    yield text[start:index]
                    break
        else:
            raise PlanError("unbalanced SwiftPM declaration")


def split_arguments(text):
    """Split only literal top-level Swift call/array arguments."""
    result, start, stack, quoted, escape = [], 0, [], False, False
    pairs = {")": "(", "]": "[", "}": "{"}
    for index, ch in enumerate(text):
        if quoted:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                quoted = False
        elif ch == '"':
            quoted = True
        elif ch in "([{":
            stack.append(ch)
        elif ch in ")]}":
            if not stack or stack.pop() != pairs[ch]:
                raise PlanError("unbalanced SwiftPM arguments")
        elif ch == "," and not stack:
            if text[start:index].strip():
                result.append(text[start:index].strip())
            start = index + 1
    if stack or quoted:
        raise PlanError("unterminated SwiftPM arguments")
    if text[start:].strip():
        result.append(text[start:].strip())
    return result


def parse_manifest(text, directory):
    text = strip_comments(text)
    if "import PackageDescription" not in text or not re.search(r"\blet\s+package\s*=\s*Package\s*\(", text):
        raise PlanError(f"{directory}: unsupported package declaration")
    # Dynamic manifests cannot be inferred without executing untrusted Swift.
    if re.search(r"#(?:if|elseif)|\b(?:if|switch|Process|ProcessInfo|CommandLine|environment)\b", code_only(text)):
        raise PlanError(f"{directory}: dynamic manifest requires full/manual validation")
    package_calls = list(calls(text, r"\bPackage"))
    if len(package_calls) != 1:
        raise PlanError(f"{directory}: ambiguous Package declaration")
    fields = {}
    for argument in split_arguments(package_calls[0]):
        field = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_]*)\s*:\s*([\s\S]+)", argument)
        if not field or field[1] in fields:
            raise PlanError(f"{directory}: unsupported/duplicate manifest field")
        fields[field[1]] = field[2].strip()
    for field in ("platforms", "targets"):
        if not fields.get(field, "").startswith("[") or not fields[field].endswith("]"):
            raise PlanError(f"{directory}: {field} must be a literal array")
    match = re.match(r'\s*name\s*:\s*"([A-Za-z_][A-Za-z0-9_]*)"\s*[,)]', package_calls[0])
    if not match or match[1] != directory:
        raise PlanError(f"{directory}: package name must match its directory")
    dependencies = []
    dependencies_text = fields.get("dependencies", "[]")
    if not dependencies_text.startswith("[") or not dependencies_text.endswith("]"):
        raise PlanError(f"{directory}: dependencies must be a literal array")
    for dependency in split_arguments(dependencies_text[1:-1]):
        declarations = list(calls(dependency, r"\.package"))
        if len(declarations) != 1 or not re.fullmatch(r"\.package\s*\(" + re.escape(declarations[0]) + r"\)", dependency):
            raise PlanError(f"{directory}: unsupported dependency expression")
        declaration = declarations[0]
        local = re.fullmatch(r'\s*(?:name\s*:\s*"[A-Za-z_][A-Za-z0-9_]*"\s*,\s*)?path\s*:\s*"\.\./([A-Za-z_][A-Za-z0-9_]*)"\s*,?\s*', declaration)
        remote = re.fullmatch(r'\s*url\s*:\s*"https://[^"\\]+"\s*,\s*exact\s*:\s*"[^"\\]+"\s*,?\s*', declaration)
        if local:
            dependencies.append(local[1])
        elif not remote:
            raise PlanError(f"{directory}: nonliteral/unpinned dependency")
    test_target = bool(re.search(r"\.testTarget\s*\(", fields["targets"]))
    host = bool(re.search(r"\.macOS\s*\(", fields["platforms"]))
    if test_target and host:
        lane = "host_test"
    elif directory in APP_BUILD_PACKAGES and not test_target:
        lane = "app_build"
    else:
        raise UnsupportedLane(f"{directory}: no supported validation lane")
    return {"package": directory, "lane": lane, "dependencies": sorted(set(dependencies))}


def package_inventory(repo, sha, files):
    inventory, errors = {}, []
    for path in sorted(files):
        match = re.fullmatch(r"Packages/([^/]+)/Package\.swift", path)
        if not match:
            if path.startswith("Packages/") and path.endswith("/Package.swift"):
                raise UnsupportedLane(f"uncovered nested package manifest: {path}")
            continue
        name = match[1]
        if not IDENTIFIER.fullmatch(name):
            raise PlanError("unsupported package directory")
        try:
            if files[path][0] != "100644":
                raise PlanError(f"{name}: package manifest is not a regular file")
            inventory[name] = parse_manifest(read_at(repo, sha, path), name)
        except UnsupportedLane:
            raise
        except PlanError as error:
            if name not in LEGACY_HOST_PACKAGES + APP_BUILD_PACKAGES:
                raise
            errors.append(str(error))
            inventory[name] = {"package": name, "lane": "host_test" if name in LEGACY_HOST_PACKAGES else "app_build", "dependencies": []}
    for name, item in inventory.items():
        for dependency in item["dependencies"]:
            if dependency not in inventory:
                errors.append(f"{name}: unresolved local dependency {dependency} at {sha}")
    if not inventory:
        raise PlanError("no package inventory available")
    return inventory, errors


def discover_tests(repo, sha, files, folder, target):
    selectors, by_stem = set(), {}
    for path in sorted(files):
        if not path.startswith(folder + "/") or not path.endswith(".swift"):
            continue
        text = code_only(read_at(repo, sha, path))
        classes = list(re.finditer(r"\bclass\s+([A-Za-z_][A-Za-z0-9_]*)\s*:\s*XCTestCase\b", text))
        found = set()
        for index, declaration in enumerate(classes):
            end = classes[index + 1].start() if index + 1 < len(classes) else len(text)
            for method in re.finditer(r"\bfunc\s+(test[A-Za-z0-9_]*)\s*\(", text[declaration.end():end]):
                found.add(f"{target}/{declaration[1]}/{method[1]}")
        selectors.update(found)
        by_stem[PurePosixPath(path).stem] = found
    if not selectors:
        raise PlanError(f"no XCTest inventory found for {target}")
    return selectors, by_stem


def version_only(repo, old, head):
    before = read_at(repo, old, "project.yml")
    after = read_at(repo, head, "project.yml")
    pattern = r"^(\s*)(MARKETING_VERSION|CURRENT_PROJECT_VERSION):\s*(\S+)\s*$"
    def normalize(text):
        values = {}
        lines = []
        for line in text.splitlines():
            match = re.fullmatch(pattern, line)
            if match:
                key, value = match[2], match[3]
                if key in values:
                    raise PlanError("duplicate version setting")
                if not re.fullmatch(r"\d+\.\d+\.\d+" if key == "MARKETING_VERSION" else r"\d+", value):
                    raise PlanError("unsupported version value")
                values[key] = value
                lines.append(f"{match[1]}{key}: <VERSION>")
            else:
                lines.append(line)
        if set(values) != {"MARKETING_VERSION", "CURRENT_PROJECT_VERSION"}:
            raise PlanError("missing version setting")
        return lines
    try:
        return normalize(before) == normalize(after)
    except PlanError:
        return False


def presentation_is_safe(text):
    code = code_only(text)
    imports = set(re.findall(r"(?m)^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)", code))
    return imports <= PRESENTATION_IMPORTS and not RUNTIME_TOKENS.search(code)


def ui_for_groups(groups, available):
    wanted = {TODAY_UI}
    if "about" in groups:
        wanted.add("NOOPCoachUITests/ApprovedDashboardUITests/testForkAboutAndWhatsNew")
    if "coach" in groups:
        wanted.update(selector for selector in available if "/LocalCoachShellTests/" in selector or "/CoachKeyboardLayoutTests/" in selector)
    if "lift" in groups:
        wanted.update(selector for selector in available if "/LiftRoutineSelectionTests/" in selector or "/LiftAccessibilityLoggingTests/" in selector)
    if "settings" in groups:
        wanted.update(selector for selector in available if "/SettingsSheetTests/" in selector or "/testDashboardSettings" in selector or "/testSettingsRootDoneAlignment" in selector)
    if "notifications" in groups:
        wanted.update(selector for selector in available if "/NotificationSettingsUITests/" in selector or "/NotificationDestinationUITests/" in selector)
    if "whoop" in groups:
        wanted.update(selector for selector in available if any(token in selector for token in ("/testWHOOP", "/testDeviceRegistry", "/testNewLiveEnrollment", "/testSharedBattery")))
    if "dashboard" in groups:
        wanted.update(selector for selector in available if "/testToday" in selector or "/testDashboardSettings" in selector)
    if "sleep" in groups:
        wanted.update(selector for selector in available if "/testPreservedSleep" in selector or "/testDaySleepWeekly" in selector)
    if "live" in groups:
        wanted.update(selector for selector in available if "/testLiveHR" in selector)
    # Workout display leaves use native presentation tests and Today's workout
    # rendering. Lift editor/persistence files are not in this reduced allowlist.
    return wanted


def plan_hash(plan):
    payload = {key: value for key, value in plan.items() if key != "plan_hash"}
    return hashlib.sha256(json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def validate_plan(plan):
    if plan.get("schema_version") != SCHEMA_VERSION or plan.get("mode") not in {"docs", "ui", "high", "full"}:
        raise PlanError("unsupported plan schema/mode")
    for key in ("base_sha", "head_sha", "tested_sha", "policy_sha"):
        if not SHA_RE.fullmatch(plan.get(key, "")):
            raise PlanError(f"invalid {key}")
    if plan.get("plan_hash") != plan_hash(plan):
        raise PlanError("plan hash mismatch")
    if plan.get("native_level") not in {"none", "smoke", "full"} or type(plan.get("run_app")) is not bool:
        raise PlanError("invalid native/app lane")
    for key in ("native_tests", "ui_tests", "host_packages", "host_matrix", "package_validation", "reasons"):
        if not isinstance(plan.get(key), list):
            raise PlanError(f"invalid {key}")
    return plan


def classify(repo, base, head, event="pull_request", tested_sha=None, full=False, policy_sha=None, bootstrap=False):
    repo = Path(repo).resolve()
    base, head = commit_sha(repo, base), commit_sha(repo, head)
    tested = commit_sha(repo, tested_sha or head)
    policy = commit_sha(repo, policy_sha or base)
    if policy != base:
        raise PlanError("policy must come from the exact protected base")
    if tested != head:
        for ancestor in (base, head):
            if git(repo, "merge-base", "--is-ancestor", ancestor, tested, check=False) is None:
                raise PlanError("tested commit must contain both the exact base and PR head")
    merge_base = git(repo, "merge-base", base, head).decode().strip()
    if not merge_base:
        raise PlanError("no merge base")
    base_files, head_files = files_at(repo, base), files_at(repo, head)
    tested_files = head_files if tested == head else files_at(repo, tested)
    changes = parse_diff(git(repo, "diff", "--name-status", "-z", "--find-renames", "--find-copies", merge_base, head, "--"))
    paths = sorted({path for change in changes for path in change["paths"]})
    base_inventory, base_errors = package_inventory(repo, base, base_files)
    head_inventory, head_errors = package_inventory(repo, head, head_files)
    tested_inventory, tested_errors = (head_inventory, []) if tested == head else package_inventory(repo, tested, tested_files)
    errors = sorted(set(base_errors + head_errors + tested_errors))
    native_available, native_by_stem = discover_tests(repo, tested, tested_files, "StrandiOSTests", "NOOPiOSTests")
    ui_available, ui_by_stem = discover_tests(repo, tested, tested_files, "StrandiOSUITests", "NOOPCoachUITests")
    missing = (set(SAFETY_NATIVE) - native_available) | (set(HIGH_UI) - ui_available)
    if missing:
        raise PlanError("policy selectors absent from tested source: " + ", ".join(sorted(missing)))
    bootstrap = bootstrap or POLICY_PATH not in base_files
    mode, reasons, groups, changed_packages = "docs", [], set(), set()
    rank = {"docs": 0, "ui": 1, "high": 2, "full": 3}
    def require(level, reason):
        nonlocal mode
        if rank[level] > rank[mode]:
            mode = level
        reasons.append(reason)
    if full or event in {"schedule", "release"}:
        require("full", "explicit full/nightly/release validation")
    elif event not in {"pull_request", "push", "workflow_dispatch", "workflow_call"}:
        require("high", f"unrecognized event: {event}")
    if bootstrap:
        require("high", "protected-base classifier absent: bootstrap preserves full native, ten UI and all host packages")
    if errors:
        require("high", "package inventory uncertainty selects every supported validation lane")
    for path in paths:
        if path.startswith("StrandiOS/Coach/"):
            groups.add("coach")
        if path.startswith(("Packages/ReceiptLift", "Strand/Screens/Lift", "Strand/Screens/NoopReceiptLift")):
            groups.add("lift")
        if "Settings" in PurePosixPath(path).stem and path.endswith(".swift"):
            groups.add("settings")
        if "Notification" in PurePosixPath(path).stem and path.endswith(".swift"):
            groups.add("notifications")
        if path.startswith(("Strand/BLE/", "Packages/WhoopProtocol/")) or "WhoopDevice" in path:
            groups.update(("whoop", "live"))
        if path in {"Strand/Screens/TodayView.swift", "Strand/Screens/TodayDashboardSettingsView.swift", "Strand/Screens/DashboardCardsEditorSheet.swift"}:
            groups.add("dashboard")
        if path.startswith("Strand/Screens/Sleep"):
            groups.add("sleep")
        if path == "Strand/Screens/LiveView.swift":
            groups.add("live")
        package_match = re.match(r"Packages/([^/]+)/", path)
        if package_match:
            changed_packages.add(package_match[1])
        if path in tested_files and tested_files[path][0] not in {"100644", "100755"}:
            require("high", f"nonregular file or submodule changed: {path}")
        elif path == "project.yml":
            if "project.yml" in head_files and version_only(repo, merge_base, head):
                require("ui", "verified version-only project settings")
            else:
                require("high", "project/build settings changed")
        elif path == "Strand/System/AppChangelog.swift":
            text = read_at(repo, tested, path) if path in tested_files else ""
            if presentation_is_safe(text):
                require("ui", "release presentation changed")
                groups.add("about")
            else:
                require("high", "release presentation contains runtime/storage logic")
        elif path in PRESENTATION:
            text = read_at(repo, tested, path) if path in tested_files else ""
            before = read_at(repo, merge_base, path) if git(repo, "cat-file", "-e", f"{merge_base}:{path}", check=False) is not None else ""
            if (path in tested_files and tested_files[path][0] not in {"100644", "100755"}) or not presentation_is_safe(text + "\n" + before):
                require("high", f"presentation file contains runtime/storage logic: {path}")
            else:
                require("ui", f"approved display leaf: {path}")
                groups.add(PRESENTATION[path])
        elif path.startswith("StrandiOS/Resources/Assets.xcassets/") and PurePosixPath(path).suffix.lower() in {".png", ".jpg", ".jpeg", ".pdf", ".json"}:
            require("ui", f"design asset: {path}")
        elif (path.startswith("docs/") and path.endswith(".md") and not any(part in path.lower() for part in ("ci-policy", "ci-contract", "test-selector"))) or path in {"README.md", "CHANGELOG.md", "LICENSE", "NOTICE"}:
            reasons.append(f"documentation: {path}")
        else:
            require("high", f"core/runtime/build/test/policy or unmapped path: {path}")
    if not reasons:
        reasons.append("no changed paths; policy and source audits remain required")
    # Union both graphs, including edges removed in the PR. A removed dependency
    # still selects every surviving consumer that depended on it at the base.
    reverse = {}
    for inventory in (base_inventory, head_inventory, tested_inventory):
        for name, item in inventory.items():
            for dependency in item["dependencies"]:
                reverse.setdefault(dependency, set()).add(name)
    affected = set(changed_packages)
    pending = list(affected)
    while pending:
        for consumer in reverse.get(pending.pop(), ()):
            if consumer not in affected:
                affected.add(consumer)
                pending.append(consumer)
    all_hosts = {name for name, item in tested_inventory.items() if item["lane"] == "host_test"}
    policy_change = any(path.startswith((".github/", "Tools/ci/", "Tools/qa/")) or path == "AGENTS.md" for path in paths)
    if full or mode == "full" or bootstrap or errors or policy_change:
        affected.update(tested_inventory)
        selected_hosts = all_hosts
    else:
        selected_hosts = all_hosts & affected
    # Any selected app-build package requires the app/extension compilation lane.
    if any(name in affected and item["lane"] == "app_build" for name, item in tested_inventory.items()):
        require("high", "affected iOS/testless package is compiled through app/extensions")
    native_tests = set()
    ui_tests = set()
    if mode == "ui":
        native_tests.update(SAFETY_NATIVE)
        for path in paths:
            native_tests.update(native_by_stem.get(PurePosixPath(path).stem + "Tests", ()))
        ui_tests.update(ui_for_groups(groups, ui_available))
    elif mode in {"high", "full"}:
        native_tests.add("NOOPiOSTests")
        ui_tests.update(ui_available if mode == "full" else set(HIGH_UI) | ui_for_groups(groups, ui_available))
        # Test files changed in a high-risk PR must run even beyond the baseline.
        for path in paths:
            if path.startswith("StrandiOSUITests/"):
                ui_tests.update(ui_by_stem.get(PurePosixPath(path).stem, ()))
    if not ui_tests <= ui_available:
        raise PlanError("selected UI test is absent")
    plan = {
        "schema_version": SCHEMA_VERSION, "base_sha": base, "head_sha": head,
        "tested_sha": tested, "policy_sha": policy, "merge_base_sha": merge_base,
        "mode": mode, "reasons": sorted(set(reasons)), "run_app": mode != "docs",
        "native_level": "none" if mode == "docs" else "smoke" if mode == "ui" else "full",
        "native_tests": sorted(native_tests), "ui_tests": sorted(ui_tests),
        "host_packages": sorted(selected_hosts),
        "host_matrix": [{"package": name, "run": name in selected_hosts, "runner": "macos-26" if name in selected_hosts else "ubuntu-latest"} for name in sorted(set(LEGACY_HOST_PACKAGES) | all_hosts)],
        "package_validation": [dict(item, affected=name in affected) for name, item in sorted(tested_inventory.items())],
        "inventory_errors": errors, "changed_files": changes,
        "ui_inventory": sorted(ui_available), "native_inventory_count": len(native_available),
        "bootstrap": bootstrap,
    }
    plan["plan_hash"] = plan_hash(plan)
    return validate_plan(plan)


def parser():
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--repo", default=".")
    result.add_argument("--base", required=True)
    result.add_argument("--head", required=True)
    result.add_argument("--tested-sha")
    result.add_argument("--policy-sha")
    result.add_argument("--event", default="pull_request")
    result.add_argument("--full", action="store_true")
    result.add_argument("--bootstrap-high", action="store_true")
    result.add_argument("--output", required=True)
    result.add_argument("--github-output")
    return result


def main():
    args = parser().parse_args()
    try:
        plan = classify(args.repo, args.base, args.head, args.event, args.tested_sha, args.full, args.policy_sha, args.bootstrap_high)
        destination = Path(args.output)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(json.dumps(plan, indent=2, sort_keys=True) + "\n")
        if args.github_output:
            with open(args.github_output, "a") as output:
                for key, value in plan.items():
                    output.write(f"{key}={json.dumps(value, separators=(',', ':')) if not isinstance(value, str) else value}\n")
        print(f"CI plan {plan['mode']}: native={plan['native_level']}, UI={len(plan['ui_tests'])}/{len(plan['ui_inventory'])}, host packages={len(plan['host_packages'])}, tested={plan['tested_sha']}")
        return 0
    except (PlanError, UnicodeError, OSError) as error:
        print(f"CI plan failed closed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
