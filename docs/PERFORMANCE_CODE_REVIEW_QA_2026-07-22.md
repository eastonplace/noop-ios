# NOOP Performance Code Review and QA Ledger — 2026-07-22

## Decision

**PR #7 remains DRAFT and MUST NOT be merged yet.**

The patch removes two credible high-frequency iOS hot loops and survived focused policy/type-check QA, but the full Xcode build, physical-device trace, and long-workout regression gates are not available yet. The review also found important adjacent freeze paths that are outside the current patch and one behavior edge that still needs a production decision.

## Scope

Reviewed:

- every changed line in PR #7;
- every call site that drives `LiveActivityController.update` and `WidgetSnapshot.publishLive`;
- the active-workout collection and durability path;
- widget slow/fast publication;
- repository refresh and full-history migration paths;
- strap-log persistence;
- the expanded Sleep and Alarm screen observation model;
- selected repository queries that materialize large collections for one-row answers.

The audit is code-first. Claims labeled **trace required** are source-backed risks, not presented as measured production regressions.

## Review result

| Severity | Count | Meaning |
|---|---:|---|
| Blocker | 2 | Do not merge without resolving or explicitly accepting |
| High | 6 | Credible freeze/jank or repeated-work path |
| Medium | 5 | Inefficient or overly broad architecture likely to regress |
| Low | 3 | Maintainability/QA hygiene |

## PR #7 findings

### B1 — Full Apple build and device QA are unavailable

**Severity: Blocker**

The app-build workflow failed for both iOS and macOS before GitHub exposed any job steps or logs. That is consistent with runner/account infrastructure failure rather than a compiler result, but it means this branch has no trustworthy Xcode compile proof.

Required before merge:

1. Generate the Xcode project from `project.yml`.
2. Build `NOOPiOS` for a generic iOS Simulator destination.
3. Build universal `Strand` for macOS.
4. Run `NOOPiOSTests`, including `LiveUpdatePoliciesTests`.
5. Build signed Release for a physical iPhone without replacing or resetting its production database.

### B2 — Live Activity may remain in workout mode for up to the projection interval after workout end

**Severity: Blocker pending product decision**

The expensive workout projection is cached for ten seconds. While a workout is active, that is intentional. On the first `activeWorkout = nil` emission, however, the controller can reuse the cached non-nil projection until the ten-second interval expires. The Lock Screen/Dynamic Island can therefore retain workout presentation briefly after End.

The clean fix is to separate the cheap mode bit from the expensive projection:

```swift
update(
    ...,
    workoutIsActive: model.activeWorkout != nil,
    workout: workoutActivityState
)
```

Mode transitions then bypass the projection throttle, while calories/zones/trace remain cached. Until this is wired through all call sites, the PR should stay draft.

### H1 — Active-workout publication caused WidgetKit/App Group work at sensor cadence

**Severity: High — fixed in this PR**

`AppModel.activeWorkout` is replaced on each captured workout sample. The iOS app observed every replacement and called `WidgetSnapshot.publishLive`. Before this PR, that method loaded the App Group snapshot, encoded a new snapshot, wrote it, and requested `WidgetCenter.reloadAllTimelines()` on every call.

The branch now:

- caches the snapshot in process;
- forces the first publish on a fresh install;
- skips semantic no-ops;
- publishes connection, battery, and workout start/end edges immediately;
- coalesces BPM, live Strain, and sparkline churn to one minute;
- handles clock rollback/future persisted timestamps;
- clears a completed workout trace.

### H2 — Live Activity built an O(n) projection before checking its throttle

**Severity: High — materially reduced in this PR**

The input property computes calories and time-in-zone from the entire growing sample array. Previously, every heart-rate emission built that state before `LiveActivityController` checked its two-second ActivityKit gate.

The branch now:

- receives the projection via autoclosure;
- checks the ActivityKit gate before evaluating it;
- rebuilds calories/zones/trace at most every ten seconds;
- avoids equal ActivityKit payloads, with a 30-second stale-date heartbeat;
- resets caches when the activity ends;
- handles wall-clock rollback.

This removes the per-tick rescan, but it does **not** make the projection algorithm truly incremental. See H3.

### H3 — Workout calories and zones still rescan the complete session every ten seconds

**Severity: High — follow-up**

The frequency is bounded, but total work over a long workout remains superlinear because each projection starts from sample zero. The production end-state should maintain incremental accumulators beside `StrainScorerV2.ActivityAccumulator`:

- running calorie integral;
- five zone-duration counters;
- bounded 48-point trace;
- immutable display snapshot.

Then Live Activity projection becomes O(1) regardless of workout length.

### M1 — Multiple unstructured ActivityKit update tasks can overlap

**Severity: Medium**

Each accepted state launches a new `Task { await activity.update(...) }`. A slow system bridge could allow updates to complete out of order. A single serialized update task or monotonic sequence should own ActivityKit writes.

### M2 — Full widget publication remains an expensive main-actor orchestration path

**Severity: Medium — partially fixed**

The slow publish still reads sleep and HRV series and up to 200k HR plus 200k R-R rows. This branch moves the pure DaytimeStress fingerprint/bucketing work to a utility detached task. The store reads and series resolution remain broad.

Follow-up:

- query only the trailing HRV points actually displayed;
- read exact-day sleep score rather than the full series;
- persist or SQL-aggregate the hourly stress projection;
- skip WidgetKit reload when the full rendered payload is unchanged.

## Adjacent repository findings

### H4 — Active workout uses a growing value-type payload and republishes it every sample

**Severity: High — trace required, strong source-level risk**

`ActiveWorkout` is a struct containing the complete `[HRSample]` array and accumulator. `captureWorkoutSample` copies the optional value into a local `var`, appends, and assigns the whole value back to an `@Published` property.

Risks:

- Array copy-on-write when the old value/buffer is still retained;
- full `AppModel.objectWillChange` fan-out every sample;
- every observer receives a value containing the growing sample collection;
- the path becomes increasingly sensitive to long sessions.

Recommended refactor:

- reference-owned `ActiveWorkoutSession` or actor;
- private mutable sample buffer;
- lightweight `Equatable` display snapshot published at a bounded cadence;
- direct leaf observation for Live/Workout UI;
- no broad `AppModel` invalidation for each sample.

### H5 — Durable active-workout snapshots serialize the full growing HR array on the main actor

**Severity: High**

The snapshot codec stores every HR sample as JSON in `UserDefaults`. `AppModel` throttles this to roughly every five seconds and force-flushes on lifecycle boundaries, but every periodic write still re-encodes the entire workout accumulated so far.

Recommended design:

- append-only binary/SQLite sample chunks;
- separately overwrite a tiny metadata/accumulator header;
- compact once at workout completion;
- force-flush on background/end;
- add a synthetic two-hour write-count and bytes-encoded test.

### H6 — Full-history Effort migration can amplify one migration into ~134 broad refreshes

**Severity: High**

`runEffortRescoreIfNeeded(historyDays: 4000)` advances in 30-day chunks. Each chunk currently calls `analyzeRecent` with repository refresh enabled. A changed chunk can call the default 4,000-day `repo.refresh`, whose wide SQLite reads occur before cache equality suppresses publication.

Required follow-up:

1. analyze chunks with `refreshRepository: false`;
2. persist progress after a completed chunk;
3. perform one final bounded refresh;
4. publish migration progress separately from dashboard data;
5. eventually derive the real HR-history bounds instead of using 4,000 calendar days.

### H7 — Strap-log durability rewrites a large array to UserDefaults for every log line

**Severity: High**

`LiveState` is main-actor isolated. `append(log:)` currently appends, may shift a 5,000-line array with `removeFirst`, slices up to 2,000 strings, and writes the full tail to `UserDefaults` synchronously on each line. Backfill and diagnostic bursts occur while SQLite/BLE are already busy.

Required follow-up:

- use a ring/deque rather than front-removing an Array;
- debounce durable writes for 2–5 seconds;
- encode/persist off-main;
- force-flush on disconnect, background, share, and scheduled export;
- verify 1,000 appends produce a bounded number of durable writes.

### M3 — SleepView rebuilds a very large snapshot on broad repository changes

**Severity: Medium**

The screen is a multi-thousand-line view with many derived series. Its key includes broad `repo.refreshSeq`; a repository change can synchronously rebuild the model on the main actor. A `.task(id: repo.refreshSeq)` also reads all sleep sessions, habitual midsleep, and per-session motion before rebuilding again.

Recommended:

- dedicated sleep-relevant generation/token;
- one off-main `SleepScreenSnapshot` builder;
- bounded screen history;
- repository-side batch snapshot query;
- split presentation into value-fed leaf views.

### M4 — SleepView has a root BehaviorStore dependency that appears leaf-owned

**Severity: Medium**

The newly added `SleepAlarmPlanSection` observes `BehaviorStore` itself, while the root also declares it. If the root does not otherwise consume the store, every alarm edit needlessly invalidates the entire heavy Sleep screen. Remove the root dependency after confirming there are no other references.

### M5 — SmartAlarmView observes broad AppModel and sends commands from four independent change handlers

**Severity: Medium**

The root screen observes `AppModel` primarily to call actions. Live BPM/workout changes can invalidate it even though the alarm UI does not render them. Mode, enabled, minutes, and weekdays each independently call `applySmartAlarm`; DatePicker/stepper interaction can produce repeated BLE command bursts.

Recommended:

- inject a non-observable command interface;
- coalesce the four fields into one value snapshot;
- debounce/reconcile a single alarm apply operation;
- preserve immediate disable as a special urgent edge.

### L1 — `stepActivityClassLatest` materializes up to 200k rows for one value

**Severity: Low/Medium**

Replace the full range read with an indexed `ORDER BY ts DESC LIMIT 1` query where `activityClass IS NOT NULL`.

### L2 — latest sleep-need lookup reads all historical points

**Severity: Low/Medium**

`latestNoopSleepNeedV2(onOrBefore:)` reads from `0000-01-01` through the requested day for each computed ID, then takes `max`. Add a descending latest-point query.

### L3 — one-day sleep-need breakdown performs several sequential series queries

**Severity: Low/Medium**

The breakdown requests five keys and may probe multiple computed IDs. Add a single one-day, multi-key store read and resolve the fields from that result.

## Dead-path and code-growth assessment

The main architectural risk is not merely file length. `AppModel`, `Repository`, `IntelligenceEngine`, and several screens have become integration hubs where new features attach to broad publishers or the default wide refresh because those are the easiest available seams.

Recommended enforcement:

1. typed refresh intents with coalescing;
2. one canonical data path per product metric;
3. ownership documents for live, persisted, imported, and computed sources;
4. file/complexity thresholds in CI;
5. DEBUG QA galleries and launch harnesses excluded from Release where possible;
6. one-shot migration retirement ledger;
7. a static audit for root views observing high-frequency models only to invoke actions.

## QA performed on this branch

### Focused pure-policy tests

A standalone Swift package reproduced the production publication policy APIs and exercised:

- first publication with no prior snapshot;
- semantic no-op suppression;
- high-frequency workout/BPM/Strain coalescing;
- sub-display-precision Strain noise;
- immediate connection, battery, workout-start and workout-end edges;
- wall-clock rollback;
- projection cache interval and rollback.

**Result: 7 tests, 0 failures.**

The repository test file contains the equivalent production-facing matrix plus separate cases where appropriate.

### Live Activity type check

A stub ActivityKit harness compiled the controller's:

- autoclosure default and call syntax;
- mode-transition recursion;
- equality heartbeat gate;
- start/update/end cache lifecycle;
- actor isolation.

**Result: compiled and executed successfully.**

### Concurrency review

`DaytimeStress` uses the repository's locked, `@unchecked Sendable` bounded memo cache. Running its pure analysis in a utility detached task is compatible with that cache's thread-safety contract.

### GitHub CI

Latest branch app-build workflow:

- iOS job: failed before step metadata appeared;
- macOS job: failed before step metadata appeared;
- no logs/artifacts exposed.

The same no-step failure shape exists on an earlier known-good performance commit, supporting an infrastructure/account gate rather than a branch-specific compiler diagnosis. It still does **not** substitute for a build.

## Required pre-merge QA matrix

### Compile and unit tests

- [ ] XcodeGen succeeds.
- [ ] NOOPiOS Debug generic simulator build succeeds.
- [ ] Strand universal macOS Debug build succeeds.
- [ ] NOOPiOSTests pass.
- [ ] Existing widget/Live Activity snapshot compatibility tests pass.
- [ ] No new Swift concurrency warnings in touched files.

### Simulator functional QA

- [ ] Fresh install/no widget snapshot: first HR event creates a snapshot.
- [ ] Paired but disconnected: widget connection state is honest.
- [ ] Start workout: widget and Live Activity switch mode immediately.
- [ ] End workout: widget and Live Activity leave workout mode immediately.
- [ ] Reconnect: no duplicate Live Activities.
- [ ] Toggle Live Activity off: all existing NOOP activities end.
- [ ] Clock moves backward/forward: updates recover without starvation/storm.
- [ ] Component 41 DEBUG QA mode still remains stable.

### Physical Release performance QA

Use the same phone/database before and after; do not uninstall or replace the database.

Capture a 30-minute workout with an active strap:

- [ ] main-thread hangs >100 ms;
- [ ] `activeWorkout` publishes/minute;
- [ ] Widget App Group writes/minute;
- [ ] WidgetKit reloads/minute;
- [ ] Live Activity projection builds/minute;
- [ ] ActivityKit pushes/minute;
- [ ] memory slope and peak;
- [ ] CPU while screen is on and backgrounded;
- [ ] workout end/save time;
- [ ] final calories/zones/Strain parity against base.

Expected branch behavior:

- widget live writes/reloads: approximately one per minute during ordinary HR churn, plus urgent edges;
- Live Activity projection: no more than approximately six per minute;
- Live Activity BPM pushes: no more than approximately thirty per minute and fewer when content is unchanged;
- no loss of workout start/end responsiveness;
- no stale workout graph after End.

## Merge recommendation

**Do not merge. Keep PR #7 draft.**

Next gate order:

1. decide/fix the ten-second workout-end mode edge;
2. obtain real Xcode iOS + macOS compile results;
3. run focused repository tests;
4. run physical Release long-workout performance capture;
5. compare counts and traces against base;
6. only then request review or remove Draft status.
