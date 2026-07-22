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
        "selectedRange.summarySubtitle",
        "paperMoverRows",
        'Text("Weekly readout")',
        "TrendDeltaTone",
        "WeeklyDigestSource.digest",
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
        "SmartAlarmAdaptiveModeStore",
        "SmartAlarmRuntimeController",
        "sameOccurrenceMinute",
    )
    require(
        "StrandiOS/App/SmartAlarmRuntimeController.swift",
        "SmartAlarmRuntimeGeneration",
        "SmartAlarmBackgroundRequest",
        "generation.accepts",
        "notificationTask?.cancel()",
        "evaluationTask?.cancel()",
        "Task.detached(priority: .utility)",
        "expirationHandler",
        "pinLegacyEndpointOnly",
        "nextDailyRearm",
        "scheduleFollowingBackgroundRequest",
        "loadRequest()",
        "clearRequest(ifMatching: request)",
        "removePendingNotificationRequests",
    )
    require(
        "StrandiOS/App/SmartAlarmCommandReconciler.swift",
        "SmartAlarmCommandSnapshot",
        "SmartAlarmCommandReconcileState",
        "SmartAlarmRuntimeController",
        "runtime.start()",
    )
    forbid(
        "StrandiOS/App/SmartAlarmCommandReconciler.swift",
        "model.applySmartAlarm()",
        "SmartAlarmCommandReconcileCoordinator",
    )
    require(
        "StrandiOS/App/StrandiOSApp.swift",
        "SmartAlarmAdaptiveModeStore",
        "SmartAlarmRuntimeController",
        ".environmentObject(alarmMode)",
        ".environmentObject(alarmRuntime)",
        "alarmRuntime.handleForeground()",
    )
    forbid(
        "StrandiOS/App/StrandiOSApp.swift",
        "SmartAlarmScheduler.register()",
        "model.applySmartAlarm()",
    )
    forbid(
        "Strand/Screens/SmartAlarmView.swift",
        "onChangeCompat(of: behavior.smartAlarmMode)",
        "onChangeCompat(of: behavior.smartAlarmEnabled)",
        "onChangeCompat(of: behavior.smartAlarmMinutes)",
        "onChangeCompat(of: behavior.smartAlarmWeekdays)",
        "SmartAlarmEvidenceStore.refreshCorrelation()",
    )
    require(
        "Packages/StrandAnalytics/Sources/StrandAnalytics/SmartAlarmSchedule.swift",
        "public static func nextDate",
        "public static func nextDailyRearm",
        "matchingPolicy: .nextTime",
    )
    require(
        "Packages/StrandDesign/Sources/StrandDesign/TrendsV2Components.swift",
        "min(Int(fraction * 7), 6)",
        ".accessibilityAdjustableAction",
    )
    forbid(
        "Strand/Screens/WeeklyDigestView.swift",
        "AnalyticsEngine.Rest.composite",
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
