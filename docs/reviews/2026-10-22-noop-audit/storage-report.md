# Storage, ingestion, and HealthKit audit

Date: 2026-10-22. Base: `6f49d855d6f747103f4dc2a60949cb933445c3c0` (main). Working branch: `fix/noop-end-to-end-audit-20261022`.

## Result

Implemented three confirmed reliability findings in five files, with five new native XCTest regressions. Eight focused runtime assertions were demonstrated failing against the original production methods and passing after the fixes. No schema migration, sample-rate change, protocol change, or commit was made by this agent.

Files changed:

- `Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift`
- `Packages/WhoopStore/Tests/WhoopStoreTests/PruneTests.swift`
- `StrandiOS/Health/HealthKitSyncCoordinator.swift`
- `StrandiOS/Health/HealthKitBridge.swift`
- `StrandiOSTests/HealthKitSyncCoordinatorTests.swift`

## Fixed findings

### STORAGE-01 — Large raw outboxes can permanently exceed SQLite's parameter ceiling (P2)

**Execution path:** `Collector.prune()` calls `WhoopStore.pruneRaw`. The age policy and size policy run in one writer transaction. The size policy previously assembled one `DELETE FROM rawBatch WHERE rowid IN (...)` placeholder for every row over budget. A long capture can accumulate more evictions than the SQLite connection's variable ceiling. Preparing that DELETE then fails, rolls back the earlier age deletions, and leaves the same oversized backlog for the next retry. `Collector.prune()` converts the error into zero rows pruned, so this can persist without a useful UI error.

**Fix:** `RawOutbox.swift:469–481` splits the selected row IDs using the existing `WhoopStore.inClauseChunk` (900), retaining the same surrounding transaction, newest-first budget calculation, row-ID tie handling, and materialization protection predicate. This changes statement size only.

**Regression:** `PruneTests.testLargeEvictionStaysWithinSQLiteVariableLimit` seeds 1,007 small batches, forces the actual writer connection's variable limit to 999 with `sqlite3_limit`, invokes the production `pruneRaw`, and expects the two newest batches to remain. The native test is ready for macOS CI.

**Executed evidence:** The exact production Swift `pruneRaw` method was compiled on Linux with a thin SQLite C adapter in place of GRDB/package dependencies. With 1,005 evictable rows plus two retained newest rows and one materialization-required historical row, the original method failed with `too many SQL variables`. The fixed method pruned 1,005 and retained all three intended rows, including the protected historical evidence.

### HEALTH-01 — Import waiters ignore cancellation, and cancellation can narrow the durable replay window (P2)

**Execution path:** `HistoricalScoringBackgroundTaskRegistrar.runBackgroundWork` calls `HealthKitBridge.drainPendingDurableSync`, which awaits `HealthKitSyncCoordinator.runAndWait`. When another import owns the run, this caller previously waited on a bare checked continuation. Cancelling the background caller did not remove it; it remained suspended until the unrelated importer finished. The sibling scoring coordinator already uses the project's cancellation-aware queue.

When the owning import was cancelled while awaiting its operation, a later `true` return from that operation also allowed `save(followUp)` to replace the original durable union. This acknowledged progress after cancellation and discarded the original window even though cancellation-aware downstream operations should be replayed conservatively. The bridge's quantity/day query loops did not stop between reads, so a cancelled import could keep querying and writing through a large history window.

**Fix:** `HealthKitSyncCoordinator.swift:558, 594–644` uses the existing `CancellableWaiterQueue<Void>`, returns promptly for an already cancelled caller, and checks cancellation before invoking the import operation and before narrowing/clearing its journal. Cancelling a coalesced caller never cancels the active importer or releases its lease. The owning importer retains its durable union and follows the existing recovery scheduling path when it stops.

`HealthKitBridge.swift` adds cancellation checks before quantity queries, between sleep/workout day chunks, before local authoritative replacement, after inbound workout streaming, and between outbound components. Cancellation is propagated separately from best-effort outbound errors so it does not appear as a completed import. The observer acknowledgement callback remains unchanged.

**Regressions:**

- `HealthKitSyncCoordinatorTests.testCancellingCoalescedImportWaiterLeavesActiveImportRunning` verifies prompt waiter return while the original import and publication fence stay active, then verifies normal completion.
- `HealthKitSyncCoordinatorTests.testCancelledImportRetainsDurableUnionBeforeClearingJournal` cancels an owner during a suspended operation after a second window arrives, then verifies that the full union remains durable and no follow-up import starts.

**Executed evidence:** The exact production `HealthKitSyncCoordinator` and actual `CancellableWaiterQueue` sources were compiled in a focused Swift executable. Only scoring/HealthKit-platform dependencies were replaced with explicit seams. Both assertions failed before the change and passed after it. The bridge's iOS code and native tests also pass an iOS-target syntax parse; the framework-backed paths still require native runtime testing.

### HEALTH-02 — Privacy cleanup bypasses export-deletion identity journaling (P2)

**Execution path:** `processSourceDeletionChunk` obtains a bounded page of samples from `healthKitSamples`, whose predicate restricts results to `HKSource.default()`. Its `deleteProjectedHealthKitPage` directly called `HKHealthStore.delete(targets)`. Ordinary write-back deletions already use `HealthKitExportDeletionCommit` to record each UUID and original date range in the `noop-healthkit-export` namespace first.

The subsequent anchored observer callback contains only deleted UUIDs. Without the export identity, `HealthKitObserverPageCommit` treats a deleted UUID as external; when it is unknown locally, it asks for the earliest Apple Health timestamp and journals a historical import through today. Thus deleting NOOP's own exports can reopen years of inbound history and consume substantial query/scoring work. This finding concerns unnecessary work and deletion classification; the original query already restricted destructive targets to NOOP's own samples.

**Fix:** `HealthKitBridge.swift:1399–1476` receives the already-open durable store and passes exactly the previously selected `targets` through `HealthKitExportDeletionCommit` before the exact-object deletion. The existing helper records identities in batches of at most 400. Journal failure prevents deletion; cancellation is checked before invoking the destructive operation. Deletion failure or cancellation leaves the ownership record intact until an observer page durably saves its anchor and retires the corresponding identities. Query predicates, page limits, cleanup cursors, and external data ownership are unchanged.

**Regressions:**

- `HealthKitSyncCoordinatorTests.testExportDeletionFailureRetainsKnownTargetIdentitiesForRetry` checks journal-before-delete order and retained UUID/date identity after deletion failure.
- `HealthKitSyncCoordinatorTests.testCancelledExportDeletionRemainsOwnedUntilObserverAnchorCommits` checks cancellation retention, no external-history lookup or inbound offer for the resulting own-deletion page, and retirement only after anchor save.

**Executed evidence:** A focused Swift executable includes the exact production deletion-page method, export journal helper, observer classification helper, and civil-day code, with only HealthKit/SQLite I/O seams. All five checks failed against the original caller: journaling on success/failure/cancellation and suppressing inbound replay after success/cancellation. All five pass after the fix.

## Coverage and data-preservation observations

| Area inspected | Files / relevant behavior |
| --- | --- |
| Live intake, clock/source ownership, failed insert rebuffering | `Strand/Collect/Collector.swift`; `FlushScheduler`; PR68 Collector diff |
| Durable history commit and acknowledgement boundary | `WhoopStore.swift`, `HistoricalDataCommitJournal.swift`, `Cursors.swift`, historical durability tests; decoded rows, receipt, retained evidence, and cursor share the FULL-synchronous transaction before success returns |
| Raw retention and materialization | `RawOutbox.swift`, `HistoricalRawMaterialization.swift`, `HistoricalMaterializationRecovery.swift`, associated tests; materialization-required raw remains protected |
| Migration/opening and source deletion | `Database.swift`, `WhoopStore.swift`, `DatabaseIntegrity.swift`, `DeviceRegistryStore.swift`, `DurableSourceLifecycleStore.swift`; shared pool/open gate, ordered privacy deletes, lineage/cursor epoch rotation |
| Receipt admission/recovery | `HistoricalReceiptAdmissionStore.swift`, source cleanup store/coordinator code; receipt work and admission watermark share one transaction |
| HealthKit local authority and identities | `HealthKitAuthoritativeStore.swift`, `HealthKitBatchHardening.swift`, `HealthKitMutationWatermarkStore.swift`; atomic range replacement and chunked identity reads/deletes |
| HealthKit observers/import/export/privacy recovery | All four files under `StrandiOS/Health`; existing coordinator, serialization, and privacy tests; observer offer precedes anchor save, export identity retirement follows anchor save |
| Background call site | Read `HistoricalScoringBackgroundTaskRegistrar.swift` to confirm the cancellation caller; no edit |

This was a focused execution-path audit, not a claim that every line of every store file was reviewed or that device behavior was exercised.

## Existing draft overlap and remaining checks

- The Collector defect is confirmed in main: buffered/suspended samples can use mutable device/family/clock state at flush/retry time. PR68 (`a5e9c5c8ed050b5a476d5b6f15daa39cebb9b433`, inspected through `origin/pr68`) already captures intake ownership and correlation for this path. No duplicate Collector fix is included here. Parent/root owns the disposition of that existing draft.
- No new schema or migration repair was justified by the inspected paths.
- A query already submitted to HealthKit still waits for its framework callback; this patch stops subsequent work at durable boundaries and makes coalesced waits cancellable. It does not install a general query cancellation/timeout layer.
- Dense sleep privacy pages with excluded leading-overlap samples deserve a device fixture: the timestamp cursor can revisit retained non-target samples. This is an unconfirmed platform-boundary candidate, not counted as a fixed or confirmed finding. No speculative cursor/predicate change was made.
- HealthKit share/read permissions, locked-device delivery, source deletion, and background expiry require native integration checks below.

## Reproducible verification

Harness directory: `/workspace/scratch/a25c9a323562/review-work/storage-harness`.

Run all three original/fixed comparisons:

```sh
python3 /workspace/scratch/a25c9a323562/review-work/storage-harness/run-regressions.py
```

The runner compiles preserved `*-before.swift` sources and current `*.swift` extracts using `/tmp/noop-swift-toolchain/usr/bin/swiftc`, a writable module cache, and the toolchain compatibility library path. Original executables are expected to exit 1 with the demonstrated failure; fixed executables exit 0. The runner itself exits 0 only if all six expected outcomes match. It ran successfully after the patch.

Logs:

- `healthkit-coordinator-before.log` / `healthkit-coordinator-after.log`
- `raw-prune-before.log` / `raw-prune-after.log`
- `privacy-deletion-before.log` / `privacy-deletion-after.log`
- `ios-syntax.log`
- `platform-probe.log`

The coordinator harness compilation has the same warning in both versions about a MainActor `shared` default argument under the compiler's Swift 5 language mode; it is not an introduced diagnostic. The focused executable still compiles and runs. These harnesses do not substitute for full GRDB, UIKit, or HealthKit integration tests.

The modified five Swift files passed:

```sh
LD_LIBRARY_PATH=/tmp/noop-swift-toolchain/compat/usr/lib/x86_64-linux-gnu \
/tmp/noop-swift-toolchain/usr/bin/swiftc -frontend -parse \
-module-cache-path /tmp/noop-storage-swift-module-cache \
-target arm64-apple-ios17.0 \
StrandiOS/Health/HealthKitBridge.swift \
StrandiOS/Health/HealthKitSyncCoordinator.swift \
StrandiOSTests/HealthKitSyncCoordinatorTests.swift \
Packages/WhoopStore/Tests/WhoopStoreTests/PruneTests.swift \
Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift
```

`git diff --check` passed. Direct compiler import probes confirm this Linux runtime has neither HealthKit nor Apple's Compression module. Therefore the native WhoopStore package suite and iOS XCTest suite were not run here. Native CI should run `swift test --package-path Packages/WhoopStore --filter PruneTests` and the existing `NOOPiOS` scheme tests, including `NOOPiOSTests/HealthKitSyncCoordinatorTests` and `SourcePrivacyCleanupCoordinatorTests`. Existing app/package workflows are on macOS.

## Manual/native checks for release review

1. On an authorized iPhone, expire a background recovery caller while a foreground HealthKit import owns the run. The cancelled caller should unwind promptly; the active import should retain its fence and complete normally.
2. Cancel an owning import during quantity, sleep, and workout queries. The next durable drain should replay the retained window, with no missing local workouts or partially acknowledged window.
3. Delete one source's NOOP export data with historical Apple Health data present. Confirm only app-owned target objects are deleted and that own-deletion observer pages do not open a full-history inbound import. Repeat with the Health database locked or delete authorization unavailable and retry after recovery.
4. Run the native forced-variable-limit pruning regression and existing protected-materialization test together. Confirm protected V20/V21 history remains available and decoded tables are unchanged.
5. Run the existing suite on macOS/iOS before merging. WHOOP 4/5/MG hardware sampling and protocol behavior were not changed by this patch, but this agent has not claimed hardware verification.
