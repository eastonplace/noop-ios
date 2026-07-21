# iOS Performance and Freeze Audit — 2026-07-21

## Scope

Code-first review of the current `main` branch after the prior `specs/013-ios-performance-stabilization` pass. The goal is to find regressions introduced by rapid feature growth, especially work that is repeated at live-sensor cadence, broad database work triggered by migrations, and observation paths that invalidate large SwiftUI trees.

## Executive summary

The app already contains several good performance defenses: repository cache diffing, off-main merges, single-flight store opening, backfill refresh debouncing, incremental live Strain, and leaf isolation on Today. The current freezing risk is not one single bad algorithm. It is **expensive work being reattached to high-frequency publishers** after those defenses were added.

The highest-confidence freeze paths are:

1. **Active workout → widget reload storm.** `AppModel.activeWorkout` is rewritten about once per HR sample. `StrandiOSApp` observes every rewrite and calls `WidgetSnapshot.publishLive`, which previously decoded and encoded the App Group snapshot and called `WidgetCenter.reloadAllTimelines()` every time.
2. **Active workout → repeated full-history projection.** The Live Activity input was computed before its two-second ActivityKit throttle. Calories and time-in-zone were rescanned over the entire growing workout sample array on every HR emission, recreating an O(n) path inside a live loop that AppModel had otherwise made O(1).
3. **One-time Effort migration → up to ~134 broad repository refreshes.** `runEffortRescoreIfNeeded(historyDays: 4000)` processes 30-day chunks and each `analyzeRecent` may call the default 4,000-day `repo.refresh()`. Even when cache diffing prevents a publish, all broad SQLite reads happen before the diff.
4. **Strap log → synchronous full-tail persistence.** `LiveState.append(log:)` runs on the main actor and writes up to 2,000 strings to UserDefaults on every line. Backfills and diagnostic modes can turn this into repeated array copies, property-list serialization, and disk coordination during the most write-heavy periods.
5. **Analysis → unconditional 60-day motion calibration scan.** Every forced `analyzeRecent` performs owner resolution and gravity reads for up to 60 days even when neither Apple step references nor gravity frontiers changed.

This PR fixes items 1 and 2. Items 3–5 should be split into focused follow-up PRs with measurements and rollback boundaries.

## Changes in this PR

### 1. Coalesce the widget fast lane

`WidgetSnapshot.publishLive` now:

- caches the last in-process snapshot instead of decoding App Group storage every call;
- skips semantically identical live payloads;
- immediately publishes connection, battery, canonical Strain, and workout start/end changes;
- limits BPM and in-workout sparkline churn to one publication per minute;
- calls `WidgetCenter.reloadAllTimelines()` only when a publication is actually admitted.

This keeps start/end and important status edges responsive while removing the ~1 Hz storage and WidgetKit loop during a workout.

### 2. Make Live Activity workout projection lazy and bounded

`LiveActivityController.update` now receives the workout state as an autoclosure. It:

- applies the existing ActivityKit push throttle before evaluating the expensive projection;
- caches the workout projection for ten seconds;
- still probes promptly when no workout is active so workout start is detected;
- skips identical ActivityKit payloads, with a 30-second heartbeat to refresh the stale date;
- clears all projection/content caches when the activity ends.

BPM remains eligible for the existing two-second Live Activity cadence. Calories, zones, and the workout trace no longer rescan the entire session every HR tick.

## Follow-up plan

### P0 — stop migration refresh amplification

Target: `Strand/Data/IntelligenceEngine.swift`

Current shape:

- full history: 4,000 days;
- chunk size: 30 days;
- potential chunks: `ceil(4000 / 30) = 134`;
- each chunk calls `analyzeRecent` with `refreshRepository: true`;
- a changed chunk can trigger a default 4,000-day repository refresh.

Recommended change:

1. run every migration chunk with `refreshRepository: false`;
2. persist offset only after a completed analysis pass;
3. perform one repository refresh after the final successful chunk;
4. publish progress without invalidating dashboard caches;
5. later replace the 4,000-calendar-day bound with the actual earliest/latest HR day range.

Success condition: one migration produces at most one dashboard refresh, remains resumable, and does not block first interaction.

### P0 — debounce durable strap-log writes

Target: `Strand/BLE/LiveState.swift`

Recommended change:

- append to the in-memory ring immediately;
- schedule one detached/debounced durable-tail write every 2–5 seconds;
- force-flush on backgrounding, scheduled export, explicit share, and disconnect;
- persist only the bounded suffix;
- never serialize the entire tail synchronously from the main actor per log line.

Success condition: 1,000 log appends cause a small bounded number of UserDefaults writes, and exported content remains complete after an explicit flush.

### P1 — fingerprint the 60-day steps-calibration inputs

Target: `Strand/Data/IntelligenceEngine.swift`

Store and compare:

- Apple Health step-reference fingerprint for the calibration window;
- per-owner gravity count/max timestamp fingerprint;
- profile manual-override/version inputs.

Only rerun the 60-day owner-resolution and gravity scan when one of those inputs changes. Reuse the last calibration dictionaries otherwise.

### P1 — narrow observation at screen roots

Targets include `SleepView`, `SmartAlarmView`, and other rapidly expanded screens.

Actions:

- remove root `@EnvironmentObject` dependencies used only by a leaf;
- feed large cards immutable, Equatable snapshots;
- move timers and live publishers into leaf views;
- avoid `.task(id: repo.refreshSeq)` on several sibling sections when one screen loader can build a coherent snapshot once;
- debounce multi-field settings writes that currently trigger several identical BLE command bursts.

### P1 — centralize refresh intents

Introduce typed refresh intents such as:

- `.dashboardRecent(days: 120)`
- `.historyWide`
- `.postBackfill`
- `.postImport`
- `.migrationFinal`

Coalesce equal or weaker requests while one is in flight. A caller should not choose `4,000` days by default merely because it needs one updated tile.

### P2 — remove dead and duplicated pathways

For each feature family:

- identify the canonical implementation and delete legacy cards/engines after migration;
- keep QA galleries and screenshot harnesses behind `#if DEBUG` and excluded from Release resources where possible;
- remove compatibility code after its persisted migration version is safely retired;
- add a CI check for source files that are compiled but unreachable except from debug launch arguments;
- cap oversized files and require new feature work to extract cohesive services rather than extending `AppModel`, `Repository`, or `IntelligenceEngine` indefinitely.

## Measurement gates for the next PRs

Capture on a physical iPhone Release build with a large database and an active strap:

- main-thread stalls over 100 ms during a 30-minute workout;
- WidgetKit reload requests per minute;
- App Group snapshot writes per minute;
- Live Activity projection builds per minute;
- repository refresh count during a full Effort migration;
- durable log writes during a 1,000-line synthetic burst;
- `analyzeRecent` duration and number of store reads with unchanged calibration inputs.

A performance PR should include before/after counts, not only code-shape claims.
