# NOOP iOS reliability, WHOOP battery, and metrics review

Review date: 2026-10-22. Repository: `eastonplace/noop-ios`.

Current integration: [PR71 after PR68](integration-after-pr68.md) records the authorized merge order, preserved fixes, 1.8.1 metadata and current validation limits. The report below retains the original audit context.

Base: default `main`, `6f49d855d6f747103f4dc2a60949cb933445c3c0`.
Branch: `fix/noop-end-to-end-audit-20261022`.

## Executive assessment

This patch addresses confirmed failures in connection intent, live-sample freshness, health calculations, retention, HealthKit cancellation, and bounded reads. It also adapts the explicit Broadcast HR OFF correction from existing draft PR68 and an output-equivalent HRV allocation optimization from RyanBR upstream. Sensor sampling intervals, essential collection modes, history acknowledgement policy, scoring coefficients and database schema remain unchanged. Decoded historical data and protection predicates are preserved; raw-outbox pruning resumes deletion under its existing retention policy.

The most important metric failures could look credible: invalid zero readings lowered resting HR; off-wrist evidence could authorize recovered sleep; a motion cache collision reused old sleep stages; reordered R-R beats changed stress HRV; and the widget's day read stopped before waking hours after enough overnight samples. These are input/processing correctness fixes. They do not establish clinical accuracy of NOOP's estimates.

For battery, a saved Broadcast OFF choice could be blocked by the command allowlist, while system reconnects could undo a deliberate stop. Live Sessions also presented the last HR snapshot as a new reading every second, allowing stale coaching and wrist prompts. Correcting those paths removes unnecessary activity without requesting less sensor data. The size of the WHOOP battery improvement is **not measured**.

There are **20 distinct confirmed issues/inefficiencies addressed**: P0 0, P1 13, P2 5, P3 2. These counts refer to this patch, not a certification that the repository contains no other critical defects. Existing source/history ownership work in PR68 remains separate and is explicitly listed below.

## Fixed issue register

| ID | Priority | Root cause and user impact | Smallest reliable correction / evidence |
| --- | --- | --- | --- |
| BLE-01 | P1 | Shared connect code cleared intentional Disconnect/Forget on system power-on, restarting an unwanted strap. | Only explicit Connect clears intent; restored/system paths honor it and pending timers are cancelled. Pure policy and real-manager regressions. |
| BLE-02 | P1 | Late success/failure callbacks from a prior target could reset the current strap's state/recovery. | Admit callbacks only for the wanted requested/pinned UUID and appropriate link state; cancel only an unwanted callback peripheral. |
| BLE-03 | P1 | Removing an inactive device row set the global stop flag and disabled the active WHOOP's recovery. | Pass existing active-row context; preserve active recovery for unrelated UUID/nil-ID rows. |
| BLE-04 | P1 | Turning Broadcast HR OFF removed the preference that the allowlist required to send OFF; a disconnected OFF choice was not replayed. | Admit only the exact OFF payload when opted out; replay a genuinely saved Boolean choice after secure proof. Adapted from PR68; untouched defaults send nothing. |
| BLE-05 | P3 | WHOOP 5/MG reboot diagnostics interpreted packet type at byte 8 as the result. | Read the decoded family-specific response result and avoid claiming physical reboot success from an ACK. WHOOP 4 semantics preserved. |
| LIVE-01 | P1 | A 1 Hz timer repeatedly forwarded cached HR as a fresh sensor sample, defeating staleness and enabling wrist prompts after silence. | Timer updates carry no sample; an unbuffered arrival subject carries actual notifications, including equal HR values. Existing display dedup remains. Original tick/real-engine reproduction produced a stale-stream prompt; fixed path suppresses it. |
| MET-01 | P1 | Resting-HR bins/fallback included invalid raw HR, including zero. | Apply existing `HRValidity` before counts/averages. Mixed 60/0 fixture changes from 30 to 60; all-invalid returns unknown. |
| MET-02 | P1 | Manual sleep recovery counted invalid HR/RR as physiological wear evidence and coverage. | Count plausible evidence; retain original RR sequence for gap-aware cleaning. Off-wrist fixture no longer becomes a complete night with RHR 0. |
| MET-03 | P1 | Gravity cache keys used the sum of axes, aliasing different orientations/movement. | Fingerprint each exact vector component; cached detection/V1/V2 stages match fresh motion input. |
| MET-04 | P1 | V2 binary-searched unordered padded streams before sorting, discarding valid night data. | Detect unordered input and filter the requested window before the existing sort. |
| MET-05 | P1 | Invalid HR satisfied the hourly stress coverage gate and altered hourly/reference means. | Filter using the existing common validity range before bucketing. Valid-only data and thresholds remain unchanged. |
| MET-06 | P1 | Stress HRV used RR arrival order instead of chronological order. | Sort only when needed before hourly buckets, retaining invalid beats for gap-aware rejection. Reordered fixture now matches chronological RMSSD. |
| MET-07 | P1 | Manual workout strain filtered invalid HR, while average/peak/calories consumed it. | Supply one valid active stream to all rescored metrics and retain pause boundaries. |
| WIDGET-01 | P1 | Ascending 20,000-row full-day reads ended at 05:33 for 1 Hz HR, before stress's waking window. | Bound HR by the actual civil-day seconds and read all RR within that same day/source policy, preserving late daytime data. |
| STORE-01 | P2 | One DELETE parameter per over-budget raw row exceeded SQLite's variable limit; transaction rollback made pruning fail repeatedly. | Use existing 900-parameter chunks in the same transaction. Actual SQL reproduction removes 1,005 excess rows while preserving newest and protected materialization evidence. |
| HEALTH-01 | P2 | Coalesced import waits ignored cancellation; an operation completing after cancellation could narrow the durable replay union. | Reuse `CancellableWaiterQueue`, check cancellation around import/journal boundaries, and stop subsequent queries/write-back components. The owner retains its lease when only a waiter is cancelled. |
| HEALTH-02 | P2 | Privacy cleanup deleted app-owned HealthKit samples without first journaling UUID ownership. Observer deletions could reopen years of inbound history. | Journal the exact already-selected app-owned targets before deletion; retain identities through failure/cancellation until observer anchor commit. |
| CAL-01 | P2 | `DateInterval.contains` includes the end boundary, counting next-week midnight in adjacent workout/planned/muscle summaries. | Use calendar-derived half-open week intervals; boundary and 167-hour DST week regressions. |
| PERF-01 | P2 | HRV cleaning allocated and sorted a new neighbor array for each beat. | Reuse a small scratch buffer, matching upstream `54196f03`; 37,555 exact-output comparisons and existing HRV tests preserve results. |
| SUPPORT-01 | P3 | The Test Centre report URL sent this fork's diagnostics to RyanBR's issue form. | Point the user-initiated form at `eastonplace/noop-ios`, retaining encoded report fields. Actual URL-builder regression fails before and passes after. |

Affected components and detailed execution paths are recorded in [BLE review](ble-report.md), [metrics review](metrics-report.md), [storage/HealthKit review](storage-report.md), [dependency/upstream review](dependency-upstream-report.md), and [independent review](final-review.md). Source filenames in those reports are relative to the repository root.

## WHOOP battery and collection behavior

### Changes with a direct radio or wrist effect

Intentional-stop admission prevents unwanted reconnect/discovery work. Callback ownership avoids recovery/state churn from an old peripheral. Broadcast OFF now sends the exact disable setting the user chose; it does not turn off the normal connected HR/RR or history channels. A genuinely absent preference does not overwrite a strap setting established elsewhere. Live Sessions use actual arrivals, so silence can become stale and eventually release the session's realtime lease instead of continuing from a cached value.

The arrival channel is separate from SwiftUI's display snapshot. Equal consecutive HR notifications remain evidence of liveness without forcing repeated `heartRate` display publication. The existing standard, proprietary, and retained non-WHOOP input writers all emit the new event, preserving their existing value gates. The timer remains 1 Hz and the engine's 8-second stale threshold remains unchanged.

### Model-specific assessment

| Device | Existing communication reviewed | Effect of this patch / remaining proof |
| --- | --- | --- |
| WHOOP 4.0 | Harvard framing, standard HR/RR, proprietary realtime/raw frames, capture reconciliation, keepalive, history/ACK and reconnect paths. | Connection intent, target ownership and live freshness apply. No keepalive, raw burst, HR toggle, history cadence, RR conversion or trim behavior changed. Verify with a physical 4.0. |
| WHOOP 5.0 | Puffin framing, CLIENT_HELLO, protected notification confirmations, owned GET_HELLO proof, confirmed writes, standard HR/RR and fallback. | Same connection/freshness corrections plus exact Broadcast OFF replay and correct reboot diagnostics. Secure proof and command scheduling remain. Verify with a physical 5.0. |
| WHOOP MG | This application shares the WHOOP 5/MG protocol family; firmware-specific behavior is not independently established here. | Test MG separately. Shared code is not proof of identical battery, bond, or sensor behavior on MG. No MG feature or data stream was disabled. |

Thirty-second keepalive/battery reads, history floors/backoff, quiet-link watchdogs, raw capture preferences and connection parameters were inspected but not tuned without traffic or hardware evidence. A smaller polling interval is not assumed to be wasteful merely from its value. See the handoff's controlled A/B battery procedure.

## Measured performance

On Swift 6.4.1, Linux x86_64, optimized builds, a synthetic eight-hour stream contained 28,799 RR observations. Nine alternating rounds of 20 iterations measured:

| Kernel | Before median | After median | Reduction |
| --- | ---: | ---: | ---: |
| `cleanRR` | 2.948 ms | 2.648 ms | 10.17% |
| `cleanRRGapAware` | 2.990 ms | 2.565 ms | 14.22% |
| `analyze` | 3.054 ms | 2.744 ms | 10.14% |

The absolute saving is approximately 0.3–0.43 ms per pass in this workload. This is not a whole-app launch/UI improvement or a device-energy measurement. Original/patched Double bit patterns, gap flags and final HRV outputs matched across 37,555 fixtures. See [benchmark output](evidence/hrv-buffer-benchmark.txt).

Other efficiency fixes remove unnecessary work rather than establish a timed speedup: own HealthKit deletions no longer reopen inbound history, cancelled import callers unwind, raw pruning succeeds at large row counts, and false stale-stream prompts stop. Complete widget RR reads may use more memory than the old truncated read; this preserves correctness and is a documented remaining pagination opportunity.

## Test evidence and its limits

Local execution uses a signature-verified official Swift 6.4.1 Linux toolchain. Xcode, UIKit, CoreBluetooth, HealthKit and Apple's Compression framework are unavailable locally. Source parsing is not Apple SDK type checking. Selected source harnesses are not the complete application.

| Executed validation | Result / scope |
| --- | --- |
| NoopPhase34Core full package | 107 tests passed. |
| WhoopProtocol full package | 528 tests passed as unprivileged UID/GID 65534. The initial root run's chmod fixture could not deny root access; no production code or test was weakened. Includes four adapted Broadcast configuration regressions. |
| OuraProtocol retained dependency | 78 tests passed. This does not imply unrelated wearable support is required for the intended product. |
| Actual-source metrics harness | 192 tests passed across 11 repository test files and 19 production sources, including HRV/gap-aware/staging/strain/pause regressions. Rerun after the HRV optimization passed. |
| Actual-source lifting harness | 12 tests passed; only Linux localization availability was shimmed. Three new boundary/DST tests failed before the fix. |
| Actual-source report URL harness | One destination/field-preservation test failed before and passed after. |
| Exact-method storage/HealthKit reproductions | Eight assertions fail on original methods and pass on patched methods; actual SQLite with forced variable limit, explicit HealthKit I/O seams. |
| Exact-method Live Session tick reproduction | Original timer fabricated arrivals, never became stale, and emitted a prompt; corrected method with the real engine passes. |
| Source-contract audits / Swift parsing | All CI source audits are rerun on the final patch; native-target syntax parsing covers changed Swift sources. See validation status. |

Logs under [evidence](evidence/) are execution records from this environment; their temporary absolute paths identify how they ran and are not promised as persistent build infrastructure. Native regressions are committed in the normal package/app test targets. The full native commands and device matrix are in [CODEX_HANDOFF.md](CODEX_HANDOFF.md).

Two new HealthKit helper tests prove failure/cancellation identity retention, but those helper tests alone would also pass with the original unjournaled caller. The exact production caller harness provides the red/green proof for that wiring change. Hardware delivery, restoration payloads and physical wrist effects remain untested.

Hosted CI subsequently exposed one historical golden expectation that encoded MET-07's invalid-HR calorie bug. Exact base/head reproduction and valid-only comparison justified changing that single literal, while all 1,123 other golden entries and all bit-exact assertions remain unchanged. The [calorie follow-up](golden-calorie-followup.md) records the initial failing hosted run and the independent proof; current hosted status is linked from [validation status](validation-status.md).

## Architecture, dependencies, privacy and WHOOP-only scope

The audit traced BLE admission through Collector/store ownership, raw retention, historical commit/ACK boundaries, metrics orchestration, repository/widget publication, HealthKit journals, and UI consumers. Migration/opening gates, cancellation, actor ownership, task retention, source deletion and credential/privacy surfaces received targeted review. Automated source-contract scanning covers the configured application/package tree; it is not a manual line-by-line proof for every source file.

All five resolved remote packages have active uses: GRDB 6.29.3, ZIPFoundation 0.9.20, MarkdownUI 2.4.1, transitive NetworkImage 6.0.1, and swift-cmark 0.9.0. Exact pins are preserved. Public primary security pages for GRDB and MarkdownUI showed no published advisories during review. The reviewed ZIPFoundation path-traversal advisory (CVE-2023-39138 / GHSA-c2cc-3569-6jh2) affects versions through 0.9.17 and was patched in 0.9.18; the pinned 0.9.20 is outside that range. Other advisory coverage was incomplete. No globally vulnerability-free claim or unverified upgrade is made. Full dependency/vendor source auditing and a complete secret-history scan were not achieved in this environment.

Unrelated wearable code remains reachable, including device/source routing, import history, Oura mapping in WhoopStore, and required CI jobs. It is not confirmed dead code. Deleting those packages would require a deliberate WHOOP-only migration that preserves historical provenance and import functionality. No package was removed on the basis of its name, and no supported WHOOP behavior was traded for cleanup.

## Relationship to open PRs and upstream

- **PR68** (`a5e9c5c8ed050b5a476d5b6f15daa39cebb9b433` reviewed): only the Broadcast OFF/saved-choice fix is deliberately adapted here. Its source/clock ownership, failed-batch ownership, ordered framing-loss/history admission, smoothing-reset, HealthKit entitlement and bundled-image privacy changes remain separate. Those are meaningful remaining main-branch risks; this PR must not be described as having already integrated them. Reconcile overlapping `BLEManager` edits carefully and preserve both suites.
- **PR67**, based on **PR66**: alarm readback/identity and update destination work is reviewed as existing work. This patch does not import their UI/version changes. Device-row edits can overlap; preserve active-removal context when integrating.
- **UI CI follow-up:** main's latest completed native run has eleven pre-existing UI-test failures. A specialist mapped them to the Settings toolbar and harness repairs in the advanced PR66/67 heads (`94c85aa7` / `88a4de42`), with the first missing Lift routine still causally unresolved. See [the full mapping and exact-head qualification requirements](ui-ci-baseline-followup.md). These source repairs are not a claim that either open PR's final UI run passes.
- **RyanBR/noop** at `8e4b0c16e7640607600fa6bde5424095eba6034e`: the upstream re-entered-bond fixes are already covered by this fork's stronger connection-generation/proof reset. Blindly copying the upstream ACK-only proof would weaken the fork. The output-equivalent HRV scratch-buffer change from `54196f03` is adapted with attribution and measured parity.

No PR was merged, no release was published, and the default branch was not modified.

## Remaining work and merge gate

The independent reviewer challenged the initial Live Session design and found the equal-HR publication interaction. The final arrival channel and real-intake regressions address it. The final review records any remaining conditions rather than treating local harnesses as a native build.

Unconfirmed candidates remain: multi-strap cold restoration before registry hydration, radio-off without a disconnect callback, app-level analysis-cache witnesses for late non-HR streams, dense sleep privacy pagination, and non-Gregorian persisted day keys. These were not speculatively changed. HealthKit query cancellation still waits for a query already submitted to return; the patch stops subsequent work at durable boundaries.

Before merge, complete macOS/iOS CI, reconcile the listed open PRs, and run the separate WHOOP 4.0/5.0/MG device matrix. Leave this PR **draft and unmerged** until those checks are reviewed.
