# NOOP PR #23 — July 27 source-review evidence pack

## Purpose and scope

This is a **redacted code-review pack**, not a release claim and not a health-data export. It records the source changes made after draft PR #23's remote head, why they were made, and the tests that were actually run. Review the candidate as a separate integration layer on top of PR #23.

**Privacy boundary:** no phone database, raw BLE capture, full app log, device identifier, screenshot, questionnaire response, or personal metric is attached here. The physical observations below are deliberately qualitative.

## Candidate identity

- Repository: `eastonplace-ai/noop`
- Review target: draft PR #23, `release/noop-ios-2.1-rc`
- Remote baseline before this integration: `05a3ed5804b6d6c70584bb2ed68fdfbf17d2e963`
- Base branch: `main` at `42dd317b59ff91db8dcf08465056422b967bbfaf`
- This file and the paths below are part of the follow-on integration commit(s) pushed to the same draft PR branch.

## Evidence labels

- **Source verified** means the listed path was inspected locally.
- **Test executed** means the named command/test result below ran against this worktree after generation where noted.
- **Physical observed** means a human-visible behavior was seen on a paired iPhone; it is not a substitute for source or test proof.
- **Inference / open gate** is intentionally not claimed as fixed.

## Issue-to-source map

| Area | Symptom / risk | Root-level change to inspect | Evidence and boundaries |
|---|---|---|---|
| PR #23 baseline: heart-rate recovery | Extreme or malformed timestamps could trap arithmetic; a feature component could exist without live wiring. | Inspect the already-remote `HeartRateRecovery` hardening and its production call sites on PR #23. Do not rely on historic PR comments; trace current `WorkoutDetailView`, `IntelligenceEngine`, and `BLEManager` paths. | **Source verified (baseline only):** remote PR #23 head contains the prior fix set. **Open:** independently prove all production wiring remains live at the final candidate SHA. |
| Sleep-window integrity | Implausibly long sleep records can contaminate selection, recovery, or display. Deleting a user's record would be destructive. | Add one shared 30-minute–16-hour policy in `Packages/WhoopProtocol/Sources/WhoopProtocol/SleepSessionWindow.swift`; apply it before cache writes, manual edits/recovery writes, repository selection, analytics, and editor submission. Invalid legacy rows are quarantined/excluded, not deleted. | **Source verified:** `SleepEditGuard.swift`, `MetricsCache.swift`, `SleepRecoveryStore.swift`, `Repository.swift`, `IntelligenceEngine.swift`, `SleepView.swift`. **Test executed:** StrandAnalytics and WhoopStore suites below. **Open:** inspect every remaining sleep-ingress path for policy bypasses. |
| Main-night selection | A stage-less partial recovery could win merely because its clock time aligned better, displacing a real staged night. | Prefer sessions with defensible stages whenever any staged session exists; retain the stage-less fallback only when all candidates are stage-less. | **Source verified:** `SleepStageTotals.swift`. **Test executed:** StrandAnalytics suite. |
| Sleep efficiency presentation | A persisted placeholder `0` could render as `0%` beside a measured asleep/in-bed window. | Treat only a plausible positive stored efficiency as authoritative; otherwise derive from measured sleep/in-bed minutes, and return no value when staging is absent. The fallback is presentation-only and does not invent sleep data. | **Source verified:** `SleepView.displayEfficiencyPercent`. **Test executed:** `SleepEfficiencyPresentationTests` (3 passed). **Physical observed:** corrected nonzero efficiency rendered after same-bundle in-place install in earlier QA; this pack deliberately omits personal values. |
| Backfill lifecycle / app freezes | During historical offload, concurrent history-wide dashboard reads fought database writes; the user could see stale results or a final-looking empty recovery state while data was still arriving. | Publish a durable `backfillDataAvailableAt` signal only after a burst changes persisted rows or heals timestamps; debounce one post-burst analysis/repository refresh. Keep Today’s heavy historical reads deferred while the burst writes, then refresh after it settles. Mount the existing syncing-history note on Today so “not rated” is not presented as final while offload is active. | **Source verified:** `BLEManager.swift`, `LiveState.swift`, `AppModel.swift`, `TodayView.swift`. **Test executed:** `BackfillBurstPublicationTests` (3 passed after XcodeGen regeneration). **Open:** verify continuation, timeout, and reconnect paths on a physical strap. |
| Lifecycle ownership / migration contention | Two scene/launch paths could independently drive the long Effort migration, competing with live analysis. | Make `AppModel.setApplicationActive(_:)` the single owner; turn `AppModel+PerformanceLifecycle` into a forwarding bridge rather than another migration driver. | **Source verified:** `AppModel+PerformanceLifecycle.swift`, `AppModel.swift`. **Test executed:** `PerformanceLifecycleOwnershipTests` (1 passed). **Open:** verify foreground/background and day-rollover behavior under a large database. |
| Today performance | Each Health Monitor tile could re-enter display-day resolution, multiplying scans across a large history on SwiftUI body updates. | Build a keyed `displayDaySnapshot` once, pass the resolved row through tiles, refresh only on the relevant day/refresh transitions, and move daytime-stress analysis off the main actor. | **Source verified:** `TodayView.swift`. **Test executed:** `TodayDisplayDaySnapshotTests` (3 passed). **Open:** profile an actual large-history device run; source tests do not prove frame time. |
| Test determinism | A debounce test guessed that 70 ms had elapsed, producing scheduler-sensitive failures. | Wait for the expected write count instead of indexing a guessed timer result. | **Source verified:** `DebouncedLogTailPersistenceTests.swift`. **Test executed:** 6 focused tests passed. |
| Missing Recovery on the current phone | Sleep/RHR may be present while Recovery stays empty; current history was actively offloading. | No code change claims to fabricate a score. Trace raw R-R → daily HRV, resting HR, baseline readiness, recovery scoring, repository refresh, and Home rendering. | **Physical observed:** current offload was active and live R-R was present; no raw phone data is included. **Inference:** current missing Recovery could be incomplete historical processing or genuinely missing overnight HRV, not a proven PR regression. |

## Files intentionally included in this integration

```text
Packages/WhoopProtocol/Sources/WhoopProtocol/SleepSessionWindow.swift
Packages/StrandAnalytics/Sources/StrandAnalytics/SleepEditGuard.swift
Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift
Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepEditGuardTests.swift
Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepStageTotalsTests.swift
Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift
Packages/WhoopStore/Sources/WhoopStore/SleepRecoveryStore.swift
Packages/WhoopStore/Tests/WhoopStoreTests/MetricsCacheTests.swift
Packages/WhoopStore/Tests/WhoopStoreTests/SleepRecoveryStoreTests.swift
Strand/App/AppModel+PerformanceLifecycle.swift
Strand/App/AppModel.swift
Strand/BLE/BLEManager.swift
Strand/BLE/LiveState.swift
Strand/Data/IntelligenceEngine.swift
Strand/Data/Repository.swift
Strand/Screens/SleepView.swift
Strand/Screens/TodayView.swift
StrandiOSTests/BackfillBurstPublicationTests.swift
StrandiOSTests/DebouncedLogTailPersistenceTests.swift
StrandiOSTests/PaperIntegrationContractTests.swift
StrandiOSTests/PerformanceLifecycleOwnershipTests.swift
StrandiOSTests/TodayDisplayDaySnapshotTests.swift
```

## Test-execution receipt

Executed from the candidate worktree:

```text
swift test --package-path Packages/StrandAnalytics
Result: 1,199 passed, 0 failed. One expected-failure assertion is recorded by the existing suite; it is not a pass for a new fix.

swift test --package-path Packages/WhoopStore
Result: 303 passed, 0 failed.

/opt/homebrew/bin/xcodegen generate --spec project.yml
Result: succeeded. Required before exercising the newly added BackfillBurstPublicationTests target membership.

Xcode simulator focused tests
Result: 13 passed, 0 failed, 0 skipped:
  - SleepEfficiencyPresentationTests (3)
  - BackfillBurstPublicationTests (3, rerun after generation)
  - PerformanceLifecycleOwnershipTests (1)
  - TodayDisplayDaySnapshotTests (3)
  - DebouncedLogTailPersistenceTests (6; 3 were in the first focused run and all 6 in that class passed)
```

Notes:

- The focused iOS result is not a full iOS-target test run.
- No physical-device, accessibility, or hosted-CI gate is closed by this document.
- `git diff --check` was clean before commit.

## Required external-review questions

1. For every claim above, classify it as source-level fix, presentation-only mitigation, test-only coverage, or unproven diagnosis.
2. Trace invalid sleep timestamps and invalid window lengths from all ingress points to rendering. Identify any bypass or inconsistent boundary.
3. Trace backfill data from packet persistence through `backfillDataAvailableAt`, `refreshAfterBackfillBurst`, analytics, repository refresh, and `TodayView`. Prove or disprove exactly-one final refresh per burst, including continuation/reconnect/error exits.
4. Audit the lifecycle consolidation for accidental loss of migration work or scene-phase races.
5. Audit the display-day snapshot invalidation contract for stale-day, local-midnight, pre-4 AM, selected-past-day, and repository-refresh cases.
6. Trace Recovery end-to-end. Determine whether any new change can suppress HRV/RHR/baseline inputs, whether the strict missing-input gates are intentional, and what exact redacted diagnostic receipt would distinguish missing raw data from a refresh/timing defect.
7. Identify regressions, missing tests, dead paths, and cases where the change only hides a symptom rather than fixing its source.

## Do not infer

- Do not call the branch release-ready or recommend merge; PR #23 remains draft.
- Do not call Recovery fixed until a settled physical history run proves the required inputs and final scoring path.
- Do not request raw health data or full logs. Ask for field-level redacted counts/timestamps only if source inspection cannot answer a question.
