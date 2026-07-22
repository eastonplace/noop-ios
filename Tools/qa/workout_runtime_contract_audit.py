#!/usr/bin/env python3
"""Fast source contracts for the active-workout rendering/publication hot path."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]


def source(path: str) -> str:
    file = ROOT / path
    if not file.exists():
        raise AssertionError(f"missing required file: {path}")
    return file.read_text(encoding="utf-8")


def require(path: str, *needles: str) -> None:
    text = source(path)
    for needle in needles:
        if needle not in text:
            raise AssertionError(f"{path}: missing contract marker {needle!r}")


def forbid(path: str, *needles: str) -> None:
    text = source(path)
    for needle in needles:
        if needle in text:
            raise AssertionError(f"{path}: forbidden hot-path marker {needle!r}")


try:
    require(
        "Strand/Data/WorkoutHeartChartProjection.swift",
        "defaultWindowSeconds = 3 * 60 * 60",
        "defaultMaximumPoints = 360",
        "extremaPreservingSample",
        "bySecond[sample.ts] = sample.bpm",
        "displayRange",
    )
    require(
        "Strand/Screens/LiveWorkoutView.swift",
        "WorkoutHeartChartProjection.make",
        "range: projection.range",
        'Text("HEART RATE (LAST 3 HOURS)")',
    )
    forbid(
        "Strand/Screens/LiveWorkoutView.swift",
        "samples.suffix(360)",
        "range: 100...180",
    )
    require(
        "StrandiOS/App/StrandiOSApp.swift",
        "WorkoutLifecycleProjection",
        ".map(WorkoutLifecycleProjection.identity)",
        ".removeDuplicates()",
    )
    forbid(
        "StrandiOS/App/StrandiOSApp.swift",
        ".onReceive(model.$activeWorkout.dropFirst())",
    )
    require(
        "StrandiOSTests/WorkoutHeartChartProjectionTests.swift",
        "testProjectionUsesTrailingTimeWindowNotCallbackCount",
        "testExtremaPreservingSampleKeepsEndpointsSpikeAndTrough",
        "testLifecycleIdentityChangesOnlyForStartEndOrReplacement",
    )
except AssertionError as error:
    print(f"Workout runtime contract audit: FAIL\n{error}", file=sys.stderr)
    raise SystemExit(1)

print("Workout runtime contract audit: PASS")
