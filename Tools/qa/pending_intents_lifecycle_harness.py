#!/usr/bin/env python3
"""Run the real pending-intent queue and drain without AppIntents, UIKit, BLE, or app data.

The queue and AppModel drain extension are copied unchanged from the selected revision. Only their
platform wrappers/imports and application dependencies are substituted. A private random defaults
suite holds all fixture data. The shell checks also require both initial-mount and append wake wiring.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]


def source(path, revision):
    if revision:
        return subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


def declaration(text, prefix):
    start = text.index(prefix)
    opening = text.index("{", start)
    depth, cursor = 1, opening + 1
    while depth:
        depth += (text[cursor] == "{") - (text[cursor] == "}")
        cursor += 1
    return text[start:cursor]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision")
    args = parser.parse_args()
    intents = source("StrandiOS/System/NOOPAppIntents.swift", args.revision)
    queue = declaration(intents, "@MainActor\nenum PendingIntents")
    drain = source("StrandiOS/App/AppModel+iOS.swift", args.revision)
    drain = "\n".join(line for line in drain.splitlines() if line not in ("#if os(iOS)", "#endif"))
    app = source("StrandiOS/App/StrandiOSApp.swift", args.revision)
    mount = app[app.index("// SwiftUI does not guarantee an initial scenePhase"):
                app.index("alarmRuntime.start()", app.index("// SwiftUI does not guarantee an initial scenePhase"))]
    wake_prefix = ".onReceive(NotificationCenter.default.publisher(for: PendingIntents.didAppend))"
    append_wake = declaration(app, wake_prefix) if wake_prefix in app else ""
    wiring = {
        "initial active mount drains without a scene change":
            "scenePhase == .active" in mount and "model.drainPendingIntents()" in mount,
        "append observer drains only while active":
            "guard scenePhase == .active else { return }" in append_wake
            and "model.drainPendingIntents()" in append_wake,
    }
    swift = r'''
import Foundation
import Darwin
enum WidgetSnapshot { static let suiteName = "noop.pending-intents.fixture." + UUID().uuidString }
@MainActor final class LiveState { var connected = true; var bonded = true; var lastSyncError: String? }
@MainActor final class AppModel {
    let live = LiveState()
    var moments: [Date] = []; var buzzes = 0; var syncs = 0
    func markMoment(at date: Date) { moments.append(date) }
    func buzzStrapOnce() { buzzes += 1 }
    func syncActiveDevice() { syncs += 1 }
}
''' + queue + "\n" + drain + r'''
@MainActor final class Harness {
    var failures = 0; var checks = 0
    var active = true
    func check(_ result: Bool, _ label: String) {
        checks += 1
        if !result { failures += 1 }
        print("\(result ? "PASS" : "FAIL"): \(label)")
    }
    func run() {
        let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName)!
        defer { defaults.removePersistentDomain(forName: WidgetSnapshot.suiteName) }
        let model = AppModel()
        let observer = NotificationCenter.default.addObserver(
            forName: Notification.Name("noop.pendingIntents.didAppend"), object: nil, queue: nil
        ) { _ in
            MainActor.assumeIsolated { if self.active { model.drainPendingIntents() } }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let invoked = Date(timeIntervalSince1970: 1_792_600_123)
        PendingIntents.append(.markMoment, at: invoked)
        check(model.moments == [invoked], "already-active append applies the invocation timestamp")
        model.drainPendingIntents()
        check(model.moments == [invoked], "foreground drain cannot replay an already applied moment")

        active = false
        PendingIntents.append(.markMoment, at: invoked.addingTimeInterval(1))
        PendingIntents.append(.buzz)
        PendingIntents.append(.syncStrap)
        check(model.moments.count == 1 && model.buzzes == 0 && model.syncs == 0,
              "background append retains all actions without executing them")
        active = true
        model.drainPendingIntents()
        check(model.moments == [invoked, invoked.addingTimeInterval(1)] && model.buzzes == 1 && model.syncs == 1,
              "activation drains the retained queue exactly once")
        check(PendingIntents.drain().isEmpty, "completed drain clears the durable queue")

        model.live.connected = false
        PendingIntents.append(.syncStrap)
        model.drainPendingIntents()
        check(model.syncs == 1 && model.live.lastSyncError != nil,
              "disconnected Sync Strap retains the existing connection guard")

        defaults.set(["", ":", "markMoment", "unknown:123", "buzz"], forKey: "noop.pendingIntents")
        let legacy = PendingIntents.drain()
        check(legacy.count == 2 && legacy[0].action == .markMoment && legacy[0].date == nil && legacy[1].action == .buzz,
              "legacy actions decode and malformed entries are skipped")
        print("queue lifecycle: \(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
Task { @MainActor in Harness().run() }
dispatchMain()
'''
    with tempfile.TemporaryDirectory(prefix="noop-pending-intents-") as scratch:
        path = Path(scratch)
        (path / "main.swift").write_text(swift)
        subprocess.run(["swiftc", "-module-cache-path", str(path / "module-cache"),
                        "-swift-version", "6", "-warnings-as-errors", str(path / "main.swift"),
                        "-o", str(path / "fixture")], check=True)
        result = subprocess.run([str(path / "fixture")], check=False)
    for label, passed in wiring.items():
        print(f"{'PASS' if passed else 'FAIL'}: {label}", flush=True)
    return 1 if result.returncode != 0 or not all(wiring.values()) else 0


if __name__ == "__main__":
    raise SystemExit(main())
