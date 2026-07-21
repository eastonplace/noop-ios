# Sleep Performance V2 — Ordered Codex Implementation Plan

**Status:** approved product direction; pure scoring foundation implemented on `agent/sleep-performance-v2-foundation`; production wiring remains intentionally off until the data-flow, provenance, Recovery, UI, and migration work below lands together.

**Foundation already on this branch**

- `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepNeedV2.swift`
- `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepPerformanceV2.swift`
- `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepNeedV2Tests.swift`
- `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepPerformanceV2Tests.swift`

The two pure engines are the contract. Do not silently change their production constants while wiring them. Any coefficient change requires a model-version bump, updated tests, and a short rationale in this document.

---

## 1. Product decision

NOOP will ship a new, independent **Sleep Performance** score that answers:

> How completely and efficiently did this main sleep meet the sleep your body appeared to require?

It is not a reproduction of WHOOP's private algorithm. It uses the same broad, explainable ideas while keeping every term inspectable on-device.

### 1.1 Dynamic Sleep Need

For the main sleep ending on day `D`:

```text
baseline need
+ previous-day Effort adjustment
+ bounded repayment of positive sleep debt
- recent nap credit
= dynamic Sleep Need
```

Production constants in `SleepNeedV2.Config.production`:

- Default baseline: **480 min**.
- Automatic personal baseline: 75th percentile of eligible low-effort, efficient, low-debt nights.
- Automatic learning is **upward-only** from 480 min. Chronic short sleep must never train the target downward.
- User override: allowed within 420...570 min.
- Previous-day Effort: monotonic 0...100 → 0...60 min.
- Debt repayment: 25% of current positive debt, capped at 90 min tonight.
- Nap credit: 80% of recent nap minutes, capped at 90 min.
- Total need: clamped to 390...630 min.
- Debt balance: positive-only, capped at 300 min.

### 1.2 Sleep Performance

The headline score is a weighted geometric mean:

```text
Sufficiency        70%
Efficiency         10%
Consistency        10%
Low sleep stress   10%
```

```text
score = 100 × exp(
    0.70 × ln(sufficiency)
  + 0.10 × ln(efficiency)
  + 0.10 × ln(consistency)
  + 0.10 × ln(lowStressQuality)
)
```

The geometric form is deliberate: strong secondary signals cannot completely hide a short night.

- `sufficiency = clamp(mainSleepMinutes / dynamicNeedMinutes, 0...1)`.
- `efficiency = asleep / inBed` from the selected main-night group.
- `consistency` compares this night's local onset and wake with the immediately preceding four main sleeps, using circular clock math.
- `lowStressQuality` is supplied by `SleepStressV1` below.
- Deep and REM remain useful diagnostics, but **do not contribute to the headline** until NOOP's staging has external validation adequate for a weighted score term.
- Missing optional inputs receive **no neutral points**. The foundation renormalizes the real terms and applies a coverage ceiling: one optional term missing caps the score at 90; both missing cap it at 80.
- The exact normalized result, `SleepPerformanceV2.Result.recoveryInput`, feeds Recovery.

---

## 2. Hard invariants

These are merge blockers.

1. **One result object per day.** Calculate `SleepPerformanceV2.Result` once from a versioned context. Persistence, Recovery, driver rows, diagnostics, Today, Sleep, Trends, Watch, notifications, and Coach all consume that same result or its persisted exact value.
2. **No pass-two default recomputation.** Do not call `AnalyticsEngine.Rest.composite(daily:)` to reconstruct the score. A `DailyMetric` does not contain the dynamic need, debt state, nap credit, calibrated consistency context, stress quality, or model version.
3. **No future leakage.** Day `D` may use only data known before or during the main sleep ending on `D`. Its baseline and consistency history exclude `D`; its effort adjustment uses `D-1`; its debt input is the balance before the main sleep.
4. **Wake-day identity.** The displayed night, score, need, source, model version, and Recovery must all share the same local wake-day key.
5. **No stale carry as “last night.”** A missing score for the displayed night shows the honest fallback. Never substitute the last non-null historical score.
6. **Separate provenance.** Imported WHOOP Sleep Performance and NOOP-computed Sleep Performance are distinct series. A graph must never alternate between them without an explicit source dimension.
7. **Recovery exactness.** `RecoveryScorer.recovery`, `chargeDrivers`, and `recoveryTrace` receive the same `recoveryInput`. No helper may independently rebuild sleep quality.
8. **Edits are first-class.** A user-corrected sleep window updates Sleep Performance, Sleep Need/debt state, and Recovery in the same rescore pass.
9. **Missing data is visible.** Missing consistency/stress lowers coverage and confidence. Missing efficiency or main-sleep duration yields no score.
10. **Version every persisted derived value.** Historical V1 and V2 values must be distinguishable and reproducible.

---

## 3. Current defects this implementation replaces

The current production path:

- defaults to an 8-hour need because `IntelligenceEngine` does not pass a personalized need into `AnalyticsEngine.analyzeDay`;
- grants a neutral consistency value when consistency is absent;
- gives deep+REM staging 20% of the headline despite the stager being explicitly approximate;
- recalculates the old Rest composite from `DailyMetric` during pass two;
- then separately recalculates it again for Recovery, Charge drivers, diagnostics, and persistence;
- stores computed and imported meanings under the shared `sleep_performance` concept;
- lets Sleep presentation select the last non-null score independently from the displayed night's wake day;
- maintains a separate eight-hour need inside wind-down planning;
- describes the old duration/efficiency/deep+REM/timing formula in the metric catalog and related explanatory surfaces.

Do not patch these independently. They are one data-contract problem.

---

## 4. Target data flow

```text
raw night streams + stored sleep edits
        │
        ▼
SleepNightSummary (main sleep only)
  - wake-day
  - onset / wake
  - total asleep / in-bed / efficiency
  - nap minutes since prior main sleep
  - stress windows / lowStressQuality
  - provenance + source row id
        │
        ▼
SleepScoringContextBuilder (chronological replay)
  - eligible prior baseline nights
  - prior four timing nights
  - previous-day Effort
  - debt balance before night
        │
        ├──► SleepNeedV2.calculate
        │
        └──► SleepPerformanceV2.score
                    │
                    ├──► persisted score + component series + model version
                    ├──► RecoveryScorer.recoveryInput
                    ├──► Charge driver breakdown + trace
                    └──► UI/Coach explanation object
```

The orchestration replay must run **oldest → newest** even if raw collection is fetched newest first. Debt and personalization are stateful chronological folds.

---

## 5. Ordered implementation

## Phase A — lock the foundation

### A1. Run and retain package tests

```bash
cd Packages/StrandAnalytics
swift test
```

Required foundation tests already exist for:

- chronic restriction not lowering the baseline;
- upward baseline learning;
- explicit override behavior;
- monotonic bounded effort adjustment;
- debt and nap effects;
- debt repayment and missing-night hold;
- geometric score behavior;
- higher need lowering the same night's score;
- missing-input coverage caps;
- required efficiency;
- circular consistency across midnight;
- four-prior-night consistency calibration.

### A2. Add property-style boundary tests

File: `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepPerformanceV2PropertyTests.swift`

Pin the following over fixed grids, not random-only tests:

- more main sleep never lowers the score;
- higher need never raises the score;
- higher efficiency, consistency, or low-stress quality never lowers the score;
- more debt never lowers need;
- more nap minutes never raises need;
- higher previous-day Effort never lowers need;
- every public output is finite and inside its documented range;
- missing optional inputs never increase score above the corresponding fully-covered score.

---

## Phase B — create the canonical per-night input

### B1. Add `SleepNightSummary`

New file: `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepNightSummary.swift`

Suggested shape:

```swift
public struct SleepNightSummary: Equatable, Sendable, Codable {
    public let wakeDay: String
    public let mainSleepStart: Int
    public let mainSleepEnd: Int
    public let mainSleepMinutes: Double
    public let inBedMinutes: Double
    public let efficiency: Double
    public let onsetMinuteLocal: Int
    public let wakeMinuteLocal: Int
    public let recentNapMinutes: Double
    public let lowStressQuality: Double?
    public let source: SleepScoreSource
    public let sourceRowId: String
}
```

`SleepScoreSource` must distinguish at least:

```swift
case noopMeasured
case noopEdited
case whoopImport
case appleHealthImport
case otherImport(String)
```

### B2. Extract it from the existing main-night selection

Files:

- `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift`
- `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStageTotals.swift`
- `Strand/Data/IntelligenceEngine.swift`

Requirements:

- Reuse `mainNightGroupIndices`; do not introduce another “main sleep” selector.
- Main sleep totals exclude naps.
- `recentNapMinutes` is the sum of eligible nap blocks after the previous main sleep and before this main sleep. Do not add naps directly to main-sleep duration.
- Inter-fragment awake gaps remain awake and affect efficiency exactly once.
- A user edit reshapes this summary before scoring.
- Imported rows produce a summary only when the source actually provides the required values. Unknown asleep time remains unknown.

### B3. Keep `AnalyticsEngine.Rest` temporarily, mark it legacy

Do not delete V1 in the first integration PR. Rename documentation/comments to `LegacyRestV1` or deprecate entry points after all live call sites move. It remains available only for migration display of old history and tests; no V2 production path may call it.

---

## Phase C — implement overnight stress quality

### C1. Add `SleepStressV1`

New files:

- `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepStressV1.swift`
- `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepStressV1Tests.swift`

This signal is an **approximate arousal load**, not a diagnosis and not WHOOP's private Sleep Stress model.

Initial contract:

1. Divide the selected main-night group into five-minute windows.
2. For each sufficiently covered window, calculate:
   - mean heart rate;
   - cleaned RMSSD when enough R-R intervals exist;
   - wake fraction from the resolved hypnogram;
   - normalized motion when motion exists.
3. Build the calm reference from prior trusted main sleeps only. Do not use the current night in its own baseline.
4. Convert each real signal into a non-negative activation term:
   - HR above personal sleeping reference raises activation;
   - RMSSD below personal sleeping reference raises activation;
   - wake and motion raise activation.
5. Combine only available terms and renormalize their weights. Never turn missing R-R or motion into zero stress.
6. Clamp each window to 0...3, then calculate duration-weighted mean stress.
7. `lowStressQuality = 1 - meanStress / 3`.
8. Require at least six covered five-minute windows and at least one physiological signal; otherwise return nil.

Before enabling V2 by default, fit/freeze the activation scales on paired nights and document them beside the constants. Until `SleepStressV1` lands, V2 may run in shadow mode with `lowStressQuality=nil`; the foundation will cap that score at 90 and label it Building.

Tests:

- calm fixture > activated fixture;
- added wake/motion cannot improve quality;
- elevated HR cannot improve quality;
- suppressed RMSSD cannot improve quality;
- missing optional streams renormalize rather than award credit;
- fewer than six windows returns nil;
- current night cannot enter its own baseline.

---

## Phase D — chronological context builder

### D1. Add `SleepScoringContextBuilder`

New files:

- `Packages/StrandAnalytics/Sources/StrandAnalytics/SleepScoringContextBuilder.swift`
- `Packages/StrandAnalytics/Tests/StrandAnalyticsTests/SleepScoringContextBuilderTests.swift`

Responsibilities:

- accept chronological prior daily rows, main-sleep summaries, and existing V2 state;
- estimate the baseline using only eligible preceding nights;
- resolve previous-day NOOP Effort from the immediately preceding local day, not the current day and not “latest available” without a freshness bound;
- calculate consistency against the prior four main sleeps;
- carry positive debt forward with `SleepNeedV2.updateDebt`;
- call `SleepNeedV2.calculate`, then `SleepPerformanceV2.score`;
- return a versioned per-day object containing summary, need, score, and post-night debt.

Suggested result:

```swift
public struct ScoredSleepDay: Equatable, Sendable, Codable {
    public let day: String
    public let summary: SleepNightSummary
    public let need: SleepNeedV2.Breakdown
    public let performance: SleepPerformanceV2.Result?
    public let debtAfterNight: SleepNeedV2.DebtUpdate
}
```

### D2. Chronological replay in `IntelligenceEngine`

File: `Strand/Data/IntelligenceEngine.swift`

- Raw stream reads may remain newest-first for I/O convenience.
- Before sleep scoring, sort final edited summaries oldest-first.
- Fold once through the window.
- Carry `ScoredSleepDay` into the existing pass-two structure.
- Never reconstruct context from a `DailyMetric` after the fold.
- A rescore window needs enough warm-up history before its first persisted day: at least 30 preceding nights for baseline/stress plus the existing active scoring range. Warm-up rows inform context but are not necessarily rewritten.

---

## Phase E — make Recovery consume the exact score

Files:

- `Packages/StrandAnalytics/Sources/StrandAnalytics/AnalyticsEngine.swift`
- `Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorer.swift`
- `Packages/StrandAnalytics/Sources/StrandAnalytics/RecoveryScorerTrace.swift`
- `Strand/Data/IntelligenceEngine.swift`
- relevant Recovery/Charge tests

### E1. Preserve the approved Recovery relationship

Keep the existing Recovery sleep weight at 15% for this release. Change only the input from Legacy Rest V1 to:

```swift
let sleepQuality = scoredSleep.performance?.recoveryInput
```

### E2. Remove duplicate reconstruction

Change these helpers to accept the already-calculated sleep input or `ScoredSleepDay`:

```swift
recomputeRecovery(..., sleepQuality: Double?)
recomputeChargeDrivers(..., sleepQuality: Double?)
recoveryTraceLines(..., sleepQuality: Double?)
```

Delete every live use of:

```swift
AnalyticsEngine.Rest.composite(daily: daily)
```

The score, driver rows, and trace must receive the exact same `Double?`.

### E3. Add exactness tests

- A fixture's `SleepPerformanceV2.Result.recoveryInput` reaches `RecoveryScorer` unchanged.
- Recovery, driver breakdown, and trace all report the same sleep term.
- Lowering only Sleep Performance cannot raise Recovery.
- A sleep edit changes Sleep Performance and Recovery in the same pass.
- A missing Sleep Performance drops and renormalizes the Recovery sleep term; it does not inject efficiency or a default score.

---

## Phase F — persistence, provenance, and migration

Files:

- `Packages/WhoopStore/Sources/WhoopStore/Database.swift`
- `Packages/WhoopStore/Sources/WhoopStore/MetricsCache.swift`
- `Strand/Data/Repository.swift`
- `Strand/Data/IntelligenceEngine.swift`
- import mapping files only where needed to preserve source separation

### F1. Persist component series

Write the following under the computed `-noop` source:

```text
noop_sleep_performance_v2
noop_sleep_need_min
noop_sleep_need_baseline_min
noop_sleep_need_strain_min
noop_sleep_need_debt_repayment_min
noop_sleep_need_nap_credit_min
noop_sleep_sufficiency_pct
noop_sleep_efficiency_pct
noop_sleep_consistency_pct
noop_sleep_low_stress_pct
noop_sleep_input_coverage_pct
noop_sleep_debt_balance_min
noop_sleep_model_version
```

`noop_sleep_model_version` may be numeric `2` in metric series until the store supports string metadata. The full semantic version remains in traces and any Codable scoring snapshot.

After the feature flag becomes authoritative, mirror the V2 headline into the computed source's existing dashboard key `sleep_performance` for compatibility. Do not rewrite imported WHOOP values.

### F2. Separate imported and computed reads

Introduce a source-aware value:

```swift
struct SleepScorePoint {
    let day: String
    let value: Double
    let source: SleepScoreSource
    let modelVersion: String?
}
```

Repository APIs should expose:

- NOOP V2 series;
- imported WHOOP series;
- a deliberate dashboard winner for one day;
- no ambiguous mixed historical series.

### F3. Migration rules

- Do not reinterpret old `sleep_performance` rows as V2.
- Recompute recent measured history from raw data when available.
- Keep older V1 values labeled “Legacy on-device” if displayed.
- Imported WHOOP history remains “WHOOP” and unchanged.
- Clear/rebuild only computed V2 keys inside the rescore window.
- Add a one-shot model-version migration marker so every launch does not rescore full history.

### F4. Freshness rules

For any “last night” surface:

```text
displayed wake day == score day == source day
```

If no value exists for that exact wake day, show no score/hours fallback. Reuse the existing Today/Watch freshness helper where possible instead of inventing another carry rule.

Tests:

- a historical 93 never appears on a newer unscored night;
- imported WHOOP and NOOP V2 values coexist;
- source badge follows the same point as the number;
- navigating past nights resolves each night's own point;
- stale computed data cannot beat a fresh imported value on another day;
- migration is idempotent.

---

## Phase G — update every explanatory screen

Use one canonical explanation model. Do not duplicate formula prose across views.

### G1. Add `SleepScoreExplanation`

New file: `Strand/Data/SleepScoreExplanation.swift` or a pure presentation type in `StrandAnalytics`.

It should format directly from `ScoredSleepDay` / persisted component values:

- headline score and confidence;
- “You slept X of Y needed”;
- baseline need;
- Effort addition;
- debt repayment addition;
- nap subtraction;
- sufficiency;
- efficiency;
- consistency or “calibrating”;
- low sleep stress or “not enough signal”;
- model/source label.

No view recalculates a component.

### G2. `Strand/Screens/SleepView.swift`

Required changes:

- Resolve the score by the displayed night's local wake day, not `series.last`.
- Hero copy: **Sleep Performance**, not “restorative score.”
- Add a “How this was calculated” card from `SleepScoreExplanation`.
- Show four score components: Sufficiency, Efficiency, Consistency, Low Sleep Stress.
- Add an expandable Sleep Need breakdown: baseline + Effort + debt repayment − naps.
- Keep Deep, REM, Light, and stage trends below as estimated sleep architecture, explicitly outside the headline formula.
- Keep source and model version attached to the displayed score.
- Missing consistency/stress shows Calibrating/Not enough signal, never a fabricated 50%.
- The debt card uses the canonical positive V2 debt balance, not a separate 14-night net surplus ledger.

Approved plain-language copy:

> Sleep Performance measures how completely and efficiently you met your dynamic Sleep Need. Sleep Need starts with your baseline, then accounts for yesterday's Effort, recent sleep debt, and naps. The score weighs sufficiency most heavily, with efficiency, timing consistency, and low overnight stress as supporting signals. Sleep stages are estimates shown for context; Deep and REM do not change this score.

### G3. `Strand/Screens/TodayView.swift` and any alternate Today implementation

- Sleep ring reads the exact day-keyed dashboard point.
- Tap-through explanation uses the same canonical copy.
- Source badge distinguishes NOOP V2 from WHOOP import.
- No freshness carry beyond the existing explicitly bounded morning behavior.

### G4. `Strand/Screens/CoupledView.swift`

Replace any old “duration/efficiency/deep+REM/timing” explanation. State that Sleep Performance is one 15%-weighted input to Charge and is already need-aware.

Approved copy:

> Last night's Sleep Performance contributes to Charge alongside HRV, resting heart rate, respiration, and skin-temperature deviation. The exact Sleep Performance shown on the Sleep screen is the value used here.

### G5. `Strand/Data/MetricCatalog.swift`

Replace the current description with:

> How completely and efficiently you met your dynamic Sleep Need, led by sleep sufficiency.

Add descriptors for the V2 component series and dynamic need where they are useful in Trends/Compare.

### G6. Wind-down and alarms

Files:

- `Strand/System/WindDownNudge.swift`
- `Strand/Screens/SmartAlarmView.swift`
- any Behavior/Alarm settings store that owns a separate need value

Remove the independent default-eight-hour planning model. The planner reads the latest canonical dynamic need or an explicit user override. If no scored history exists, it uses the same `SleepNeedV2` default and labels it as a starting estimate.

### G7. Other surfaces to search and update

Codex must search for these strings and concepts before marking the work complete:

```text
Rest composite
restorative score
deep+REM
duration, efficiency
sleepNeedHours
neutralConsistency
AnalyticsEngine.Rest.composite
sleep performance is calculated
How Rest is calculated
```

Review at least:

- `Strand/System/AppChangelog.swift`
- Coach context builders and prompts
- notification copy
- widgets/watch bridge
- weekly digest
- Trends/Compare descriptors
- `docs/ANALYTICS.md`
- `docs/FEATURES.md`
- privacy/disclaimer wording where scores are enumerated
- localized string catalogs or translation scripts

No surface may claim the model is WHOOP-identical or medically validated.

---

## Phase H — diagnostics and observability

Extend Sleep test-mode traces with one parseable line per scored wake day:

```text
sleepV2 day=2026-07-20 source=noopMeasured model=sleep-performance-v2.0
  tstMin=...
  inBedMin=...
  baselineNeedMin=...
  effortAddMin=...
  debtAddMin=...
  napCreditMin=...
  totalNeedMin=...
  suff=...
  eff=...
  consistency=...|nil
  lowStress=...|nil
  coverage=...
  score=...
  recoveryInput=...
```

Also emit:

- prior debt and post-night debt;
- baseline source and eligible-night count;
- score day, displayed/source row id, and provenance;
- explicit reason when score is nil.

Diagnostics must reuse stored/calculated result values. A trace may not recalculate the model.

---

## Phase I — feature flag, shadow scoring, and release gates

Add `SleepPerformanceV2Prefs` with three states:

```text
off       legacy remains authoritative
shadow    V2 persists diagnostics/parallel keys; UI and Recovery stay legacy
on        V2 drives UI, persistence compatibility key, and Recovery
```

### I1. Shadow period

Run V2 in shadow for at least the available paired-history window before default-on. Compare by wake day:

- NOOP V2 need vs imported WHOOP need where available;
- NOOP V2 score vs imported WHOOP Sleep Performance;
- V2 vs V1;
- score by sleep-duration bucket;
- score by debt and previous-day Effort bucket;
- manually edited vs auto-detected nights;
- missing-input rate and coverage distribution.

### I2. Release gates

Do not enable by default until all are true:

- zero stale-score/date mismatches in tests and sampled traces;
- zero source-label mismatches;
- a detected sleep below six hours cannot produce 90+ under full production inputs;
- chronic short-sleep fixtures do not lower baseline need;
- score monotonicity suite passes;
- Recovery/driver/trace exactness suite passes;
- edited-night end-to-end test passes;
- imported WHOOP history remains byte-for-byte unchanged;
- `swift test` passes in every touched package;
- iOS and macOS app schemes build without new warnings;
- Sleep/Today/Coupled/Alarm screens are manually reviewed in light/dark mode and Dynamic Type.

### I3. Rollback

The flag can return authority to V1 without deleting V2 parallel keys. Never overwrite imported values. Keep model versions attached so rollback does not create a mixed unlabeled line.

---

## 6. Codex work units

Execute in this order. Each unit should be its own focused commit where practical.

1. **Foundation QA** — run package tests and add monotonic/property boundaries.
2. **Night summary** — add `SleepNightSummary`; reuse existing main-night selector and edit seam.
3. **Sleep stress** — implement and test `SleepStressV1`.
4. **Context replay** — add chronological `SleepScoringContextBuilder` and warm-up history.
5. **Shadow persistence** — write V2 component/version keys without changing authority.
6. **Recovery exactness** — thread one V2 result into Recovery, drivers, and trace behind the flag.
7. **Freshness/provenance** — source-aware day-keyed point APIs; remove last-non-null “last night” fallback.
8. **UI explanation** — Sleep, Today, Coupled, Metric Catalog, Trends, Coach, changelog.
9. **Planner unification** — WindDown and Smart Alarm consume canonical need.
10. **Migration and default-on** — compatibility key, one-shot rescore, release evidence.

Do not combine phases 6–9 into an unreviewable mega-diff. The authority switch should be the final small commit after parallel results and UI have been validated.

---

## 7. Required review checklist

- [ ] `SleepNeedV2` is the only computed need model.
- [ ] `SleepPerformanceV2.Result` is calculated once per wake day.
- [ ] The same `recoveryInput` reaches Recovery, drivers, and traces.
- [ ] No live call to `AnalyticsEngine.Rest.composite(daily:)` remains.
- [ ] WHOOP and NOOP scores are separately identifiable.
- [ ] Displayed night, score day, and source day are identical.
- [ ] Deep/REM is not a headline input or described as one.
- [ ] Missing consistency/stress receives no neutral credit.
- [ ] Wind-down/alarm uses canonical need.
- [ ] Every explanatory surface uses the canonical copy.
- [ ] All derived rows carry a model version.
- [ ] Package tests and app builds pass.

---

## 8. Ready-to-use Codex brief

```text
Implement docs/superpowers/plans/2026-07-20-sleep-performance-v2.md in ordered,
reviewable commits. Treat SleepNeedV2.swift and SleepPerformanceV2.swift as the
approved algorithm contract. Begin by running StrandAnalytics tests and adding
the property-boundary suite. Then implement SleepNightSummary and the
chronological context replay before touching Recovery or UI.

Hard requirements:
- calculate one versioned SleepPerformanceV2.Result per local wake day;
- use no current-day/future values in its baseline, consistency, debt, or effort context;
- pass result.recoveryInput unchanged to Recovery, Charge drivers, and traces;
- never reconstruct V2 from DailyMetric or Legacy Rest defaults;
- keep imported WHOOP and NOOP-computed series separate;
- resolve every displayed score by the displayed night's wake-day key;
- remove neutral credit for missing consistency/stress;
- keep Deep/REM diagnostic-only;
- update Sleep, Today, Coupled, MetricCatalog, alarms/wind-down, Coach, changelog,
  docs, and localization surfaces to the canonical explanation;
- land shadow scoring and provenance tests before switching authority on.

Stop and report rather than guessing if an existing store field cannot preserve
source or model version. Do not silently overload an imported WHOOP key.
```
