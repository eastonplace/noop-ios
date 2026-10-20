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


def require_unobserved_live_state_root(errors: list[str], path: Path, type_name: str) -> None:
    """Keep streaming LiveState subscriptions in purpose-built leaves, never a heavy route root."""
    source = path.read_text(encoding="utf-8")
    body = swift_type_body(source, type_name)
    label = f"{relative(path)} {type_name}"
    if body is None:
        errors.append(f"{label}: root declaration is missing.")
        return
    if re.search(r"(?m)^\s*@EnvironmentObject[^\n]*\bLiveState\b", body):
        errors.append(f"{label}: must not broadly observe LiveState; use LiveStateReferenceCapture.")
    for contract in (
        "@State private var liveState: LiveState?",
        "LiveStateReferenceCapture(reference: $liveState)",
    ):
        if contract not in body:
            errors.append(f"{label}: missing narrow LiveState reference contract {contract!r}.")


def require_plain_device_content(errors: list[str], path: Path) -> None:
    """DevicesContent is the long paired-device list; live work belongs in purpose-built leaves."""
    source = path.read_text(encoding="utf-8")
    body = swift_type_body(source, "DevicesContent")
    label = f"{relative(path)} DevicesContent"
    if body is None:
        errors.append(f"{label}: declaration is missing.")
        return
    if "@EnvironmentObject" in body:
        errors.append(f"{label}: must keep AppModel/LiveState as plain references and scope updates to leaves.")
    for contract in (
        "let model: AppModel",
        "let live: LiveState",
        "DeviceSummaryLiveObservation(live: live)",
    ):
        if contract not in body:
            errors.append(f"{label}: missing scoped device-list contract {contract!r}.")
    for forbidden in ("DeviceCommandCenterLiveSnapshot", "DeviceCommandCenterSnapshotObservation", "TimelineView("):
        if forbidden in body:
            errors.append(f"{label}: WHOOP command-centre observation belongs in WHOOP Settings, not the device list ({forbidden!r}).")
    require_plain_live_references(errors, body, label)


def require_plain_live_references(errors: list[str], body: str, label: str) -> None:
    """Registry observation is allowed; AppModel/LiveState must stay unobserved references."""
    if re.search(r"(?m)^\s*@(?:EnvironmentObject|ObservedObject|StateObject)[^\n]*\b(?:AppModel|LiveState)\b", body):
        errors.append(f"{label}: AppModel/LiveState must remain plain references; observe only the narrow snapshot.")


def require_whoop_settings_snapshot_owner(errors: list[str]) -> None:
    """The native WHOOP Settings page owns live commands and samples packet age every five seconds."""
    path = ROOT / "Strand/Screens/WhoopDeviceSettingsView.swift"
    if not path.exists():
        errors.append(f"{relative(path)} is missing.")
        return
    source = strip_swift_comments(path.read_text(encoding="utf-8"))
    contracts = {
        "WhoopDeviceSettingsView": (
            "@State private var model: AppModel?",
            "@State private var live: LiveState?",
            "AppModelReferenceCapture(reference: $model)",
            "LiveStateReferenceCapture(reference: $live)",
            "WhoopDeviceSettingsContent(model: model, live: live, registry: registry)",
        ),
        "WhoopDeviceSettingsContent": (
            "let model: AppModel",
            "let live: LiveState",
            "@StateObject private var observation: DeviceCommandCenterLiveSnapshot",
            "_observation = StateObject(wrappedValue: DeviceCommandCenterLiveSnapshot(live: live))",
            "TimelineView(.periodic(from: .now, by: 5))",
            "let value = observation.value",
            "let now = context.date",
            "lastFrameUnix: live.lastFrameAtUnix",
            "nowUnix: Int(now.timeIntervalSince1970)",
        ),
    }
    for type_name, markers in contracts.items():
        body = swift_type_body(source, type_name)
        label = f"{relative(path)} {type_name}"
        if body is None:
            errors.append(f"{label}: declaration is missing.")
            continue
        require_plain_live_references(errors, body, label)
        for marker in markers:
            if marker not in body:
                errors.append(f"{label}: missing scoped WHOOP Settings contract {marker!r}.")
        if ".onReceive(" in body or re.search(r"\blive\.\$", body):
            errors.append(f"{label}: live subscriptions must stay in DeviceCommandCenterLiveSnapshot.")


def require_device_command_center_snapshot(errors: list[str]) -> None:
    """Pin the narrow, deduplicated command-centre adapter and its native Settings owner."""
    snapshot = ROOT / "Strand/Screens/DeviceCommandCenterLiveSnapshot.swift"
    if not snapshot.exists():
        errors.append(f"{relative(snapshot)} is missing.")
        return
    snapshot_text = snapshot.read_text(encoding="utf-8")
    for contract in (
        "final class DeviceCommandCenterLiveSnapshot: ObservableObject",
        ".removeDuplicates()",
        "live.syncChunksPublisher",
        "live.$historicalSyncPassProgress",
        "bind(live.$lastSyncedAt, to: \\.lastSyncedAt)",
        "bind(live.$historicalDataFrontierAt, to: \\.historicalDataFrontierAt)",
        "bind(live.$historicalSyncSessionState, to: \\.historicalSyncSessionState)",
        "bind(live.$streamingLiveHR, to: \\.liveHeartRateAvailable)",
    ):
        if contract not in snapshot_text:
            errors.append(f"{relative(snapshot)} is missing narrow snapshot contract {contract!r}.")
    for forbidden in ("live.$heartRate", "live.$rr", "live.$log", "live.$lastFrameAtUnix", "live.objectWillChange"):
        if forbidden in snapshot_text:
            errors.append(f"{relative(snapshot)} must not subscribe to high-frequency field {forbidden!r}.")

    require_whoop_settings_snapshot_owner(errors)


def strip_swift_comments(source: str) -> str:
    """Blank out // and /* */ comments, keeping line breaks and string literals, so prose that names a view is not
    read as code."""
    out: list[str] = []
    index, size = 0, len(source)
    while index < size:
        if source.startswith('"""', index):
            end = source.find('"""', index + 3)
            end = size if end < 0 else end + 3
            out.append(source[index:end])
            index = end
        elif source[index] == '"':
            end = index + 1
            while end < size and source[end] not in '"\n':
                if source[end] == "\\":
                    end += 1
                    if source.startswith("(", end):  # an interpolation: skip to its closing parenthesis
                        depth = 0
                        while end < size:
                            depth += source[end] == "("
                            depth -= source[end] == ")"
                            end += 1
                            if depth == 0:
                                break
                        continue
                end += 1
            end = min(end + 1, size)
            out.append(source[index:end])
            index = end
        elif source.startswith("//", index):
            end = source.find("\n", index)
            end = size if end < 0 else end
            out.append(" " * (end - index))
            index = end
        elif source.startswith("/*", index):
            end = source.find("*/", index + 2)
            end = size if end < 0 else end + 2
            out.append(re.sub(r"[^\n]", " ", source[index:end]))
            index = end
        else:
            out.append(source[index])
            index += 1
    return "".join(out)


def closing_index(source: str, open_index: int) -> int:
    """Index just past the bracket that closes the one at `open_index`, or -1."""
    pairs = {"(": ")", "{": "}"}
    opener = source[open_index]
    closer = pairs[opener]
    depth = 0
    for index in range(open_index, len(source)):
        if source[index] == opener:
            depth += 1
        elif source[index] == closer:
            depth -= 1
            if depth == 0:
                return index + 1
    return -1


def active_on_ios(source: str, offset: int) -> bool:
    """False when `offset` sits in a branch of a conditional compile that iOS never builds (macOS-only code)."""
    stack: list[tuple[str, bool]] = []
    for line in source[:offset].splitlines():
        directive = line.strip()
        if directive.startswith("#if "):
            stack.append((directive[4:].replace(" ", ""), False))
        elif directive.startswith("#elseif ") and stack:
            stack[-1] = (directive[8:].replace(" ", ""), False)
        elif directive == "#else" and stack:
            stack[-1] = (stack[-1][0], True)
        elif directive.startswith("#endif") and stack:
            stack.pop()
    for condition, in_else in stack:
        negated = "!os(" in condition
        if "os(macOS)" in condition:
            if (not in_else) != negated:
                return False
        elif "os(iOS)" in condition:
            if in_else != negated:
                return False
    return True


def named_view_bodies(text: str, site: str) -> str:
    """The bodies of the `var name: some View { ... }` properties of the same file that `site` names, so a sheet that
    presents `{ settingsSheet }` is read as what `settingsSheet` builds."""
    bodies: list[str] = []
    for name in set(re.findall(r"\b[a-z]\w*\b", site)):
        for declaration in re.finditer(rf"\bvar\s+{re.escape(name)}\s*:\s*some\s+View\s*\{{", text):
            end = closing_index(text, declaration.end() - 1)
            if end > 0:
                bodies.append(text[declaration.end():end])
    return "\n".join(bodies)


def without_child_presentations(text: str) -> str:
    """`text` with every .sheet / .fullScreenCover / .popover call (arguments and trailing closure) removed, so what is
    left is what the screen itself does and not what it hands to a screen it presents."""
    call = re.compile(r"\.(?:sheet|fullScreenCover|popover)\(")
    out: list[str] = []
    cursor = 0
    for match in call.finditer(text):
        if match.start() < cursor:
            continue
        end = closing_index(text, match.end() - 1)
        if end < 0:
            continue
        trailing = re.match(r"[ \t]*\{", text[end:])
        if trailing:
            body_end = closing_index(text, end + trailing.end() - 1)
            end = body_end if body_end > 0 else end
        out.append(text[cursor:match.start()])
        cursor = end
    out.append(text[cursor:])
    return "".join(out)


def host_resets_its_own_root(host_text: str) -> bool:
    """True when the screen itself applies sheetScreenScaffoldEnvironment (in its body or in a view it builds). A reset
    that appears only inside a sheet the screen presents (WorkoutsView resets its WorkoutDetailView sheet, say) does
    not clear the header context the screen itself inherits."""
    return "sheetScreenScaffoldEnvironment" in without_child_presentations(host_text)


def presentation_findings(sources: dict[str, str]) -> list[str]:
    """Sheets and full-screen covers that do not give what they present its own header context.

    A sheet inherits its presenter's environment. Opened from a pushed screen, a screen that draws a ScreenScaffold
    header would wear the pushed row (a back chip, no subtitle), and one opened from Settings would draw no header at
    all, so the sheet loses what its subtitle says. Either the site must call
    sheetScreenScaffoldEnvironment on what it presents, or the presented screen must apply it in its own body (a reset
    that appears only on a sheet that screen presents does not count), or the site sets screenScaffoldNavigationRole
    on purpose, as a pillar's full-screen cover does.

    Settings shown in a sheet needs the same care the other way round: Settings is the sheet `SettingsSheetHost`, which
    sets `.settingsDetail` on its navigation stack so every page it pushes that is not converted to the widget language
    yet keeps the native grouped-list look. A sheet that presents `SettingsSheetHost` is fine for as long as the host
    still sets it; a sheet that shows a bare SettingsView must set it itself (settingsSheetScreenScaffoldEnvironment), or
    its pages fall back to the dashboard scaffold.
    `sources` maps a repository-relative path to its text."""
    stripped = {path: strip_swift_comments(text) for path, text in sources.items()}
    declaration = re.compile(r"\b(?:struct|class)\s+(\w+)\b[^{;]*\{")
    hosts: dict[str, str] = {}
    for text in stripped.values():
        for match in declaration.finditer(text):
            end = closing_index(text, match.end() - 1)
            if end > 0 and "ScreenScaffold(" in text[match.end():end]:
                hosts[match.group(1)] = text[match.end():end]
    settings_host = next((text for text in stripped.values() if re.search(r"\bstruct\s+SettingsSheetHost\b", text)), "")
    call = re.compile(r"\.(sheet|fullScreenCover)\(")
    findings: list[str] = []
    for path, text in sorted(stripped.items()):
        for match in call.finditer(text):
            end = closing_index(text, match.end() - 1)
            if end < 0:
                continue
            trailing = re.match(r"[ \t]*\{", text[end:])
            if trailing:
                body_end = closing_index(text, end + trailing.end() - 1)
                end = body_end if body_end > 0 else end
            site = text[match.start():end]
            if not active_on_ios(text, match.start()):
                continue
            line = text.count("\n", 0, match.start()) + 1
            if "sheetScreenScaffoldEnvironment" not in site and "screenScaffoldNavigationRole" not in site:
                for name in sorted(set(re.findall(r"\b[A-Z]\w*\b", site)) & hosts.keys()):
                    if host_resets_its_own_root(hosts[name]):
                        continue
                    findings.append(f"{path}:{line}: .{match.group(1)} presents {name}, a ScreenScaffold screen, without "
                                    "sheetScreenScaffoldEnvironment; a sheet inherits its presenter's header context.")
            presented = site + "\n" + named_view_bodies(text, site)
            if re.search(r"\bSettingsSheetHost\(", presented) and "screenScaffoldPresentation" not in settings_host:
                findings.append(f"{path}:{line}: .{match.group(1)} presents SettingsSheetHost, which does not set "
                                "screenScaffoldPresentation on its navigation stack; the pages Settings pushes would lose "
                                "the native settings-detail look.")
            if re.search(r"\bSettingsView\(", presented) and not (
                    "settingsSheetScreenScaffoldEnvironment" in presented or "screenScaffoldPresentation" in presented):
                findings.append(f"{path}:{line}: .{match.group(1)} presents SettingsView without "
                                "settingsSheetScreenScaffoldEnvironment; the pages Settings pushes would lose the native "
                                "settings-detail look.")
    return findings


def require_presented_screens_own_header_context(errors: list[str]) -> None:
    sources: dict[str, str] = {}
    for root in ("Strand", "StrandiOS"):
        for path in (ROOT / root).rglob("*.swift"):
            parts = path.relative_to(ROOT).parts
            if "Tests" in parts or "Debug" in parts or ".build" in parts:
                continue
            sources[relative(path)] = path.read_text(encoding="utf-8")
    errors.extend(presentation_findings(sources))


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

    today = ROOT / "Strand/Screens/TodayView.swift"
    today_text = today.read_text(encoding="utf-8")
    for contract in (
        "private struct TodayScreenSnapshot: Equatable",
        "@State private var screenSnapshot: TodayScreenSnapshot?",
        "defer { refreshScreenSnapshot() }",
        "TodaySnapshotHeartSection(snapshot: screenSnapshot.heart",
        "TodaySnapshotStressSection(snapshot: screenSnapshot.stress",
        "TodaySnapshotHealthSection(",
        ".equatable()",
    ):
        if contract not in today_text:
            errors.append(
                f"{relative(today)} is missing immutable Today section-snapshot contract {contract!r}."
            )
    for type_name, filename in (("DevicesView", "DevicesView.swift"), ("TestCentreView", "TestCentreView.swift")):
        path = ROOT / "Strand/Screens" / filename
        require_unobserved_app_model_root(errors, path, type_name)
        require_unobserved_live_state_root(errors, path, type_name)
    require_plain_device_content(errors, ROOT / "Strand/Screens/DevicesView.swift")
    require_device_command_center_snapshot(errors)

    scoped_control_contracts = {
        ROOT / "Strand/Screens/TestCentreView.swift": (
            "private struct TestCentreConnectionTrustLeaf",
            "private struct TestCentreRecordInspectLeaf",
        ),
        ROOT / "Strand/Screens/WorkoutsView.swift": (
            "private struct WorkoutsActiveWorkoutButtonLeaf",
        ),
    }
    for path, contracts in scoped_control_contracts.items():
        text = path.read_text(encoding="utf-8")
        for contract in contracts:
            if contract not in text:
                errors.append(f"{relative(path)} is missing scoped live-control contract {contract!r}.")

    ios_root = ROOT / "StrandiOS/App/RootTabView.swift"
    ios_root_text = ios_root.read_text(encoding="utf-8")
    for contract in (
        # The running workout is the journey's: one full-screen cover owned by the shell, opened through the router.
        ".fullScreenCover(item: $journey",
        "WorkoutJourneyView(entry: entry",
        "case .activeWorkout:\n                // The deep-link key for the running workout: the journey opens at the live screen.\n                router.openActiveWorkout()",
    ):
        if contract not in ios_root_text:
            errors.append(f"{relative(ios_root)} is missing direct active-workout route {contract!r}.")

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

    require_presented_screens_own_header_context(errors)

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
