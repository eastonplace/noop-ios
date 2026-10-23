# Health metrics audit and correction report

## Scope and outcome

Reviewed the analytics path from decoded HR, RR, gravity, respiration, and steps through daily calculations, recovered/manual sleep, stress, workout rescoring, rolling baselines, and readiness/training load. The review traced the app's raw-store consumers and `IntelligenceEngine.analyzeRecent` orchestration as well as the package kernels. This was a focused source audit of the files and paths listed below, not a claim that every file in the repository or every device behavior was exercised.

The patch fixes **seven independently reproduced defects**, changes **seven production files**, and adds **17 tests in five test files**. Sixteen of the new tests failed against the corresponding pre-fix implementation; one is a boundary-preservation control. No production changes were made to `IntelligenceEngine.swift`, raw storage, collection, sensor frequency, scoring coefficients, clinical ranges, or database history by this workstream. No commit or push was performed by this agent.

The final exact-production-source Linux harness ran **192 XCTest tests with zero failures and exited 0**. It compiles 19 real analytics source files plus the local `WhoopProtocol` package and runs 11 original repository test files. This result does not establish that the full StrandAnalytics package, iOS app, or device integrations pass. Those require the parent audit's macOS/Xcode verification.

## Confirmed defects fixed

### M1. Invalid HR contaminated resting HR before the artifact gate

**Root cause:** `RecoveryScorer.restingHR` filtered timestamps but accepted raw invalid/off-wrist HR before computing five-minute means and the sparse-bin fallback. Filtering the resulting average cannot repair contaminated input: equal numbers of 60 bpm and zero readings produced a plausible-looking 30 bpm result. An all-invalid sparse stream containing 0, 29, and 241 returned 90 bpm.

**Fix:** Apply the existing shared `HRValidity.isPlausible` predicate to each reading before binning or fallback. Existing valid limits, bin density requirements, and sustained-floor logic remain unchanged. Unsorted valid data still follows the existing chronological sort path.

**Evidence:** `RecoveryScorerTests.testRestingHRDoesNotTurnInvalidReadingsIntoFallbackPhysiology` and `testRestingHRDropsInvalidReadingsBeforeAveragingUnsortedBins` failed before the fix and pass afterward. `testRestingHRPreservesTheSharedPlausibilityBoundaries` proves that the existing inclusive 30 and 240 bpm boundaries remain accepted.

### M2. Invalid HR/RR rows could authorize a fabricated recovered sleep session

**Root cause:** `SleepWindowRecovery.analyze` treated a nonempty raw physiological array as evidence of wear and counted invalid rows toward evidence coverage. A still, off-wrist strap with zero HR was classified as a complete, persistable recovered night, with resting HR 0 and confidence 0.89. An RR-only array of 0, 299, and 2001 ms similarly passed the physiology-presence guard despite having no plausible beats.

**Fix:** Filter HR through the established shared validity predicate before evidence, vitals, and staging. Count only RR values within the existing analyzer's inclusive 300–2000 ms range as RR wear evidence and coverage. **The original RR sequence remains available to HRV cleaning and staging**, including invalid beats, so artifact removal still creates the existing gaps instead of joining formerly separated beats. Valid RR-only recovery remains supported and can yield a partial session without invented resting HR.

**Evidence:** Four new `SleepRecoveryValidityTests` cover all-off-wrist HR, mixed valid/invalid out-of-order HR, all-invalid RR-only input, and valid RR-only input combined with invalid HR. All four failed at least one assertion before the fix and pass afterward. Existing gap-aware HRV tests also pass.

### M3. Gravity cache identity collapsed different vectors to the same sum

**Root cause:** Sleep detection and both sleep stagers fingerprinted gravity as `Int((x + y + z) * 1024)`. Different orientations with the same axis sum therefore had identical keys even when their vector differences changed the motion features and actual sleep result. Quantization additionally erased some smaller differences.

**Fix:** Add one shared gravity fingerprint that folds each timestamp and the full Double bit pattern of x, y, and z separately. Use it in sleep detection, V1 staging, and V2 staging. The cache remains bounded and stores results rather than raw arrays. No staging thresholds or calibration changed.

**Evidence:** Three new `SleepMemoInputTests` warm a still-stream cache, then submit a moving stream whose per-row axis sums are identical. The detector's trace path supplies an uncached oracle; the staging tests obtain equivalent fresh computations by shifting timestamps by whole days. Each test verifies that motion changes real output, then verifies that the warm-cache result equals that output. All three failed before the fix and pass afterward.

### M4. V2 cropped unordered input using binary search before sorting

**Root cause:** The public V2 stager accepts unordered streams and sorts defensively later, but its earlier padded-window clipping performed binary search and endpoint shortcuts on the original order. A late block preceding the real night could discard the in-window data before the sort, producing the sparse all-light fallback.

**Fix:** Check timestamp order before the shortcut or binary search. For unordered input, retain the requested half-open window using filtering; the existing downstream sort then orders it. The sorted-input path retains its binary bounds and avoids unnecessary copying when already in bounds.

**Evidence:** `SleepMemoInputTests.testV2ClipsUnorderedPaddedStreamsWithoutDiscardingTheNight` uses the same padded HR/gravity values in sorted and unordered batches. It verifies that an actual wake segment survives. The unordered output differed before the fix and equals the sorted output afterward.

### M5. Invalid HR supplied stress coverage and shifted hourly/reference values

**Root cause:** The stress view can pass raw store readings directly to `DaytimeStress.analyze`. The analyzer counted every reading toward its 300-per-hour coverage gate and included zero/out-of-range values in hourly means and the day's calm reference. Fully invalid hours became scored stress, insufficient valid coverage became sufficient, and mixed 60/0 data produced a 30 bpm hourly mean.

**Fix:** Apply the existing shared HR validity predicate before memoization, hourly bucketing, and calm-reference calculation. The 300-reading gate and stress scoring formula remain unchanged.

**Evidence:** Three new `DaytimeStressTests` cover wholly invalid hours, 299 valid readings plus an invalid filler, and a covered hour mixed with invalid readings. Each failed before the fix and passes afterward.

### M6. Stress HRV depended on arrival order rather than beat timestamps

**Root cause:** `DaytimeStress` bucketed RR values in arrival order and discarded their timestamps before successive-difference HRV analysis. The same alternating 800/850 ms beats yielded approximately 2.89 ms RMSSD when delivered grouped/out of order versus 50 ms in timestamp order.

**Fix:** Detect chronological RR input and sort only when needed, before bucketing. Keep invalid RR values for the existing gap-aware cleaner. Do not reorder equal-timestamp beats by value or introduce deduplication semantics.

**Evidence:** `DaytimeStressTests.testTimestampedRRUsesChronologicalSuccessiveDifferences` fails on the original implementation and passes after the sort. The existing `HrvGapAwareTests` pass in the final run.

### M7. Manual workout metrics used inconsistent HR populations

**Root cause:** `ManualWorkoutRescore` passed raw HR to average, peak, and calories while the strain implementation already filtered invalid HR internally. On the regression fixture, the same workout had average 70 bpm, peak 255 bpm, and approximately 234 kcal instead of valid-only average/peak 140 bpm and approximately 424 kcal, while strain was identical. Two invalid readings could also create an apparently rescorable workout.

**Fix:** Create one plausible-HR window before pause segmentation and the two-reading eligibility gate. Use that same window or its pause segments for every metric. Existing pause duration, strain, calorie, and profile logic remain intact.

**Evidence:** `ManualWorkoutRescoreTests.testInvalidReadingsDoNotCreateARescorableWorkout` and `testEveryRescoredWorkoutMetricUsesTheSameValidHeartRate` failed before the fix and pass afterward. Existing pause-ledger, workout rescoring, and strain-accumulator tests pass in the same final run.

## Exact changes to evidence/count semantics

| Consumer | Previous count/input | Corrected count/input | Threshold/calibration impact |
| --- | --- | --- | --- |
| Resting HR | Every in-window HR row | Only HR accepted by the existing inclusive 30–240 bpm predicate | Existing bin count and physiological mean gates preserved; counts now refer to usable readings |
| Recovered sleep HR evidence | Every raw HR row and occupied bucket | Plausible HR rows and their occupied buckets | No coverage threshold change |
| Recovered sleep RR evidence | Every raw RR row and occupied bucket | RR in the existing inclusive 300–2000 ms range and its occupied buckets | No minimum-clean-beat or HRV window threshold change; original RR retained for cleaner |
| Recovered sleep wear presence | Any raw HR/RR/respiration | Any plausible HR/RR or existing respiration evidence | One nonempty plausible stream still suffices for this presence guard; downstream confidence/staging requirements remain |
| Hourly stress | At least 300 raw HR readings | At least 300 plausible HR readings | 300 remains unchanged; RR still enriches a qualifying HR hour rather than replacing its HR gate |
| Manual workout eligibility | At least two active raw HR readings | At least two active plausible HR readings | Two remains unchanged; pauses still segment time before integration |

## Test execution and reproducibility

All new regression tests were written and run before their corresponding production fixes. The initial recovery/sleep run executed 26 tests with 23 failing assertions across 10 tests. The second run, after those fixes but before stress/workout fixes, executed 48 tests with eight failing assertions across six tests. The original boundary-control test passed throughout.

The final run executes these repository test files without rewriting their test bodies:

- `RecoveryScorerTests.swift` — 18 tests.
- `SleepRecoveryValidityTests.swift` — four tests, new file.
- `SleepMemoInputTests.swift` — four tests, new file.
- `SleepStagerTests.swift` — 71 tests.
- `SleepStagerV2Tests.swift` — 11 tests.
- `HRVAnalyzerTests.swift` — 21 tests.
- `HrvGapAwareTests.swift` — seven tests.
- `DaytimeStressTests.swift` — 13 tests.
- `ManualWorkoutRescoreTests.swift` — nine tests.
- `WorkoutPauseLedgerTests.swift` — 25 tests.
- `StrainScorerV2Tests.swift` — nine tests across its three test classes.

Harness: `/tmp/noop-metrics-harness/Package.swift`. Production and test files under that package are symlinks to the actual checkout. There are no mocked production types or substituted numerical kernels. The target is named `StrandAnalytics` to preserve the original `@testable import` declarations. Its dependency is the real local `Packages/WhoopProtocol` package. The source selection is recorded in `metrics-harness-manifest.txt` beside this report.

The 19 selected production sources are `AnalyticsMemo`, `HRValidity`, `HRVAnalyzer`, `RecoveryScorer`, `Baselines`, `SleepStager`, `SleepStager+Trace`, `SleepStagerV2`, `SleepWindowRecovery`, `ScoreConfidence`, `StableStatistics`, `StrainScorer`, `DaytimeStress`, `ManualWorkoutRescore`, `WorkoutDetector`, `StrainScorerV2`, `WorkoutPauseLedger`, `HRZones`, and `WorkoutLiveProjectionAccumulator` (all `.swift`).

Final invocation:

```sh
LD_LIBRARY_PATH=/tmp/noop-swift-toolchain/compat/usr/lib/x86_64-linux-gnu \
CLANG_MODULE_CACHE_PATH=/tmp/noop-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/noop-swift-module-cache \
/tmp/noop-swift-toolchain/usr/bin/swift test \
  --build-system native \
  --package-path /tmp/noop-metrics-harness \
  --scratch-path /tmp/noop-metrics-build \
  --cache-path /tmp/noop-swift-cache \
  --config-path /tmp/noop-swift-config \
  --security-path /tmp/noop-swift-security
```

The default SwiftPM build system could not communicate through the sandbox's IPC restrictions; the native build system with automatically approved local execution was used. The attempted full-package run could not fetch GRDB because the sandbox network proxy connection failed. Therefore there is no passing full-package result from this agent. Linux/Apple framework compatibility beyond that fetch step was not established by the failed full-package command.

Logs copied beside this report:

- `logs/metrics-initial-red.log` — original recovery/sleep regression failures.
- `logs/metrics-stress-workout-red.log` — original stress/workout regression failures.
- `logs/metrics-final-green.log` — final 192-test run.
- `metrics-harness-manifest.txt` — exact test/source symlink targets and Package.swift.

`git diff --check -- Packages/StrandAnalytics` also completed successfully. These test results establish behavior of the selected kernels and their original unit tests. They do not exercise WhoopStore persistence, the full analysis orchestration, UI rendering, HealthKit, Bluetooth, or an actual device.

## Source coverage and data-flow observations

The principal path traced was decoded `WhoopProtocol` streams → raw `WhoopStore` reads → `IntelligenceEngine` civil-day scans and `AnalyticsEngine` → persisted/published daily metrics. Additional raw-store consumers traced were manual sleep recovery, manual workout rescoring, and the stress view. The automatic main analytics path already rejects unsafe timestamps and implausible HR; the confirmed missing gates were at the direct helper boundaries documented above.

Substantive source review covered:

| Area | Files/paths inspected | Scope and outcome |
| --- | --- | --- |
| Raw types and ownership boundaries | `WhoopProtocol/Streams.swift`; read-only `WhoopStore/Reads.swift`, `StreamStore.swift`; relevant repository sleep-recovery and stress-view callers | Established that zero/invalid raw readings can legitimately remain stored and reach direct consumers. Storage ownership and collector fixes belong to other workstreams. |
| Main pipeline | `AnalyticsEngine.swift`; major `IntelligenceEngine.analyzeRecent`, civil-day, cache, source-selection, baseline-fold, manual-rescore sections | Traced windowed reads, automatic HR gate, sleep/vitals/workouts/calories/strain integration, and persistence handoff. No orchestration production edit. |
| Sleep | `SleepStager.swift`, `SleepStager+Trace.swift`, `SleepStagerV2.swift`, `SleepWindowRecovery.swift`, `SleepStageTotals.swift`, `ManualSleepDailyScorer.swift`, `SleepDebt.swift` | Reviewed detection/staging, clipping, stage totals, edits, and manual evidence. Fixed M2–M4; did not alter stage heuristics or sleep-debt calibration. |
| HR and recovery | `HRValidity.swift`, `HRVAnalyzer.swift`, `RecoveryScorer.swift`, `HeartRateRecovery.swift`, `ScoreConfidence.swift`, `StableStatistics.swift` | Reviewed valid ranges, cleaning, successive differences, gap handling, RHR bins/fallback, confidence, and recovery components. Fixed M1; gap-aware behavior retained. |
| Exercise and energy | `WorkoutDetector.swift` including `Calories`/`UserProfile`, `ManualWorkoutRescore.swift`, `WorkoutPauseLedger.swift`, `WorkoutLiveProjectionAccumulator.swift`, `HRZones.swift`, `StrainScorer.swift`, `StrainScorerV2.swift`, `DailyCalories.swift` | Reviewed pause segmentation, integration, activity/physiological strain, calories, live projection, and daily deduplication. Fixed M7 without recalibration. |
| Daily/rolling aggregates | `StepsCounter.swift`, `TrainingLoadEngine.swift`, `Baselines.swift`, `ReadinessEngine.swift`, `DailyCalories.swift` | Reviewed missing versus zero, counter wrap, calendar-day decay, baseline chronology, and civil-day bounds. No confirmed, verified new production change in this group. |
| Memoization | `AnalyticsMemo.swift`, `AnalyzeRecentDayCache.swift`, relevant `IntelligenceEngine` keys | Fixed the proven per-kernel gravity collision. Broader orchestration cache completeness remains a separate candidate below. |

The calendar-based civil-day duration handling already allows 23/25-hour days. The current-day read end is bounded by the next midnight or now as appropriate. Full-day calories already deduplicate by second and fill uncovered time with basal energy. Training-load chronology distinguishes missing observations from an observed zero. These existing behaviors were not replaced with new models.

## Remaining limitations and candidates, not claimed fixed

1. **App-level scan-cache completeness candidate.** `IntelligenceEngine`'s WHOOP 4 day-scan reuse key watches HR count/max timestamp, RR scoring fingerprint, skin anchor, edit/selection inputs, and pass configuration. It does not visibly witness every independently changing input consumed by the scan, such as gravity/events/respiration/band state and all temperature values. Raw streams can be inserted independently of existing HR. A late motion-only batch may therefore leave the app-level day scan stale even after the corrected per-kernel gravity fingerprint. The metric impact of an end-to-end late-batch case was not reproduced in the app/WhoopStore environment here. This is a follow-up candidate requiring a full integration fixture and coordination with storage, not an additional claimed fix.

2. **Non-Gregorian day-key candidate.** Some app paths format components obtained from `Calendar.current` into `yyyy-MM-dd` strings while package day parsing assumes Gregorian. A Buddhist/Japanese device calendar merits a targeted integration test. Correcting persisted day-key semantics may require compatibility/migration handling for existing records; no speculative migration or calendar rewrite was made.

3. **Baseline missing-day semantics.** Existing fold/as-of behavior is based on supplied historical entries and tests intentionally carry forward the last state beyond the final entry. Calendar-age staleness across entirely absent records should be reviewed against product policy before changing baseline confidence or readiness. It is not part of this verified patch.

4. **Collection is upstream.** These calculations cannot recover values that were not collected, prove source ownership, repair incorrect decoded units/timestamps, or guarantee successful BLE backfill. Those issues must be validated against the separate BLE/storage fixes and on-device data.

5. **Respiration-only wear evidence remains existing behavior.** A nonempty respiration ADC stream can still satisfy the manual-recovery physiology-presence guard. No established raw ADC plausibility/wear rule was found to justify inventing one. Validate worn/off-wrist respiration behavior with actual firmware captures before changing it.

6. **No new clinical validation.** Sleep staging, stress, recovery/readiness, strain, calories, and training load remain the existing estimates. Regression parity and input hygiene do not establish clinical accuracy, polysomnography equivalence, calorimetry accuracy, or diagnosis. No physiology thresholds or coefficients were tuned during this audit.

## Required remaining integration/device checks

1. Run the full package suites and iOS app build/tests on macOS/Xcode. Include existing `SleepWindowRecoveryTests`, day-calorie/calendar suites, and app cache/persistence tests that are outside this Linux subset.
2. On each supported strap family, collect a worn interval and an off-wrist still interval. Verify raw history remains present, invalid HR does not appear in computed stress/RHR/manual-workout averages, and selecting the off-wrist interval cannot create a recovered sleep session from zero HR alone.
3. Verify a valid RR-only recovered interval remains partial with HRV and no invented resting HR; verify known artifact runs preserve RMSSD gaps through decode, store, and manual recovery.
4. Exercise sleep through local midnight and spring/fall DST with a single captured history. Confirm session attribution, duration, 23/25-hour day energy, and rolling-day labels across the UI and persistence. Include a non-Gregorian calendar setting as the candidate check above.
5. Deliver a delayed gravity/respiration/event batch after an HR-complete day, then compare warm analysis with a forced fresh scan. This directly tests the app-level scan-cache candidate beyond the fixed kernel caches.
6. Trim and pause/resume a workout containing off-wrist sections. Compare rescored average/peak HR, calories, strain, and stored/exported values with the same usable HR samples. Confirm pause time is not bridged into energy or strain.
7. Verify existing saved history and manual edits survive app restart/reanalysis and that the corrected metrics reach dashboard/detail views and HealthKit through the parent workstreams' source-selection/export paths.

## Changed file inventory

Production under `Packages/StrandAnalytics/Sources/StrandAnalytics`: `AnalyticsMemo.swift`, `DaytimeStress.swift`, `ManualWorkoutRescore.swift`, `RecoveryScorer.swift`, `SleepStager.swift`, `SleepStagerV2.swift`, `SleepWindowRecovery.swift`.

Tests under `Packages/StrandAnalytics/Tests/StrandAnalyticsTests`: modified `DaytimeStressTests.swift`, `ManualWorkoutRescoreTests.swift`, `RecoveryScorerTests.swift`; new `SleepMemoInputTests.swift` and `SleepRecoveryValidityTests.swift`. The two new files must be included in the parent's Git staging step.
