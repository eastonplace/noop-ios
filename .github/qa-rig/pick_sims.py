#!/usr/bin/env python3
"""Pick a primary (6.3" Pro class) and a small iPhone simulator from the newest iOS runtime.

Prints GitHub step outputs: primary=<udid>, primary_name=..., small=<udid>, small_name=...
"""
import json
import re
import subprocess
import sys

PRIMARY = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone 16", "iPhone 15 Pro"]
SMALL = ["iPhone SE (3rd generation)", "iPhone 16e", "iPhone 17e", "iPhone 13 mini", "iPhone 12 mini"]

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))


def version(runtime: str):
    match = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?", runtime)
    return tuple(int(x or 0) for x in match.groups()) if match else (0, 0, 0)


runtimes = sorted((r for r in data["devices"] if "iOS" in r), key=version, reverse=True)
devices = [(r, d) for r in runtimes for d in data["devices"][r] if d.get("isAvailable")]


def pick(preferences):
    for name in preferences:
        for runtime, device in devices:
            if device["name"] == name:
                return device, runtime
    return None, None


primary, primary_rt = pick(PRIMARY)
if primary is None:
    primary, primary_rt = next(((d, r) for r, d in devices if d["name"].startswith("iPhone")), (None, None))
if primary is None:
    sys.exit("no iPhone simulator available")
small, small_rt = pick(SMALL)
if small is None:
    small, small_rt = primary, primary_rt
print(f"primary={primary['udid']}")
print(f"primary_name={primary['name']} ({primary_rt.split('.')[-1]})")
print(f"small={small['udid']}")
print(f"small_name={small['name']} ({small_rt.split('.')[-1]})")
