# NOOP Performance State and Next Steps — 2026-07-22

## Status

- **Branch:** `perf/freeze-paths-2026-07-21`
- **Pull request:** #7, draft, do not merge yet
- **Implementation code through:** `3a1b793e0ced1ab82490619fbaac663e381a816b`
- **Base:** `main` at `4b60de7ac065cc562558d367f0a8003d30165bee`

This is the durable checkpoint for the current production-performance pass. Documentation-only commits may follow the implementation SHA above. The original source audit remains in `PERFORMANCE_CODE_REVIEW_QA_2026-07-22.md`; the exact Apple-runtime handoff is in `CODEX_PERFORMANCE_QA_HANDOFF_2026-07-22.md`.

## Product invariants

The branch preserves these hard requirements:

- the active workout UI still receives every accepted heart-rate sample;
- BPM and zone feedback inside the app are not throttled or debounced;
- Lock Screen / Dynamic Island BPM remains eligible approximately every two seconds;
- expensive Live Activity calories, zones, Strain, and trace work is bounded;
- widgets do not refresh at heart-rate cadence;
- workout Start and Finish mode edges remain immediate;
- final workout persistence remains authoritative and backward compatible;
- no visual redesign, terminology change, score change, or destructive migration is included.

## Implemented

### 1. Bounded widget live lane

The live widget publisher now:

- caches the latest snapshot in process;
- forces the first publication when no App Group snapshot exists;
- skips semantic no-ops;
- publishes connection, battery, workout-start, and workout-end edges immediately;
- coalesces BPM, live Strain, and workout sparkline churn to one minute;
- compares Strain at the one-decimal precision the widget renders;
- clears a stale workout trace immediately after Finish;
- recovers from clock rollback and future-dated persisted timestamps.

### 2. Latest-wins full widget publication

The slower dashboard projection now owns a monotonic generation token and checks it after each expensive suspension point. An older refresh cannot resume and overwrite newer App Group state.

Widget snapshots also have timestamp-independent rendered-content equality. An unrelated repository refresh that rebuilds the same payload no longer forces another App Group write and `WidgetCenter.reloadAllTimelines()`. A fifteen-minute unchanged-content heartbeat preserves freshness.

### 3. Serialized and coalesced ActivityKit lifecycle

`LiveActivityController` now owns one reconciliation worker and one latest pending drive state.

- Incoming HR callbacks replace pending desired state instead of creating unbounded update tasks.
- ActivityKit update, end, and mode-transition operations are serialized.
- A stale async update cannot complete after explicit end and revive old content.
- An activity adopted after relaunch recovers its actual current mode.
- Equal content is suppressed, with a thirty-second stale-date heartbeat.
- Disconnect and opt-out end every outstanding NOOP activity through the same lifecycle.

### 4. Cheap workout mode separated from expensive projection

Workout presence is an explicit cheap signal. Start and Finish mode edges bypass the normal two-second content throttle, while calories/zones/trace remain cached for ten seconds.

This closes the prior blocker where the Lock Screen or Dynamic Island could retain workout presentation for up to ten seconds after Finish.

### 5. Active-workout durability moved off MainActor during steady state

The existing JSON snapshot format is preserved, but production writes now flow through one utility serial writer:

- foreground snapshots are latest-wins and coalesced;
- JSON encoding and `UserDefaults` I/O run off MainActor;
- the first snapshot remains synchronous so a kill immediately after Start cannot lose the session;
- inactive/background writes are ordered and synchronous on iOS and macOS;
- newer generations invalidate older queued work;
- clear waits for the writer and invalidates pending generations, preventing a delayed write from resurrecting a finished workout;
- the growing persisted Data blob is no longer read on MainActor merely to check whether a first snapshot exists;
- isolated direct store/load seams remain deterministic for tests.

### 6. Slow stress projection work moved off MainActor

The pure DaytimeStress fingerprint and hourly bucketing scan runs at utility priority and returns only the small widget projection to MainActor. Repository access and final App Group/WidgetKit publication remain actor-correct.

## Validation completed

### Focused Swift concurrency/type checking

The changed policy, ActivityKit controller, workout-status seam, widget publisher, and active-workout persistence code were compiled against focused Linux stubs with Swift 6.2.1 and `-strict-concurrency=complete`.

**Result: pass.** This proves Swift syntax, generic/autoclosure shape, focused actor crossings, and the coalescing writer implementation. It is not an Apple SDK build.

### ActivityKit reconciliation harness

A stub ActivityKit runtime executed:

1. generic Live HR start;
2. immediate workout-mode transition;
3. one hundred HR updates while the system bridge was treated as busy;
4. immediate workout Finish back to generic mode;
5. disconnect/end.

**Result: pass.** The expensive workout supplier was evaluated once during the burst and lifecycle mutations remained serialized.

### Deterministic 30-minute, 1 Hz workout simulation

For 1,800 incoming HR events:

| Work | Result |
|---|---:|
| Widget live publications | 31 |
| ActivityKit push opportunities | 901 |
| Expensive workout projection builds | 180 |

Interpretation:

- widget: Start + approximately one per minute + immediate Finish;
- ActivityKit: Start + approximately every two seconds + immediate Finish;
- calories/zones/trace projection: once every ten seconds;
- active in-app HR delivery is outside these gates and remains per sample.

### Active-workout persistence stress

The focused harness queued hundreds of growing snapshots, forced a synchronous final snapshot, and cleared while writes were pending.

**Result:** newest snapshot won; synchronous final state won; clear left no resurrected session.

### Synthetic persistence comparison

Linux synthetic input: one snapshot containing 20,000 HR samples, written 100 times.

| Path | Measured wall time |
|---|---:|
| Prior synchronous encode/write loop | ~5.58 s |
| Caller time to enqueue 100 coalesced writes | ~0.00037 s |
| Coalesced writer through final flush | ~0.070 s |

This is controlled sandbox evidence, not an iPhone performance claim. Physical-device Instruments evidence is still required.

### GitHub Actions

Latest observed app-build run for the implementation code: `29888702308`.

- `NOOPiOS`, `generic/platform=iOS Simulator`, `macos-26`: failed before step metadata appeared;
- universal `Strand`, `macos-15`: failed before step metadata appeared;
- no checkout/build steps, logs, or artifacts were exposed.

This failure occurs before repository execution and is consistent with an account, runner, billing, or minutes gate. It provides no compiler evidence either way.

## Remaining production work

Keep these ordered. Do not blend them into one unreviewable mega-diff.

### Gate 1 — Apple compile and runtime evidence

1. Generate the project with XcodeGen.
2. Build `NOOPiOS` for an iOS Simulator.
3. Build universal `Strand` for macOS.
4. Build widgets and the Live Activity extension.
5. Run `NOOPiOSTests`, `StrandTests`, and touched package suites.
6. Run the Simulator Start → active → Finish → restart matrix.
7. Capture a physical Release 30-minute workout on the same phone and database as baseline.
8. Compare WidgetKit reloads, App Group writes, ActivityKit pushes, projection builds, durability writes, main-thread stalls, CPU, memory, and final-result parity.

The exact Codex/Xcode evidence task is stored in `CODEX_PERFORMANCE_QA_HANDOFF_2026-07-22.md`.

### Gate 2 — Reference-owned active workout session

Replace the growing `@Published ActiveWorkout` value with reference-owned session storage plus a lightweight display snapshot:

- private mutable HR buffer and accumulators owned by one session object or actor;
- immediate leaf-level BPM/zone publication for every sample;
- lightweight Equatable UI snapshot rather than republishing the complete array;
- bounded trace projection;
- no broad `AppModel.objectWillChange` fan-out at HR cadence;
- explicit session generation so old tasks cannot mutate a restarted workout.

This is the highest-value remaining structural change, but it should land only after the current tranche has real Xcode proof.

### Gate 3 — O(1) workout projection

Each ten-second projection is bounded in frequency but still scans the whole session. Add incremental accumulators beside live Strain:

- running calorie integral;
- five zone-duration counters;
- bounded display trace;
- immutable projection snapshot.

Final saved values must be compared against the current canonical calculation before switching authority.

### Gate 4 — Strap-log durability

`LiveState.append(log:)` still rewrites up to 2,000 strings to `UserDefaults` for each log line. Replace it with:

- a ring/deque or bounded chunk buffer;
- one coalescing utility writer;
- a two-to-five-second durable debounce;
- force flush on disconnect, background, manual share, and scheduled export;
- a test proving 1,000 appends cause a bounded number of writes.

### Gate 5 — Refresh and query amplification

- run the long Effort migration without repository refresh per 30-day chunk, then publish one final bounded refresh;
- replace large-range materialization for latest values with indexed descending-limit queries;
- add exact-day, multi-key reads for Sleep Need components;
- query only the trailing HRV points widgets render;
- persist or SQL-aggregate hourly stress where practical.

### Gate 6 — Observation scope

- split Sleep loading onto a sleep-specific generation and off-main snapshot builder;
- remove root observation dependencies already owned by leaf views;
- move Smart Alarm application behind one coalesced configuration snapshot, preserving immediate disable;
- ensure screens that only invoke AppModel commands do not observe all high-frequency AppModel publications.

## Merge decision

**Keep PR #7 draft.**

The known workout-end mode blocker, overlapping ActivityKit tasks, steady-state MainActor durability encode, stale full-widget overwrite, and unchanged full-widget reload paths are fixed in source and focused harnesses.

The remaining blockers are evidence gates:

- no trustworthy Xcode build;
- no iOS Simulator interaction proof;
- no physical Release long-workout trace;
- no final calories/zones/Strain/sample-count parity capture.

Do not remove Draft until those gates pass or a specific runtime failure is fixed and revalidated.
