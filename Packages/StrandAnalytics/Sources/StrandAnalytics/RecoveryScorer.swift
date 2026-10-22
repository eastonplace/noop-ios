import Foundation
import WhoopProtocol

// RecoveryScorer.swift — resting HR during sleep + a transparent 0–100 recovery score.
//
// Ported from server/ingest/app/analysis/recovery.py.
//
// recovery() is a z-score + logistic composite. It is APPROXIMATE — not
// WHOOP-identical (WHOOP's model is proprietary). It is a transparent,
// HRV-dominant, baseline-normalized proxy.
//
// Weighting (documented, grounded, explainable; this is "Charge" in the UI):
//   higher HRV vs baseline       → higher recovery  (W_HRV       = 0.55, dominant)
//   lower resting HR vs baseline → higher recovery  (W_RHR       = 0.20)
//   higher rest quality (sleep)  → higher recovery  (W_SLEEP     = 0.15)
//   lower resp vs baseline       → higher recovery  (W_RESP      = 0.05)
//   skin-temp deviation from 0   → lower recovery   (W_SKIN_TEMP = 0.05)
//
// The Charge/Effort/Rest redesign folds skin temperature in (illness/overreach
// signal): HRV dropped 0.60 → 0.55 to make room for W_SKIN_TEMP = 0.05. The
// skin-temp term is a SYMMETRIC penalty on the ±°C deviation (−|dev|/scale), so any
// drift away from the personal baseline — hot or cold — lowers Charge. It is added
// ONLY when a skin-temp deviation is supplied; when nil the term drops and the
// weights renormalize, leaving the no-skin-temp score IDENTICAL to before.
//
// Each metric is standardized to a robust z-score against the personal baseline
// (mean + EWMA-abs-dev spread). Missing terms are dropped and the weights
// renormalized. The composite z is squashed through a logistic anchored so that
// Z = 0 → ~58% (WHOOP's published population-average recovery).
//
// Cold-start: if the HRV baseline (dominant driver) is not yet usable
// (< MIN_NIGHTS_SEED valid nights), recovery() returns nil. Callers may use
// RECOVERY_POPULATION_MEAN (58.0) as a fallback but should flag it.

public enum RecoveryScorer {

    // MARK: - Constants (recovery.py)

    public static let wHRV: Double = 0.55
    public static let wRHR: Double = 0.20
    public static let wResp: Double = 0.05
    public static let wSleep: Double = 0.15
    /// Skin-temperature deviation weight (Charge/Effort/Rest redesign). HRV gave up
    /// 0.05 (0.60 → 0.55) to fund it.
    public static let wSkinTemp: Double = 0.05

    /// Skin-temp penalty scale (°C): a 1 °C deviation from baseline costs ≈1 z-unit of
    /// penalty before weighting. Symmetric — sign of the deviation does not matter.
    public static let skinTempScaleC: Double = 1.0

    /// Logistic spread: ±2 z-units ≈ full Red–Green band (15%–95%).
    public static let logisticK: Double = 1.6
    /// Logistic offset so Z=0 → 58%.
    public static let logisticZ0: Double = -0.20
    /// WHOOP-published population-average recovery (%). Cold-start fallback.
    public static let populationMean: Double = 58.0

    /// Recovery band thresholds (WHOOP color scheme).
    public static let bandRedMax: Double = 34.0
    public static let bandYellowMax: Double = 67.0

    /// Sleep-performance center ("good night" at ~85% efficiency).
    public static let sleepPerfCenter: Double = 0.85
    /// Sleep-performance scale (±2 z spans the normal range).
    public static let sleepPerfScale: Double = 0.12

    /// Rolling-mean HR window (seconds) for the resting-HR estimate.
    public static let restingHRWindowS: Int = 5 * 60

    /// Minimum HR samples a 5-min bin must hold before its mean is eligible to WIN the resting
    /// floor (#686). A thinly-populated bin — at the limit a single lone beat — lets one artifact
    /// (a dropout, a decode glitch) become the bin "mean" and win the night's minimum, dragging
    /// resting HR implausibly low. Requiring a handful of samples means the floor is a genuine
    /// sustained dip, not a one-sample fluke. Worn nights stream ~1 Hz HR so a real 5-min bin holds
    /// hundreds of samples and clears this trivially; only sparse/edge bins (a partial trailing bin,
    /// a gap-straddling bin) fall below it. Does NOT change the floor DEFINITION — still the min of
    /// 5-min bin means — it only stops an under-sampled artifact bin from being that min.
    public static let restingHRMinBinSamples: Int = 5

    /// Physiological resting-HR floor (bpm) below which a bin mean is rejected as a dropout artifact
    /// (#686), never the resting floor. An adult's true sleeping resting HR essentially never sits
    /// below this; a 5-min mean that does is a run of dropout/decode-zero beats, not a real cardiac
    /// dip. 25 bpm clears even deeply-bradycardic trained athletes (resting HRs in the low 30s) with
    /// margin while rejecting the implausible artifact range. A bin below this is excluded from floor
    /// candidacy; if it were allowed to win, resting HR would read a fabricated sub-physiological value.
    public static let restingHRMinPlausibleBpm: Double = 25.0

    // MARK: - Resting HR

    /// Lowest sustained HR during the in-bed window (bpm, rounded), or nil.
    ///
    /// "Sustained" = the minimum of 5-minute non-overlapping bin means of the HR
    /// samples whose ts ∈ [start, end]. Rejects single-beat dips while capturing
    /// the night's true floor. Only `HRValidity`-plausible readings count; returns nil when the window
    /// has no usable HR, including an off-wrist stream of zero readings.
    ///
    /// Artifact hardening (#686): a bin may only WIN the floor when it is BOTH well-populated
    /// (≥ `restingHRMinBinSamples`, so one lone artifact beat can't be a bin "mean") AND
    /// physiologically plausible (mean ≥ `restingHRMinPlausibleBpm`, rejecting dropout-driven
    /// sub-physiological dips). The floor DEFINITION is unchanged — still the minimum of the
    /// 5-min bin means — only artifact bins are barred from being that minimum. If no bin
    /// qualifies (a wholly sparse/degenerate window), fall back to the lowest of ALL bin means,
    /// else the all-sample mean, preserving the never-nil-on-data behaviour.
    public static func restingHR(_ hr: [HRSample], start: Int, end: Int) -> Int? {
        // AN-06: this is THE resting-HR kernel. `SleepStager.sessionRestingHR` (the shipped
        // DailyMetric.restingHr) and `SleepWindowRecovery` call it, so the #686 gates protect production.
        guard let span = SleepTimestampMath.nonnegativeDuration(start: start, end: end) else { return nil }
        // One forward pass over the time-ordered in-window slice. Production passes ts-sorted streams, so
        // the sort is skipped after an O(n) check.
        var seg = hr.filter { $0.ts >= start && $0.ts <= end && HRValidity.isPlausible($0.bpm) }
        guard !seg.isEmpty else { return nil }
        if !zip(seg, seg.dropFirst()).allSatisfy({ $0.ts <= $1.ts }) { seg.sort { $0.ts < $1.ts } }

        var lowestMean: Double?        // every bin mean (legacy floor, the fallback)
        var lowestQualified: Double?   // bins eligible to WIN the floor (#686)
        var bin = -1, binSum = 0, binCount = 0
        func closeBin() {
            guard binCount > 0 else { return }
            let mean = Double(binSum) / Double(binCount)
            lowestMean = min(lowestMean ?? mean, mean)
            // A bin wins the floor only if it is well-populated AND physiologically plausible — a thin
            // (single-artifact) or sub-physiological (dropout) bin can't be the minimum.
            if binCount >= restingHRMinBinSamples && mean >= restingHRMinPlausibleBpm {
                lowestQualified = min(lowestQualified ?? mean, mean)
            }
        }
        var totalSum = 0
        for sample in seg {
            totalSum += sample.bpm
            let offset = sample.ts - start
            // Bins start at `start + k·window` and only while the bin start is before `end`; a sample at
            // exactly `end` on a bin boundary belongs to no bin (it still counts in the all-sample mean).
            guard offset < span || span % restingHRWindowS != 0 else { continue }
            let index = offset / restingHRWindowS
            if index != bin { closeBin(); bin = index; binSum = 0; binCount = 0 }
            binSum += sample.bpm
            binCount += 1
        }
        closeBin()
        let floor = lowestQualified ?? lowestMean ?? Double(totalSum) / Double(seg.count)
        return Int(floor.rounded())
    }

    // MARK: - Recovery band

    /// WHOOP-style color band for a recovery score [0, 100].
    public static func band(_ score: Double) -> String {
        if score < bandRedMax { return "red" }
        if score < bandYellowMax { return "yellow" }
        return "green"
    }

    // MARK: - Cold-start calibration progress

    /// The recovery baseline's real seed count while it still cold-starts — the honest
    /// "Calibrating — N of <seed> nights" progress the dashboard shows in place of a bare empty state;
    /// nil once recovery exists or the baseline has crossed the seed gate. N is the HRV baseline's
    /// `nValid` from folding the SAME day-keyed, epoch-aware history the recovery engine folds
    /// (`Baselines.foldHistory(_:dayKeys:cfg:baselineEpoch:)`), NOT a looser per-night bounds count.
    ///
    /// The old count advanced on every in-range night, including nights the engine's fold DROPS after a
    /// manual "Recalibrate HRV baseline" (each night dated before the epoch is discarded, not
    /// skip-and-held). A genuinely-calibrating user who had ≥ seed old in-range nights therefore read
    /// `count ≥ seed → nil` here, and the Today score side fell through to "Needs the strap" while the
    /// post-recalibration baseline was still seeding (Bug B, #393 follow-up). `nValid` is the exact count
    /// `Baselines.computeStatus` gates CALIBRATING on, so N now tracks the baseline the Charge ring rides
    /// and can never over-state it. Never claims "calibrating" at/above the seed gate (a nil recovery
    /// there is some other gap). N counts the nights before the newest day, the baseline that day is
    /// scored against (AN-01). `baselineEpoch` nil reads the persisted HRV epoch from UserDefaults,
    /// exactly like the engine's fold. Mirrors Android TodayScreen.recoveryCalibrationNights
    /// (RecoveryCalibrationTest is the oracle).
    public static func calibrationNights(nightlyHrv: [Double?],
                                         dayKeys: [String],
                                         hasRecovery: Bool,
                                         seed: Int = Baselines.minNightsSeed,
                                         cfg: MetricCfg = Baselines.hrvCfg,
                                         baselineEpoch: Double? = nil) -> Int? {
        guard !hasRecovery else { return nil }
        // AN-01: the newest day is scored against the nights strictly before it, so its own night
        // doesn't count toward its seed.
        guard let newest = dayKeys.max() else { return 0 }
        let n = Baselines.foldHistoryAsOf(nightlyHrv, dayKeys: dayKeys, cfg: cfg,
                                          baselineEpoch: baselineEpoch).asOf(newest).nValid
        // Include 0: a brand-new user (no banked nights yet) should read "Calibrating — 0 of N" on the
        // Charge ring, not a bare "No data" that looks broken (#335). Past days are gated to nil by the
        // caller; >= seed (recovery should exist) still returns nil.
        return (0..<seed).contains(n) ? n : nil
    }

    // MARK: - Recovery score

    /// A baseline driver: mean + spread (internal abs-dev units, as in BaselineState).
    public struct DriverBaseline: Equatable, Sendable {
        public let mean: Double
        public let spread: Double
        public init(mean: Double, spread: Double) {
            self.mean = mean; self.spread = spread
        }
        public init(_ state: BaselineState) {
            self.mean = state.baseline; self.spread = state.spread
        }
    }

    /// Robust z-score using EWMA spread: (value − mean) / (1.253 × spread).
    static func zScore(_ value: Double, mean: Double, spread: Double) -> Double {
        let sigma = max(1.253 * spread, 1e-9)
        return (value - mean) / sigma
    }

    /// Z-score + logistic recovery score in [0, 100]. APPROXIMATE.
    ///
    /// Returns nil when the HRV baseline (dominant driver) is not yet usable, or
    /// no valid driver is available at all.
    ///
    /// - Parameters:
    ///   - hrv: tonight's HRV (RMSSD, ms).
    ///   - rhr: tonight's resting HR (bpm).
    ///   - resp: tonight's respiration (raw or calibrated — z is scale-invariant);
    ///           nil drops the term.
    ///   - hrvBaseline: HRV baseline (required for a score).
    ///   - rhrBaseline: resting-HR baseline; nil drops the RHR term.
    ///   - respBaseline: respiration baseline; nil drops the resp term.
    ///   - sleepPerf: Rest quality (Rest composite ÷100, 0..1; was raw efficiency);
    ///     nil drops the term.
    ///   - skinTempDev: skin-temperature deviation from the personal baseline (±°C,
    ///     `DailyMetric.skinTempDevC`). Entered as a SYMMETRIC penalty −|dev|/scale,
    ///     weight wSkinTemp. nil drops the term and the weights renormalize so the
    ///     no-skin-temp score is identical to before.
    ///   - hrvBaselineUsable: whether the HRV baseline has enough nights
    ///     (BaselineState.usable). When false, returns nil (cold-start).
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: DriverBaseline?,
                                rhrBaseline: DriverBaseline?,
                                respBaseline: DriverBaseline?,
                                sleepPerf: Double?,
                                skinTempDev: Double? = nil,
                                hrvBaselineUsable: Bool = true) -> Double? {
        // Cold-start gate: HRV is the dominant driver; if its baseline isn't
        // usable, refuse to score (more honest than a fabricated value).
        if !hrvBaselineUsable { return nil }

        var terms: [(z: Double, w: Double)] = []

        // HRV term: higher is better.
        if let b = hrvBaseline {
            terms.append((zScore(hrv, mean: b.mean, spread: b.spread), wHRV))
        }
        // RHR term: lower is better → (μ − x) / σ.
        if let b = rhrBaseline {
            terms.append((zScore(b.mean, mean: rhr, spread: b.spread), wRHR))
        }
        // Resp term: lower is better, optional.
        if let r = resp, let b = respBaseline {
            terms.append((zScore(b.mean, mean: r, spread: b.spread), wResp))
        }
        // Sleep-performance / Rest-quality term: no baseline needed; centered at SLEEP_PERF_CENTER.
        if let sp = sleepPerf {
            terms.append(((sp - sleepPerfCenter) / sleepPerfScale, wSleep))
        }
        // Skin-temp term: SYMMETRIC penalty on |deviation| (illness/overreach). Any
        // drift from the personal baseline lowers Charge; added only when supplied.
        if let dev = skinTempDev {
            terms.append((-abs(dev) / skinTempScaleC, wSkinTemp))
        }

        guard !terms.isEmpty else { return nil }
        let totalWeight = terms.reduce(0) { $0 + $1.w }
        guard totalWeight > 0 else { return nil }

        let z = terms.reduce(0) { $0 + $1.z * $1.w } / totalWeight
        let score = 100.0 / (1.0 + exp(-logisticK * (z - logisticZ0)))
        return max(0.0, min(100.0, score))
    }

    /// Convenience overload taking BaselineState directly. HRV must be usable for a score;
    /// unusable optional personal baselines are omitted before weight renormalization.
    public static func recovery(hrv: Double,
                                rhr: Double,
                                resp: Double?,
                                hrvBaseline: BaselineState,
                                rhrBaseline: BaselineState?,
                                respBaseline: BaselineState?,
                                sleepPerf: Double?,
                                skinTempDev: Double? = nil) -> Double? {
        recovery(hrv: hrv,
                 rhr: rhr,
                 resp: resp,
                 hrvBaseline: DriverBaseline(hrvBaseline),
                 rhrBaseline: rhrBaseline.flatMap { $0.usable ? $0 : nil }.map(DriverBaseline.init),
                 respBaseline: respBaseline.flatMap { $0.usable ? $0 : nil }.map(DriverBaseline.init),
                 sleepPerf: sleepPerf,
                 skinTempDev: skinTempDev,
                 hrvBaselineUsable: hrvBaseline.usable)
    }
}
