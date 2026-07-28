#!/usr/bin/env python3
"""Fast source-level guardrails for NOOP's iPhone-only integration branch.

This is intentionally a pre-build audit, not a replacement for Xcode. It catches regressions that are
cheap and deterministic to identify from source before package resolution and simulator compilation.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def relative(path: Path) -> str:
    return path.relative_to(ROOT).as_posix()


def swift_sources() -> list[Path]:
    roots = [ROOT / "Strand", ROOT / "StrandiOS", ROOT / "StrandiOSShared", ROOT / "StrandiOSWidgets", ROOT / "Packages"]
    files: list[Path] = []
    for root in roots:
        if root.exists():
            files.extend(path for path in root.rglob("*.swift") if ".build" not in path.parts)
    return sorted(files)


def require_before(errors: list[str], source: str, earlier: str, later: str, label: str) -> None:
    try:
        earlier_index = source.index(earlier)
        later_index = source.index(later)
    except ValueError as error:
        errors.append(f"{label}: missing ordered marker {error.args[0]!r}.")
        return
    if earlier_index >= later_index:
        errors.append(f"{label}: {earlier!r} must appear before {later!r}.")


def swift_type_body(source: str, type_name: str) -> str | None:
    """Return one Swift struct declaration, without confusing nested braces for its end."""
    match = re.search(rf"\bstruct\s+{re.escape(type_name)}\b[^{{]*{{", source)
    if not match:
        return None
    depth = 0
    for index in range(match.end() - 1, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[match.start() : index + 1]
    return None


def require_unobserved_app_model_root(errors: list[str], path: Path, type_name: str) -> None:
    """Keep high-frequency AppModel observation in the inert capture leaf, never a heavy screen root."""
    source = path.read_text(encoding="utf-8")
    body = swift_type_body(source, type_name)
    label = f"{relative(path)} {type_name}"
    if body is None:
        errors.append(f"{label}: root declaration is missing.")
        return
    if re.search(r"(?m)^\s*@EnvironmentObject[^\n]*\bAppModel\b", body):
        errors.append(f"{label}: must not broadly observe AppModel; use AppModelReferenceCapture.")
    for contract in (
        "@State private var appModel: AppModel?",
        "AppModelReferenceCapture(reference: $appModel)",
    ):
        if contract not in body:
            errors.append(f"{label}: missing narrow AppModel command-reference contract {contract!r}.")


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []

    trace_interpolation = re.compile(
        r'PerformanceTrace\.begin\s*\(\s*"(?:(?:\\.)|[^"\\])*\\\(',
        re.MULTILINE,
    )
    zero_argument_refresh = re.compile(r"\b(?:self\.)?repo\.refresh\(\s*\)")
    direct_days_refresh = re.compile(r"\b(?:self\.)?repo\.refresh\(\s*days\s*:")
    active_workout_value = re.compile(r"\bstruct\s+ActiveWorkout\b")
    active_workout_reference = re.compile(r"\bfinal\s+class\s+ActiveWorkout\b")

    sources = swift_sources()
    intent_definitions: dict[str, list[str]] = {
        "BuzzStrapIntent": [],
        "MarkMomentIntent": [],
        "NOOPShortcuts": [],
    }

    for path in sources:
        text = path.read_text(encoding="utf-8")
        name = relative(path)

        for symbol in intent_definitions:
            if re.search(rf"\b(?:struct|class|enum)\s+{re.escape(symbol)}\b", text):
                intent_definitions[symbol].append(name)

        if trace_interpolation.search(text):
            errors.append(
                f"{name}: PerformanceTrace.begin requires a compile-time StaticString; "
                "map dynamic states to literal trace names instead of interpolating."
            )

        if "WorkoutLiveProjectionAccumulator: Sendable" in text:
            errors.append(
                f"{name}: mutable workout projection must not claim Sendable while it stores "
                "non-Sendable sample values."
            )

        direct_refresh_owners = {
            "Strand/Data/RepositoryRefreshIntent.swift",
            # HealthKit's exclusive publisher already owns the central fence and must call the coherent
            # snapshot directly; typed admission would defer behind its own fence and deadlock.
            "StrandiOS/App/StrandiOSApp.swift",
        }
        if name not in direct_refresh_owners:
            for match in direct_days_refresh.finditer(text):
                line = text.count("\n", 0, match.start()) + 1
                warnings.append(
                    f"{name}:{line}: direct refresh(days:) bypasses typed refresh coalescing."
                )

        for line_number, line_text in enumerate(text.splitlines(), start=1):
            if line_text.lstrip().startswith("//"):
                continue
            if zero_argument_refresh.search(line_text):
                errors.append(
                    f"{name}:{line_number}: zero-argument refresh bypasses explicit intent ownership."
                )

        if active_workout_value.search(text):
            warnings.append(
                f"{name}: ActiveWorkout is still a growing value type; long sessions can trigger copy-on-write."
            )
        if name == "Strand/App/AppModel.swift" and not active_workout_reference.search(text):
            errors.append(
                f"{name}: ActiveWorkout must remain reference-owned so live HR appends do not copy the full session."
            )

    plist = ROOT / "StrandiOS/Resources/Info.plist"
    if not plist.exists():
        errors.append("StrandiOS/Resources/Info.plist is missing.")
    elif "UISupportedInterfaceOrientations~ipad" in plist.read_text(encoding="utf-8"):
        errors.append("StrandiOS/Resources/Info.plist still contains iPad-only orientation configuration.")

    project = ROOT / "project.yml"
    app_packages = (
        "WhoopProtocol",
        "OuraProtocol",
        "WhoopStore",
        "StrandAnalytics",
        "StrandImport",
        "StrandDesign",
    )
    retained_packages = app_packages + ("NoopLocalAccess",)
    if not project.exists():
        errors.append("project.yml is missing.")
    else:
        project_text = project.read_text(encoding="utf-8")
        if project_text.count('TARGETED_DEVICE_FAMILY: "1"') < 2:
            errors.append("project.yml must target iPhone for both the app and widget extension.")
        for package in app_packages:
            if f"{package}:\n    path: Packages/{package}" not in project_text:
                errors.append(f"project.yml is missing app-linked local package {package}.")
        for package in retained_packages:
            if not (ROOT / "Packages" / package / "Package.swift").exists():
                errors.append(f"repository is missing retained package Packages/{package}.")
        for forbidden in ("PolarProtocol", "platform: macOS", "platform: watchOS", "platform: tvOS"):
            if forbidden in project_text:
                errors.append(f"project.yml restored forbidden retired-platform marker {forbidden!r}.")

    forbidden_paths = (
        "docs/ANDROID.md",
        "docs/CROSS_PLATFORM.md",
        "docs/assets/shot-android-today.png",
        "docs/assets/shot-android-trend.png",
        "StrandTests/MacEnvHeaderTests.swift",
        "Tools/anonymize-macos-app.sh",
        "Tools/build-v7-artifacts.sh",
        "Packages/PolarProtocol",
        "StrandAndroid",
        "StrandWatch",
        "StrandMac",
        "NoopAndroid",
        "NoopWatch",
        "NoopMac",
    )
    for forbidden in forbidden_paths:
        if (ROOT / forbidden).exists():
            errors.append(f"retired platform residue restored at {forbidden}.")

    audit_names = (
        "source_contract_audit.py",
        "ui_unification_contract_audit.py",
        "workout_runtime_contract_audit.py",
        "workout_persistence_contract_audit.py",
        "trends_snapshot_contract_audit.py",
        "accessibility_localization_contract_audit.py",
        "healthkit_sync_contract_audit.py",
    )
    for audit in audit_names:
        if not (ROOT / "Tools/qa" / audit).exists():
            errors.append(f"missing focused source audit Tools/qa/{audit}.")

    app_workflow = ROOT / ".github/workflows/app-build.yml"
    if not app_workflow.exists():
        errors.append(".github/workflows/app-build.yml is missing.")
    else:
        workflow_text = app_workflow.read_text(encoding="utf-8")
        audit_markers = list(audit_names)
        for marker in audit_markers:
            if marker not in workflow_text:
                errors.append(f"app-build workflow is missing audit command marker {marker!r}.")
        for earlier, later in zip(audit_markers, audit_markers[1:]):
            require_before(errors, workflow_text, earlier, later, "app-build workflow")
        require_before(errors, workflow_text, audit_markers[-1], "xcodegen generate", "app-build workflow")
        for package in retained_packages:
            if package not in workflow_text:
                errors.append(f"app-build workflow does not run retained package {package}.")

    package_workflow = ROOT / ".github/workflows/swift-packages.yml"
    if not package_workflow.exists():
        errors.append(".github/workflows/swift-packages.yml is missing.")
    else:
        package_workflow_text = package_workflow.read_text(encoding="utf-8")
        for package in retained_packages:
            if package not in package_workflow_text:
                errors.append(f"swift-packages workflow does not run retained package {package}.")
        if "PolarProtocol" in package_workflow_text:
            errors.append("swift-packages workflow restored PolarProtocol without an intentional package.")

    refresh_contract = ROOT / "Strand/Data/RepositoryRefreshIntent.swift"
    if "inferredLegacyIntent" in refresh_contract.read_text(encoding="utf-8"):
        errors.append("RepositoryRefreshIntent must not restore the deleted heuristic compatibility router.")

    capture = ROOT / "Strand/Screens/ScreenScaffold.swift"
    if not capture.exists():
        errors.append("Strand/Screens/ScreenScaffold.swift is missing.")
    else:
        capture_text = capture.read_text(encoding="utf-8")
        for contract in (
            "@EnvironmentObject private var model: AppModel",
            "@Binding var reference: AppModel?",
            "guard reference !== model else { return }",
        ):
            if contract not in capture_text:
                errors.append(f"{relative(capture)} is missing AppModel capture contract {contract!r}.")
    require_unobserved_app_model_root(errors, ROOT / "Strand/Screens/TodayView.swift", "TodayView")
    require_unobserved_app_model_root(errors, ROOT / "Strand/Screens/WorkoutsView.swift", "WorkoutsView")

    intents = ROOT / "StrandiOS/System/NOOPAppIntents.swift"
    if not intents.exists():
        errors.append("iPhone Siri/Shortcuts intents were removed from the iOS source tree.")
    else:
        intent_text = intents.read_text(encoding="utf-8")
        for symbol in ("BuzzStrapIntent", "MarkMomentIntent", "NOOPShortcuts"):
            locations = intent_definitions[symbol]
            if locations != [relative(intents)]:
                errors.append(
                    f"{symbol} must have exactly one iPhone definition at {relative(intents)}; "
                    f"found {locations or 'none'}."
                )
        for required_contract in (
            "enum PendingIntents",
            "PendingIntents.append(.markMoment",
            "PendingIntents.append(.buzz)",
            "static let openAppWhenRun = true",
        ):
            if required_contract not in intent_text:
                errors.append(
                    f"{relative(intents)} is missing the foreground-safe intent contract: "
                    f"{required_contract}."
                )

        drain = ROOT / "StrandiOS/App/AppModel+iOS.swift"
        if not drain.exists() or "PendingIntents.drain()" not in drain.read_text(encoding="utf-8"):
            errors.append(
                "StrandiOS/App/AppModel+iOS.swift must drain queued iPhone intents through the "
                "existing AppModel lifecycle."
            )

    print("NOOP iPhone source contract audit")
    print(f"Scanned {len(sources)} Swift files")
    for warning in warnings:
        print(f"WARNING: {warning}")
    for error in errors:
        print(f"ERROR: {error}")

    if errors:
        print(f"RESULT: FAIL ({len(errors)} blocking issue(s), {len(warnings)} warning(s))")
        return 1

    print(f"RESULT: PASS ({len(warnings)} architecture warning(s) remain)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
