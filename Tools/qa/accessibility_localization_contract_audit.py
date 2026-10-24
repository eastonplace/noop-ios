#!/usr/bin/env python3
"""Static release contract for iOS accessibility sizing and alarm localization."""
from pathlib import Path

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


def declaration(rel: str, start: str) -> str:
    """The source of one top-level declaration: from `start` to the next closing brace at column zero."""
    source = text(rel)
    begin = source.find(start)
    if begin < 0:
        raise AssertionError(f"{rel}: missing declaration {start!r}")
    end = source.find("\n}\n", begin)
    return source[begin:end if end >= 0 else len(source)]


def require_in(rel: str, start: str, *needles: str) -> None:
    body = declaration(rel, start)
    for needle in needles:
        if needle not in body:
            raise AssertionError(f"{rel}: {start!r} is missing contract marker {needle!r}")


def forbid(rel: str, *needles: str) -> None:
    source = text(rel)
    for needle in needles:
        if needle in source:
            raise AssertionError(f"{rel}: forbidden stale marker {needle!r}")


try:
    forbid(
        "StrandiOS/App/StrandiOSApp.swift",
        ".dynamicTypeSize(...DynamicTypeSize.accessibility1)",
    )
    require(
        "StrandiOS/App/RootTabView.swift",
        # A tab label is one line that scales to its slot (never split inside a word), under a growth ceiling, with the
        # large content viewer carrying the full-size label, and the bar keeps one height at every text size.
        "struct PaperTabLabel: View",
        ".microLabelFit(lines: 1,",
        ".accessibilityShowsLargeContentViewer",
        ".frame(height: NoopMetrics.navBarHeight)",
    )
    require(
        "Strand/Screens/SmartAlarmView.swift",
        # Alarm days now use native Form Toggle rows; the multi-alarm list stacks at large sizes.
        "private struct WakeAlarmEditor: View",
        "Form {",
        'Section("Repeat")',
        "Toggle(Calendar.current.weekdaySymbols[weekday - 1]",
        "dynamicTypeSize.isAccessibilitySize",
        "AnyLayout(VStackLayout(alignment: .leading",
        ".frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)",
        '.accessibilityLabel("Edit alarm ',
        "static func windDownTimeLabel",
        "SleepAlarmTime.clock(minutes, locale: locale, calendar: calendar, timeZone: timeZone)",
    )
    forbid(
        "Strand/Screens/SmartAlarmView.swift",
        'String(format: "%02d:%02d"',
        ".frame(width: 30, height: 30)",
    )
    require(
        "Strand/Screens/TrendsView+SelectedRange.swift",
        "private var rangeControls",
        "TrendsControlRow(",
    )
    require_in(
        "Packages/StrandDesign/Sources/StrandDesign/TrendsWidgetComponents.swift",
        "public struct TrendsControlRow",
        "typeSize >= .xLarge",
        "ViewThatFits(in: .horizontal)",
        ".frame(minHeight: 44)",
    )
    require(
        "Strand/Screens/TrendsView+WeeklyReview.swift",
        "frame(width: 44, height: 44)",
    )
    require(
        "Packages/StrandDesign/Sources/StrandDesign/SleepAlarmComponents.swift",
        "@Environment(\\.dynamicTypeSize)",
        "if dynamicTypeSize.isAccessibilitySize",
        "LazyVGrid(columns: [GridItem(.flexible())]",
        ".frame(width: 44, height: 44)",
        ".frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: 44)",
    )
except AssertionError as error:
    raise SystemExit(f"accessibility/localization contract audit failed: {error}")

print("accessibility/localization contract audit passed")
