# Audit Coverage

## Repository pin

- Repository: `eastonplace-ai/noop`
- Phase 1: PR #26
- Phase 2: PR #27
- Exact Phase 2 head: `976d7d48df6930046eb38cb2f46febb18a986a48`
- Final Phase 2 hosted workflow: green

Phase 2 committed while the longer QA was in progress. The GitHub connector was used again after that commit.
The final Phase 2 SHA matched the SHA already audited by both source bundles.

## Phase 1 source reviewed

```text
Packages/WhoopStore/Sources/WhoopStore/Database.swift
Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift
Packages/WhoopStore/Sources/WhoopStore/TodayHealthSnapshotResolver.swift
Packages/WhoopStore/Sources/WhoopStore/TodayHealthSnapshotStore.swift
Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift
Strand/App/AppModel.swift
Strand/Data/IntelligenceEngine.swift
Strand/Data/Repository.swift
Strand/Data/RepositoryRefreshIntent.swift
Strand/Screens/DataSourcesView.swift
Strand/Screens/DevicesView.swift
Strand/Screens/TodayView.swift
```

Changed Phase 1 tests were reviewed for snapshot state, hydration, source context, scalar Sleep, display-day,
Strain V2, persistence ordering, migration, and refresh behavior.

## Phase 2 source reviewed

```text
Packages/WhoopStore/Sources/WhoopStore/Cursors.swift
Packages/WhoopStore/Sources/WhoopStore/Database.swift
Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift
Packages/WhoopStore/Sources/WhoopStore/HistoricalAnalysisCheckpoint.swift
Packages/WhoopStore/Sources/WhoopStore/HistoricalDataCommitJournal.swift
Packages/WhoopStore/Sources/WhoopStore/RawOutbox.swift
Packages/WhoopStore/Sources/WhoopStore/StreamStore.swift
Packages/WhoopStore/Sources/WhoopStore/TodayHealthSnapshotStore.swift
Packages/WhoopStore/Sources/WhoopStore/WhoopStore.swift
Strand/App/AppModel.swift
Strand/BLE/BLEManager.swift
Strand/BLE/LiveState.swift
Strand/Collect/Backfiller.swift
Strand/Data/CommittedAnalysisRequest.swift
Strand/Data/CommittedAnalysisRuns.swift
Strand/Data/CommittedAnalysisWindow.swift
Strand/Data/HistoricalReceiptAnalysisConsumer.swift
Strand/Data/HistoricalReceiptAnalysisPlanner.swift
Strand/Data/IntelligenceAnalysisCoordinator.swift
Strand/Data/IntelligenceEngine.swift
```

Changed Phase 2 tests were reviewed for receipt replay, cursor, raw outbox, burst publication, planning,
checkpoint recovery, Backfiller ACK order, migration, and analysis coordination.

## Additional paths traced

```text
Strand/Data/Repository.swift
Strand/Screens/SleepView.swift
Strand/Screens/TrendsView.swift
StrandiOS/App/StrandiOSApp.swift
widget / Live Activity / Watch snapshot paths
SleepPerformanceV2 and preference mode
Repository metric-series, history, and session APIs
device registry activation/deletion/restore
raw stream table keys and insert behavior
```

## Bundle-level validation

- Reconciled independent and prior QA bundles against the exact final Phase 2 head.
- Compiled and ran `ReferenceCore` under Swift 6.2.1.
- Parsed every integration and repository test Swift file.
- Executed migration/hot-path SQLite smoke tests.
- Executed audit-tool unit tests.
- Verified 46 pure Swift state-machine/calendar tests.
- Syntax-parsed 24 integration files and one repository parity test.
- Executed 11 audit-tool unit tests.
- Generated a manifest and archive checksum.

## Required inside the real checkout

The connector did not expose a local Xcode checkout. Codex must run the supplied audit and all repository
build/test commands after integration:

```bash
python3 tools/qa/audit_phase34.py .
rg -n '86_?400|try\?|sleep_performance|refresh\(\.postBackfill\)|allSleepSessions\(' Strand Packages StrandiOS
```

Each remaining match must be classified. A literal full-repository compile, query-plan check, simulator run,
and physical overnight run can occur only after the package is applied to the checkout.
