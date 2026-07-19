# Implementation Plan

## Feature / thing update map

| Update | Why | Affected surfaces/files | User-visible result | Verification |
|---|---|---|---|---|
| Fitness Age destination | Component 39 is the screen opened from age, not an inline Health expansion | `HealthView.swift`, Today/dashboard Fitness Age destination mapping, new `FitnessAgeDetailView.swift` | Tapping Fitness Age opens the full hero, drivers, calibration, and six-month history | Route tests plus scored/calibrating phone QA |
| Honest Fitness Age presentation | Design Lab fixtures contain arbitrary pace and nine causal impacts | `FitnessAgeEngine.swift`, new pure presentation resolver, StrandDesign components | Real age rail and history; numeric pace only when earned; exact direct drivers only | Resolver math, sparse-history, bounds, and repository fixture tests |
| Active device command center | Existing Devices cards do not answer connection/sync/clock health in one read | `DevicesView.swift`, new `DeviceCommandCenterStatus.swift`, StrandDesign device components | One-scroll identity, issue summary, status list, sync, power, commands | Resolver matrix and connected/disconnected phone QA |
| Connection uptime | Backend has connection state but no durable session start stamp | `LiveState.swift`, `BLEManager.swift` | Real connection uptime instead of a fixture label | Connect/reconnect/disconnect transition tests |
| Safe commands | UI should not reach into BLE internals or imply unsupported commands | `AppModel.swift`, Devices action grid | Four common commands with correct gating and local feedback | Action-gating tests and hardware action QA |
| Existing management | Active command center must not erase multi-device workflows | Existing registry cards, add wizard, confirmations | Other/removed devices and add/rename/switch/remove remain below | Registry regression and interaction QA |
| Widgets & Live | Existing out-of-app surfaces are much thinner than component 41 | shared snapshot, widget extension, ActivityKit controller/state | Rich Home widgets, Recovery + selectable Strain Lock widgets, workout Live Activity and Island | Backward-codec/state tests plus physical Lock/Island QA |
| Flat visual adoption | Raised gray cards conflict with the approved NOOP direction | New StrandDesign primitives and both host screens | Continuous canvas with dividers; bounded controls only where interactive | Light/dark screenshots and visual comparison |

## Architecture and data decisions

- `StrandDesign` owns narrow display models and visual primitives. App screens own repository access, environment objects, routing, and command closures.
- Add a pure `FitnessAgeDetailSnapshotResolver` in `StrandAnalytics` (or the nearest existing analytics presentation layer). It receives already-queried profile/series/weekly inputs and returns display-ready values without touching SwiftUI or storage.
- Keep the existing compact Health Fitness Age summary. Replace its metric-trend tap with a push to `FitnessAgeDetailView`; the detail screen retains a secondary route to the generic metric trend and Settings readiness fixes.
- The real six-month plot uses weekly `fitness_age` points. Calendar age is a fixed reference because NOOP currently stores age, not date of birth; it must not draw a false precise rising birthday line.
- Pace of aging is the slope of real Fitness Age change versus elapsed calendar time, normalized so `1.0x` means one Fitness Age year per calendar year. Require at least 12 weekly readings spanning at least 90 days and use a tested robust/least-squares fit; otherwise show Calibrating. Label it as trend pace, not biological aging.
- Expose exact direct contributions from the current equation: resting-HR deviation and physical-activity-index deviation. Their signed year impacts must sum to `fitnessAge - chronoAge` before clamping. Age/sex/readiness/VO2max appear as inputs or context, not fabricated contributors.
- Add a pure `DeviceCommandCenterStatusResolver` beside `DevicesView`. It accepts an immutable snapshot of `PairedDevice`, `LiveState`, clock-readout results, R22 preference/config count, and current time; it returns identity/status/sync/power/health/action-gating models.
- Reuse `ConnectionReadout.clockCorrelatedDevice`, `clockLatchedLabel`, `lastFrameLabel`, and `rtcWarning`; RTC thresholds remain in `StrandAnalytics`.
- Add `LiveState.connectedAt` plus explicit connection-state mutators so every BLE transition stamps/clears both `connected` and uptime consistently. Do not add RSSI polling.
- Add thin `AppModel` methods: `syncActiveDevice`, `testDeviceVibration`, `refreshDeviceBattery`, and `refreshDeviceLink`.
- Keep high-frequency observation narrow: the top-level Devices composition receives stable snapshots; last packet and uptime labels use small timer-driven leaf views.
- Enrich `WidgetSnapshot` with optional slow fields and split publication into a slow dashboard lane and fast live lane so HR ticks never trigger stress/history reads.
- Keep serialized `effort` compatibility while exposing it as canonical Strain to new widget code. Add a second circular-only Strain widget; rectangular/inline show both Recovery and Strain.
- Make ActivityKit state mode-aware with optional workout fields. Live HR stays simple; a manual workout restarts/adopts the activity in workout mode and reuses authoritative Strain, Calories, and HRZones paths.

## Status contracts

### Device health

Resolve the primary issue in this order:

1. Bluetooth unavailable
2. Reconnect guidance
3. Pairing hint or connected without `encryptedBond`
4. RTC warning
5. Last sync error
6. Strap needs reboot
7. Battery at/below the existing critical threshold
8. Experimental history mode
9. Standard-HR fallback

The summary level is healthy only when no informational, warning, or critical issue exists. The first issue appears directly below Issues detected; the count includes every backed signal without double-counting live-HR-only and its pairing hint.

### Sync labels

- `Syncing · N chunks received`
- `Caught up · <relative time>`
- `Waiting for first sync`
- `History sync experimental`
- `Needs attention · Sync interrupted`
- `Not connected`

No percentage is shown because the protocol exposes acknowledged chunks but not the total pending count.

### Action gates

| Action | Enabled when | Existing path |
|---|---|---|
| Sync now | connected, encrypted bond, not backfilling | `ble.syncNow()` |
| Test vibration | connected and encrypted bond | `buzzStrapOnce()` |
| Refresh battery | connected | `getBattery()` / `ble.refreshBattery()` |
| Reconnect / Refresh link | Bluetooth available | existing scan/connect path |

Feedback remains local to the Devices action area: Syncing, Sent, Refreshing, or a concise disabled reason.

## Step-by-step execution

1. Add failing Fitness Age presentation tests for real-series routing, calibrating behavior, pace history gates, exact driver attribution, engine bounds, and disclaimer/band consistency.
2. Add failing device resolver/action tests for healthy, live-HR-only, clock failure, sync failure, experimental history, low battery, reconnect guidance, non-WHOOP, and no-active-device states.
3. Add connection-uptime transition tests, then implement `connectedAt` and route every BLE connect/teardown branch through consistent state mutators.
4. Productionize flat, narrow-input Fitness Age and device-command components in `StrandDesign`, including Dynamic Type, VoiceOver, Reduce Motion, missing-data, and error states.
5. Implement the Fitness Age resolver and `FitnessAgeDetailView`; wire Health and every eligible Today/catalog Fitness Age destination to it while retaining generic trend and Settings actions.
6. Implement `DeviceCommandCenterStatusResolver`, AppModel wrappers, and the single-scroll active-device command center; preserve current other/removed device management below it.
7. Enrich widgets through slow/fast snapshot publication, add the separate Strain circular accessory, and adopt component 41 across all Home/Lock families.
8. Extend ActivityKit state/controller for simple live-HR and rich manual-workout modes without duplicating scoring math.
9. Run StrandAnalytics, StrandDesign, WhoopStore, focused app/device/widget tests, static honesty audits, and macOS/iPhone compile gates.
10. Build a signed iPhone Release and install it in place with `com.eastonplace.noop`; do not uninstall, reset, seed, or replace the database.
11. Visually and interactively QA all three components on the physical phone, including both circular accessories and Lock/Island workout states.
12. Run the no-mistakes review, record evidence under this spec's `qa/`, commit and push the existing child branch/PR #5, and leave PR #4 and PR #5 unmerged.

## Artifact outputs

- `specs/017-fitness-age-device-command-center/spec.md`
- `specs/017-fitness-age-device-command-center/plan.md`
- `specs/017-fitness-age-device-command-center/tasks.md`
- `specs/017-fitness-age-device-command-center/checklists/requirements.md`
- Planned verification: `specs/017-fitness-age-device-command-center/qa/verification.md`

## Risks and gates

- The Design Lab's nine Fitness Age impacts and sample pace are fixtures. Shipping them as real would be false; production uses only equation-backed contributions and earned history.
- Fitness Age is clamped to 20–80. Attribution must explain pre-clamp math and avoid implying a contribution beyond the displayed bound.
- `LiveState.connected` is written in several recovery paths. Missing one would leave stale uptime, so the transition audit is a hard test gate.
- Device-specific commands only fully apply to WHOOP. Generic HR/Oura/FTMS sources must not expose a working-looking unsupported command.
- Existing focused app tests have known unrelated stale Sleep API failures; verification must separate new failures from that baseline and cannot overclaim a full suite.
- Phone install success, launch success, database preservation, and visual QA are reported as separate evidence.
