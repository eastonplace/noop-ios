#!/usr/bin/env python3
"""Source contracts for Trends freshness, bounded projection work, and atomic UI handoff."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]


def text(path: str) -> str:
    file = ROOT / path
    if not file.exists():
        raise AssertionError(f"missing required file: {path}")
    return file.read_text(encoding="utf-8")


def require(path: str, *markers: str) -> None:
    source = text(path)
    for marker in markers:
        if marker not in source:
            raise AssertionError(f"{path}: missing contract marker {marker!r}")


def forbid(path: str, *markers: str) -> None:
    source = text(path)
    for marker in markers:
        if marker in source:
            raise AssertionError(f"{path}: forbidden stale marker {marker!r}")


try:
    require(
        "Strand/Data/TrendsLoadedData.swift",
        "struct TrendsLoadedData",
        "let revision: Int",
        "sleepPerfByDay.filter { $0.value.isFinite }",
        "stressByDay.filter { $0.value.isFinite }",
        "let anchorDay: String",
        "let timeZoneIdentifier: String",
        "let canonicalDays: [DailyMetric]",
        "let canonicalByDay: [String: DailyMetric]",
        "let appleByDay: [String: AppleDaily]",
        "uniquingKeysWith",
    )
    require(
        "Strand/Data/TrendPointExtremaSampler.swift",
        "enum TrendPointExtremaSampler",
        ".filter { $0.value.isFinite",
        ".sorted { $0.date < $1.date }",
        "minimum.element",
        "maximum.element",
        "result.append(last)",
    )
    require(
        "Strand/Screens/TrendsSnapshotModels.swift",
        "struct TrendsScreenSnapshotKey",
        "struct TrendsScreenSnapshot",
        "data.canonicalByDay[",
        "TrendPointExtremaSampler.sample",
        "enum TrendsSnapshotHandoff",
        "snapshotKey == currentKey",
        "guard accepts(snapshotKey: snapshot?.key, currentKey: key)",
        "finiteChronological",
        "$0.value.isFinite",
        ".sorted { lhs, rhs in",
        'guard value.isFinite else { return "—" }',
        "private static func finite(_ value: Double?)",
        "private static func stableMean(_ values: [Double])",
        "private static func stableSpread(_ values: [Double], around baseline: Double)",
        "private static func finiteTypical(center: Double, spread: Double)",
        "data.sleepPerfByDay.filter { $0.value.isFinite }",
        "effortDisplayFactor.isFinite ? effortDisplayFactor : 1",
        "loaded.revision < 0 ? fallback : loaded.canonicalDays",
        "value.formatted(.number.precision(.fractionLength(0)))",
    )
    forbid(
        "Strand/Screens/TrendsSnapshotModels.swift",
        "filter(Self.hasFiniteDigestInputs)",
    )
    require(
        "Strand/Screens/TrendsView.swift",
        "@State private var loadedData = TrendsLoadedData.empty",
        ".task(id: repo.refreshSeq)",
        ".task(id: screenSnapshotKey)",
        "await loadDataForCurrentRevision()",
        "await rebuildScreenSnapshot()",
        "let (sleep, stress, apple) = await",
        "revision == repo.refreshSeq",
        "let next = TrendsLoadedData(",
        "var currentScreenSnapshot: TrendsScreenSnapshot?",
        "TrendsSnapshotHandoff.current(screenSnapshot, for: screenSnapshotKey)",
        "guard !Task.isCancelled, key == screenSnapshotKey, let next else { return }",
        "TrendsScreenSnapshot.build(",
    )
    require(
        "Strand/Screens/TrendsView+SelectedRange.swift",
        "if let screenSnapshot = currentScreenSnapshot",
        "paperScoresOverTime(screenSnapshot)",
    )
    require(
        "Strand/Screens/TrendsView+WeeklyReview.swift",
        "if let screenSnapshot = currentScreenSnapshot",
        "paperWeekReview(screenSnapshot)",
        "currentScreenSnapshot?.minimumWeekOffset",
        "Sleep score variability ±",
    )
    forbid(
        "Strand/Screens/TrendsView.swift",
        ".task(id: repo.days.count)",
        "@State private var sleepPerfByDay",
        "@State private var appleDays",
        "@State private var stressByDay",
        "Double(slot) * Double(series.count - 1)",
        "Dictionary(appleDays.map",
        "canonicalDays.filter",
        "selectedMetricObservations",
        "Sleep consistency ±",
    )
    forbid(
        "Strand/Screens/TrendsView+SelectedRange.swift",
        "if let screenSnapshot {",
    )
    forbid(
        "Strand/Screens/TrendsView+WeeklyReview.swift",
        "if let screenSnapshot {",
        "screenSnapshot?.minimumWeekOffset",
        "Sleep consistency ±",
    )
    require(
        "StrandiOSTests/TrendsSnapshotTests.swift",
        "testExtremaSamplerKeepsEndpointsSpikeAndTrough",
        "testExtremaSamplerSortsAndDropsNonFiniteValues",
        "testLoadedDataKeepsOneCanonicalRevisionAndAuxiliaryMaps",
        "testSnapshotHandoffRejectsRapidMetricChanges",
        "testSnapshotHandoffRejectsRapidRangeChanges",
        "testSnapshotHandoffRejectsRapidWeeklyReviewNavigation",
        "testSnapshotHandoffRejectsRepositoryRevisionWhileBuildIsSuspended",
        "testOldCompletionCannotReplaceNewerSnapshotKey",
        "testSnapshotHandoffRejectsNilDuringFirstOrReplacementBuild",
        "testFourThousandDaySnapshotKeepsRenderInputsBounded",
        "testTrendSummaryDropsNonFiniteValuesAndSortsLatestChronologically",
        "testSnapshotDropsNonFiniteMetricValuesBeforeBuildingRanges",
        "testMetricFormatterFailsClosedForNonFiniteAndExtremeValues",
        "testLoadedEmptyRevisionDoesNotFallBackToRepositoryRows",
    )
    require(
        "StrandiOSTests/UIUnificationTests.swift",
        "testTrendSummaryDropsNonFiniteValuesBeforeMeanAndReliability",
        "testWeeklyDigestDropsNonFiniteInputs",
    )
except AssertionError as error:
    print(f"Trends snapshot contract audit: FAIL\n{error}", file=sys.stderr)
    raise SystemExit(1)

print("Trends snapshot contract audit: PASS")
