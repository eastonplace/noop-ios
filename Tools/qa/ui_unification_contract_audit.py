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
        "Strand/Screens/TrendsView+SelectedRange.swift",
        "selectedRange.summarySubtitle",
        "TrendDeltaTone",
    )
    require(
        "Strand/Screens/TrendsView+WeeklyReview.swift",
        "paperMoverRows",
        'Text("Weekly readout")',
    )
    require(
        "Strand/Screens/TrendsSnapshotModels.swift",
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
        "let endpoint: Date",
        "endpoint.timeIntervalSince(now)",
        "let endpointComponents",
        "let wakeAxisMinutes",
        "let nowAxisMinutes",
        "let civilDayOffset",
        "voiceOverWakeTimeValue",
        "func clockLabel(",
        "date(forAxisMinute axisMinute: Int)",
        "formatter.setLocalizedDateFormatFromTemplate(\"EEEE MMM d\")",
        "preservesTimeZoneOccurrence(",
        "calendar.isDate(proposed, inSameDayAs: endpoint)",
        "repeatedTimePolicy: .first",
        "return first == last || abs(first.timeIntervalSince(proposed)) < 0.5",
    )
    forbid(
        "Strand/Screens/SleepAlarmEditorSection.swift",
        "nowMinuteOfDay + elapsedMinutes",
        "let continuousMinutes",
        "presentation.continuousMinutes",
    )
    require(
        "StrandiOSTests/AlarmPresentationTests.swift",
        "testSpringForwardPresentationUsesEndpointClockAndRealElapsedTime",
        "testSpringForwardPlanClocksMapBackToRealDates",
        "testFallBackPresentationUsesEndpointClockAndRealElapsedTime",
        "testFallBackPlanClocksMapBackToRealDates",
        "testSameDayAlarmKeepsTodayIdentity",
        "testTomorrowAlarmKeepsTomorrowIdentity",
        "testWeekdaySeveralDaysAwayUsesCalendarDayIdentity",
        "testMidnightBoundaryNudgeStaysWithinRecurringOccurrence",
        "testVoiceOverWakeTimeValueUsesEndpointClock",
    )
    require(
        "StrandiOS/App/SmartAlarmBackgroundCompletionGate.swift",
        "enum SmartAlarmBackgroundTerminalEvent",
        "case missingRuntime",
        "case missingRequest",
        "case malformedRequest",
        "case cancelled",
        "case expired",
        "case evaluationError",
        "guard terminalEvent == nil else { return false }",
        "final class SmartAlarmBackgroundCompletionGate",
    )
    require(
        "StrandiOS/App/SmartAlarmBackgroundTaskRegistrar.swift",
        "BGTaskScheduler.shared.register",
        "SmartAlarmBackgroundCompletionGate",
        "completion.complete(.missingRequest)",
        "completion.complete(.malformedRequest)",
        "clearStoredRequest()",
        "completion.complete(.missingRuntime)",
        "completion.complete(.cancelled)",
        "completion.complete(.evaluationError)",
        "completion.complete(.expired)",
        "refreshTask.setTaskCompleted(success: success)",
        "SmartAlarmRuntimeBackgroundScheduler.requestKey",
        "SmartAlarmRuntimeBackgroundScheduler.clearRequest(ifMatching: request)",
    )
    require(
        "StrandiOSTests/SmartAlarmBackgroundCompletionGateTests.swift",
        "testSuccessCompletesExactlyOnce",
        "testFailureCompletesExactlyOnce",
        "testEveryExceptionalTerminalEventCompletesFalse",
        "testExpirationWinsOverLateSuccess",
        "testCancellationWinsOverLateFailure",
        "testStateMachineAcceptsOnlyFirstTerminalEvent",
    )
    require(
        "StrandiOSTests/SmartAlarmBackgroundTaskRegistrarTests.swift",
        "testRequestLoaderDistinguishesMissingMalformedAndValidPayloads",
        "SmartAlarmBackgroundTaskRegistrar.clearStoredRequest(defaults: defaults)",
        "testBackgroundRequestPersistenceRoundTripsBeforeSubmission",
    )
    require(
        "StrandiOS/App/StrandiOSApp.swift",
        "SmartAlarmBackgroundTaskRegistrar.install(alarmRuntime)",
    )
    forbid(
        "StrandiOS/App/StrandiOSApp.swift",
        "SmartAlarmRuntimeBackgroundScheduler.install(alarmRuntime)",
    )
    require(
        "StrandiOS/App/SmartAlarmRuntimeController.swift",
        "SmartAlarmRuntimeGeneration",
        "SmartAlarmBackgroundRequest",
        "generation.accepts",
        "notificationTask?.cancel()",
        "evaluationTask?.cancel()",
        "async let child = Self.computeEvaluation",
        "try Task.checkCancellation()",
        "configurationID",
        "nextDailyRearm",
        "scheduleFollowingBackgroundRequest",
        "clearRequest(ifMatching: payload)",
        "persistRequest(payload)",
        "removePendingNotificationRequests",
    )
    forbid(
        "StrandiOS/App/SmartAlarmRuntimeController.swift",
        "Task.detached(priority: .utility)",
        "BGTaskScheduler.shared.register(forTaskWithIdentifier: bgTaskIdentifier",
        "SmartAlarmRuntimeBackgroundScheduler.install(self)",
        "static func install(_ runtime: SmartAlarmRuntimeController)",
    )
    forbid(
        "Strand/App/AppModel.swift",
        "func applySmartAlarm()",
        "evaluateConditionalSmartAlarm",
        "scheduleSmartAlarmBackupNotification",
        "scheduleDailySmartAlarmRearm",
        "SmartAlarmScheduler",
        "pinLegacyEndpointOnly",
        "live.$connectSettled.dropFirst()",
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
        "SettingsCatalog.searchSections(",
        "resultSections: moreSearchSections",
        "private var moreSearchSections",
        "MoreCategoryView",
        "understandRows",
        "planAutomateRows",
    )
    forbid(
        "StrandiOS/App/RootTabView.swift",
        ".simultaneousGesture(",
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
