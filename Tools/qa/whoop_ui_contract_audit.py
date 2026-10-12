#!/usr/bin/env python3
"""Static contract for NOOP's single dark, WHOOP-aligned visual system.

This audit protects the shared design-system decisions. It does not claim visual proof.
Simulator screenshots, accessibility inspection, and performance traces remain required.
"""

from __future__ import annotations

from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[2]

# --- UI style sweep -----------------------------------------------------------------------------
# One visual language means screens compose design-system controls instead of re-declaring them.
# These checks count hard-coded styling per source directory. Directories marked `gated` fail the
# audit when a count rises above its recorded ceiling (a ratchet: lower the ceiling as sites are
# cleaned up, never raise it). Directories marked report-only are printed but never fail CI yet.
STYLE_ROOTS: tuple[tuple[str, str, bool], ...] = (
    # (label, directory, gated)
    ("Strand/Screens", "Strand/Screens", True),
    ("StrandiOS/App", "StrandiOS/App", True),
    # Coach (phase 2a) and Lift (phase 2b): gated at 0 on every check.
    ("StrandiOS/Coach", "StrandiOS/Coach", True),
    ("Strand/Screens (Lift, Live workout)", "Strand/Screens", True),
    ("Packages/ReceiptLiftFeature", "Packages/ReceiptLiftFeature", True),
    # Report-only: intentionally fixed-size (widget text).
    ("StrandiOSWidgets", "StrandiOSWidgets", False),
)

# Files under Strand/Screens that belong to the Lift / Live-workout group (its own row below).
LIFT_SCREEN_PREFIXES = (
    "Strand/Screens/Lift",
    "Strand/Screens/NoopReceiptLift",
    "Strand/Screens/LiveWorkout",
    "Strand/Screens/WorkoutJourney",
    "Strand/Screens/WorkoutResumeBar",
)

# The design system itself, galleries, QA harnesses and previews legitimately use raw styling.
STYLE_EXEMPT_MARKERS = (
    "Packages/StrandDesign/",
    "Gallery",
    "DesignLab",
    "/QA/",
    "QA.swift",
    "/Tests/",
    "+Preview",
)

STYLE_CHECKS: tuple[tuple[str, str], ...] = (
    # (key, what it flags)
    ("bordered", "system .buttonStyle(.bordered/.borderedProminent) - use NoopButtonStyle"),
    ("legacy-noop", "legacy gold .buttonStyle(.noopPrimary/.noopSecondary/.noopGhost) - use NoopButtonStyle"),
    ("color-red", "Color(red:...) literal - use a StrandPalette token"),
    ("text-size", "text .font(.system(size:)) - use a StrandFont role (icon glyph sizing is allowed)"),
)

# Ceilings for gated directories as of the UI consistency pass (phase 1; Coach joined in phase 2a). Missing
# key = 0. StrandiOS/Coach is fully migrated: its only fixed-size `.font(.system(size:))` sites are SF Symbol
# glyphs, so every Coach ceiling is 0.
#   bordered:  TestCentreView.swift "Copy report.txt" (content shared with the Settings tab; left as-is)
#   color-red: TodayView.swift RecordingStatusLight (Today top bar; structure frozen in phase 1)
STYLE_CEILINGS: dict[tuple[str, str], int] = {
    ("Strand/Screens", "bordered"): 1,
    ("Strand/Screens", "color-red"): 1,
}

BORDERED_RE = re.compile(r"\.buttonStyle\(\s*\.bordered(?:Prominent)?\s*\)")
LEGACY_NOOP_RE = re.compile(r"\.buttonStyle\(\s*\.noop(?:Primary|Secondary|Ghost)\s*\)")
COLOR_RED_RE = re.compile(r"(?<![A-Za-z0-9_])Color\(\s*(?:\.sRGB\s*,\s*)?red:")
SYSTEM_SIZE_RE = re.compile(r"\.font\(\s*(?:Font)?\.system\(\s*size:")
VIEW_HEAD_RE = re.compile(r"\b(Image|Text|Label|Circle|ProgressView)\(")


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
        ROOT / "StrandiOS" / "Coach",
        ROOT / "StrandiOSWidgets",
        ROOT / "Packages" / "ReceiptLiftFeature",
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


def style_sources(root: Path, lift_group: bool | None) -> list[Path]:
    """Swift files under `root`. `lift_group` True/False selects only/excluding the report-only
    Lift / Live-workout screens under Strand/Screens; None applies no such filter."""
    if not root.exists():
        return []
    files = []
    for path in sorted(root.rglob("*.swift")):
        rel = path.relative_to(ROOT).as_posix()
        if any(marker in rel for marker in STYLE_EXEMPT_MARKERS):
            continue
        in_lift = rel.startswith(LIFT_SCREEN_PREFIXES)
        if lift_group is not None and in_lift != lift_group:
            continue
        files.append(path)
    return files


def is_text_size_site(lines: list[str], index: int) -> bool:
    """True when `.font(.system(size:))` at `lines[index]` styles text rather than an SF Symbol.

    Icon glyph sizing via a fixed point size is legitimate; fixed-size TEXT bypasses Dynamic Type and
    the StrandFont roles. The nearest view constructor in the six preceding lines decides.
    """
    context = " ".join(lines[max(0, index - 6): index + 1])
    heads = VIEW_HEAD_RE.findall(context)
    return bool(heads) and heads[-1] != "Image"


def scan_style(directory: str, lift_group: bool | None) -> dict[str, list[str]]:
    hits: dict[str, list[str]] = {key: [] for key, _ in STYLE_CHECKS}
    for path in style_sources(ROOT / directory, lift_group):
        rel = path.relative_to(ROOT).as_posix()
        lines = path.read_text(encoding="utf-8", errors="ignore").split("\n")
        for i, line in enumerate(lines):
            if line.lstrip().startswith("//"):
                continue
            if BORDERED_RE.search(line):
                hits["bordered"].append(f"{rel}:{i + 1}")
            if LEGACY_NOOP_RE.search(line):
                hits["legacy-noop"].append(f"{rel}:{i + 1}")
            if COLOR_RED_RE.search(line):
                hits["color-red"].append(f"{rel}:{i + 1}")
            if SYSTEM_SIZE_RE.search(line) and is_text_size_site(lines, i):
                hits["text-size"].append(f"{rel}:{i + 1}")
    return hits


def audit_style(errors: list[str], warnings: list[str]) -> None:
    print("UI style sweep (hard-coded styling per directory):")
    keys = [key for key, _ in STYLE_CHECKS]
    print("  " + "directory".ljust(38) + "".join(key.ljust(13) for key in keys) + "mode")
    for label, directory, gated in STYLE_ROOTS:
        lift_group: bool | None = None
        if directory == "Strand/Screens":
            lift_group = label != "Strand/Screens"  # the base row excludes the Lift group; the Lift row is only it
        hits = scan_style(directory, lift_group)
        cells = []
        for key in keys:
            count = len(hits[key])
            ceiling = STYLE_CEILINGS.get((label, key), 0)
            cells.append((f"{count}/{ceiling}" if gated else f"{count}").ljust(13))
            if not gated:
                continue
            if count > ceiling:
                sites = ", ".join(hits[key][:6])
                errors.append(
                    f"{label}: {count} {key} site(s) exceed the ceiling of {ceiling}. "
                    f"Use NoopButtonStyle / palette tokens / StrandFont roles. e.g. {sites}"
                )
            elif count < ceiling:
                warnings.append(
                    f"{label}: {key} dropped to {count}; lower its ceiling in STYLE_CEILINGS (was {ceiling})."
                )
        print("  " + label.ljust(38) + "".join(cells) + ("gated (count/ceiling)" if gated else "report-only"))
    for key, meaning in STYLE_CHECKS:
        print(f"  {key}: {meaning}")


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
            # The palette holds no recovery cuts of its own: the colour of a score comes from RecoveryBands.
            "return RecoveryBands.color(for: score)",
            ".init(color: recoveryLow, location: 0.339)",
            ".init(color: recoveryMed, location: 0.340)",
            ".init(color: recoveryMed, location: 0.669)",
            ".init(color: recoveryHigh, location: 0.670)",
        )
        forbid(
            "Packages/StrandDesign/Sources/StrandDesign/Palette.swift",
            "case ..<34: return recoveryLow",
            "case ..<67: return recoveryMed",
        )
        require(
            "Packages/StrandDesign/Sources/StrandDesign/StrainScale.swift",
            "private static let mediumFrom = 34.0",
            "private static let highFrom = 67.0",
            "if value >= highFrom { return .high }",
            "if value >= mediumFrom { return .medium }",
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

    audit_style(errors, warnings)

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
