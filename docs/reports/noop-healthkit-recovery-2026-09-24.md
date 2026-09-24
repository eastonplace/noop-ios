# NOOP Apple Health recovery report

Date: 2026-09-24
Recovered checkout: `/Users/eastonplace/Library/Mobile Documents/com~apple~CloudDocs/Vibed Code/projects/noop-integration-20260924`
Base: `321f5186` (`PR53 Xcode27 fixes`)
Source log: Codex log database `/Users/eastonplace/.codex/logs_2.sqlite`, Apple Health worker thread `01a0d430-24e8-7df1-a4dc-7a21a319df94`

## Restored files owned by this recovery

- `Packages/StrandImport/Sources/StrandImport/HealthWriteback.swift`
  - Added `HealthWriteback.HrvExportValue` with explicit `.rmssd` and `.sdnn` cases.
  - Added `HealthWriteback.sdnnMilliseconds(from:)`, which returns a value only for explicit, finite, non-negative SDNN input.
- `Packages/StrandImport/Tests/StrandImportTests/HealthWritebackTests.swift`
  - Added regression coverage for RMSSD rejection, explicit SDNN acceptance, and invalid SDNN rejection.
- `Strand/Data/RepositoryHistoricalHealthKitPayloadBuilder.swift`
  - Treats persisted `avgHrv` as RMSSD and leaves historical SDNN empty.
  - Keeps the changed-day replacement scope, so the publisher can retract a prior NOOP-owned SDNN sample without rewriting immutable historical keys.
- `StrandiOS/Health/HealthKitBridge.swift`
  - Uses the current `HealthKitAnchorPager.scan(anchor:)` label.
  - `writeVitals` records stale NOOP-owned SDNN keys for deletion, including days whose HRV value disappeared.
  - Includes deletion keys in the vitals fingerprint and deletes only samples from `HKSource.default()` with matching external UUIDs.
  - Never writes `DailyMetric.avgHrv` as `heartRateVariabilitySDNN`.

## Ownership boundaries preserved

No changes were made to `Repository.swift`, `AppModel.swift`, `IntelligenceEngine.swift`, `HealthKitSyncCoordinator.swift`, or UI files. The existing custom observer and workout replay path remains in place: `syncFromObserver(type:)`, `HealthKitWorkoutReplayPlan`, `writeWorkoutRows(_:)`, and `deleteWorkoutReplayArtifacts(_:)`. Workout cleanup remains scoped to NOOP-owned external UUIDs and the app source.

The parent integration hook remains outside this patch. After an atomic Lift save, refresh the frozen owner and invoke the existing selective analysis and historical publish path only when the active source still equals that frozen owner. Do not score the current active source after a mid-session source switch.

## Verification

- `git diff --check`: passed after restoration.
- `swift test -j 2 --filter HealthWritebackTests`: passed in the recovered checkout.
- Result: 18 tests, 0 failures at 2026-09-24 13:35:28.
- Persistent output: `/Users/eastonplace/Library/Mobile Documents/com~apple~CloudDocs/Vibed Code/outputs/noop/recovery/health-tests.log`.
- The log preserves one initial sandbox cache failure and the successful escalated retry.

## Concurrent files left untouched

The final readback also showed concurrent changes in `Packages/WhoopStore/Sources/WhoopStore/Database.swift`, `Packages/WhoopStore/Sources/WhoopStore/DeviceRegistryStore.swift`, `Packages/ReceiptLiftActivity/`, `Packages/ReceiptLiftFeature/`, new `Lift*` package files and tests, `Packages/StrandAnalytics/*Lift*`, `Strand/Data/Lift*`, `Strand/Resources/LiftCatalog/`, `StrandTests/Lift*`, `StrandiOSWidgets/LiftLiveActivityWidget.swift`, `StrandiOSWidgets/NOOPWidgetBundle.swift`, and `project.yml`. These are not part of the Apple Health recovery and were left untouched.

## Remaining gate

The focused package test is complete. Compile the app target before merging. The app-target compile was not rerun during recovery.
