# Noop iOS 2.1 WHOOP implementation handoff

> **Historical handoff.** The listed production wiring and timestamp-safety work was completed on draft PR #23 (`release/noop-ios-2.1-rc`) on 2026-07-26. This file is retained as rationale and verification history; do not replay its old rebase or app-edit instructions.

This handoff originally separated work already committed to `release/noop-ios-2.1` from edits that required a local macOS checkout. The 2.1 release scope is WHOOP. Oura is not a 2.1 release requirement.

## Historical branch-refresh plan (superseded)

PR #20 is behind the moving PR #19 release line. Preserve the current tip before rewriting history:

```bash
git fetch --all --prune
git switch release/noop-ios-2.1
git status --short --branch

git branch "archive/release-noop-ios-2.1-before-refresh-$(date +%Y%m%d-%H%M%S)"
git push origin "archive/release-noop-ios-2.1-before-refresh-$(date +%Y%m%d-%H%M%S)"

# Rebase the 2.1 delta onto the current 2.0 release line.
git rebase release/noop-ios-2.0
```

Use one timestamp variable in the real command sequence so the local and pushed archive branch names match. Do not resolve conflicts by dropping PR #19 HealthKit, workout-persistence, numeric-stability, audit, backup, or accessibility work.

After the rebase:

```bash
git merge-base --is-ancestor release/noop-ios-2.0 HEAD
git diff --check
git status --short
```

Run XcodeGen after any source-membership or `project.yml` change.

## Already committed on the WHOOP path

### Journal import

The explicit and auto-detected WHOOP paths recognize the real `Answered yes` header. The compatibility pass is bounded to 32 MiB and 64 CSV candidates, prefers canonical `journal_entries.csv`, and parses the selected table once.

Longer-term cleanup: add `answered_yes` directly to `WhoopExportImporter.parseJournal` and `sniffKind`, then delete the compatibility second pass.

### Seeded WHOOP family correction

The settled-connection hook is connected. The correction now:

- captures physical peripheral and family evidence before awaiting the store;
- revalidates that evidence afterward;
- updates only an atomic `lower(trim(model)) = 'whoop'` row;
- reports success only when exactly one row changed.

Specific model labels are never overwritten.

### Raw IMU helpers

`Whoop5RawImu.decode`, `rawColumns`, and `baseTs` share one complete frame-shape validator. A long unrelated frame can no longer be interpreted as an IMU timestamp.

### WHOOP 5/MG byte-82 beta candidate

The production extraction and presentation path is connected:

1. `HistoricalStreams` reads the existing decoded `aux_byte_82` field.
2. It accepts only `70...100` while the same record reports `sleep_state == 2`.
3. All accepted values in one extraction minute are folded into one order-independent rounded mean.
4. The compatibility representation writes percentage in `red` and marker `ir == -82`.
5. The canonical `spo2Pct` / Blood O₂ path remains untouched.
6. The Health tile uses approximate, neutral, explicitly unvalidated presentation instead of “in range.”

Remaining architecture work is listed below; the current marker representation is not the desired final storage design.

### Heart-rate recovery engine

The pure engine now requires one longest contiguous Zone-3-or-higher run. Separated dense bursts cannot add together. Same-second duplicates remain canonicalized, and missing 1/2/5-minute coverage stays nil.

The card:

- includes workout source in its task identity;
- queries mature workouts once;
- refreshes only at still-pending 1/2/5-minute deadlines when opened immediately after Finish.

### Workout backfill validation

The pure backfill now rejects:

- average HR above peak HR;
- a computed peer that contradicts an existing real HR;
- nonfinite values;
- Strain outside `0...100`;
- Strain without explicit version provenance.

The production detector-collision call is now wired with the real row's owning namespace.

### GET_CLOCK planner

The planner emits at most three retries and one Data Range fallback per connection generation. It rejects a newest-bank timestamp more than five minutes ahead of wall time, is wired to the BLE timeout/connection lifecycle, and `reset()` rearms the next generation.

### Unsupported GATT families

Puffin-1150, Monument, and Symphony remain commandless metadata. The scan decision now fails closed when the **selected** UUID is unknown or unsupported, even when it is advertised or CoreBluetooth omits advertised service UUIDs.

## Historical app-file edits (completed)

These files were large, actively moving files. The completed changes were applied surgically against the PR #23 structure; the snippets below remain historical acceptance criteria, not instructions to reapply.

### 1. Place the heart-rate-recovery card

File:

```text
Strand/Screens/WorkoutDetailView.swift
```

In the `.overview` branch, place the card after the stats grid and before the zones card:

```swift
case .overview:
    paperStatsGrid
    WorkoutHeartRateRecoveryCard(
        workout: displayRow,
        maxHR: Double(profile.hrMax)
    )
    paperZonesCard
```

Acceptance criteria:

- No card for ineligible workouts or workouts with no real post-session coverage.
- Opening detail immediately after Finish updates as real 1/2/5-minute windows mature.
- A mature workout performs one repository read.
- Switching between two workouts with the same times but different source namespaces does not reuse a stale result.
- Maximum Dynamic Type stacks the three tokens vertically without clipping.

### 2. Wire missing-field workout backfill

File:

```text
Strand/Data/IntelligenceEngine.swift
```

Current collision seam:

```swift
if let hit = realWorkouts.first(where: { s.start < $0.endTs && $0.startTs < s.end }) {
    // currently logs and continues
}
```

Replace the unconditional drop with a non-destructive backfill attempt:

```swift
if let index = realWorkouts.firstIndex(where: { s.start < $0.endTs && $0.startTs < s.end }) {
    let existing = realWorkouts[index]
    let computed = WorkoutDetectedBackfill.ComputedValues(
        averageHeartRate: Int(s.avgHR),
        peakHeartRate: s.peakHR,
        caloriesKcal: s.caloriesKcal,
        strain: s.strain,
        strainVersion: s.strain == nil ? nil : 2
    )
    let enriched = WorkoutDetectedBackfill.applying(computed, to: existing)

    if enriched != existing {
        // Upsert under the source/device namespace that owns the real row.
        // Use the existing source-aware helper rather than assuming `deviceId`.
        try await upsertRealWorkout(enriched, matching: existing, store: store)
        realWorkouts[index] = enriched
    }

    if workoutsTraceActive {
        diagnosticSink?(WorkoutsTrace.detectedBoutLine(
            verdict: enriched == existing ? "droppedOverlap" : "backfilledOverlap",
            durMin: durMin,
            avgBpm: avgBpm,
            overlapSource: WorkoutSource.sourceLabel(existing)
        ), .workouts)
    }
    continue
}
```

The exact store call must preserve the owning namespace. The current `realWorkouts` array combines rows from the canonical WHOOP source and `apple-health`; do not write every collision under `computedId` or the active device blindly.

Required tests:

- Manual workout with all metrics missing receives valid computed HR/calories/Strain.
- Existing imported/manual values remain byte-identical.
- Apple Health collision writes back under `apple-health`, not the WHOOP namespace.
- No duplicate detected workout persists.
- Re-running the analysis is idempotent.
- A disk/store failure leaves the real row unchanged and does not silently discard the detected data without a diagnostic.

### 3. Wire GET_CLOCK recovery per connection generation

File:

```text
Strand/BLE/BLEManager.swift
```

State:

```swift
private var clockRecovery = StrapClockRecoveryPlanner()
```

Reset it whenever a new physical connection generation begins and on final teardown:

```swift
connectGeneration &+= 1
clockRecovery.reset()
```

When the existing GET_CLOCK timeout fires:

```swift
switch clockRecovery.nextAction(
    hasPreciseCorrelation: clockRef != nil,
    newestBankedUnix: strapNewestTs,
    wallUnix: Int(Date().timeIntervalSince1970)
) {
case .retryGetClock(let attempt, let maximum):
    log("Clock: no precise correlation; retrying GET_CLOCK \(attempt)/\(maximum)")
    // Reuse the existing allowlisted GET_CLOCK forms and acknowledged command lane.
    send(.getClock, payload: [])
    send(.getClock, payload: [0x00])

case .installDataRangeFallback(let deviceUnix, let wallUnix):
    let approximate = ClockRef(device: deviceUnix, wall: wallUnix)
    clockRef = approximate
    collector?.clockRef = approximate
    backfiller?.clockRef = approximate
    log("Clock: GET_CLOCK unresponsive; installed one approximate Data Range correlation")

case .none:
    break
}
```

A later real GET_CLOCK response must replace the approximate reference. Do not add an opcode. Do not run the fallback more than once in the same generation.

Required tests/QA:

- Three timeouts produce exactly three retries.
- Fourth timeout produces one fallback.
- Fifth and later timeouts do nothing.
- A real response on any retry suppresses fallback.
- Disconnect/reconnect resets the retry budget.
- A future Data Range marker is rejected.
- Physical strap comparison verifies dates land on the correct day when GET_CLOCK is intentionally dropped.

### 4. Wire diagnostic-only WHOOP family discovery

File:

```text
Strand/BLE/BLEManager.swift
```

Keep the normal production scan limited to the selected supported family. Under an explicit Test Centre/debug diagnostic toggle only:

```swift
let services = [selectedModel.deviceFamily.serviceUUIDString]
    + WhoopGattServiceFamily.unsupportedServiceUUIDStrings
central.scanForPeripherals(
    withServices: services.map(CBUUID.init(string:)),
    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
)
```

Before any `preparePeripheral` or `central.connect` call:

```swift
let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
    .map(\.uuidString) ?? []
let decision = whoopGattScanDecision(
    selectedServiceUUIDString: selectedModel.deviceFamily.serviceUUIDString,
    advertisedServiceUUIDStrings: advertised
)

guard decision.shouldConnect else {
    if let family = decision.unsupportedFamily {
        log(family.diagnosticUnsupportedMessage)
    }
    return
}
```

Never persist an unsupported family as the selected production model. Never discover its characteristics or send CLIENT_HELLO.

### 5. Add the upstream sleep-skip diagnostic

File:

```text
Strand/Data/IntelligenceEngine.swift
```

At the existing guard:

```swift
let hr = bundle?.hr ?? []
guard hr.count >= 200 else {
    // Return this diagnostic from the detached scan rather than calling the MainActor sink here.
    out.append(.skipped(
        day: day,
        readOwner: owner,
        hrRows: hr.count,
        line: "sleep day=\(day) SKIPPED hrSamples=\(hr.count) (need ≥200)"
    ))
    continue
}
```

Do not call the MainActor-bound `diagnosticSink` directly from the detached task. Extend the detached scan result with a lightweight skipped-day diagnostic and replay it on the main actor in day order.

Acceptance criteria:

- Always-on/shareable strap log distinguishes “insufficient data” from “stager found no sleep.”
- No raw HR values or timestamps are logged.
- A 199-row day logs once and does not score.
- A 200-row day scores and does not emit the skipped line.

### 6. Record live HR at alarm arm time

Files:

```text
Strand/BLE/BLEManager.swift
Strand/System/DebugDataDiagnostics.swift
```

In `recordAlarmArm`, write or clear the value atomically with the other diagnostic fields:

```swift
if let heartRate = state.heartRate {
    d.set(heartRate, forKey: "alarm.lastArmHeartRate")
} else {
    d.removeObject(forKey: "alarm.lastArmHeartRate")
}
```

In the debug export Alarm line:

```swift
if let heartRate = d.object(forKey: "alarm.lastArmHeartRate") as? Int {
    line += " · HR \(heartRate) bpm at arm"
}
```

This is diagnostic-only. It must not gate arming or imply that HR proves sleep state.

## Experimental SpO₂ structural follow-up

The current marker representation is acceptable only as an explicit beta compatibility bridge. The desired storage design is a dedicated local-only table:

```text
experimentalSpo2Candidate
- deviceId
- minuteTs
- sum
- count
- min
- max
- layoutVersion
- firmware/version provenance when available
PRIMARY KEY (deviceId, minuteTs)
```

The upsert must combine independent extraction chunks and remain idempotent under retransmission. A raw export should use explicit fields such as:

```text
stream=spo2_candidate_beta
candidate_pct=96
candidate_count=42
```

It must not use `spo2_red` or `spo2_ir` labels for the final design.

Required migration path:

1. Add the dedicated table and include it in device-data deletion coverage.
2. Add a protocol/domain candidate aggregate type rather than overloading `SpO2Sample`.
3. Persist with an associative, commutative upsert.
4. Compute nightly candidate only above an agreed coverage threshold.
5. Expose a repository-owned beta reading with coverage/provenance.
6. Remove the UI's direct dependency on `WhoopProtocol` marker interpretation.
7. Export under explicit beta column names.
8. Retain canonical `spo2Pct` isolation tests.

## Qualification sequence (automated and simulator gates completed)

1. Run all eight audits in `noop-ios-2.1-local-verification.md`.
2. Run all seven retained package suites for repository health.
3. Regenerate with XcodeGen, build the iOS app, and run the complete iOS simulator suite.
4. Perform manual simulator checks of the populated workout-recovery and Sleep flows in light and dark appearance.
5. Keep PR #23 draft until Easton explicitly authorizes a merge; physical WHOOP/iPhone and assistive-technology gates remain outstanding.

No hosted GitHub Actions result is release evidence for the repaired PR head: both workflows and their reruns failed before any job step started, and the job-log endpoint returned `BlobNotFound`. Do not merge PR #23, staging, or main during this work.
