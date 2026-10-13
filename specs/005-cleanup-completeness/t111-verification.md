# T111 — Tests, dead code, and strings

## Test expectation repairs

- `WeeklyDigestTests.testFocalPointSurfacesBiggestMover` still asserted the retired pillar label `Charge`; the retained test now asserts the current `Recovery` copy while preserving its upward-move and positive-sentiment coverage.
- `StrandDesignTests.testPaperProportionContract` still pinned the pre-D12 30 pt trio numeral. The shared `NoopMetrics.trioRingNumeralSize` token and its retained regression assertion now pin D12's 26 pt ruling.

## Dead-code caller proof

Repository-wide Swift symbol search before deletion returned one occurrence apiece for `LiveWorkoutView.heroHeartRate` and `LiveWorkoutView.statsGrid`: their declarations. The latter's private `stat` helper had callers only inside that orphan builder. The active body renders `PaperLiveWorkoutStatsGrid`, `PaperWorkoutMapCard`, and `paperHeartRateCard` per D15.

Deleted:

- pre-D15 `heroHeartRate`
- pre-D15 `statsGrid`
- the now-zero-caller private `stat` helper owned by that grid

Post-deletion repository search returns zero occurrences for `heroHeartRate` and `statsGrid`; the remaining `stat` declaration belongs to `SensorRowIfPresent` and retains three live callers.

## String-catalog sweep

- Audited all four catalogs: app, watch app, watch complication, and StrandDesign.
- Removed all 69 app-catalog entries Xcode marked `extractionState: stale`, including every localized language payload attached to those dead keys.
- Rechecked every catalog: zero stale entries remain.
- Rechecked source keys and all localized values for retired English pillar labels `Charge` and `Effort`. No live English pillar term remains. French `charge` occurrences translate the ordinary nouns “load” or “charging,” not the retired Recovery pillar.
- Languages inspected in the app catalog: German, English, Spanish, French, Italian, European Portuguese, Russian, Simplified Chinese, and Traditional Chinese.

## Verification

- `swift test` — StrandAnalytics: 954 tests, 0 failures.
