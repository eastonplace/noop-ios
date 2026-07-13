#!/usr/bin/env python3
"""Build the spec-006 reference/current pair stack and dark-mode strip."""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


ROOT = Path(__file__).resolve().parents[1]
QA = ROOT / "specs/006-data-prominence/qa/t125"
REFS = ROOT / "specs/001-concept-ui-reskin/references"


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(
        "/System/Library/Fonts/HelveticaNeue.ttc", size, index=1 if bold else 0
    )


# Boxes isolate the phone viewport (not the surrounding reference-sheet labels).
PAIRS = [
    ("Today", "sheet-3-pillar-details.png", (43, 41, 333, 785), "today"),
    ("Trends", "sheet-1-main-screens.png", (307, 65, 509, 456), "trends"),
    ("Sleep", "sheet-3-pillar-details.png", (1119, 41, 1398, 785), "sleep"),
    ("Recovery", "sheet-3-pillar-details.png", (430, 41, 711, 785), "recoverydetail"),
    ("Strain", "sheet-3-pillar-details.png", (773, 41, 1054, 785), "straindetail"),
    ("Workouts", "sheet-1-main-screens.png", (1321, 65, 1524, 456), "workouts"),
    ("Live", "sheet-1-main-screens.png", (307, 523, 509, 916), "live"),
    ("Insights", "sheet-5-insights-labs.png", (28, 69, 244, 741), "insights"),
]


def fit(image: Image.Image, width: int, height: int) -> Image.Image:
    return ImageOps.contain(image.convert("RGB"), (width, height), Image.Resampling.LANCZOS)


def build_pair_stack() -> None:
    thumb_w, thumb_h = 280, 606
    margin, gap, row_gap, label_h = 34, 28, 24, 46
    width = margin * 2 + thumb_w * 2 + gap
    header_h = 118
    row_h = thumb_h + label_h
    height = header_h + len(PAIRS) * row_h + (len(PAIRS) - 1) * row_gap + margin
    sheet = Image.new("RGB", (width, height), "#F7F6F3")
    draw = ImageDraw.Draw(sheet)
    draw.text((margin, 22), "NOOP — data prominence", fill="#141414", font=font(30, True))
    draw.text((margin, 63), "REFERENCE", fill="#6F6F6C", font=font(15, True))
    draw.text((margin + thumb_w + gap, 63), "CURRENT · HEALTHY DAY", fill="#6F6F6C", font=font(15, True))

    opened: dict[str, Image.Image] = {}
    for index, (label, sheet_name, crop, current_name) in enumerate(PAIRS):
        y = header_h + index * (row_h + row_gap)
        reference_sheet = opened.setdefault(sheet_name, Image.open(REFS / sheet_name))
        reference = fit(reference_sheet.crop(crop), thumb_w, thumb_h)
        current = fit(Image.open(QA / "light" / f"{current_name}.png"), thumb_w, thumb_h)
        for col, image in enumerate((reference, current)):
            x = margin + col * (thumb_w + gap)
            px = x + (thumb_w - image.width) // 2
            py = y + (thumb_h - image.height) // 2
            sheet.paste(image, (px, py))
            draw.rounded_rectangle((x, y, x + thumb_w, y + thumb_h), 12, outline="#D9D6CF", width=2)
        draw.text((margin, y + thumb_h + 10), f"{index + 1}. {label}", fill="#141414", font=font(17, True))

    output = QA / "data-prominence-stack.jpg"
    sheet.save(output, quality=93)
    print(f"wrote {output} {sheet.size}")


def build_dark_strip() -> None:
    thumb_w, thumb_h = 230, 498
    margin, gap, header_h, label_h = 28, 18, 90, 38
    width = margin * 2 + len(PAIRS) * thumb_w + (len(PAIRS) - 1) * gap
    height = header_h + thumb_h + label_h + margin
    sheet = Image.new("RGB", (width, height), "#11110F")
    draw = ImageDraw.Draw(sheet)
    draw.text((margin, 20), "DARK-MODE GRAPHICS CHECK", fill="#F4F3EF", font=font(28, True))
    for index, (label, _, _, current_name) in enumerate(PAIRS):
        x = margin + index * (thumb_w + gap)
        image = fit(Image.open(QA / "dark" / f"{current_name}.png"), thumb_w, thumb_h)
        sheet.paste(image, (x + (thumb_w - image.width) // 2, header_h))
        draw.text((x, header_h + thumb_h + 9), label, fill="#A7A6A1", font=font(14, True))
    output = QA / "dark-strip.jpg"
    sheet.save(output, quality=92)
    print(f"wrote {output} {sheet.size}")


if __name__ == "__main__":
    build_pair_stack()
    build_dark_strip()
