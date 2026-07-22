#!/usr/bin/env python3
"""Source contracts for Trends freshness and bounded projection work."""
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
        "let canonicalDays: [DailyMetric]",
        "let appleByDay: [String: AppleDaily]",
        "uniquingKeysWith",
    )
    require(
        "Strand/Data/TrendPointExtremaSampler.swift",
        "enum TrendPointExtremaSampler",
        "minimum.element",
        "maximum.element",
        "result.append(last)",
    )
    require(
        "Strand/Screens/TrendsView.swift",
        "@State private var loadedData = TrendsLoadedData.empty",
        ".task(id: repo.refreshSeq)",
        "await loadDataForCurrentRevision()",
        "let (sleep, stress, apple) = await",
        "guard !Task.isCancelled else { return }",
        "loadedData = TrendsLoadedData(",
        "let observations = selectedMetricObservations",
        "TrendPointExtremaSampler.sample",
    )
    forbid(
        "Strand/Screens/TrendsView.swift",
        ".task(id: repo.days.count)",
        "@State private var sleepPerfByDay",
        "@State private var appleDays",
        "@State private var stressByDay",
        "Double(slot) * Double(series.count - 1)",
        "Dictionary(appleDays.map",
    )
    require(
        "StrandiOSTests/TrendsSnapshotTests.swift",
        "testExtremaSamplerKeepsEndpointsSpikeAndTrough",
        "testLoadedDataKeepsOneCanonicalRevisionAndAuxiliaryMaps",
    )
except AssertionError as error:
    print(f"Trends snapshot contract audit: FAIL\n{error}", file=sys.stderr)
    raise SystemExit(1)

print("Trends snapshot contract audit: PASS")
