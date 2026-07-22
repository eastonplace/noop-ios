# NOOP Production Performance Pass — Completion Report

## Verdict

**CONDITIONAL PASS for source-level implementation; PR #7 remains draft pending Apple-runtime evidence.**

The highest-impact hot paths identified in the current pass were materially changed and focused deterministic validation is green. A real Xcode build, Simulator interaction pass, and physical Release trace could not be completed because the GitHub-hosted macOS jobs failed before checkout or step creation and this ChatGPT execution environment is not macOS.

## Branch state

- Implementation branch: `perf/freeze-paths-2026-07-21`
- Pull request: #7, draft and mergeable
- Base: `main` at `4b60de7ac065cc562558d367f0a8003d30165bee`
- Implementation code checkpoint: `3a1b793e0ced1ab82490619fbaac663e381a816b`
- Current state and next steps: `PERFORMANCE_STATE_AND_NEXT_STEPS_2026-07-22.md`
- Apple-runtime handoff: `CODEX_PERFORMANCE_QA_HANDOFF_2026-07-22.md`

## Material changes

### ActivityKit

- Replaced independent update tasks with one serialized, coalescing reconciliation worker.
- Added latest-state replacement so HR bursts cannot form an unbounded task backlog.
- Separated cheap workout presence from expensive workout projection.
- Made Start and Finish mode edges immediate while retaining the approximate two-second BPM cadence.
- Bounded calories/zones/trace projection to ten-second rebuilds.
- Prevented stale update completion after explicit end.
- Recovered actual mode when adopting an existing activity after relaunch.
- Suppressed equal payloads while retaining a thirty-second stale-date heartbeat.

### Widgets and App Group

- Cached the live snapshot in process.
- Coalesced high-frequency live changes to one minute plus immediate connection, battery, Start, and Finish edges.
- Added latest-wins generations for full async dashboard publication.
- Added rendered-content equality that ignores timestamp-only churn.
- Suppressed unchanged full App Group writes and WidgetKit reloads with a fifteen-minute heartbeat.
- Cleared stale workout traces immediately after Finish.
- Moved pure DaytimeStress analysis off MainActor.

### Active-workout durability

- Moved steady-state whole-workout JSON encoding and UserDefaults writes off MainActor.
- Added one utility serial latest-wins writer.
- Kept first-session persistence synchronous.
- Kept inactive/background persistence ordered and synchronous on iOS and macOS.
- Added generation invalidation and ordered clear so pending writes cannot resurrect a finished workout.
- Preserved the existing serialized shape and legacy decoding behavior.
- Avoided reading the growing persisted Data value on MainActor merely to test key existence.

## Important bugs fixed

- Lock Screen / Dynamic Island could remain in workout mode for up to the projection cache interval after Finish.
- ActivityKit updates could overlap and complete out of order.
- A stale ActivityKit update could race with end.
- A slower full-widget refresh could overwrite a newer publication after suspension.
- Unchanged full-widget payloads still triggered App Group writes and timeline reloads.
- Steady-state workout recovery encoded the complete growing HR array on MainActor.
- Pending workout persistence could theoretically land after clear without ordered invalidation.

## Validation run

- Swift 6.2.1 focused type-check with complete strict-concurrency diagnostics: pass.
- Stub ActivityKit lifecycle and reconciliation execution: pass.
- Thirty-minute 1 Hz deterministic workload:
  - 1,800 incoming HR events;
  - 31 widget live publications;
  - 901 ActivityKit push opportunities;
  - 180 expensive workout projections.
- Persistence stress:
  - newest queued snapshot wins;
  - synchronous final state wins;
  - clear prevents delayed resurrection.
- Synthetic 20,000-sample snapshot, 100 writes:
  - prior synchronous loop: approximately 5.58 seconds;
  - caller enqueue time: approximately 0.00037 seconds;
  - coalesced writer through flush: approximately 0.070 seconds.

The synthetic measurements are Linux sandbox evidence, not iPhone Instruments results.

## Apple-runtime blocker

GitHub Actions run `29888702308` failed both the `NOOPiOS` macOS-26 job and universal `Strand` macOS-15 job before any checkout/build steps, logs, or artifacts were created. This did not execute the repository and therefore is neither a pass nor a compiler failure.

## Remaining risks

- The growing `@Published ActiveWorkout` value still fans out a complete value-type session on each sample.
- Calories and zone duration are bounded to ten-second scans but are not yet incremental O(1) accumulators.
- Strap-log durability still rewrites a large UserDefaults array for every log line.
- Long Effort migration refresh behavior, latest-value repository queries, Sleep snapshot rebuilding, and Smart Alarm observation/command fan-out remain follow-up tranches.
- Physical BLE, background scheduling, ActivityKit presentation, CPU, memory, thermal, battery, and final score parity remain unverified.

## Required before merge

1. XcodeGen and all affected Apple targets build.
2. Focused and neighboring Xcode tests pass repeatedly.
3. Simulator Start → active → Finish → restart and reconnect scenarios pass with screenshots and logs.
4. A physical Release 30-minute workout is captured without resetting the user's database.
5. Final calories, zone seconds, Strain, duration, and sample count match the canonical base behavior.
6. Measured WidgetKit, App Group, ActivityKit, durability-write, CPU, memory, and main-thread results meet the expected bounded behavior.
