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
        "@Environment(\\.dynamicTypeSize)",
        "dynamicTypeSize.isAccessibilitySize ? 92 : NoopMetrics.navBarHeight",
        ".fixedSize(horizontal: false, vertical: true)",
    )
    require(
        "Strand/Screens/SmartAlarmView.swift",
        "LazyVGrid(columns: alarmWeekdayColumns",
        "GridItem(.flexible(minimum: 44)",
        "count: dynamicTypeSize.isAccessibilitySize ? 4 : 7",
        ".frame(maxWidth: .infinity, minHeight: 44)",
        ".accessibilityAddTraits(selected ? .isSelected : [])",
        ".accessibilityHint(\"Double-tap to",
        "static func windDownTimeLabel",
        "SleepAlarmTime.clock(minutes, locale: locale, calendar: calendar, timeZone: timeZone)",
        "ViewThatFits(in: .horizontal)",
    )
    forbid(
        "Strand/Screens/SmartAlarmView.swift",
        'String(format: "%02d:%02d"',
        ".frame(width: 30, height: 30)",
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
