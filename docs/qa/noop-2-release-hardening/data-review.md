# Data specialist review

This is the specialist evidence snapshot before delivery. The [combined report](README.md) is authoritative for final CI/release status. Scratch paths below record the original execution environment; committed tests and source references are the durable reproduction inputs.

## Scope and status

- Repository: `/workspace/scratch/fc582a8e42a6/noop-ios`.
- Audited base: `a7ade2598d439d33cd20816d69ccc991b29322fc`.
- Working branch: `audit/noop-2-release-hardening-20261023`.
- Audit date: 2026-10-23. All reproduction inputs are synthetic; no live health database was opened.
- Four confirmed findings were triaged with the root agent and authorized for narrow fixes. Changes are uncommitted in the shared checkout. No push, PR, release, device installation, or schema change was performed by this agent.
- Scientific scoring, thresholds, stage-reclip math, HRV kernels, and existing deduplication policy were preserved. The only `IntelligenceEngine.swift` diff removes `private` from the existing habitual-timing helper to permit direct native parity tests; its implementation is unchanged.
- This is a focused audit, not a claim that all files in the large packages were reviewed. The full reviewed-file manifest and its coverage limits are below.

## Confirmed findings

### DATA01 — sleep mutations use different source/key semantics from reads

**Suggested priority: P1 for lost undo; P2 for edits/deletes that silently do nothing. Confirmed on the audited base.**

The UI reads sleep from the active source plus the stable canonical imported and computed namespaces. The engine keeps writing derived sleep under `my-whoop-noop` after a strap is removed and re-added. However, the ordinary sleep edit/delete paths try only `computedDeviceId` and `deviceId`, which move with the active strap. The undo snapshot uses those same incomplete namespaces. A visible canonical night can therefore be edited or deleted with no effect, while deletion still writes a suppression tombstone.

There is a second independent key mismatch within the snapshot helper. It asks the interval reader for `[detectedStartTs, detectedStartTs]` and then looks for the immutable key. The reader correctly uses the *effective* onset for overlap. Once an onset has been moved forward, the row no longer overlaps its original detected start second. The delete still finds its natural key, but the snapshot is absent, so there is no undo and the code incorrectly treats the edited night as an unedited detection when creating the tombstone.

**Evidence at base:**

- `Strand/Data/Repository.swift:3503–3509`: generic edit writes only active computed/imported IDs.
- `Strand/Data/Repository.swift:3562–3570`: tombstone written before deletion, missing snapshot treated as unedited, failures converted to zero, only active namespaces tried.
- `Strand/Data/Repository.swift:3628–3650`: snapshot performs interval query at immutable start and only tries active namespaces.
- `Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift:522–537`: interval predicate is `COALESCE(startTsAdjusted,startTs) <= to AND endTs > from`; it is unsuitable as an exact natural-key lookup.
- `Strand/Data/IntelligenceEngine.swift:800–805` and class-level ownership contract: computed persistence remains canonical.

**Reproduction:** Insert canonical row `(my-whoop-noop,1000)` ending at 29800, adopt `whoop-readded`, then edit to onset 3400. Both old updates change zero rows. Separately, set the canonical row's effective onset to 3400 and look it up with the old snapshot interval at 1000: zero rows, despite the natural-key row existing. The same failure exists without re-pairing.

**Fix:** Add an exact-key, ordered-namespace store snapshot; use `computedReadIds + importedReadIds` and preserve computed-first collision precedence. Read failure or no row is not mutation success. Snapshot and delete occur together in one transaction; a tombstone is written only after actual deletion. The stored row's actual edited flag and bounds determine tombstone behavior. Undo restores the saved owner and does not lift a tombstone on failure.

**Current implementation:** `Strand/Data/Repository.swift:3431,3534,3578`; `Packages/WhoopStore/Sources/WhoopStore/SleepSessionUndoStore.swift:34,42,123`.

**Regression risks/coverage:** Existing same-key computed-first ownership policy is retained. Canonical imported rows are also reachable. Exact-key lookup intentionally replaces interval semantics only for mutations. Tests cover re-added source, moved onset, missing row, injected delete failure, owner/tracks round trip, and newer-row undo conflict.

### DATA02 — repeated imported sleep edit trims minutes twice

**Suggested priority: P2. Confirmed on the audited base.**

The reclip kernel expects the previous effective session start. The caller supplies the immutable detected key every time. After the first onset edit has already removed time from an imported minute dictionary, saving the same edited bounds again removes the same time a second time. This changes measured-looking sleep totals and any downstream Rest/Charge based on them, even though the user made no further boundary change.

**Evidence at base:**

- `Strand/Data/Repository.swift:3497–3499`: `SleepWindowReclip.reclip(...sessionStart:detectedStartTs,oldEnd:oldEndTs...)`.
- `Strand/Screens/SleepView.swift:402–404`: save supplies immutable detected key, current wake, and stored stages; it does not supply the old effective onset.
- The editor models separately contain effective `bedTs` at the main-night/nap/invalid-window construction sites. The source contract was independently confirmed by the UI agent.
- `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepWindowReclip.swift` correctly interprets the caller's prior bounds; no mathematical defect was found in that kernel.

**Literal reproduction:** Original 8-hour dictionary `{awake:30,light:280,deep:80,rem:90}`, window 1000…29800; onset edited to 3400. First result has light 270 minutes. A second unchanged save using the old adapter has light 230. Supplying the stored effective onset 3400 yields the expected unchanged `{awake:0,light:270,deep:80,rem:90}`.

**Fix:** Resolve a current stored snapshot first. Reclip from its stages, effective onset and end, rather than caller snapshots. The commit compares the complete stored snapshot again so an edit derived during an await cannot overwrite changed session/overlay/auxiliary evidence.

**Current implementation:** `Strand/Data/Repository.swift:3441–3449,3493–3501`; `SleepSessionUndoStore.swift:58–72`.

**Regression risks/coverage:** Raw-stream restaging retains priority exactly as before. Imported fallback uses the same reclip formula. Public editor argument labels remain compatible. The native regression calls the real repository twice and asserts literal stage totals. A standalone Swift probe ran the production kernel with both old and corrected caller contracts.

### DATA03 — UI learned sleep timing differs from the engine across DST and shifted duplicates

**Suggested priority: P2. Confirmed after initial hypothesis.**

The Sleep UI calls `Repository.habitualMidsleepSec`, whose contract says it computes the same learned timing as the analytics engine. The repository adapter used a single `TimeZone.current.secondsFromGMT()` for all historical nights and did not run the engine's overlap-aware duplicate collapse. The engine already uses each night's own midpoint UTC offset and `SleepSessionDedup`. This can give the UI a different habitual time and therefore a different main-night group from the engine on the same data.

**Evidence at base:**

- `Strand/Data/Repository.swift:3406–3429`: current-offset history construction, only exact-key dedup.
- `Strand/Data/IntelligenceEngine.swift:4708–4747`: overlap dedup and per-midpoint historical offsets already correct.
- `Strand/Screens/SleepView.swift:376–380`: repository habitual value drives displayed main-night selection.
- `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift:757–811`: optional per-block `clockOffsetSec` is the existing supported contract; selector at 510+.

**Executed reproduction:** 28 synthetic nights with local 03:00 midpoint in `America/New_York`, 14 before and 14 after the autumn transition, evaluated on 2026-11-15. Exact production learner returns 9000 seconds (02:30) for the repository's old single-offset inputs and 10800 (03:00) for the engine inputs. Two same-wake-day four-hour blocks at 21:50–01:50 and 03:30–07:30 are separated by 100 minutes (therefore not bridged); exact production selector chooses UI group `[0]` and engine group `[1]`.

**Additional native regression:** Seven real nights plus seven overlapping shorter copies shifted to preceding midpoint dates must remain below the 14-day history gate. The old adapter can count fourteen date keys; the engine correctly keeps seven physical nights.

**Fix:** Repository adapter uses the same existing valid-window filter, overlap dedup and per-midpoint offset contract. Defaulted `now` and `timeZone` inputs permit deterministic actual-repository tests. The learner and selector formulas are untouched. Engine helper access becomes internal only for direct parity assertions.

**Current implementation:** `Strand/Data/Repository.swift:3390–3419`; `StrandiOSTests/RepositorySleepMutationTests.swift:186,228`.

**Regression risks/coverage:** Narrow adapter behavior change around DST/timebase duplicates, matching already-shipped engine behavior. Existing user-edited precedence within the dedup helper is retained. Tests assert the actual repository's learned time, engine parity, and selected same-wake-day group. Native execution is still required.

### DATA04 — undo restores a recovered session but loses its protected recovery state

**Suggested priority: P1. Confirmed on the audited base.**

A recovered sleep owns a persisted daily override containing sleep totals, Rest, Charge, baseline-normalized Charge context, sleep need/consistency and provenance time. The existing delete trigger deliberately clears that override, the protected daily fields and the Rest series. The old undo snapshot contains only the session and decoded motion/state arrays, so undo cannot recover the protected data. It also removes the tombstone before independent best-effort writes, allowing a failed/partial restore to look successful.

**Evidence at base:**

- `Packages/WhoopStore/Sources/WhoopStore/SleepRecoverySchema.swift:216–282`: session delete/bounds triggers invalidate daily sleep/recovery and remove the override/Rest point.
- `Strand/Data/Repository.swift:3589–3614`: undo lifts tombstone and separately writes session and auxiliary tracks, without the override.
- `SleepRecoveryDailyOverrideStore.swift:5–65,73–168`: full protected fields, persistence contract, and latest non-sleep daily fields.

**Executed reproduction:** Seed recovered row with Charge 78 and Rest 88. Run the actual production deletion trigger and the old session-only reinsertion. Override count becomes 0, daily recovery stays NULL, and Rest series count stays 0.

**Fix:** Store-owned snapshot includes exact session, original namespace, database instance identity, raw auxiliary JSON and every recovery override attached to the session. Capture/delete is one transaction. Undo inserts session/auxiliary tracks and restores overlays/daily sleep fields/Rest in one transaction. Current activity fields are read inside that transaction, so newer Strain, steps, calories, exercise count and non-sleep signals survive. Undo fails closed with explicit `.conflict` for a replacement database, existing saved session key, or already occupied protected recovery day. The repository returns `Bool`, keeps the tombstone on failure/conflict, and removes it only after successful restore.

**Review-discovered race:** While a generic edit awaits raw staging, another writer can add a recovery override without changing the cached session fields. Comparing only `CachedSleepSession` would permit the subsequent generic update to erase that new overlay. A focused regression failed three assertions against that preliminary guard. The final guard compares the entire fresh `StoredSleepSessionSnapshot` (including database, overlays and raw tracks); it passes.

**UI completion:** Sleep undo now checks its result. A failure retains the banner/snapshot and displays “Couldn't restore this sleep. Try again.” with a retry action. Each banner has a UUID; stale completion/timeout cannot dismiss a later delete (including a new deletion of the same key). Duplicate taps on an in-flight banner are suppressed.

**Current implementation:** `SleepSessionUndoStore.swift:5–147`; `SleepRecoveryDailyOverrideStore.swift:224` (decoder visibility only); `Repository.swift:3578–3607`; `SleepView.swift:513–585,2317–2322`.

**Regression risks/coverage:** No schema changes. Native WhoopStore tests use existing migrations and real in-memory transactions; the extracted host harness uses the exact recovery migrations/writer and new helper with a synthetic prerequisite schema. Tests inject delete-trigger and Rest-insert failures, verify complete rollback, exact recovery provenance/auxiliary round trip, preservation of newer activity and conflict refusal. The transient undo snapshot and UserDefaults tombstone remain the existing separate mechanisms; no claim of cross-store crash atomicity is made.

## Already-fixed behavior and unconfirmed leads

- Canonical **recovered**-sleep editing after re-pairing already had a special canonical lookup and regression (`SleepRecoveryAppTests.testEditingCanonicalRecoveredSessionAfterRepairRekeysCanonicalOverride`). DATA01 concerns the ordinary path and exact snapshot lookup; it does not claim that prior fix was absent.
- Engine habitual timing already handled historical DST and overlap duplicates. DATA03 repairs the UI/repository adapter only.
- RR reads already select one source train before LIMIT, preserve ordered source ordinals, and expose the same policy to analysis snapshots. HR reads already implement measured-first same-second PPG anti-join. The reviewed stream insertion paths are idempotent by natural key and RR conflict upgrades respect source priority. No new confirmed duplicate/order defect was identified in these inspected paths.
- Training load already uses calendar ordinals, distinguishes nil/missing from measured zero, tolerates configured short gaps with explicit coverage, and does not compress gap days. That was a recent integration repair, not a new finding.
- Baseline scoring already builds as-of timelines so a day's own/future nights do not contribute to its personal baseline. No new scoring formula defect was established.
- `Reads.plausibleHRCount` applies the requested bpm range only to the measured arm; the PPG fallback arm counts all rows. Whether this violates a shipping contract depends on producer range constraints and the requested bounds. Not sufficiently traced/reproduced here; no fix or confirmed severity assigned.
- Some public math helpers accept broader inputs than shipping producers supply (for example negative/extreme timestamps or invalid training-load configuration). No crash or user-visible incorrect result through an actual producer path was proved in this sub-audit, so no speculative changes were made.
- A SourceCoordinator callback/source-generation candidate was relayed by the BLE agent at the end; it was explicitly not audited by this agent and remains with BLE/root.

## Validation and exact evidence

### Completed host checks

1. `swiftc -frontend -parse` on all seven owned changed/new Swift files: **exit 0**.
2. `git diff --check`: **exit 0**.
3. Synthetic SQLite baseline proof: **three confirmed baseline failures**, script intentionally exits 1 after asserting their reproduction.
4. Production `SleepWindowReclip`/`SleepTimestampMath` probe: old caller light **230**, corrected caller light **270**, all literal corrected stage totals asserted; **exit 0**.
5. Production `SleepStageTotals` DST/selection probe: UI old contract **02:30 / group 0**, engine contract **03:00 / group 1**, asserted; **exit 0**.
6. Focused real-GRDB extracted-production harness: **10 XCTest methods, 0 failures** (final run 2026-10-23 10:04:57 UTC). Preliminary snapshot-only guard: **10 methods, 3 failed assertions in the one new recovery race test**, other nine passing. The guard was corrected only after reproducing this failure.

### Pending native checks

- **9 new app tests** in `StrandiOSTests/RepositorySleepMutationTests.swift`. They exercise actual Repository/store adapters and directly compare the actual engine habitual helper. They were parsed here but not run as an iOS app test target.
- **10 new package tests** in `SleepSessionUndoTransactionTests.swift` must still run in the full native WhoopStore target against its complete normal initialization/migrations.
- Existing affected suites: `RepositoryEditRescoreTests`, `SleepRecoveryAppTests`, `SleepDeleteUndoStoreTests`, `SleepRecoveryStoreTests`, relevant sleep reclip/selection/date suites.
- Manual/simulator UI check: inject a failed/conflicting sleep undo, verify snapshot/banner remains with retry copy; rapid repeat tap does not start a second undo; a newer deletion's banner survives an older completion/timeout. Basic successful delete/undo still restores the displayed source night and refreshes.

The full Linux WhoopStore package build was **blocked**, not passed: `AnalysisInputWitness.swift:3` imports unavailable `SQLite3`; existing unrelated files also import Apple `Compression`/`CryptoKit`. An initial normal-sandbox SwiftPM run stalled on CFSocket setup and was stopped; an escalated synthetic build reached the explicit platform compiler blocker. Product imports/build configuration were not altered to hide it.

### Reproduction artifacts

All paths below are under `/workspace/scratch/fc582a8e42a6/data-audit-evidence/`:

| Artifact | Purpose/result |
|---|---|
| `reproduce_baseline_sleep_sql.py` | Extracts SQL from exact audited Git base; synthetic SQLite reproductions for DATA01/04. |
| `baseline_sleep_sql.log` | Zero edited rows, zero snapshot rows, lost override/Recovery/Rest after legacy undo. |
| `reproduce_reclip.swift.py` | Generates production-kernel caller-contract probe. |
| `reclip_contract.swift`, `reclip_contract.log` | Executed red/green stage-minutes evidence. |
| `reproduce_habitual_dst.py` | Generates production learner/selector DST probe. |
| `habitual_dst.swift`, `habitual_dst.log` | Executed 02:30/03:00 and group 0/1 mismatch. |
| `make_focused_store_harness.py` | Reproducibly copies exact helper/writer/recovery migrations, extracts exact models/accessors, and copies unchanged new XCTest file into a scratch package. |
| `focused_store_red.log` | Review race reproduced before complete snapshot guard. |
| `focused_store_green.log` | Ten focused tests pass after complete snapshot guard. |
| `full_store_linux_blocked.log` | Explicit full-target platform blocker, not a test pass. |

The focused harness lives at `/tmp/noop-data-harness`, build at `/tmp/noop-data-harness-build`. It uses the exact pinned GRDB 6.29.3 checkout from `/tmp/noop-data-build/checkouts/GRDB.swift`, real SQLite/DatabaseQueue, the complete unchanged `SleepRecoverySchema.swift`, unchanged recovery writer aside from decoder access, and exact new helper/test source. It does **not** exercise app UI, the entire product store initialization/journal/observation graph, or native SQLite/Apple framework integration.

Harness generation:

```sh
python3 /workspace/scratch/fc582a8e42a6/data-audit-evidence/make_focused_store_harness.py \
  /workspace/scratch/fc582a8e42a6/noop-ios /tmp/noop-data-harness \
  /tmp/noop-data-build/checkouts/GRDB.swift
```

Final focused command (run with required sandbox escalation for SwiftPM runtime):

```sh
env PATH=/tmp/noop-swift/usr/bin:$PATH \
  CLANG_MODULE_CACHE_PATH=/tmp/noop-data-clang-cache \
  SWIFTPM_MODULECACHE_OVERRIDE=/tmp/noop-data-spm-module-cache \
  swift test --package-path /tmp/noop-data-harness \
  --scratch-path /tmp/noop-data-harness-build \
  --cache-path /tmp/noop-spm-cache --config-path /tmp/noop-spm-config \
  --security-path /tmp/noop-spm-security \
  -Xcc -I/tmp/noop-data-sqlite/usr/include \
  -Xlinker -L/tmp/noop-data-sqlite/usr/lib/x86_64-linux-gnu \
  -Xswiftc -DGRDBCUSTOMSQLITE --filter SleepSessionUndoTransactionTests -j 4
```

Temporary SQLite dev headers were extracted into `/tmp/noop-data-sqlite` and its library symlink points to the installed system runtime. `GRDBCUSTOMSQLITE` is a **harness-only dependency compilation condition** to avoid linking absent Linux SQLite WAL snapshot symbols; DatabaseQueue transactions are real and this flag does not change the sleep SQL or product code. The actual native package must still be verified normally.

## Owned changed-file manifest

| File | Change / new test count |
|---|---|
| `Packages/WhoopStore/Sources/WhoopStore/SleepSessionUndoStore.swift` | New exact-key snapshot, transactional delete/edit/restore and explicit conflict result. |
| `Packages/WhoopStore/Sources/WhoopStore/SleepRecoveryDailyOverrideStore.swift` | Decoder becomes internal for exact snapshot reuse; persistence body unchanged. |
| `Packages/WhoopStore/Tests/WhoopStoreTests/SleepSessionUndoTransactionTests.swift` | **10** new focused methods. |
| `Strand/Data/Repository.swift` | Owner/current-state sleep mutations, transactional undo integration, habitual adapter consistency. |
| `Strand/Data/IntelligenceEngine.swift` | One access-control change for actual parity tests; function body unchanged. |
| `Strand/Screens/SleepView.swift` | Honor undo success, retain failed snapshot with retry, per-banner async ownership. |
| `StrandiOSTests/RepositorySleepMutationTests.swift` | **9** new native app methods. |

No other agent's changes were edited. Root owns release metadata and combined CI. No additional measured performance optimization was claimed in this data sub-audit; the confirmed changes prioritize correctness and existing index/natural-key boundaries.

## Reviewed-file manifest

Paths below are relative to repository root. “Full” means the file was read for the stated task; “targeted” means only the named paths/ranges were inspected. This explicitly excludes files only enumerated by `rg --files` or referenced by an unexpanded search result. Some long source outputs were truncated; those entries remain targeted rather than claiming full-file review.

### Governance/build context

| File | Coverage |
|---|---|
| `AGENTS.md` | Full; staged 2.0 version policy, focused checks, final CI requirements. |
| `CONTRIBUTING.md` | Full. |
| `docs/CONTRIBUTING.md` | Full. |
| `Packages/WhoopStore/Package.swift` | Full; dependencies/platforms. |
| `Packages/WhoopProtocol/Package.swift` | Full. |
| `Packages/StrandAnalytics/Package.swift` | Full. |

### Store/data boundaries

| File | Coverage |
|---|---|
| `Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift` | Targeted actor/pool/open gate and syncRead/syncWrite/poolRead, roughly 1–215. |
| `Packages/WhoopStore/Sources/WhoopStore/Database.swift` | Targeted schema/migration registrations and table/index contracts; not every migration body. |
| `Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift` | Models; sleep upsert/edit/delete, aux persistence/decoding; daily upsert; interval/daily reads. Most 1–310, 370–450, 490–592. |
| `Packages/WhoopStore/Sources/WhoopStore/MetricSeriesStore.swift` | Targeted MetricPoint and metricSeries accessor, for persistence/test contract. |
| `Packages/WhoopStore/Sources/WhoopStore/SleepMerge.swift` | Full; namespace/session merge precedence. |
| `Packages/WhoopStore/Sources/WhoopStore/SleepSessionDedup.swift` | Full; eligibility, overlap collapse, edited precedence. |
| `Packages/WhoopStore/Sources/WhoopStore/SleepRecoveryDailyOverrideStore.swift` | Full; protected fields, atomic writer and exact provenance decoding. |
| `Packages/WhoopStore/Sources/WhoopStore/SleepRecoverySchema.swift` | Targeted all delete/bounds invalidation and protection triggers, context/efficiency migrations; complete file compiled/executed by focused harness, not a full historical-migration audit. |
| `Packages/WhoopStore/Sources/WhoopStore/SleepRecoveryStore.swift` | Targeted first ~210 lines: atomic session/audit/override write and replacement semantics. |
| `Packages/WhoopStore/Sources/WhoopStore/SleepSessionUndoStore.swift` | Full; new implementation, manually reviewed and compiled/executed in focused harness. |
| `Packages/WhoopStore/Sources/WhoopStore/Reads.swift` | Targeted HR/PPG union/count/fingerprint/bucket and RR read contracts; remaining read helpers inspected in larger excerpts, not exhaustive. |
| `Packages/WhoopStore/Sources/WhoopStore/RRReadPolicy.swift` | Full; source selection, prior-before-LIMIT, within-second order. |
| `Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift` | Targeted 1–215: prepared batched inserts, RR conflict priority, annotation and natural keys. |
| `Packages/WhoopStore/Sources/WhoopStore/StoreIndexHygieneMigration.swift` | Full; index rebuild/removal and lookup shape. |
| `Packages/WhoopStore/Sources/WhoopStore/AnalysisInputWitness.swift` | Full; cache input identity and observation coupling. |
| `Packages/WhoopStore/Sources/WhoopStore/HistoricalRawMaterialization.swift` | Targeted 1–37,120–174,265–492: lease, malformed receipt, raw materialization, atomic commit/finalize, retry. |
| `Packages/WhoopStore/Sources/WhoopStore/HistoricalMaterializationRecovery.swift` | Targeted recovery flow excerpts; output truncation prevents a full-file claim. |
| `Packages/WhoopStore/Sources/WhoopStore/HistoricalDataCommitJournal.swift` | Targeted API map and database instance identity 614–631; not entire journal implementation. |
| `Packages/WhoopProtocol/Sources/WhoopProtocol/SleepSessionWindow.swift` | Shared validity/plausibility contract inspected and exercised by harness dependency. |

### Analytics/calculation inputs

| File | Coverage |
|---|---|
| `Packages/StrandAnalytics/Sources/StrandAnalytics/LoadFocus.swift` | Full; adapters and zones/load input semantics. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/DailyTrainingTarget.swift` | Full; current target/gap inputs. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/TrainingLoadEngine.swift` | Full; calendar ordinal gap model, thresholds, nil vs zero, duplicate-day admission, as-of target. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyzeRecentDayCache.swift` | Substantial cache/key/read-window inspection; large combined output partly truncated. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsMemo.swift` | Full; memo scope/keys. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/HRZones.swift` | Full; sorted input, gap/duration handling and aggregation. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/HRVAnalyzer.swift` | Full in separate ranges; range/ectopic/gap-aware cleaning, raw/rolling RR order assumptions. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/HRVReadiness.swift` | Targeted result/admission/evaluate in combined excerpt; output truncated. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift` | Targeted ~90–303: sustained RHR, calibration/as-of gate, baseline/weight renormalization, logistic score. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/Baselines.swift` | Targeted update/rejection, history/recalibration/as-of timelines and rolling mean/SD; long output partly truncated. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/StrainScorerV2.swift` | Targeted day accumulator, sorted kernel/coverage, duplicate-second maximum, components and cumulative curve; not every declaration. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepWindowReclip.swift` | Full; production source executed unchanged. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepWindowRecovery.swift` | Targeted timestamp arithmetic and bounded recovery contracts; SleepTimestampMath executed unchanged. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift` | Targeted 1–120,220–625,750–844: safe arithmetic, selector/bridging/habitual history; full file compiled in probes. |
| `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift` | Targeted timestamp/day formatter and references from day scoring; not full scorer. |

### Incremental/source/date policies

| File | Coverage |
|---|---|
| `Packages/NoopPhase34Core/Sources/NoopPhase34Core/CivilDay.swift` | Full. |
| `Packages/NoopPhase34Core/Sources/NoopPhase34Core/ExactDayCacheMerge.swift` | Full. |
| `Packages/NoopPhase34Core/Sources/NoopPhase34Core/HistoricalAnalysisWorkReducer.swift` | Full. |
| `Packages/NoopPhase34Core/Sources/NoopPhase34Core/HealthKitReadResumePolicy.swift` | Full. |
| `Packages/NoopPhase34Core/Sources/NoopPhase34Core/SourceTransitionPolicy.swift` | Full. |
| `Packages/NoopPhase34Core/Sources/NoopPhase34Core/RepositoryActiveSourceState.swift` | Full. |

### Production integration and existing/new tests

| File | Coverage |
|---|---|
| `Strand/Data/Repository.swift` | Targeted source namespaces/union helpers, full-history cache reads, date helper, sleep adapters/mutations/undo/restaging, timeline RR entry. Not entire 6000+ line file. |
| `Strand/Data/Repository+LoadFocus.swift` | Full. |
| `Strand/Data/Repository+DailyTrainingTarget.swift` | Full. |
| `Strand/Data/Repository+SleepRecovery.swift` | Targeted result contract, raw source union and recovery orchestration; large output partly truncated. |
| `Strand/Data/IntelligenceEngine.swift` | Targeted ownership ~790–825; incremental analysis/cache windows 1260–1745; sleep/HRV loops 1905–2140; baseline wiring search ~2334; self-heal ~3670–3785; band series/habitual/date ~4690–4755. Not full engine. |
| `Strand/Screens/SleepView.swift` | Targeted task/editor/delete/undo contracts ~375–585, editor identity construction and banner/model structs; UI agent independently traced construction sites. |
| `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepWindowReclipTests.swift` | Full. |
| `Packages/WhoopStore/Tests/WhoopStoreTests/SleepDeleteUndoStoreTests.swift` | Full. |
| `Packages/WhoopStore/Tests/WhoopStoreTests/SleepRecoveryStoreTests.swift` | Targeted setup/first ~160 lines and failure-injection patterns. |
| `Packages/WhoopStore/Tests/WhoopStoreTests/SleepSessionUndoTransactionTests.swift` | Full; all ten executed in extracted harness. |
| `StrandiOSTests/RepositoryEditRescoreTests.swift` | Targeted first ~140 lines. |
| `StrandiOSTests/SleepRecoveryAppTests.swift` | Targeted first ~140 lines plus canonical recovered edit regression. |
| `StrandiOSTests/WorkoutLoadFocusRepositoryTests.swift` | Substantial adapter regression inspection; long combined output partly truncated. |
| `StrandiOSTests/RepositorySleepMutationTests.swift` | Full; all nine new methods parsed, pending native run. |

Recent history reviewed included the data integration commits `a530e38` (Sleep/load-focus state), `457fa4c` (source ownership), `880702e` (reviewed 2.0 safety/migrations), and `123e250` (training gaps). History was used for context; findings above are grounded in current base behavior and executable synthetic evidence, not an unsupported claim that any one merge introduced them.
