# NOOP Analytics

On-device analytics for **NOOP** — a standalone, fully offline companion app for WHOOP straps (4.0 and 5.0/MG). NOOP talks to *your own* strap over Bluetooth, stores everything locally in SQLite, and computes its three daily scores plus HRV and sleep staging on-device. There is no cloud and no account involved in any of the math described here.

## NOOP's three daily scores — Charge / Strain / Rest

NOOP gives you Charge and Rest on 0–100 plus Strain on the canonical 0–21 display scale. Strain remains stored on a 0–100 compatibility axis internally.

| Score | Answers | Engine | Internal key | Was called |
|---|---|---|---|---|
| **Charge** | How recovered are you? | `RecoveryScorer` | `recovery` | Recovery |
| **Strain** | How hard did your body work? | `StrainScorerV2` | `strain` | — |
| **Rest** | How restorative was your sleep? | Rest composite (`AnalyticsEngine`) | `sleep_performance` | Sleep Performance |

Each score is built from your strap's raw signals using published sport science and computed entirely on your device. Strain V2 uses continuous HRR load rather than Edwards/Banister zones.

They are **NOT WHOOP's scores.** We don't have WHOOP's private algorithms and don't pretend to. NOOP's scores aim at the same three questions using open science, so they'll usually track WHOOP's *in direction*, but won't match number-for-number — and that's the point.

Every score also carries a small **confidence tier — Solid / Building / Calibrating** (`ScoreConfidence`) so a sparse day reads truthfully instead of faking a number. When NOOP can't compute a score honestly, it shows nothing rather than a fabricated value.

> **Naming & continuity.** Display Strain is always 0–21. The internal `strain` key and 0–100 persistence boundary remain unchanged so existing history and imports keep working. `StrainScorer` remains only as the V1 rollback/shadow comparator while `StrainScorerV2` produces new candidates.

> **Not affiliated with WHOOP.** NOOP interoperates with hardware and data you already own. The scores and metrics below are **independent approximations** of common exercise-physiology and HRV methods, derived from published literature — they are **not** reproductions of any proprietary scoring model, and they are **not a medical device**. Nothing here is medical advice.

All analytics live in the cross-platform `StrandAnalytics` Swift package. Every entry point is a **pure, deterministic, DB-free** function over its inputs — no I/O, no global state, no network. Persistence and BLE are wired in elsewhere (`WhoopStore`, the app target). This makes the whole package straightforward to unit-test against fixed vectors.

- Package: `Packages/StrandAnalytics/Sources/StrandAnalytics/`
- Top-level index: `StrandAnalytics.swift` (`StrandAnalytics.version == "0.1.0"`)
- App reference implementation: `Strand/` (SwiftUI, macOS + iOS). The same `StrandAnalytics` code backs both Swift app targets, and Android (Room/Kotlin) runs equivalent analytics — the number-crunching is shared, so results match across platforms.

---

## What is actually wired into the app

The package contains more analytics than the app currently surfaces. This section is the honest map of **library-only** vs **live**, verified against the app sources. The status below is shared across the Swift targets (macOS + iOS); Android runs the equivalent code through its own Kotlin/Room layer.

| Engine | File | Status in the app |
|---|---|---|
| `HRVAnalyzer` | `HRVAnalyzer.swift` | **Library-only** as a type. The app computes RMSSD inline via `AppModel.rmssd(_:)` (same Task-Force formula) for the live stress nudge. |
| `RecoveryScorer` | `RecoveryScorer.swift` | **Live.** Computes the **Charge** score. Runs inside `AnalyticsEngine.analyzeDay` via `Strand/Data/IntelligenceEngine.swift`; computed values are persisted under the `"<deviceId>-noop"` source and merged **under** any imported `recovery_score_pct` (imports always win). APPROXIMATE. |
| `StrainScorerV2` | `StrainScorerV2.swift` | **Live in shadow mode.** Computes sleep-to-sleep Strain candidates and activity-only workout Strain. Imported WHOOP values remain untouched; canonical day promotion is gated on the comparison report. APPROXIMATE. |
| `SleepStager` | `SleepStager.swift` | **Live.** Stages each offloaded night inside `analyzeDay`; the per-night stages feed the **Rest** composite. Computed sessions are persisted under the `"-noop"` source, with imported sleeps taking precedence. APPROXIMATE. |
| `Baselines` | `Baselines.swift` | **Live.** Seeds the recovery baseline in `IntelligenceEngine.analyzeRecent` (two-pass cold-start). The illness early-warning in `AppModel` still uses its own trailing-window baseline math inline (see below). |
| `WorkoutDetector` / `Calories` | `WorkoutDetector.swift` | **Live.** Runs inside `AnalyticsEngine.analyzeDay`; detected bouts are persisted as `workout` rows under the computed `"<deviceId>-noop"` source (sport `"detected"`), de-duplicated against imported WHOOP workouts. All intensity/calorie fields are APPROXIMATE. Not yet surfaced in the Workouts screen. |
| `AnalyticsEngine` | `AnalyticsEngine.swift` | **Live orchestrator.** `analyzeDay(...)` is called by `Strand/Data/IntelligenceEngine.swift` — every 15 minutes while connected, and from the Intelligence screen — and its `DailyMetric`, sleep sessions and detected workouts are persisted under the `"-noop"` source. |
| `HRZones` | `HRZones.swift` | **Library-only** (display zone model). The app's live zone coaching computes `%HRmax` inline in `AppModel.coachZone(_:)`. |
| `CorrelationEngine` | `CorrelationEngine.swift` | **Live.** Used by `InsightsView`, `CompareView`, `MetricExplorerView`. |
| `BehaviorInsights` | `BehaviorInsights.swift` | **Live.** Used by `InsightsView` (`rank` + `sentence`). |
| `ComparisonEngine` | `ComparisonEngine.swift` | **Live.** Used by `MetricExplorerView`. |

**In short:** the *interactive data-interrogation* engines (correlation, behavior effects, period comparison) are wired into screens, and the *recompute-from-raw-streams* engines that produce the three daily scores — Charge (recovery), Effort (strain), Rest (sleep), plus workout detection — run live too: `IntelligenceEngine` calls `analyzeDay` for every night the strap offloaded and persists the APPROXIMATE results under the `"-noop"` source, merged under any imported rows — a WHOOP export still wins wherever it covers a day. The live BLE app additionally runs four small inline analytics in `AppModel`: HR smoothing, RMSSD, HR-zone coaching, an illness/strain early-warning, and a resting-stress nudge.

---

## Live analytics in `AppModel`

Source: `Strand/App/AppModel.swift`. These run against the live BLE stream and the daily history, on the main actor.

### 1. Heart-rate smoothing (`ingestHR`)

Every screen shows a **smoothed** bpm (`AppModel.bpm`), never the raw per-beat value (which swings with HRV). The smoother:

1. Prefers the strap's reported HR; falls back to `60000 / RR` (last R-R interval) if needed.
2. Clamps to a plausible `30…220` bpm range — rejects `0` and garbage spikes.
3. Keeps a ~10-second sliding window (max 40 samples) and **publishes the window median**.

```swift
hrWindow.append((now, inst))
hrWindow.removeAll { now.timeIntervalSince($0.t) > 10 }   // ~10 s window
if hrWindow.count > 40 { hrWindow.removeFirst(hrWindow.count - 40) }
let vals = hrWindow.map(\.v).sorted()
bpm = vals.isEmpty ? nil : Int(vals[vals.count / 2].rounded())
```

Median (not mean) is deliberate: it rejects single-beat outliers without lagging the signal.

### 2. RMSSD for the stress nudge (`rmssd` + `evaluateStress`)

The live RMSSD uses the classic Task-Force successive-difference formula over a rolling R-R buffer:

```swift
static func rmssd(_ rr: [Int]) -> Double {
    guard rr.count >= 2 else { return 0 }
    var sum = 0.0, n = 0
    for i in 1..<rr.count { let d = Double(rr[i] - rr[i - 1]); sum += d * d; n += 1 }
    return n > 0 ? (sum / Double(n)).squareRoot() : 0
}
```

`evaluateStress()` is an **experimental, off-by-default** resting-stress nudge:

- Only runs when `behavior.stressNudge` is on **and** the strap is bonded **and** worn.
- Filters R-R to plausible beats (`300 < rr < 2000` ms, i.e. 30–200 bpm), keeps the last 60, needs ≥ 20.
- Tracks a **slow HRV baseline** as an EWMA: `hrvBaseline = hrvBaseline * 0.98 + rmssd * 0.02`.
- Only fires when HR is in a **resting band** (`55…100` bpm — not a workout) and current RMSSD has dropped **below 60% of baseline**.
- Rate-limited to **once per 15 minutes** (`> 900` s). On fire it buzzes the strap once and logs "take a paced breath."

It is intentionally conservative so it rarely false-fires.

### 3. HR-zone haptic coaching (`coachZone`)

Watches the smoothed `bpm`, computes `%HRmax` from `profile.hrMax`, and buckets into 5 zones at `0.6 / 0.7 / 0.8 / 0.9` of max:

```swift
let pct = Double(hr) / maxHR
let zone = pct >= 0.9 ? 5 : pct >= 0.8 ? 4 : pct >= 0.7 ? 3 : pct >= 0.6 ? 2 : 1
```

On crossing **into zone 5** it buzzes three times ("ease off"); on dropping back **to zone ≤ 1** it buzzes once ("recovered"). Gated on `behavior.zoneCoaching`, bonded, worn, and a valid `hrMax`.

### 4. Illness / strain early-warning (`evaluateIllness`)

This is the live, app-side version of the baseline-comparison idea. It recomputes whenever the daily history changes (`repo.$days`). It compares the **last ~2 days** against a **~28-day baseline ending 3 days ago** (so the recent window doesn't contaminate its own baseline):

```swift
let recent = Array(days.suffix(2))
let base   = Array(days.suffix(31).dropLast(3))   // ~28 days ending 3 days ago
```

It then flags anomalies against simple, explainable thresholds using `DailyMetric` fields:

| Signal | Field(s) | Anomaly condition |
|---|---|---|
| Resting HR ↑ | `restingHr` | recent mean ≥ baseline mean **+ 5 bpm** |
| HRV ↓ | `avgHrv` | recent mean ≤ baseline mean **× 0.80** (−20%) |
| Skin temp ↑ | `skinTempDevC` | recent mean deviation **≥ +0.6 °C** |
| Respiration ↑ | `respRateBpm` | recent mean ≥ baseline mean **+ 1.5 bpm** |

A banner appears only when **two or more** anomalies fire together — the classic early-illness signature is *RHR up + HRV down + skin-temp up*. Requires `behavior.illnessWatch` on and at least 14 days of history. On-device only; the message is a plain-English summary like *"Your body looks strained — resting HR +6 bpm, HRV −22%. Consider taking it easy."*

---

## `HRVAnalyzer` — RMSSD / SDNN with cleaning

Source: `HRVAnalyzer.swift`. Reproduces the **Task Force (1996)** definitions over R-R / NN intervals (ms), with a deterministic cleaning pipeline.

### Formulas

```
RMSSD = sqrt( (1/(N-1)) · Σ (NN[i+1] − NN[i])² )    (Task Force 1996)
SDNN  = sample standard deviation of NN, ddof = 1     (Task Force 1996)
pNN50 = 100 · (count of |ΔNN| > 50 ms) / (N − 1)
```

`rmssdRaw(_:)` and `sdnnRaw(_:)` are the raw primitives (no filtering, return `nil` for fewer than 2 values).

### Cleaning pipeline (`cleanRR`)

1. **Range filter** — drop intervals outside `[rrMinMs, rrMaxMs] = [300, 2000]` ms (≈ 200 bpm to 30 bpm).
2. **Ectopic rejection (Malik-style)** — drop any beat deviating more than `ectopicThreshold = 0.20` (20%) from a **local median** over a centered window of `2·ectopicWindowRadius + 1 = 5` beats. Beats with too small a neighbourhood are kept.
3. **Sufficiency gate** — require at least `minBeats = 20` clean intervals before returning a trustworthy result; otherwise `HRVResult.empty(...)`.

> **Honest substitution.** The reference Python pipeline ran neurokit2's Kubios / Lipponen–Tarvainen (2019) artifact classifier, which isn't available on-device. NOOP substitutes the classical **Malik et al. (1989)** 20%-local-median rule — a simpler, fully deterministic approximation of the same intent (remove physiologically impossible beat-to-beat jumps before computing HRV). It does not model the missed/extra-beat insertion that Kubios does.

### API

```swift
HRVAnalyzer.analyze(_ rr: [RRInterval], windowStart: Int?, windowEnd: Int?) -> HRVResult
HRVAnalyzer.analyze(rawRR: [Double]) -> HRVResult
```

`HRVResult` carries `rmssd`, `sdnn`, `meanNN`, `pnn50`, plus `nInput` and `nClean` (counts before/after cleaning) for transparency.

---

## `RecoveryScorer` — the **Charge** score (transparent 0–100 recovery composite)

Source: `RecoveryScorer.swift`. Produces **Charge** — *"how recovered are you?"* A **z-score + logistic** composite, **led by your heart-rate variability (HRV) measured against your own personal baseline**, plus resting heart rate, last night's Rest, breathing rate, and a skin-temperature signal (an early illness / overreach flag). It is explicitly **approximate** and makes no claim to reproduce WHOOP's proprietary Recovery % model — same core idea (HRV-led recovery), but our weighting and baseline maths are our own and openly documented here.

### Weighting

Higher HRV versus your baseline means more Charge. Skin-temp folds in as a symmetric penalty: the further from baseline (in either direction), the less Charge, since a large deviation flags possible illness or overreach.

| Driver | Direction | Weight |
|---|---|---|
| HRV vs baseline | higher → more Charge | `wHRV = 0.55` (dominant) |
| Resting HR vs baseline | lower → more | `wRHR = 0.20` |
| Rest quality (sleep) | higher → more | `wSleep = 0.15` |
| Respiration vs baseline | lower → more | `wResp = 0.05` |
| Skin-temp deviation | further from baseline → less | `wSkinTemp = 0.05` |

The skin-temp term uses the absolute deviation already computed as `DailyMetric.skinTempDevC` (a z-like ±°C), entered as a symmetric penalty `−|dev|/scale`. SpO₂ folds in **only when real** (imported) as a small penalty below ~95%; it's never fabricated and never applied on a bare 5/MG day. HRV's weight dropped from `0.60` to `0.55` to make room for skin-temp; when skin-temp is absent the weights renormalize, so the score matches the older HRV-led composite.

Each metric is standardized to a **robust z-score** against the personal baseline (EWMA spread):

```
z = (value − mean) / (1.253 · spread)
```

The `1.253` converts an EWMA mean-absolute-deviation into an approximate Gaussian σ (`E[|X−μ|] = σ·√(2/π) ≈ σ/1.253`). For "lower is better" drivers (RHR, resp) the z is inverted by swapping value and mean. The sleep term is centered directly: `(sleepPerf − 0.85) / 0.12`.

Missing terms are dropped and weights renormalized. The weighted-mean z is squashed:

```
score = 100 / (1 + exp(−logisticK · (z − logisticZ0)))
        logisticK  = 1.6     (±2 z ≈ the full red–green band)
        logisticZ0 = −0.20   (anchors z = 0 → ~58 %)
```

The `58%` anchor matches WHOOP's published population-average recovery (`populationMean = 58.0`).

### Cold-start ("Calibrating")

HRV is the dominant driver, and NOOP needs a few nights to learn your personal baseline first. If that baseline isn't usable yet (`BaselineState.usable == false`, i.e. fewer than `minNightsSeed` valid nights), `recovery(...)` returns `nil` and the UI shows **"Calibrating"** — more honest than fabricating a number. Callers may fall back to `populationMean` but should flag it.

### Bands (`band(_:)`)

| Band | Range |
|---|---|
| red | `< 34` |
| yellow | `34 … 67` |
| green | `≥ 67` |

### Resting HR (`restingHR`)

"Lowest sustained HR" during the in-bed window = the **minimum of 5-minute non-overlapping bin means** of HR samples in `[start, end]`. This rejects single-beat dips while capturing the night's true floor.

---

## `StrainScorerV2` — Strain (0–21 display; 0–100 storage)

Source: `StrainScorerV2.swift`. Produces NOOP's transparent cardiovascular-and-movement load score. It is WHOOP-informed, not a reproduction of WHOOP's proprietary algorithm. Public APIs return the existing stored 0–100 value; every user-facing surface converts that value to the canonical 0–21 scale through `StrainScale`.

> **Versioning.** Legacy `StrainScorer` remains for rollback and shadow comparison during the V2 release window. Imported WHOOP strain is never recomputed.

### Pipeline

1. **Heart-rate reserve:** `HRR = HRmax − RHR`; manual HRmax wins, then Tanaka, while the cycle's nightly RHR wins over the fallback.
2. **Continuous intensity:** interpolate equivalent load/minute through `%HRR` anchors `30→0`, `40→0.05`, `60→0.20`, `70→0.45`, `80→0.70`, `90+→1.0`. There are no Edwards stair-step discontinuities.
3. **Timestamp integration:** integrate each adjacent real interval independently. Intervals over 90 seconds are missing coverage, not sustained exertion. A score needs at least 20 samples and ten valid minutes.
4. **Saturating display map:**

```
displayStrain = 21 · (1 − exp(−effectiveLoad / 32))
```

The curve approaches rather than targets 21. One hour at genuine Zone 5 with a normal sleep seed is about 18–19; multiple hours approach 21. Activity mode starts at zero. Physiological-day mode uses the main-sleep cycle and the non-additive background floors below.

### Steps / active-energy floor

A long walk with little cardio counts without double-counting its heart-rate response:

- Worn sleep contributes `0.014` effective minutes per valid sleep minute, capped at display Strain 4.0.
- Step floor: `7 × (1 − exp(−steps / 6000))`.
- Active-energy floor: `7 × (1 − exp(−activeKcal / 500))` when a true active-energy source is available. The current HR calorie estimate includes resting expenditure and is intentionally not used for this floor.
- Final physiological-day Strain is the maximum of the sleep-seeded cardiovascular score and available movement floors; floors are never added to cardio load.

Raw sleep-to-sleep step deltas are preferred. Wake-day steps are the lower-confidence fallback. Muscular load is not part of V2.

### HRmax estimation (`estimateHRmax`)

- With ≥ `hrmaxMinSamples = 600` HR samples, use the observed `99.5th` percentile (`"observed"`), unless a Tanaka estimate is higher.
- **Tanaka (2001):** `HRmax = 208 − 0.7 × age` (gender-independent), used as the floor / fallback (`"tanaka"`).
- No data and no age → `(0, "unknown")`.

### Cycle and guards

- Physiological days run main-sleep onset to next main-sleep onset; an open cycle ends at `now` and is stored on its wake-day key.
- Missing trustworthy sleep falls back to local midnight and building confidence.
- Invalid HRR, fewer than 20 samples, or under ten integrated minutes returns `nil` for cardiovascular load; valid sleep or movement evidence can still establish a background day score.

### Denominator calibration (`fitStrainDenominator`)

Given `(TRIMP, reference_strain)` pairs, fits `D` via a through-origin least-squares line in log-space: `ln(D) = maxStrain · Σx² / Σ(x·strain)`, `x = ln(TRIMP+1)`, where `maxStrain` is the full-scale value (now `100`, formerly `21`). Throws on fewer than 2 usable pairs.

---

## `SleepStager` — sleep/wake detection + approximate 4-class staging (feeds **Rest**)

Source: `SleepStager.swift`. Detects in-bed sessions from gravity/HR/RR/respiration and produces a 30-second hypnogram of `{wake, light, deep, rem}`. These stages and the AASM roll-up below are the raw material the **Rest** score composite consumes (see *The Rest score composite* immediately after this section).

> **Honest hedging.** These stages are **approximations**, not PSG-validated, not medical advice. The EEG-free 4-class ceiling is ~65–73% epoch agreement (Walch 2019). **Light/deep separation is the weakest link — deep-minute estimates are the least reliable output.**

### Stage 0 — gravity-stillness sleep/wake spine (`detectSleep`)

- Per-record movement proxy = L2 magnitude of the gravity-vector change vs the previous record (`gravityDeltas`).
- A sample is "still" if its delta < `gravityStillThresholdG = 0.01 g`. A rolling window (`stillWindowMin = 15` min) calls its center "sleep" when ≥ `stillFraction = 0.70` of samples are still.
- Contiguous runs are built, breaking on a class change or a data gap > `maxGapMin = 20` min; runs shorter than `mergeMin = 15` min are absorbed into neighbours.
- A run must exceed `minSleepMin = 60` min to count, and is **HR-confirmed**: mean HR over the run must be ≤ `hrSleepBaselineMult = 1.05 ×` the day's median HR (skipped when fewer than 30 HR samples — gravity is trusted alone).
- A citable **te Lindert 30 s Cole–Kripke** index (`SI = 0.001 · Σ wᵢ·Aᵢ`, sleep iff `SI < 1`, weights `[106, 54, 58, 76, 230, 74, 67]`) is computed per epoch as a cross-check and to find onset / final-wake.

### Stage 1 — per-epoch cardiorespiratory features

Over a rolling 5-minute window per 30 s epoch:

- mean HR;
- **Walch difference-of-Gaussians HR variability** (`σ1 = 120 s` minus `σ2 = 600 s`, reflect-padded convolution; NaNs linearly interpolated);
- **RMSSD / SDNN** from range-filtered R-R (`HRVAnalyzer.rmssdRaw` / `sdnnRaw`);
- **respiration rate + RRV** from the raw 1 Hz resp channel via a simple peak detector (detrend → local-maxima peaks ≥ 2 s apart → breath intervals 1.5–12 s → rate = `60 / median interval`, RRV = std of intervals).

> Frequency-domain HRV (HF, LF/HF) is **omitted** — there is no neurokit2/scipy on-device — so the parasympathetic-tone signal is **RMSSD only**. The respiration peak-finder is a faithful port (the reference derived these "robustly ourselves" too, without neurokit).

### Stage 2 — percentile-band classifier (`classifyOne`)

Reference distributions are taken over the session's **sleep-period** epochs (Cole–Kripke = sleep). A motion fraction and the per-epoch features are compared against session-relative percentiles:

| Class | Rule |
|---|---|
| **wake** | sustained motion (`moveFrac ≥ 0.15`) **and** activated cardiac (high HR or high DoG-HR variability), or no HR to vet the motion |
| **deep** | still (`moveFrac ≤ 0.10`) **and** high parasympathetic tone (RMSSD ≥ 70th pct) **and** low HR (≤ 25th pct) **and** regular respiration |
| **rem** | still body **and** activated cardiac **and** irregular respiration (RRV ≥ 65th pct); a fallback requires both cardiac signals when respiration is unavailable |
| **light** | everything else (the default) |

### Stage 3 — smoothing + physiology re-imposition

- 5-epoch **median smoothing** of the label sequence (`smoothLabels`).
- **No REM in the first 15 min** after onset (`reimposePhysiology` → demote to light).
- **No deep after the first third** of the night (deep is biased early) → demote to light.
- Pre-onset and post-final-wake epochs are forced to `wake`.

Consecutive same-stage epochs are merged into `StageSegment`s tiling `[start, end]`.

### Outputs

- `SleepSession` — `start`, `end`, `efficiency` (AASM `asleep / in-bed`, where `asleep = in-bed − wake`), `stages`, per-session `restingHR` (lowest 5-min rolling-mean HR) and `avgHRV` (mean RMSSD over 5-min tumbling windows).
- `hypnogramMetrics(_:)` — AASM-style roll-up: TIB / TST / SPT / SOL / REM latency / WASO / efficiency / disturbances, plus deep/REM/light minutes and percentages.

---

## The **Rest** score composite — *"how restorative was your sleep?"*

Source: assembled in `AnalyticsEngine` from the `SleepStager` outputs above. Rest is a 0–100 composite that **replaces the older bare-efficiency proxy** for the `sleep_performance` key. It blends four components:

| Component | Weight | What it measures |
|---|---|---|
| Duration vs personal need | 0.50 (biggest factor) | how long you slept against your own sleep need |
| Efficiency (asleep / in-bed) | 0.20 | how efficiently you slept |
| Restorative share (deep + REM) / asleep | 0.20 | how much of the night was restorative |
| Consistency (sleep/wake regularity) | 0.10 | how consistent your sleep and wake timing is |

- **Personal sleep need:** 8 h default, refined by your recent average; the hours-vs-need term clamps at 100.
- Rest consumes whatever stages each device provides (v25 motion on 4.0; PPG/IMU on 5/MG as it unlocks) — the sleep-staging algorithm itself is unchanged.
- The `sleep_performance` key now stores this 0–100 composite. The **Charge** "Rest quality" driver reads it (÷100) instead of raw efficiency.

This composite is similar *in spirit* to WHOOP's Sleep Performance %, but the blend is our own.

---

## `Baselines` — personal rolling baselines

Source: `Baselines.swift`. Per-metric personal baselines that `RecoveryScorer` consumes. Two interchangeable paths produce the same `BaselineState` shape.

### 1. Winsorized EWMA (production model — `update` / `foldHistory`)

A robust, recency-weighted center with an EWMA-of-absolute-deviation spread tracker:

- **Half-life → smoothing factor:** `λ = 1 − 0.5^(1/halfLife)`. Center half-life 14 nights; spread half-life 21 (slower).
- **Sanity gate:** values outside `[minVal, maxVal]` (per-metric) → skip-and-hold.
- **Hard outlier rejection:** once seeded, a value > `hardOutlierK = 5 ×` spread away is seen but not folded.
- **Winsor clamp:** fold only within `± winsorK = 3 ×` spread of the current baseline, so a single big night can't yank the center; the **spread** uses the unclamped deviation so real change is still tracked.

```swift
let clamped = max(lo, min(hi, value))                       // ±3·spread
let newBaseline = lb * clamped + (1 - lb) * state.baseline
let newSpread   = max(cfg.floorSpread, ls * abs(value - newBaseline) + (1 - ls) * state.spread)
```

### 2. Trailing-window mean/SD (`rollingMeanSD`)

The simple, maximally auditable path: plain mean and sample SD (ddof = 1) over the trailing N (default 30) valid nights, with the σ floor applied and converted back into abs-dev space (`÷ 1.253`) so `deviation()` recovers the intended Gaussian σ unchanged.

### Status lifecycle (`BaselineStatus`)

| Status | Condition |
|---|---|
| `calibrating` | fewer than `minNightsSeed = 4` valid nights (no score yet) |
| `provisional` | `4 … 13` valid nights (usable, higher uncertainty) |
| `trusted` | ≥ `minNightsTrust = 14` valid nights |
| `stale` | usable but no update for > `staleDays = 14` nights |

### Per-metric config (`metricCfg`)

| Metric | min | max | floor spread | center / spread half-life |
|---|---|---|---|---|
| `hrv` | 5 | 250 | 5.0 | 14 / 21 |
| `resting_hr` | 30 | 120 | 2.0 | 14 / 21 |
| `resp` | 4 | 40 | 0.5 | 14 / 21 |
| `skin_temp` | 20 | 42 | 0.3 | 14 / 21 |

### Deviation

`deviation(_:state:)` returns a robust z-score, a signed physical-units delta, a fractional ratio (`value/baseline − 1`), and an `inNormalRange` flag (`|z| ≤ 1`).

---

## `WorkoutDetector` + `Calories` — retroactive workout detection

Source: `WorkoutDetector.swift`. Finds workouts in the stored 1 Hz HR + gravity streams (no manual logging).

A workout is a **sustained window** (≥ `minExerciseMin = 5` min) where **both** gates hold per sample:

- **Elevated HR** — above `RHR + hrMarginBPM (15 bpm)`. RHR defaults to the day's 10th-percentile HR.
- **Sustained motion** — gravity-derived intensity (10-second trailing mean) above `motionThreshold = 0.20`.

Active samples are grouped into runs (merging gaps < `mergeGapS = 150 s`), then qualified by intensity: ≥ `minIntensityZ2Plus = 0.50` of the bout in Edwards zone 2+. Per bout it reports avg/peak HR, duration, Edwards zone-time %, mean `%HRR`, strain (via `StrainScorer`), and calories.

### Calories (`Calories.estimateBoutCalories`)

Per-second blend of **Keytel (2005)** active expenditure and **revised Harris–Benedict** BMR (resting), with sex-specific coefficients (`male` / `female` / `nonbinary`). Below a `RHR + 0.30 × HRR` threshold the resting rate is used; above it, the HR-driven active rate. Returns `(kcal, kJ)`. **Approximate** — not laboratory calorimetry.

---

## Interactive engines (wired into screens)

These are the **live** data-interrogation engines, used by `InsightsView`, `CompareView`, and `MetricExplorerView`.

### `CorrelationEngine`

Source: `CorrelationEngine.swift`. Pearson r, OLS regression, and an approximate two-sided p-value between two daily series.

```
r         = Σ(x−x̄)(y−ȳ) / sqrt( Σ(x−x̄)² · Σ(y−ȳ)² )
slope     = Σ(x−x̄)(y−ȳ) / Σ(x−x̄)²          (OLS, y on x)
intercept = ȳ − slope·x̄
t         = r · sqrt( (n−2) / (1−r²) )
p         = 2·(1 − Φ(|t|))                  (normal approximation)
```

- Returns `nil` for fewer than 3 pairs or zero variance in either variable.
- Φ uses the Abramowitz & Stegun 7.1.26 `erf` approximation. The normal approximation slightly **understates** p for small n (true Student-t tails are heavier) but is fully deterministic with no special-function tables.
- `alignByDay(...)` inner-joins two `yyyy-MM-dd`-keyed series; `lagged(x:y:lagDays:)` shifts y forward by `lagDays` (UTC day arithmetic) to probe directional/delayed effects — e.g. *today's strain vs tomorrow's recovery*.

### `BehaviorInsights`

Source: `BehaviorInsights.swift`. The headline "does this behavior move an outcome?" feature. Splits days where a behavior was logged (e.g. *Alcohol*, *Late meal*, *Meditation*) from days it was not, and compares an outcome metric between the groups.

For each behavior/outcome it reports group means, signed `delta`, `pctChange`, **Cohen's d** (pooled SD), and a **Welch t-test** p-value (unequal variances, Welch–Satterthwaite df, normal-approx tail):

```
sp = sqrt( ((n1−1)·s1² + (n2−1)·s2²) / (n1+n2−2) )     d = (m1 − m2) / sp
t  = (m1 − m2) / sqrt(s1²/n1 + s2²/n2)
```

- `significant` requires `p < 0.05` **and** `min(nWith, nWithout) ≥ 5` (guards against spurious "significance" from a handful of days).
- `rank(...)` orders effects by `|d|` descending, significant first.
- `sentence(_:)` renders plain English, e.g. *"On days you logged 'Alcohol', Charge was 12% lower (avg 61 vs 69, n=140 vs 498)."*

### `ComparisonEngine`

Source: `ComparisonEngine.swift`. Period-over-period comparison of one daily metric.

- `stat(_:)` → `SeriesStat`: mean, median, min, max, sample SD (ddof = 1), n, and least-squares slope-per-day (OLS against the 0-based index).
- `compare(current:previous:)` → `PeriodComparison`: signed `delta` on the means, `pctChange` (nil when the previous mean is 0/empty), and a coarse `direction` (`-1/0/+1`).
- `monthOverMonth(byDay:referenceDay:)` splits a `yyyy-MM-dd` series on the `yyyy-MM` prefix (locale/timezone-free) into the reference month vs the immediately preceding calendar month.

---

## The library orchestrator: `AnalyticsEngine`

Source: `AnalyticsEngine.swift`. A pure function that ties the recompute engines together for one day, producing the three daily scores — **Charge** (recovery), **Effort** (strain), **Rest** (sleep). **Live:** `analyzeDay` is wired in via `Strand/Data/IntelligenceEngine.swift` — it runs every ~15 minutes while connected and on demand from the Intelligence screen, persisting the computed Charge/Effort/Rest/workouts under the `"<deviceId>-noop"` source and **merged under** imports. Where a WHOOP export covers a day, its own per-day numbers still win; the recompute fills in the days the strap offloaded but no export covers.

`analyzeDay(day:hr:rr:resp:gravity:profile:baselines:maxHROverride:)` runs, in order:

1. `SleepStager.detectSleep` → keep sessions whose `end` falls on `day` (UTC) — a night ending that morning.
2. Daily sleep aggregates (in-bed-weighted efficiency; deep/REM/light minutes; disturbances) via `hypnogramMetrics`.
3. Daily resting HR = lowest per-session resting HR; daily avg HRV = in-bed-weighted mean of per-session HRV.
4. **Rest** — the four-component sleep composite (duration vs need / efficiency / restorative share / consistency), stored under `sleep_performance`.
5. **Charge** — `RecoveryScorer.recovery(...)` with the personal HRV/RHR/resp/skin-temp baselines and the Rest score as the sleep input, stored under `recovery`.
6. **Strain** — `StrainScorerV2.strain(...)` over the sleep-to-sleep cycle with timestamp-aware HRR integration plus non-additive sleep/step floors. The 0–21 result is converted at the storage boundary and written to `strain_v2_shadow` until promotion gates pass.
7. `WorkoutDetector.detect(...)`.

Each score is also tagged with its **confidence tier** (`ScoreConfidence`: Solid / Building / Calibrating — see below). It assembles a `DailyMetric` (the `WhoopStore` cache shape) plus rich `SleepSession`s and `CachedSleepSession` cache rows. Every derived value is **approximate** by construction.

### Score confidence (`ScoreConfidence`)

Each score carries a small honesty label so a sparse day reads truthfully:

| Tier | Meaning |
|---|---|
| **Calibrating** | NOOP is still learning your baseline, or doesn't have enough data yet (baseline not usable for Charge; no in-bed data for Rest; no HR window for Effort). |
| **Building** | Enough to show, but thin (e.g. fewer than ~7 nights of baseline, or a 5/MG day backed mostly by PPG-derived HR). |
| **Solid** | Full inputs present. |

When NOOP can't compute a score honestly it shows **nothing** rather than a fake number.

### Imported-strain rescale

Imported WHOOP "Day Strain" is on WHOOP's 0–21 scale. To keep the Effort axis consistent, the importer (`WhoopExportImporter`) **rescales at import**: an imported Day Strain is multiplied by `100/21` when writing the `strain` metric series, so everything stored under `strain` is on the 0–100 Effort scale (a lossless round-trip — the CSV export down-converts back to 0–21).

---

## Data flow summary

```
WHOOP strap (BLE) ─┐
                   ├─► WhoopProtocol (frame decode) ─► WhoopStore (SQLite, 1 Hz streams)
WHOOP CSV export ──┤                                         │
Apple Health XML ──┘                                         │
                                                             ▼
   importers copy per-day recovery / strain / sleep ──► DailyMetric (metrics cache)
                                                             │
                          ┌──────────────────────────────────┤
                          ▼                                   ▼
   IntelligenceEngine ─► AnalyticsEngine.analyzeDay   Repository.days ─► TodayView,
   (live recompute: HRV + Charge/Effort/Rest +        InsightsView (CorrelationEngine,
   workouts from raw streams, every ~15 min +         BehaviorInsights), CompareView,
   Intelligence screen; persisted under the           MetricExplorerView (ComparisonEngine)
   "<deviceId>-noop" source, merged UNDER imports)

   live BLE stream ─► AppModel: HR smoothing · RMSSD · zone coaching ·
                       illness early-warning · resting-stress nudge
```

---

## Conventions & honesty notes

- **Approximate by design.** Charge, Effort, Rest (and sleep stages, workout intensity, calories) are transparent approximations of published methods — not reproductions of any proprietary algorithm. They're **independent approximations from a consumer strap, built on open science — not medical advice, and not WHOOP's official scores.** Each engine's source header states exactly where it approximates (e.g. Malik instead of Kubios; RMSSD-only parasympathetic tone; normal-approx p-values).
- **One scale, honest about certainty.** All three scores are 0–100 and each rides a Solid / Building / Calibrating confidence tier; a score that can't be computed honestly shows nothing rather than a number.
- **Deterministic.** No randomness, no wall-clock dependence inside the math, no DB/network access. Same inputs → same outputs, which makes the package unit-testable against fixed vectors.
- **Robust statistics.** z-scores use EWMA mean-absolute-deviation (`× 1.253` to a Gaussian σ); resting HR uses 5-minute bin minima; HR display uses windowed medians — all chosen to resist single-sample outliers.
- **Cold-start honesty.** When a baseline isn't trustworthy yet, the recovery scorer returns `nil` rather than a fabricated number.
- **Not a medical device.** None of this is diagnostic or medical advice. The illness early-warning is a wellness nudge from your own baselines, not a clinical screen.
- **Not affiliated with WHOOP.** NOOP interoperates with hardware and exports you already own, entirely on-device. Protocol decoding builds on community reverse-engineering of the WHOOP 4.0 (project *my-whoop*, `johnmiddleton12/my-whoop`) and WHOOP 5.0 (project *goose*, `b-nnett/goose`) protocols.
