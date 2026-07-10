#!/usr/bin/env python3
"""Build a labeled screenshot contact sheet from one or two directories."""
from __future__ import annotations

import argparse
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont:
    path = "/System/Library/Fonts/HelveticaNeue.ttc"
    return ImageFont.truetype(path, size, index=1 if bold else 0)


def images_in(directory: Path) -> dict[str, Path]:
    supported = {".png", ".jpg", ".jpeg"}
    return {p.stem: p for p in sorted(directory.iterdir()) if p.suffix.lower() in supported}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--after", type=Path, required=True)
    parser.add_argument("--before", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--title", default="NOOP Paper UI — fidelity evidence")
    args = parser.parse_args()

    after = images_in(args.after)
    before = images_in(args.before) if args.before else {}
    names = sorted(after)
    thumb_w, thumb_h = 246, 532
    label_h, gap, margin = 48, 22, 32
    columns = 6
    rows = (len(names) + columns - 1) // columns
    width = margin * 2 + columns * thumb_w + (columns - 1) * gap
    height = 112 + rows * (thumb_h + label_h + gap) + margin
    sheet = Image.new("RGB", (width, height), "#F7F6F3")
    draw = ImageDraw.Draw(sheet)
    draw.text((margin, 24), args.title, fill="#141414", font=font(34, True))
    draw.text((margin, 68), f"{len(names)} AFTER screens · reference-ordered", fill="#6F6F6C", font=font(18))

    for index, name in enumerate(names):
        row, col = divmod(index, columns)
        x = margin + col * (thumb_w + gap)
        y = 104 + row * (thumb_h + label_h + gap)
        image = Image.open(after[name]).convert("RGB")
        image.thumbnail((thumb_w, thumb_h), Image.Resampling.LANCZOS)
        px = x + (thumb_w - image.width) // 2
        py = y + (thumb_h - image.height) // 2
        sheet.paste(image, (px, py))
        draw.rounded_rectangle((x, y, x + thumb_w, y + thumb_h), 12, outline="#D9D6CF", width=2)
        draw.text((x, y + thumb_h + 10), name, fill="#141414", font=font(16, True))
        if name in before:
            draw.text((x + thumb_w - 58, y + thumb_h + 10), "B/A", fill="#3B82F6", font=font(14, True))

    args.output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.output, quality=92)
    print(f"wrote {args.output} {sheet.size}")


if __name__ == "__main__":
    main()
