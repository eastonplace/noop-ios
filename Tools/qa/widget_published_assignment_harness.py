#!/usr/bin/env python3
"""Exercise the real widget callbacks, gates, overlay write and display read with Combine willSet.

No UIKit, WidgetKit, BLE, database, or live App Group access is used. AppModel dependencies are tiny
fixtures. WidgetSnapshot's suite name is the only shared-model substitution: a unique private suite.
"""
from pathlib import Path
import argparse
import subprocess
import tempfile

from pending_intents_lifecycle_harness import ROOT, declaration, source


def stripped(text):
    return "\n".join(line for line in text.splitlines()
                     if not line.startswith("import ") and line not in ("#if os(iOS)", "#endif"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--revision")
    args = parser.parse_args()
    app = source("StrandiOS/App/StrandiOSApp.swift", args.revision)
    publish = source("StrandiOS/Widgets/WidgetPublish.swift", args.revision)
    core = source("StrandiOS/Widgets/WidgetCorePublication.swift", args.revision)
    snapshot = source("StrandiOSShared/WidgetSnapshot.swift", args.revision)
    suite = declaration(snapshot, "    public static let suiteName: String =") + "()"
    snapshot = snapshot.replace(suite, '    public static let suiteName = "noop.widget-assignment.fixture." + UUID().uuidString')
    shared = [stripped(source(f"StrandiOSShared/{path}.swift", args.revision)) for path in (
        "ActiveVerifiedSinkEpoch", "VerifiedProjectionGenerationStore", "WidgetVerifiedEnvelope", "WidgetStressFreshness")]
    policies = source("StrandiOS/Widgets/LiveUpdatePolicies.swift", args.revision)
    callbacks = []
    for publisher in ("model.live.$batteryPct.dropFirst()", "model.live.$connected.dropFirst()", "model.$bpm.dropFirst()"):
        callback = declaration(app, f".onReceive({publisher})")
        callbacks.append(f"{publisher}.sink " + callback[callback.index("{"):])
    live_methods = [declaration(publish, prefix) for prefix in (
        "    @MainActor\n    static func publishLive(from model: AppModel)",
        "    @MainActor\n    static func publishLive(\n", "    @MainActor\n    enum HRPublishThrottle")]
    live_methods.append(declaration(publish, "    static func liveStoredStrain("))
    after_assignment = declaration(app, "    @MainActor static func afterAssignment(")
    swift = r'''
import Foundation
import Combine
import Darwin
public enum StrainBand { case light, moderate, high, allOut }
''' + declaration(source("Packages/StrandDesign/Sources/StrandDesign/StrainScale.swift", args.revision), "public enum StrainScale") + "\n" + stripped(snapshot) + "\n" + "\n".join(shared) + r'''
struct CivilDay: Equatable { let key: String; init(key: String) throws { self.key = key } }
struct VerifiedHealthProjection { let contextId: String; let generation: Int64; let logicalDay: CivilDay }
struct ResolvedStrain { let day: String; let storedValue: Double }
@MainActor final class LiveState: ObservableObject {
    @Published var connected = true
    @Published var batteryPct: Double? = 80
    var heartRate: Int? = 80
}
@MainActor final class Repository {
    var verifiedHealthProjection: VerifiedHealthProjection?
    func canonicalStrain(for day: String) -> ResolvedStrain? { nil }
}
@MainActor final class AppModel: ObservableObject {
    @Published var bpm: Int? = 80
    let live = LiveState(); let repo = Repository()
    var activeWorkout: Workout?
    struct Workout { var samples: [Sample] = [] }
    struct Sample { let bpm: Int }
}
@MainActor enum WidgetCoreDay {
    static func currentKey(now: Date, calendar: Calendar = .current) -> String { WidgetLogicalDay.key(of: now, calendar: calendar) }
    static func isCurrent(_ day: CivilDay, now: Date, calendar: Calendar) -> Bool { day.key == currentKey(now: now, calendar: calendar) }
}
@MainActor enum WidgetTimelineReloads {
    static func afterLivePublish(previous: WidgetSnapshot?, next: WidgetSnapshot) {}
}
enum ScenePhase { case active, background }
@MainActor final class UIApplication {
    static let shared = UIApplication()
    var applicationState = ScenePhase.active
}
@MainActor enum WorkoutLifecycleProjection {
''' + after_assignment + "\n}\n" + "\n".join(declaration(policies, p) for p in (
        "enum WidgetLivePublicationContext", "enum WidgetLivePublishPolicy", "enum WidgetFullPublishPolicy")) + "\n" + declaration(publish, "@MainActor\nprivate enum WidgetLivePublishGate") + r'''
@MainActor enum WidgetCorePublication {
''' + declaration(core, "    static func assembleLive(") + "\n" + declaration(core, "    static func widgetBonded(") + "\n}\n" + "extension WidgetSnapshot {\n" + "\n".join(live_methods) + r'''
}
@MainActor final class Harness {
    var checks = 0; var failures = 0
    var scenePhase = ScenePhase.active
    let model = AppModel()
    var tokens: [AnyCancellable] = []
    func check(_ result: Bool, _ label: String) {
        checks += 1; if !result { failures += 1 }
        print("\(result ? "PASS" : "FAIL"): \(label)")
    }
    func settle() async { await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } } }
    func seed() -> UserDefaults {
        let defaults = UserDefaults(suiteName: WidgetSnapshot.suiteName)!
        let epoch = ActiveVerifiedSinkEpochStore.beginTransition(defaults: defaults)!
        let token = ActiveVerifiedSinkEpochStore.activate(contextId: "fixture", epoch: epoch, defaults: defaults)!
        let day = try! CivilDay(key: WidgetLogicalDay.key(of: Date()))
        model.repo.verifiedHealthProjection = VerifiedHealthProjection(contextId: "fixture", generation: 1, logicalDay: day)
        let base = WidgetSnapshot(recovery: 72, bpm: 80, batteryPct: 80, bonded: true, updated: Date(),
                                  verifiedContextId: "fixture", verifiedProjectionGeneration: 1)
        _ = VerifiedWidgetEnvelopeStore.commit(token: token, generation: 1, snapshot: base, defaults: defaults)
        WidgetLivePublishGate.notePublished(base, at: Date())
        return defaults
    }
    func subscribe() {
        let model = model
        var scenePhase: ScenePhase { self.scenePhase }
''' + "\n".join(f"        tokens.append({callback})" for callback in callbacks) + r'''
    }
    func run() async {
        let defaults = seed()
        defer { defaults.removePersistentDomain(forName: WidgetSnapshot.suiteName) }
        subscribe()
        _ = WidgetSnapshot.HRPublishThrottle.admit()
        model.live.connected = false
        model.bpm = nil
        model.live.heartRate = nil
        await settle()
        check(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.bonded == false,
              "disconnect is committed even while HR correction is throttled")

        model.live.connected = true
        await settle()
        model.live.batteryPct = 41
        await settle()
        check(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.batteryPct == 41,
              "battery-only callback commits its new value")

        WidgetLivePublishGate.notePublished(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)!,
                                           at: Date().addingTimeInterval(-61))
        _ = WidgetSnapshot.HRPublishThrottle.admit(now: .distantPast)
        model.bpm = 92
        await settle()
        check(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.bpm == 92,
              "admitted smoothed-HR callback commits its new value")

        let prior = defaults.data(forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey)
        model.live.batteryPct = 37
        UIApplication.shared.applicationState = .background
        await settle()
        check(defaults.data(forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey) == prior,
              "a foreground callback rechecks actual app state before its queued write")

        scenePhase = .background
        model.live.batteryPct = 33
        await settle()
        check(defaults.data(forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey) == prior,
              "incidental background battery updates remain deferred")

        model.activeWorkout = AppModel.Workout()
        model.live.batteryPct = 30
        await settle()
        check(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults)?.batteryPct == 30,
              "an active workout retains background battery publication")
        model.activeWorkout = nil

        scenePhase = .active
        UIApplication.shared.applicationState = .active
        let beforeRevocation = defaults.data(forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey)
        model.live.connected = false
        _ = ActiveVerifiedSinkEpochStore.beginTransition(defaults: defaults)
        await settle()
        check(VerifiedWidgetEnvelopeStore.loadForDisplay(defaults: defaults) == nil,
              "revoked source epoch remains closed to queued widget writes")
        check(defaults.data(forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey) == beforeRevocation,
              "a queued callback cannot overwrite an overlay after epoch revocation")
        print("widget assignment: \(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
Task { @MainActor in await Harness().run() }
dispatchMain()
'''
    with tempfile.TemporaryDirectory(prefix="noop-widget-assignment-") as scratch:
        path = Path(scratch)
        (path / "main.swift").write_text(swift)
        subprocess.run(["swiftc", "-module-cache-path", str(path / "module-cache"), "-swift-version", "6",
                        "-warnings-as-errors", str(path / "main.swift"), "-o", str(path / "fixture")], check=True)
        return subprocess.run([str(path / "fixture")], check=False).returncode


if __name__ == "__main__":
    raise SystemExit(main())
