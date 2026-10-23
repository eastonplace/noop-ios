#!/usr/bin/env python3
"""Compatibility entry point for the real confirmed-queue deep-data permission harness."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def source(path, revision):
    if revision:
        return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


def main():
    # Keep the original entry point, but run the canonical enqueue/issue path rather than a recording
    # send stub. The companion imports source() above to read the selected immutable revision.
    from deep_data_confirmed_queue_harness import main as run_queue_checks
    return run_queue_checks()


if __name__ == "__main__":
    raise SystemExit(main())
