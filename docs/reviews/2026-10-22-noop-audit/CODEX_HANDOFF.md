# Codex technical handoff and merge readiness

## Starting point

Repository: `eastonplace/noop-ios`. Review base: `6f49d855d6f747103f4dc2a60949cb933445c3c0`.
Branch: `fix/noop-end-to-end-audit-20261022`. Keep its pull request **draft and unmerged**. Do not deploy or publish a release.

Read [README.md](README.md), [final-review.md](final-review.md), and [validation-status.md](validation-status.md) before changing the patch. The detailed specialist reports identify affected source and evidence. There are no schema migrations or historical-data deletions in this patch.

## First: run native validation

The editing environment was Linux. Successful source parsing and portable harnesses do not establish an iOS build, Apple framework behavior, or a device result. Use the existing macOS CI workflows or a Mac with Xcode and XcodeGen:

```sh
git fetch origin
git switch fix/noop-end-to-end-audit-20261022
git status --short
xcodebuild -version
swift --version
xcodegen generate
xcodebuild -scheme NOOPiOS -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Choose an available iPhone from `xcrun simctl list devices available`, then set `NOOP_SIMULATOR_UDID` to its UUID:

```sh
xcodebuild -scheme NOOPiOS -configuration Debug \
  -destination "platform=iOS Simulator,id=$NOOP_SIMULATOR_UDID" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test

for package in NoopPhase34Core WhoopProtocol OuraProtocol WhoopStore StrandAnalytics StrandImport StrandDesign NoopLocalAccess; do
  swift test --package-path "Packages/$package" || exit 1
done
```

Also run the existing `NOOPCoachUI` selections from `.github/workflows/app-build.yml`. Do not weaken a test or branch-protection check merely because the hosted runner is unavailable. The initial Linux WHOOP protocol chmod failure disappeared when the unchanged compiled suite ran as an unprivileged user; it was not fixed by changing expected results.

Prioritize these app/package regressions when diagnosing native failures:

- `BLEConnectionIntentTests`, `RebootResponseLogTests`, `PuffinBroadcastPreferenceTests` and existing secure-session/source-coordinator tests.
- `LiveSessionFreshnessTests`: steady equal standard notifications for more than eight seconds, proprietary notifications, no cached replay, and silence becoming stale. Verify `heartRateArrivals` remains a main-actor, unbuffered event channel and no writer is left on snapshot-only delivery.
- `HealthKitSyncCoordinatorTests`, `SourcePrivacyCleanupCoordinatorTests`, and `WhoopStoreTests/PruneTests`, especially forced variable-limit pruning and protected materialization evidence.
- `PR29IOSSinkAndHealthKitTests` stress input cases, `DaytimeStressTests`, `SleepRecoveryValidityTests`, `SleepMemoInputTests`, `RecoveryScorerTests`, `ManualWorkoutRescoreTests`, existing gap-aware HRV, pause and full civil-day tests.
- `LiftWeekSummaryTests`, `LiftMuscleVolumeTests`, and `TestReportDestinationTests`.

The HealthKit privacy helper tests are useful but do not, by themselves, prove the actual bridge caller is wired correctly. Exercise `processSourceDeletionChunk` against a disposable app-owned fixture on an authorized iPhone as described below. The exact caller's extracted Linux harness is the recorded pre/post proof.

## Integration with existing open PRs

Do not silently discard the existing work:

| Existing PR | Reviewed head | Required disposition |
| --- | --- | --- |
| #68 | `a5e9c5c8ed050b5a476d5b6f15daa39cebb9b433` | This patch adapts its Broadcast OFF admission/saved-choice fix only. Reconcile the remaining source/clock ownership, owned failed-batch rebuffering, ordered framing-loss/history admission, `@Published` smoothing/reset, HealthKit background entitlement and bundled-image privacy fixes in a separate reviewed integration step. Preserve both test sets and the arrival subject introduced here. |
| #67 | `ff0ec0f72a611adf6b83aabe9f0754879c76e4f3` | Stacked on #66. Preserve WHOOP 4 alarm readback identity, zero-value confirmation, restoration and update destination fixes. Do not duplicate version/UI work. Recheck head before integrating because it can advance. |
| #66 | `abe2918cb63166489c7d746c29bc880d9bea32fb` | UI work is outside this patch. Preserve the required active-device argument at the Devices removal call site during conflict resolution. |

These branches were inspected, not merged. Source/history ownership remains a material main-branch concern until its existing fix is integrated and validated. The review does not imply those issues are repaired by this branch.

## Physical-device matrix

Run all relevant journeys separately for **WHOOP 4.0, WHOOP 5.0 and WHOOP MG**. Record model, firmware, iPhone, iOS, app commit, timezone, granted permissions and capture preferences. Use a debug/test container or backup appropriate to the test; retain existing user history. Do not reset production data to make a test pass.

### 1. Connection intent, recovery and background

1. Cold-launch with the selected strap present. Wait for the current-family handshake and HR/RR. Confirm startup does not require a new Connect tap.
2. Tap Disconnect. Toggle Bluetooth off/on, lock/unlock the phone, and foreground/background the app. Confirm no connection or service discovery until explicit Connect.
3. Tap Connect and repeat an out-of-range/return cycle. Confirm normal recovery and delayed history catch-up resume.
4. With strap A active, remove inactive B, including an import-only row with no peripheral UUID. Confirm A's live feed and automatic reconnect continue. Remove A itself and confirm release/no retry.
5. Start connecting A, select B before completion, and induce delayed success/failure for A. Verify B stays selected; only the unwanted A connection is cancelled; B's secure proof/retry state survives.
6. Lock for 30 minutes, then several hours out of range. Reconnect and compare newest/oldest stored timestamps, duplicate counts, raw materialization and durable receipt/trim progress with a baseline capture. Repeat after system termination, a phone restart, and a user force-quit followed by manually reopening NOOP.
7. Change Bluetooth/HealthKit permissions and recover them. Test network offline independently: local collection/history must not depend on update-check or report network access.

Apple documents different background relaunch conditions for system termination and user force-quit. Do not promise continuous iOS execution or automatic relaunch after force-quit. Validate post-reopen history recovery instead. References: [TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules) and [Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html).

### 2. Live HR, Broadcast OFF, and wrist prompts

1. Begin a Live Session with a steady HR. Confirm repeated equal readings keep it fresh beyond eight seconds without additional display-value publications. Ensure 4.0 proprietary and 5.0/MG standard paths both deliver arrival events.
2. Stop actual notifications while leaving the last display value populated. After more than eight seconds, coaching must become stale and produce no new cue. After ten minutes of continuous stale ticks, the session must end and release its realtime lease.
3. Reconnect and start another session. Confirm current readings resume normal scoring/cues; stale data from the previous session must not be replayed as a new arrival.
4. On 5.0 and MG, explicitly enable Broadcast HR, then disable it while connected. Verify the OFF command is admitted and acknowledged according to firmware behavior. Repeat disabling while disconnected, then reconnect. Only the exact saved Boolean OFF choice should replay.
5. With no stored Broadcast preference, connect. Confirm NOOP sends no new persistent broadcast configuration. Confirm connected HR/RR and history continue regardless of this optional advertising preference.
6. Verify reboot logging separately: 4.0 uses its legacy result layout; 5.0/MG prints the actual command-specific byte. Physical restart requires observing the device/link, not inferring it from an ACK.

### 3. Calculations, delayed input and historical preservation

1. Capture matched worn and off-wrist still periods. Raw evidence should remain stored, while zeros no longer lower RHR, count as stress coverage, or authorize a recovered night.
2. Recover a valid RR-only interval. It should retain existing partial HRV behavior without inventing HR. Include invalid beats and gaps to verify the gap-aware cleaner does not splice artifacts away.
3. Re-score a workout containing invalid HR and pause/resume segments. Average, peak, strain and calories must use the same valid active samples and preserve pause gaps.
4. Fill an entire day with 1 Hz HR and dense RR. Compare the widget/dashboard stress to the detail view after 06:00, at midday and late evening. Repeat a 23-hour and 25-hour DST day; late data must not disappear at a row cap.
5. Stage the same sleep window first with still gravity, then movement vectors with equal axis sums. Warm-cache and fresh results must agree. Reorder padded inputs; in-window data must survive.
6. Test workouts exactly at next-week midnight, plus the DST week. Completed, planned and muscle summaries must count them in one week only.
7. After restart/reanalysis, compare manual edits, source provenance and historical rows with the pre-test snapshot. This patch must not delete raw history or change migrations.

### 4. HealthKit and retention

1. Cancel an awaiting background caller while a foreground import owns the lease. The caller must return, the owner must remain active, and publication must remain fenced until its normal completion.
2. Cancel the owning import during quantity, sleep and workout collection after another window is offered. Verify the durable union remains and the next wake idempotently completes it.
3. On disposable NOOP-owned HealthKit sample fixtures, run the bridge privacy deletion path. Confirm identities are journaled before deletion and the observer recognizes the deleted UUIDs without offering an oldest-to-now import. External HealthKit objects must remain untouched.
4. Repeat deletion after a locked-store or injected delete failure/cancellation, then retry. UUID ownership must remain until anchor save/retirement.
5. Run the native forced-SQLite-variable-limit prune and protected-materialization tests together. Pruning must remove only eligible raw batches and never remove unmaterialized required history.

## Battery and performance measurement

Use matched baseline and patch builds for each physical model, with the same firmware, iPhone, official WHOOP app presence, signal environment, charge range, live-screen usage and capture settings. Run at least a full day per condition when possible; percentage resolution and activity variation can dominate short tests. Record:

- Strap battery percent and elapsed time, separated into idle/background, active Live Session and backlog catch-up periods.
- Scans, connects/disconnects, service discovery, notification subscriptions, GATT writes, history requests, retries and haptic commands.
- HR/RR sample counts, valid coverage, maximum gaps, history latency and final receipt/trim progress.
- iPhone Instruments Energy Log, CPU time, allocations and main-thread stalls.

Compare drain as percentage points per hour under matched conditions, and report uncertainty rather than extrapolating a day-long lifetime from a short segment. Acceptance requires accurate/timely collection and no material new gaps; lower drain alone is insufficient. The observed Linux HRV kernel improvement is about 0.3–0.43 ms/pass, not a battery estimate.

## Remaining investigation queue

| Item | Evidence status | Next concrete check |
| --- | --- | --- |
| Restored peripheral chosen before active registry hydration | Suspected startup ordering risk | Restore two registered straps in reversed array order; trace pin/source admission before discovery and sample writes. |
| Radio-off without a disconnect delegate | Unconfirmed platform scenario | Observe connected UI/realtime leases and recovery when Bluetooth changes state but no disconnect callback arrives. |
| App-level analysis-cache input completeness | Suspected beyond the fixed per-kernel cache | Insert a late gravity/respiration/event/temperature batch without changing HR/RR witnesses; compare warm and forced-fresh day analysis. |
| Dense sleep privacy pagination | Unconfirmed cursor boundary case | Seed a full page of excluded leading-overlap samples; verify cursor progress and completion without revisiting retained samples indefinitely. |
| Non-Gregorian civil-day keys | Suspected persisted compatibility risk | Test Buddhist/Japanese device calendars with existing Gregorian-key history; design a migration only after reproducing impact. |
| RR memory bound for complete widget day | Known tradeoff | Profile dense 25-hour/multi-source data. If needed, add source-policy-preserving keyset pagination with `(ts, rrMs, seq)` tie handling; do not silently truncate or select transport independently per hour. |
| WHOOP-only migration | Confirmed reachable unrelated code, not dead code | Inventory source/import provenance and CI gates; isolate live discovery first, preserve historical/import reads, remove dependencies only after native migration tests. |
| Remaining PR68 source/history fixes | Confirmed existing separate work | Integrate the reviewed fixes, preserve this branch's connection/arrival/Broadcast semantics, and rerun combined suites and device backfill tests. |

## Merge checklist

- [ ] Final-head macOS package suites and iOS app/widget build pass.
- [ ] New native tests and existing integration/UI gates pass; CI status is inspected, not inferred.
- [ ] Independent review's resolved arrival-event interaction remains covered.
- [ ] Existing PR68/67/66 overlap is explicitly reconciled without dropping fixes.
- [ ] WHOOP 4.0 physical matrix complete.
- [ ] WHOOP 5.0 physical matrix complete.
- [ ] WHOOP MG physical matrix complete.
- [ ] HealthKit locked/expired/deletion/retry journeys verified on device.
- [ ] Historical data/provenance and no reduction in essential collection verified.
- [ ] Battery A/B evidence recorded; no unsupported battery-life percentage claimed.
- [ ] Dense RR day memory and background catch-up observed.
- [ ] User reviews the draft and separately authorizes merge/release when ready.
