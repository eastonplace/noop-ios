> Final verification: see [release verification](noop-release-verification-2026-09-24.md). Full app and package tests now pass; the startup stall is fixed. Findings below retain the original audit context.

# NOOP original feature checklist QA

Date: 2026-09-24

Compared: `feat/ryan-selective-integration-20260924` at `2cfde81a` and its working tree against `../noop-upstream-reference-20260924` at `ef0c0d7`.

Scope: Apple Health safety, writeback and observer replay; Sync Strap shortcut; workout Current/Archived organization; stress widget; clock preferences. Coach, Lift and R-R work are excluded.

**Result: Partial.** The branch contains the listed features, with a Sync Strap behavior gap against the reference and a confirmed Apple Health startup stall. Parent owns the `HealthKitBridge.swift` fix. This audit did not edit that file or its tests.

## Findings

### Apple Health: safety and replay are present; startup is blocked

The reviewed source separates HealthKit read and write types, leaves body-composition values read-only, and checks the HealthKit entitlement before requesting permission in `StrandiOS/Health/HealthKitBridge.swift`. `Packages/StrandImport/Sources/StrandImport/HealthWriteback.swift` only exports HRV as SDNN when the input is explicitly `.sdnn`; it rejects RMSSD, non-finite values and negatives. The historical payload builder also omits persisted `avgHrv` from SDNN output. Workout replay deletion is restricted to the app source and matching NOOP external UUIDs in `HealthKitBridge.swift` around lines 2305-2338.

Observer delivery registers anchored queries, excludes NOOP-authored samples, resolves deleted sample identities, and persists a pending import window before advancing the HealthKit anchor. The observer callback acknowledges HealthKit after the catch-up attempt. See `HealthKitBridge.swift` around lines 619-664 and 1015-1110, and `StrandiOS/Health/HealthKitSyncCoordinator.swift` around lines 294-380. Existing app-target coverage is in `StrandiOSTests/HealthKitSyncCoordinatorTests.swift` and `StrandiOSTests/PR29IOSSinkAndHealthKitTests.swift`; this audit did not run those tests.

The supplied `/private/tmp/noop-startup-sample.txt` confirms a critical startup failure in the sampled build. At 15:18:28, all 2,578 main-thread samples were blocked in `HealthKitBridge.refreshAuthIfPreviouslyGranted()` at lines 577-578, inside `HKHealthStore.authorizationStatusForType` waiting for a synchronous XPC reply. That process launched at 15:14:25. The same startup method has a second synchronous authorization-status scan at lines 599-600. Other synchronous status reads remain in writeback and cleanup paths in `HealthKitBridge.swift`. Parent owns the fix and post-fix test rerun; this report does not verify a repair.

### Sync Strap: shortcut exists, but behavior is reduced

`StrandiOS/System/NOOPAppIntents.swift` registers `SyncStrapIntent` as a plain `AppIntent` with `openAppWhenRun = true`. It queues the action, and `StrandiOS/App/AppModel+iOS.swift` starts syncing only if the strap is already connected and bonded. Otherwise it reports an error and requires the user to run the shortcut again.

The reference uses a `LiveActivityIntent` with `openAppWhenRun = false`, starts a sync Live Activity, waits for an in-progress connection, and arms a pending manual sync when the strap is not ready. Those behaviors are absent from the branch path. `StrandiOSTests/AppIntentRegistrationTests.swift` checks shortcut registration and the open-app flag, but does not cover the disconnected or deferred-sync behavior.

### Workouts: Current and Archived are present, with a different boundary

`Strand/Screens/WorkoutsView.swift` exposes both tabs and keeps archived sessions saved. In this branch, Current means the last 90 calendar days, as implemented by `Packages/StrandAnalytics/Sources/StrandAnalytics/WorkoutHistoryScope.swift`. The upstream reference defines Current as the ten most recent sessions after the active filters. The branch has a boundary test in `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/WorkoutHistoryScopeTests.swift`; it was not run in this focused package test.

### Stress widget: present and snapshot-driven

`StrandiOSWidgets/NOOPWidgetBundle.swift` includes `NOOPStressWidget`. The widget reads the verified shared snapshot, supports small and medium sizes, and shows no recent data when the snapshot is more than one hour old. Its timeline requests refresh every 15 minutes. App-side stress enrichment in `StrandiOS/Widgets/WidgetPublish.swift` computes values from verified source IDs, stores them in the verified envelope, and reloads WidgetKit timelines.

The widget extension does not query HealthKit or compute stress itself. New values depend on app-side publication. The reference also uses an app snapshot, with a 30-minute timeline in `StrandiOSWidgets/StressWidget.swift`; no widget runtime or refresh test was run here.

### Clock preferences: present; locale parity differs

`Strand/Screens/SettingsView.swift` offers System, 12-hour and 24-hour choices and invalidates the formatter when the choice changes. `Strand/App/AppClock.swift` applies the selected hour cycle. The reference builds formatters from `AppLanguage.activeLocale`; this branch uses `Locale.autoupdatingCurrent` directly. The preference is implemented, but preserving the in-app language’s time formatting was not established. Pure preference and template tests exist in `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/ClockFormatTests.swift`; they were not run here.

## Verification and limits

Ran `swift test -j 2 --scratch-path /private/tmp/noop-original-features-strandimport-20260924` from `Packages/StrandImport`: **196 tests passed, 1 skipped, 0 failures**. The skipped test requires `XIAOMI_REAL_DB`. This covers the pure `HealthWriteback` rules, not HealthKit framework calls or app startup.

No `xcodebuild` command was run. Parent owns the simulator startup fix and the affected Xcode test rerun. No commit was made.
