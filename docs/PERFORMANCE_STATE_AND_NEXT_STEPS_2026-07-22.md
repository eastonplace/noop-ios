# NOOP Performance State and Next Steps — 2026-07-22

## Status

**Branch:** `perf/freeze-paths-2026-07-21`  
**Pull request:** #7, draft, do not merge yet  
**Implementation tranche through:** `b87cc5ddf89c73b08db524ca13fa0536218e751f`

This document is the durable checkpoint for the current production-performance pass. It records what is implemented, what was actually validated, and the exact order of the remaining work. It supplements `PERFORMANCE_CODE_REVIEW_QA_2026-07-22.md`.

## Product invariants

The branch preserves these hard requirements:

- the active workout screen still receives every accepted heart-rate sample;
- BPM and zone feedback inside the app are not throttled or debounced;
- Lock Screen / Dynamic Island BPM remains eligible approximately every two seconds;
- expensive Live Activity calories, zones, Strain, and trace work is bounded;
- widgets do not refresh at heart-rate cadence;
- workout start/end mode edges remain immediate;
- final workout persistence remains authoritative and existing storage formats remain compatible;
- no visual redesign, terminology change, score change, or destructive migration is included.

## Implemented in this branch

### 1. Widget live lane is bounded

The live widget publisher now:

- keeps the latest snapshot in process instead of decoding the App Group blob on every event;
- forces the first publication when no snapshot exists;
- skips semantic no-ops;
- publishes connection, battery, workout-start, and workout-end edges immediately;
- coalesces BPM, live Strain, and workout sparkline churn to one minute;
- compares Strain at the one-decimal precision rendered by widgets;
- clears a stale workout trace immediately after Finish;
- recovers from wall-clock rollback and future-dated persisted timestamps.

### 2. Full widget publication is latest-wins

The slower dashboard projection performs several asynchronous reads. It now owns a monotonic generation token and checks it after every expensive suspension point, so an older refresh cannot resume and overwrite newer App Group state.

The rendered snapshot now has timestamp-independent semantic equality. Unrelated repository refreshes that rebuild the same widget payload no longer force another App Group write and `WidgetCenter.reloadAllTimelines()`. An unchanged-payload heartbeat remains bounded at fifteen minutes.

### 3. ActivityKit writes are serialized and coalesced

`LiveActivityController` now has one reconciliation worker and one latest pending drive state.

Consequences:

- incoming HR callbacks replace pending desired state instead of creating unbounded update tasks;
- ActivityKit update, end, and mode-transition operations are serialized;
- a stale async update cannot complete after an explicit end and revive old content;
- activity adoption after relaunch recovers the actual current mode;
- equal content is suppressed, with a thirty-second stale-date heartbeat;
- disconnect and opt-out end every outstanding NOOP activity through the same serialized lifecycle.

### 4. Workout mode is separated from its expensive projection

Workout presence is now a cheap explicit signal. Start and Finish mode edges bypass the ordinary two-second content throttle, while the expensive projection remains cached for ten seconds.

This closes the prior blocker where the Lock Screen or Dynamic Island could remain in workout mode for up to ten seconds after Finish.

### 5. Active-workout durability no longer encodes on MainActor during steady state

The growing active-workout snapshot is still JSON-compatible with existing installs, but production writes now flow through one utility serial writer:

- foreground snapshots are latest-wins and coalesced;
- JSON encoding and `UserDefaults` writes run off MainActor;
- the first snapshot is synchronous so an immediate kill after Start cannot lose the session;
- iOS inactive/background flushes are synchronous before suspension;
- newer generations invalidate older queued work;
- clear waits for the writer and invalidates pending generations, so a delayed write cannot resurrect a finished workout;
- isolated direct store/load seams remain deterministic for existing tests.

This removes the periodic full-array JSON encode from the interactive actor without changing the persisted schema.

### 6. Slow stress projection work is off MainActor

The pure DaytimeStress fingerprint and hourly bucketing scan runs at utility priority and returns only the small widget projection to MainActor. Repository reads and UI/App Group publication remain actor-correct.

## Validation completed

### Strict Swift concurrency/type checking

The changed policy, ActivityKit controller, workout-status seam, widget publisher, and active-workout persistence code were compiled against focused Linux stubs with Swift 6.2.1 and `-strict-concurrency=complete`.

**Result:** pass.

This proves Swift syntax, generic/autoclosure shape, actor crossings in the focused harness, and the coalescing writer implementation. It is not an Apple SDK build.

### ActivityKit reconciliation harness

A stub ActivityKit runtime executed this sequence:

1. generic Live HR start;
2. immediate workout-mode transition;
3. one hundred HR updates while the system bridge was treated as busy;
4. immediate workout Finish back to generic mode;
5. disconnect/end.

**Result:** pass. The expensive workout supplier was evaluated once during the burst, and lifecycle mutations remained serialized.

### Deterministic 30-minute, 1 Hz workout simulation

For 1,800 incoming HR events:

| Work | Result |
|---|---:|
| Widget live publications | 31 |
| ActivityKit push opportunities | 901 |
| Expensive workout projection builds | 180 |

Interpretation:

- widget: start + approximately one per minute + immediate finish;
- ActivityKit: start + approximately every two seconds + immediate finish;
- calories/zones/trace projection: once every ten seconds;
- active in-app HR delivery is outside these gates and remains per sample.

### Active-workout persistence stress harness

The focused harness queued hundreds of growing snapshots, forced a synchronous final snapshot, and then tested clear while writes were pending.

**Result:** latest snapshot won; synchronous final state won; clear left no resurrected session.

### Synthetic persistence benchmark

Linux synthetic input: one snapshot containing 20,000 HR samples, written 100 times.

| Path | Measured wall time |
|---|---:|
| Prior synchronous encode/write loop | ~5.58 s |
| Main-thread time to enqueue 100 coalesced writes | ~0.00037 s |
| Coalesced writer through final flush | ~0.070 s |

This is a controlled algorithm/I/O comparison in the ChatGPT Linux sandbox, not an iPhone performance claim. It demonstrates that steady-state caller latency and redundant encoding work are removed; physical-device Instruments evidence is still required.

### GitHub Actions

Latest observed app-build run for the branch: `29887889943`.

- `NOOPiOS`, `generic/platform=iOS Simulator`, `macos-26`: failed before step metadata appeared;
- universal `Strand`, `macos-15`: failed before step metadata appeared;
- no job steps, logs, or artifacts were exposed.

This failure shape occurs before checkout/build execution and is consistent with an account/runner/minutes gate. It provides no compiler evidence either way.

## Remaining production work

The following work remains intentionally ordered. Do not blend all of it into one unreviewable diff.

### Gate 1 — Apple compile and runtime evidence

1. Generate the project with XcodeGen.
2. Build `NOOPiOS` for an iOS Simulator.
3. Build universal `Strand` for macOS.
4. Build widgets and Live Activity extension.
5. Run `NOOPiOSTests`, `StrandTests`, and touched package suites.
6. Run the simulator start/active/finish/restart matrix.
7. Capture a physical Release 30-minute workout on the same phone and database as baseline.
8. Compare WidgetKit reloads, App Group writes, ActivityKit pushes, projection builds, main-thread stalls, CPU, memory, and final score parity.

The exact Codex/Xcode evidence task is stored in `CODEX_PERFORMANCE_QA_HANDOFF_2026-07-22.md`.

### Gate 2 — Reference-owned active workout session

The next major runtime refactor should replace the growing `@Published ActiveWorkout` value with reference-owned session storage plus a lightweight display snapshot.

Required shape:

- private mutable HR buffer and accumulators owned by one session object/actor;
- immediate leaf-level BPM/zone publication for every sample;
- lightweight Equatable UI snapshot rather than republishing the complete array;
- bounded trace projection;
- no broad `AppModel.objectWillChange` fan-out at HR cadence;
- explicit session generation so old tasks cannot mutate a restarted workout.

This is the highest-value remaining structural change, but it should land only after the current branch has real Xcode proof.

### Gate 3 — O(1) workout projection

The current projection frequency is bounded, but each ten-second rebuild still scans the session for calories and zone duration. Add incremental accumulators beside live Strain:

- running calorie integral;
- five zone-duration counters;
- bounded display trace;
- immutable projection snapshot.

The Live Activity projection should then be O(1) regardless of workout length. Final saved values must be compared against the existing canonical calculation before switching authority.

### Gate 4 — Strap-log durability

`LiveState.append(log:)` still rewrites up to 2,000 strings to UserDefaults for each log line. Replace that path with:

- a real ring/deque or bounded chunk buffer;
- one coalescing utility writer;
- a two-to-five-second durable debounce;
- force flush on disconnect, background, manual share, and scheduled export;
- a test proving 1,000 appends cause a bounded write count.

### Gate 5 — Refresh and query amplification

- run the long Effort migration without repository refresh per 30-day chunk, then publish one final bounded refresh;
- replace large range materialization for latest values with indexed descending-limit queries;
- add exact-day, multi-key reads for Sleep Need components;
- query only the trailing HRV points widgets render;
- persist or SQL-aggregate hourly stress where practical.

### Gate 6 — Observation scope

- split Sleep screen loading onto a sleep-specific generation and off-main snapshot builder;
- remove root observation dependencies that are already owned by leaf views;
- move Smart Alarm command application behind one coalesced configuration snapshot, preserving immediate disable;
- ensure screens that only invoke AppModel actions do not observe all high-frequency AppModel publications.

## Merge decision

**Keep PR #7 draft.**

The known workout-end mode blocker and ActivityKit overlap risk are fixed in source and focused harnesses. The remaining merge blockers are now evidence gates:

- no trustworthy Xcode build;
- no iOS Simulator interaction proof;
- no physical Release long-workout trace;
- no final calories/zones/Strain parity capture.

Do not remove Draft until those gates pass or a specific failure is fixed and revalidated.
