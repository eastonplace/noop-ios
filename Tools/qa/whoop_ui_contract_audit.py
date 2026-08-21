#!/usr/bin/env python3
"""Static contract for NOOP's single dark, WHOOP-aligned visual system.

This audit protects the shared design-system decisions. It does not claim visual proof.
Simulator screenshots, accessibility inspection, and performance traces remain required.
"""

from __future__ import annotations

from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]


def source(relative: str) -> str:
    path = ROOT / relative
    if not path.exists():
        raise AssertionError(f"missing required file: {relative}")
    return path.read_text(encoding="utf-8")


def require(relative: str, *markers: str) -> None:
    text = source(relative)
    for marker in markers:
        if marker not in text:
            raise AssertionError(f"{relative}: missing contract marker {marker!r}")


def forbid(relative: str, *markers: str) -> None:
    text = source(relative)
    for marker in markers:
        if marker in text:
            raise AssertionError(f"{relative}: forbidden stale marker {marker!r}")


def count_ui_sources_containing(marker: str) -> list[str]:
    roots = (
        ROOT / "Strand" / "Screens",
        ROOT / "StrandiOS" / "App",
        ROOT / "StrandiOSWidgets",
        ROOT / "Packages" / "StrandDesign" / "Sources" / "StrandDesign",
    )
    hits: list[str] = []
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*.swift"):
            if marker in path.read_text(encoding="utf-8"):
                hits.append(path.relative_to(ROOT).as_posix())
    return sorted(hits)


def main() -> int:
    errors: list[str] = []
    warnings: list[str] = []

    try:
        require(
            "Packages/StrandDesign/Sources/StrandDesign/Appearance.swift",
            "public static let allCases: [AppearanceMode] = [.system]",
            "public var colorScheme: ColorScheme? { .dark }",
            "public static func resolve(_ raw: String) -> AppearanceMode",
            "public static let allCases: [ChartStyle] = [.titanium]",
            "public static func resolve(_ raw: String) -> ChartStyle",
            "func chartStyle(_ raw: String) -> some View",
            "_ = raw\n        return self",
            "public static let isEnabled = false",
        )
        forbid(
            "Packages/StrandDesign/Sources/StrandDesign/Appearance.swift",
            '.id("noop.chartStyle.',
            "StrandPalette.chartStyle = ChartStyle.resolve(raw)",
        )

        require(
            "Packages/StrandDesign/Sources/StrandDesign/Palette.swift",
            'public static let canvas = Color(hex: "#101518")',
            'public static let cardFillTop = Color(hex: "#283339")',
            'public static let ink = Color(hex: "#00F19F")',
            'public static let recoveryLow = Color(hex: "#FF0026")',
            'public static let recoveryMed = Color(hex: "#FFDE00")',
            'public static let recoveryHigh = Color(hex: "#16EC06")',
            'public static let strainAccent = Color(hex: "#0093E7")',
            'public static let sleepAccent = Color(hex: "#7BA1BB")',
            'public static let sleepNeedTeal = Color(hex: "#00F19F")',
            'public static let recoveryData = Color(hex: "#67AEE6")',
            "case ..<34: return recoveryLow",
            "case ..<67: return recoveryMed",
            ".init(color: recoveryLow, location: 0.339)",
            ".init(color: recoveryMed, location: 0.340)",
            ".init(color: recoveryMed, location: 0.669)",
            ".init(color: recoveryHigh, location: 0.670)",
        )

        require(
            "Packages/StrandDesign/Sources/StrandDesign/Typography.swift",
            "Font.system(.largeTitle, design: .default).weight(.bold)",
            "Font.system(.body, design: .default).weight(.medium)",
            ".monospacedDigit()",
        )
        forbid(
            "Packages/StrandDesign/Sources/StrandDesign/Typography.swift",
            'Font.custom("SF Pro"',
        )

        require(
            "Packages/StrandDesign/Sources/StrandDesign/StrandCard.swift",
            "StrandPalette.cardFillTop",
            "StrandPalette.cardFillBottom",
            "shape.strokeBorder(StrandPalette.cardBorder, lineWidth: 1)",
        )

        require(
            "Packages/StrandDesign/Tests/StrandDesignTests/WhoopThemeContractTests.swift",
            "testEveryStoredAppearanceValueResolvesToDark",
            "testWhoopRecoveryBandsUseExactInclusiveRanges",
            "testWhoopMetricColorsStayDistinct",
        )

        require(
            "StrandiOS/App/StrandiOSApp.swift",
            ".preferredColorScheme(AppearanceMode.resolve(appearanceRaw).colorScheme)",
            ".chartStyle(chartStyleRaw)",
        )
        require(
            "Strand/Screens/TodayView.swift",
            "topBackground: nil",
        )
    except AssertionError as error:
        errors.append(str(error))

    custom_font_hits = count_ui_sources_containing("Font.custom(")
    custom_font_hits = [
        path
        for path in custom_font_hits
        if not path.endswith("Typography.swift")
    ]
    if custom_font_hits:
        warnings.append(
            "custom font lookup remains outside the shared type system: "
            + ", ".join(custom_font_hits)
        )

    settings = source("Strand/Screens/SettingsView.swift")
    day_cycle_count = settings.count("Day-cycle background")
    if day_cycle_count:
        warnings.append(
            f"SettingsView still contains {day_cycle_count} day-cycle label occurrence(s); "
            "remove them after simulator route verification."
        )
    if "Choose Light, Dark, or follow your system" in settings:
        warnings.append(
            "SettingsView still contains stale multi-theme explanatory copy."
        )

    for warning in warnings:
        print(f"WHOOP UI contract audit: WARNING: {warning}")

    if errors:
        for error in errors:
            print(f"WHOOP UI contract audit: FAIL: {error}", file=sys.stderr)
        return 1

    print("WHOOP UI contract audit: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
