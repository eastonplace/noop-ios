#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2] if "Tools/qa" in str(Path(__file__)) else Path.cwd()


def read(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def write(path: str, text: str) -> None:
    (ROOT / path).write_text(text, encoding="utf-8")


def replace_once(path: str, old: str, new: str) -> None:
    text = read(path)
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected exactly one replacement, found {count}: {old[:120]!r}")
    write(path, text.replace(old, new, 1))


def regex_once(path: str, pattern: str, replacement: str, flags: int = 0) -> None:
    text = read(path)
    next_text, count = re.subn(pattern, lambda _: replacement, text, count=1, flags=flags)
    if count != 1:
        raise RuntimeError(f"{path}: regex replacement count {count}: {pattern[:120]!r}")
    write(path, next_text)


def insert_before_last(path: str, marker: str, insertion: str) -> None:
    text = read(path)
    index = text.rfind(marker)
    if index < 0:
        raise RuntimeError(f"{path}: missing final marker {marker!r}")
    write(path, text[:index] + insertion + text[index:])
