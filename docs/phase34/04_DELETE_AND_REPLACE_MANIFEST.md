# Delete and Replace Manifest

Remove each old owner only after its replacement tests pass in the same draft PR. The final branch must not
leave two production owners active.

## Delete after replacement

| Current code/path | Replacement | Root reason |
|---|---|---|
| `HistoricalAnalysisCheckpoint.swift` staged execution state | `historicalAnalysisWork` + reducer + `analysisMutationJournal` | No lease, retry, verification, or terminal state |
| `HistoricalReceiptAnalysisConsumer.swift` | transactional admission + `HistoricalPipelineCoordinator` | Generic deferred failures and incomplete crash state |
| Receipt global `CommittedAnalysisWindow(min,max)` expansion | sparse `HistoricalReceiptEvidence` buckets | Fills empty months or years |
| Historical path through `CommittedAnalysisRunPlanner` | exact `CivilDayWindow` analysis | Re-widens sparse work into relative runs |
| `submitStablePostBackfillAnalysis` forced 21-day owner | durable receipt work | Duplicate scoring owner |
| `.postBackfill` or `.currentDay` → 4,000-day refresh | exact publish + bounded recent request | Dominant latency regression |
| Pre-save `publishTodayHealthSnapshot(resolved...)` | `VerifiedTodaySnapshotCommit` order | Visible value can be non-durable |
| SleepView production Rest recomputation | `repo.canonicalHealth.sleepScore` | Cross-screen score mismatch |
| Trends production `exploreSeries("sleep_performance")` | captured canonical model | Cross-screen and mixed-WAL mismatch |
| Trends independent stress/Apple reads | one canonical WAL snapshot | Mixed database generation |
| Today private production Sleep precedence | canonical Sleep point | Duplicate authority |
| `ExternalSurfaceDayProjection.make(repository:)` or equivalent | exact stored `VerifiedHealthProjection` | Generation drift |
| Analysis-to-snapshot retry without durable mapping | `verifiedSnapshotCommit` | A restart can create a second snapshot generation for one analysis mutation |
| Raw frame decoder that returns a prefix after corruption | strict decompression and frame decoder | Partial replay is unsafe |
| Raw batch `ON CONFLICT DO NOTHING` | exact semantic replay validation | Silent conflicting identity |
| Device registry demote-first activation | guarded single transaction | Invalid target can leave no active source |

## Retain

- Existing scoring formulas and AnalyticsEngine inputs.
- Sleep Performance V2 persistence and model gates.
- Recovery persistence receipts and verification concepts.
- Repository publication barrier, adapted to typed outcomes.
- SQLite Today snapshot, with save/read-back-before-publish ordering.
- Historical rows + cursor + receipt transaction before trim ACK.
- Database identity, device lineage, cursor epoch, and trim scope.
- Five-minute durable live-Strain throttle.
- Generic `exploreSeries` for nonheadline exploratory metrics.
- Full-history import and migration code outside launch/current-day paths.

## Modify once

| File/area | Required modification |
|---|---|
| `Repository.swift` | canonical health model, exact publish, bounded recent cache, history extent, verified projection |
| `RepositoryRefreshIntent.swift` | typed exact/recent/history request and outcome |
| `IntelligenceEngine.swift` | exact-window API; formulas unchanged; durable mutation record after score commit |
| `IntelligenceAnalysisCoordinator.swift` | keep one scoring owner; remove old forced post-backfill adapter |
| `HistoricalDataCommitJournal.swift` | fingerprint V2, sparse buckets, recorded zone, explicit heal days |
| `Database.swift` | register v40–v43 and include `verifiedSnapshotCommit` plus all new tables in deletion/restore audits |
| `Cursors.swift` | greater-generation update; exact equal-generation replay only |
| `RawOutbox.swift` | bounded strict decompression and semantic conflict validation |
| `DeviceRegistryStore.swift` | guarded activation; logical family deletion; old-scope retirement |
| `BLEManager.swift` | exact characteristic/connection-generation token retirement |
| `AppModel.swift` | one `HistoricalPipelineRuntime`; remove checkpoint consumer and broad post-backfill callback |
| `StrandiOSApp.swift` | signal outbox workers; no independent health projection |
| `SleepView.swift` | canonical score and paginated wake-day history |
| `TrendsView.swift` | captured canonical model and bounded refresh |

## Old durable data

- Convert or quarantine any existing staged checkpoint row before deleting its code/table access.
- Old receipts remain as audit evidence.
- A source transition retires the old consumer watermark and quarantines nonterminal work.
- Do not drop legacy checkpoint tables in the same migration unless upgrade tests prove no pending work is lost.

## Deferred schema work

Do not alter RR or event primary keys without stable decoder identity evidence. Add collision diagnostics now.
Track the schema change separately after fixtures prove a protocol sequence, frame offset, or record ordinal.
