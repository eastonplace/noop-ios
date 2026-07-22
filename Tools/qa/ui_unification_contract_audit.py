#!/usr/bin/env python3
"""Static release contract for the Trends / alarm / Settings / More unification."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]


def text(rel: str) -> str:
    path = ROOT / rel
    if not path.exists():
        raise AssertionError(f"missing required file: {rel}")
    return path.read_text(encoding="utf-8")


def require(rel: str, *needles: str) -> None:
    source = text(rel)
    for needle in needles:
        if needle not in source:
            raise AssertionError(f"{rel}: missing contract marker {needle!r}")


def forbid(rel: str, *needles: str) -> None:
    source = text(rel)
    for needle in needles:
        if needle in source:
            raise AssertionError(f"{rel}: forbidden stale marker {needle!r}")


try:
    require(
        "Strand/Screens/TrendsView.swift",
        "previousPaperTrendSeries",
        "selectedRange.summarySubtitle",
        "paperMoverRows",
        'Text("Weekly readout")',
        "TrendDeltaTone",
    )
    forbid(
        "Strand/Screens/TrendsView.swift",
        'subtitle: "This week"',
        "paperInsight\n",
    )
    require(
        "Packages/StrandDesign/Sources/StrandDesign/TrendsV2Components.swift",
        "weekdayIndex(atUnitPosition",
        "@State private var scrubIndex",
        "Touch and drag to read a weekday",
        "public enum TrendDeltaTone",
        "summarySubtitle",
    )
    require(
        "Strand/Screens/SleepView.swift",
        "SleepAlarmEditorSection()",
    )
    forbid(
        "Strand/Screens/SleepView.swift",
        "Read-only mirror of tonight's armed alarm path",
        "SleepAlarmPlanSection",
    )
    require(
        "Strand/Screens/SleepAlarmEditorSection.swift",
        "SleepAlarmModuleCard",
        "BehaviorStore",
        "canonicalSleepNeedPlan",
        "SmartAlarmView()",
    )
    require(
        "StrandiOS/App/SmartAlarmCommandReconciler.swift",
        "model.applySmartAlarm()",
        "SmartAlarmCommandSnapshot",
        "SmartAlarmCommandReconcileCoordinator",
        "pendingTask?.cancel()",
        "try await Task.sleep",
        "if !snapshot.enabled",
    )
    forbid(
        "Strand/Screens/SmartAlarmView.swift",
        "onChangeCompat(of: behavior.smartAlarmMode)",
        "onChangeCompat(of: behavior.smartAlarmEnabled)",
        "onChangeCompat(of: behavior.smartAlarmMinutes)",
        "onChangeCompat(of: behavior.smartAlarmWeekdays)",
    )
    require(
        "Strand/Screens/SettingsView.swift",
        "SettingsScreenTemplate",
        "displaySettingsDetail",
        "strapSettingsDetail",
        "recoverySettingsDetail",
        ".navDetail(",
    )
    forbid(
        "Strand/Screens/SettingsView.swift",
        "advancedOpen",
        'id: "all-settings"',
        'title: "Detailed settings"',
    )
    require(
        "StrandiOS/App/RootTabView.swift",
        "SmartAlarmCommandReconciler()",
        "SettingsScreenTemplate(sections: moreSections)",
        "MoreCategoryView",
        "understandRows",
        "planAutomateRows",
    )
    forbid(
        "StrandiOS/App/RootTabView.swift",
        "MoreRow<",
        "expandedMoreSections",
        'MoreRow("Insights"',
    )
    require(
        "Packages/StrandDesign/Sources/StrandDesign/SettingsKitComponents.swift",
        "case navDetail",
        "public static func navDetail",
        "public struct SettingsDestination",
        "destination: SettingsDestination",
        "SettingsDestination { AnyView(destination()) }",
    )
    forbid(
        "Packages/StrandDesign/Sources/StrandDesign/SettingsKitComponents.swift",
        "destination: AnyView(destination())",
        "screenScaffoldNavigationRole",
    )
    for staged_path in (
        ".github/workflows/ui-unification-patcher.yml",
        ".github/ui-patcher-parts",
        ".github/ui-patcher-binary",
        "Tools/qa/apply_ui_unification.py",
    ):
        if (ROOT / staged_path).exists():
            raise AssertionError(f"temporary patch-delivery artifact survived: {staged_path}")
except AssertionError as error:
    print(f"UI unification contract audit: FAIL\n{error}", file=sys.stderr)
    raise SystemExit(1)

print("UI unification contract audit: PASS")
