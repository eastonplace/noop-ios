# Noop iOS 2.1 implementation handoff

This handoff distinguishes code that is already on the production path from tested integration seams that still need a narrow local edit after `release/noop-ios-2.1` is refreshed onto the current moving `release/noop-ios-2.0` base.

## Branch refresh first

PR #20 was created from an earlier PR #19 head. Before compilation or additional app-file edits:

```bash
git fetch --all --prune
git switch release/noop-ios-2.1
git branch archive/release-noop-ios-2.1-before-refresh-$(date +%Y%m%d-%H%M%S)
git rebase release/noop-ios-2.0
```

Do not resolve conflicts by dropping PR #19 HealthKit, workout-persistence, audit, or backup work. Run XcodeGen after any source-membership or `project.yml` change.

## Already on the production path

### WHOOP journal `Answered yes`

`ImportCoordinator.importWhoopExport` and the auto-detected WHOOP path run `WhoopV91JournalCompatibility`. No additional app wiring is required.

### Seeded WHOOP family correction

`StrandiOSApp` observes the existing settled-connection signal and invokes `AppModel.correctSeededWhoopModelIfNeeded`. The corrector updates only the generic `WHOOP` registry model. Device verification remains required.

### WHOOP raw-IMU storage helpers

`Whoop5RawImu.rawColumns` and `baseTs` are available to the current raw-capture/store pipeline. No existing decoder behavior was replaced.

## Narrow local wiring still required

### Workout heart-rate recovery card

File: `Strand/Screens/WorkoutDetailView.swift`

In the `.overview` section, place the card after the stats grid and before/after the zones card:

```swift
case .overview:
    paperStatsGrid
    WorkoutHeartRateRecoveryCard(
        workout: displayRow,
        maxHR: Double(profile.hrMax)
    )
    paperZonesCard
```

The card performs its own narrow repository read. Do not reuse the chart's bucketed HR values; HRR requires distinct raw seconds after the workout ends.

### Missing-field workout backfill

File: `Strand/Data/IntelligenceEngine.swift`

In the collision path where a newly detected bout overlaps a real/manual/imported workout:

1. Compute the detector's values from the already-loaded HR window.
2. Build `WorkoutDetectedBackfill.ComputedValues`.
3. Call `WorkoutDetectedBackfill.applying(_:to:)` for the real row.
4. Upsert only when the result differs.
5. Retire or skip the duplicate detected row through the existing collision semantics.

Never overwrite a non-nil imported/manual HR, calories, Strain, route, notes, zones, source, or natural key. Use the current NOOP iOS Strain scorer/version; do not import an upstream scoring formula.

### GET_CLOCK retry and Data Range fallback

File: `Strand/BLE/BLEManager.swift`

Add one `StrapClockRecoveryPlanner` per connection generation. Reset it on disconnect/new connection. When the normal GET_CLOCK response timeout fires:

- `.retryGetClock`: resend the existing GET_CLOCK command through the existing acknowledged command lane.
- `.installDataRangeFallback`: install an explicitly approximate `ClockRef` using the newest banked Data Range timestamp and current wall time, and log that the correlation is approximate.
- `.none`: leave the correlation absent and do not fabricate history timestamps.

A later real GET_CLOCK response must replace the fallback. Do not add a new opcode or speculative command.

### Unsupported WHOOP GATT-family diagnostics

File: `Strand/BLE/BLEManager.swift`

For an opt-in/debug broadened scan only, include `WhoopGattServiceFamily.unsupportedServiceUUIDStrings` in the scan filter. Before connecting, run `whoopGattScanDecision`:

- connect only when the selected established family is advertised or CoreBluetooth omitted service UUIDs;
- log `diagnosticUnsupportedMessage` for Puffin-1150, Monument, or Symphony;
- never connect, discover, subscribe, send CLIENT_HELLO, or write commands to those unsupported families.

The normal production scan may remain limited to the selected established family until device QA is complete.

### Oura feature-status, wear, and IBI timestamp wiring

File: `Strand/BLE/OuraLiveSource.swift` and/or the existing Oura driver integration.

- Send `spo2ReadStatus()` and `realStepsReadStatus()` only from an explicit diagnostic path; decode `0x21` replies through `OuraFeatureStatusProbe` and log status/subscription without claiming a measurement.
- Feed `OuraWearTracker.notePulse()` only from the live daytime-HR stream. Feed charger state strings through `note(state:)`. Apply a watchdog to call `noteLivePulseTimeout()`; banked IBI must not mark the ring currently worn.
- For each IBI, map ring time through the current anchor. Apply `OuraIBITimestampPolicy`: persist only `.persist`; queue `.park` until an anchor arrives. Do not advance a historical resume cursor merely because a live beat was observed.

### WHOOP v18 byte-82 diagnostic correlation

The decoder is intentionally absent from app targets. A future explicit diagnostic tool may call `Whoop5V18SpO2Candidate.decode` and export only raw/candidate correlation evidence. It must not write a health row, metric series, HealthKit sample, Recovery input, illness input, or UI value.

## Static and local QA sequence

1. Refresh onto the current stacked base.
2. Run all eight audits in `noop-ios-2.1-local-verification.md`.
3. Run the focused package tests while iterating.
4. Run all seven retained package suites.
5. Regenerate with XcodeGen.
6. Build warning-clean and run the complete iOS simulator suite.
7. Perform the manual simulator checks.
8. Keep PR #20 draft until device-only WHOOP/Oura/background gates are recorded.

No GitHub Actions result is release evidence for this PR.
