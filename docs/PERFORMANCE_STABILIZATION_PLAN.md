# NOOP Performance Stabilization Plan

Updated: 2026-07-22

## Branch structure

- `perf/freeze-paths-2026-07-21` / draft PR #7: widget and Live Activity publication foundation.
- `perf/production-stabilization-2026-07-22-v2`: stacked production-stabilization pass described below.
- Neither branch is approved for automatic merge.

## Runtime contract

The optimization work must preserve these independent cadences:

- Active workout BPM and zone UI: every available HR sample.
- Lock Screen / Dynamic Island BPM: approximately every two seconds.
- Expensive Live Activity calories, zone totals, strain projection, and trace: bounded/coalesced.
- Home Screen widgets: separately throttled and semantic-change guarded.
- Persistence: serialized and durable without blocking HR ingestion.

## Implemented in the stacked stabilization branch

### Workout runtime

- Incremental exact-equivalent Live Activity calorie and display-zone projection.
- Bounded 48-point Live Activity HR trace.
- Reference-owned projection cache that consumes only newly appended HR samples.
- Active workout SwiftUI split into stable content and high-frequency heart/zone/strain leaves.
- GPS map, static chrome, timer shell, and controls no longer rebuild solely because an HR sample arrived.
- Final workout save continues using the existing authoritative calculations and storage format.

### Historical migrations

- Chunked migration driver with cancellation, pause, resumability, failure reporting, and completion markers.
- Each Effort migration chunk runs analysis with repository publication disabled.
- Exactly one typed full-history refresh is required before the completion marker is committed.
- Failed or cancelled chunks do not advance the committed offset.

### Strap-log durability

- Immediate in-memory/UI append remains on MainActor.
- Durable tail uses a serial utility queue and an O(1) bounded ring.
- Writes are debounced for three seconds and never overlap.
- Background, termination, disconnect, biometric teardown, export, and explicit clear have flush paths.
- Clear revision-invalidates an old debounce callback so stale data cannot resurrect.
- The existing `strapLog.tail` UserDefaults format remains compatible.

### Repository refresh ownership

- Added typed refresh intents and a main-actor single-flight coordinator.
- Pending compatible requests coalesce to the broadest required range.
- A broad pending request absorbs narrower pending requests.
- A request arriving after a broad query starts remains queued, because it may represent a newer database mutation.
- Current-day and post-backfill intents use the coherent 120-day dashboard horizon rather than 4,000 days.
- Full-history ranges remain limited to actual broad operations such as imports, device replacement, initial hydration, and migration finalization.

### Maintainability

- Split LiveState battery, biometrics/device, and log responsibilities into focused extensions.
- Moved DEBUG screenshot/demo routing out of the production iOS lifecycle file.
- Kept the existing score semantics, UI terminology, navigation, and persistence schema.

## Next performance work after this branch

### P0 — finish typed refresh migration

Classify and migrate every remaining direct `Repository.refresh()` / `refresh(days:)` call. Priorities:

1. post-backfill completion;
2. active-device changes;
3. workout save completion;
4. import completion;
5. restore/reopen;
6. launch hydration.

After call-site coverage and instrumentation prove the typed route is canonical, remove obsolete broad-refresh entry points.

### P0 — reference-owned active workout session

`AppModel.ActiveWorkout` remains a growing value type assigned through an `@Published` property for each captured sample. The next isolated change should:

- own samples and incremental accumulators in a reference type or actor;
- publish a lightweight Equatable workout display snapshot;
- retain every-sample BPM/zone responsiveness;
- preserve PR #7's serialized durable snapshot writer;
- keep final save parity against the authoritative sample history.

### P1 — analysis and repository query narrowing

- Fingerprint the 60-day step-calibration inputs and skip unchanged scans.
- Add indexed latest-point queries instead of materializing broad series for one value.
- Batch one-day multi-key sleep-need reads.
- Persist or SQL-aggregate hourly stress data used by widgets.

### P1 — SwiftUI observation cleanup

- Build a repository-owned, off-main `SleepScreenSnapshot` keyed only to sleep-relevant generations.
- Remove root-level BehaviorStore observation when only a leaf consumes it.
- Keep timers and live streams in leaf views.
- Continue replacing broad AppModel observation with action-only references and narrow observable projections.

### P1 — command/state reconciliation

- Coalesce Smart Alarm edits into one reconciled configuration apply.
- Keep disable as an immediate urgent edge.
- Audit BLE reconnect and command retry loops for owned cancellation and stale-generation rejection.

### P2 — dead-path retirement

- Remove private legacy cards and compatibility routes after compile/reference proof.
- Retire completed one-shot migrations after their supported-version window.
- Keep debug galleries and screenshot harnesses in DEBUG-only files and targets.
- Add file-size/complexity and high-frequency-root-observation checks to CI.

## Merge gates

This work remains draft until all available automated builds/tests pass and the following physical Release checks are complete on the same phone/database used for the base comparison:

- 30-minute active workout;
- no main-thread hang over 100 ms attributable to the changed paths;
- BPM and zone UI update for every incoming sample;
- ActivityKit BPM cadence and update ordering;
- widget/App Group write counts;
- memory slope and CPU foreground/background;
- workout end/save latency;
- final calories, zones, Strain, route, and history parity;
- rapid disconnect/reconnect and background/foreground behavior.
