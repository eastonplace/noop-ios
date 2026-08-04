# File Application Map

All code targets `eastonplace-ai/noop@976d7d48df6930046eb38cb2f46febb18a986a48`.
`ReferenceCore` is complete and tested. Integration files are replacement implementations or exact splice maps
for large existing repository types.

| Bundle file | Repository destination/action |
|---|---|
| `ReferenceCore/Sources/NoopPhase34Core/*` | Add once as a local package/target, or move intact into an existing foundation target without duplicate types. |
| `CanonicalHealthReadModel.swift` | Add to `Strand/Data`; Repository owns and publishes it. |
| `CanonicalHealthSurfaceStore.swift` | Add to `WhoopStore`; one GRDB read snapshot for Today/Sleep/Trends inputs. |
| `CanonicalSurfacePatches.swift` | Apply to Today, Sleep, Trends, widget, Watch, and export surfaces. |
| `TodaySnapshotPresentationPatch.swift` | Replace snapshot presentation equality in `TodayHealthSnapshotStore.swift`. |
| `VerifiedTodaySnapshotCommit.swift` | Apply inside `Repository.swift`; save/read-back before publish. |
| `VerifiedSnapshotCommitStore.swift` | Add to `WhoopStore`; map each analysis generation to one durable snapshot generation for crash-safe replay. |
| `VerifiedHealthProjectionBuilder.swift` | Add to `Strand/Data`; build only from verified snapshot state. |
| `RepositoryRefreshV2.swift` | Replace days-count/Boolean refresh contract. |
| `RepositoryHistoryExtentStore.swift` | Add to `WhoopStore`; aggregate full-history metadata. |
| `RepositoryExactDayPublisher.swift` | Apply inside `Repository.swift`; reuse current merge helpers. |
| `ExactDayAnalysisIntegration.swift` | Extract exact-window scoring inside `IntelligenceEngine.swift`; preserve formulas. |
| `AnalysisMutationJournalStore.swift` | Add to `WhoopStore`; sole analysis generation domain. |
| `HistoricalReceiptV2Integration.swift` | Replace v1 fingerprint/evidence in commit journal and Backfiller. |
| `HistoricalCursorHardeningPatch.swift` | Replace `setHistoricalCursor` in `Cursors.swift`. |
| `RawOutboxHardeningPatch.swift` | Replace permissive decompress/unpack and silent conflict insert. |
| `Phase34DatabaseMigrations.swift` | Register after current v39 in `Database.swift`. |
| `HistoricalAnalysisWorkStore.swift` | Add to `WhoopStore`; replaces checkpoint execution state. |
| `HistoricalReceiptAdmissionStore.swift` | Add to `WhoopStore`; work and watermark commit together. |
| `HistoricalPipelineRuntime.swift` | Add to `Strand/App`; one admission/coordinator owner. |
| `ExternalPublicationOutboxStore.swift` | Add to `WhoopStore`; exact projection plus destination state. |
| `ExternalPublicationWorker.swift` | Add to iOS runtime; destination-specific adapters and lease heartbeat. |
| `VerifiedExternalSurfaceIntegration.swift` | Replace independent widget/Watch/HealthKit projection paths. |
| `BLEConfirmedWriteQueuePatch.swift` | Apply inside `BLEManager.swift`; exact callback generation matching. |
| `DeviceLifecycleHardeningPatch.swift` | Replace registry activation and wire receipt-scope retirement/deletion. |

## Replace and remove before completion

- `HistoricalAnalysisCheckpoint.swift` execution path
- `HistoricalReceiptAnalysisConsumer.swift`
- receipt use of global `CommittedAnalysisWindow` and `CommittedAnalysisRunPlanner`
- `submitStablePostBackfillAnalysis` historical owner
- broad `refresh(.postBackfill)` and broad current-day refresh
- production Sleep precedence/recomputation in `SleepView`
- Trends production `exploreSeries(key: "sleep_performance")` and independent input reads
- independent external surface projection
- full-history `allSleepSessions()` initial/revision reload
- pre-save Today snapshot publication

Keep compatibility adapters only for unrelated callers. The historical receipt path must have one owner at the
end of the PR.
