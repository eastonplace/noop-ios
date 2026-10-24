import Foundation

// EffectRanker.swift — the unified "what moves your outcomes" ranker.
//
// Pure, deterministic, DB-free. Compares the days a factor held (Journal "yes" answers or an
// automatically detected factor) with the days it did not, against each daily outcome.
//
// FIXED LAG. Each test uses one lag chosen up front, never the best of several. Both the Journal
// and AutoFactors key a behaviour under the morning it affects (an evening on day D is stored
// under D+1), so the default lag is 0: the factor's key IS the outcome day. Searching lags
// {0, 1, 2} and keeping the largest |d| (the old behaviour) tripled the comparisons and inflated
// every effect it reported.
//
// FAMILY CORRECTION. `rankFamily` runs every factor x outcome test together and adjusts the
// p-values with Benjamini–Hochberg (MultipleComparisons), so adding factors does not add false
// positives. A row is significant only when its adjusted p is below BehaviorInsights.alpha and
// both sides clear the 5-day group gate.
//
// HONESTY: effect size, day counts and a ScoreConfidence tier come first; association, not cause.

// MARK: - Result

/// One ranked behaviour→outcome effect at a fixed lag, with a confidence tier from the
/// paired-day count and, when ranked as a family, its adjusted p-value.
public struct RankedEffect: Equatable, Sendable {
    /// The behaviour label (e.g. "Alcohol").
    public let behavior: String
    /// The outcome metric label (e.g. "Charge").
    public let outcome: String
    /// The fixed lag (in days) between the factor's key and the outcome day: 0 = the same key
    /// (the morning a Journal answer or AutoFactor is stored under), +1 = the morning after.
    public let lag: Int
    /// The measured effect at `lag` (means, delta, Cohen's d, Welch p, significant).
    public let effect: BehaviorEffect
    /// Per-result certainty tier from the smaller group's size at the chosen lag.
    public let confidence: ScoreConfidence
    /// Benjamini–Hochberg adjusted p-value across the family this row was ranked in, or nil
    /// when the row was ranked on its own (`rank`).
    public let adjustedP: Double?

    public init(behavior: String, outcome: String, lag: Int,
                effect: BehaviorEffect, confidence: ScoreConfidence, adjustedP: Double? = nil) {
        self.behavior = behavior
        self.outcome = outcome
        self.lag = lag
        self.effect = effect
        self.confidence = confidence
        self.adjustedP = adjustedP
    }

    /// Significant after the family correction when there was one, else the raw per-test flag.
    public var isSignificant: Bool {
        guard let q = adjustedP else { return effect.significant }
        return q < BehaviorInsights.alpha
            && Swift.min(effect.nWith, effect.nWithout) >= BehaviorInsights.minGroupForSignificance
    }

    /// Plain-English lead/lag chip text, e.g. "same day" / "next morning" / "2 mornings later".
    public var leadLagText: String {
        switch lag {
        case 0: return "same day"
        case 1: return "next morning"
        default: return "\(lag) mornings later"
        }
    }

    /// The sign-aware sentence for this row, reusing BehaviorInsights' renderer plus the
    /// lead/lag clause so each card reads "…, showing up the next morning."
    public func sentence() -> String {
        let base = BehaviorInsights.sentence(effect)
        // Drop the trailing period, append the lead/lag, restore it.
        let trimmed = base.hasSuffix(".") ? String(base.dropLast()) : base
        return "\(trimmed) (\(leadLagText))."
    }
}

// MARK: - Engine

public enum EffectRanker {

    /// The lag every test uses unless the caller says otherwise. Factors are keyed by the
    /// morning they affect, so 0 pairs each factor day with that morning's outcome.
    public static let defaultLag: Int = 0

    /// Paired-day count below which confidence is `.calibrating` (too thin to shout). This equals
    /// BehaviorInsights' significance group gate, so a row that clears the gate is never `.calibrating`.
    public static let calibratingBelow: Int = BehaviorInsights.minGroupForSignificance  // 5
    /// Paired-day count at/above which confidence is `.solid` (else `.building`).
    public static let solidPairs: Int = 10

    /// One factor x outcome test for `rankFamily`.
    public struct FactorTest: Sendable {
        public let behavior: String
        public let yesDays: Set<String>
        public let noDays: Set<String>
        public let outcome: String
        public let outcomeByDay: [String: Double]
        public let lag: Int

        public init(behavior: String, yesDays: Set<String>, noDays: Set<String>,
                    outcome: String, outcomeByDay: [String: Double], lag: Int = EffectRanker.defaultLag) {
            self.behavior = behavior
            self.yesDays = yesDays
            self.noDays = noDays
            self.outcome = outcome
            self.outcomeByDay = outcomeByDay
            self.lag = lag
        }
    }

    // MARK: - Rank

    /// Rank every behaviour against one outcome at one fixed lag. Rows are uncorrected
    /// (`adjustedP == nil`); use `rankFamily` when several tests are shown together.
    public static func rank(behaviors: [String: Set<String>],
                            controls: [String: Set<String>],
                            outcomeByDay: [String: Double],
                            outcome: String,
                            lag: Int = defaultLag) -> [RankedEffect] {
        var rows: [RankedEffect] = []
        for name in behaviors.keys.sorted() {
            if let row = effect(behaviorDays: behaviors[name]!,
                                controlDays: controls[name] ?? [],
                                outcomeByDay: outcomeByDay,
                                behavior: name, outcome: outcome, lag: lag) {
                rows.append(row)
            }
        }
        return sorted(rows)
    }

    /// Run a whole family of tests, adjust their p-values together (Benjamini–Hochberg) and
    /// rank the survivors: significant first, then |d| descending.
    public static func rankFamily(_ tests: [FactorTest]) -> [RankedEffect] {
        let raw = tests.compactMap { t in
            effect(behaviorDays: t.yesDays, controlDays: t.noDays, outcomeByDay: t.outcomeByDay,
                   behavior: t.behavior, outcome: t.outcome, lag: t.lag)
        }
        let q = MultipleComparisons.benjaminiHochberg(raw.map(\.effect.pApprox))
        let adjusted = zip(raw, q).map { row, q in
            RankedEffect(behavior: row.behavior, outcome: row.outcome, lag: row.lag,
                         effect: row.effect, confidence: row.confidence, adjustedP: q)
        }
        return sorted(adjusted)
    }

    /// The effect of ONE behaviour on ONE outcome at a fixed lag, or nil when it cannot be
    /// computed or either side has fewer than the group gate's days.
    public static func effect(behaviorDays: Set<String>,
                              controlDays: Set<String>,
                              outcomeByDay: [String: Double],
                              behavior: String,
                              outcome: String,
                              lag: Int = defaultLag) -> RankedEffect? {
        let shifted = shiftedOutcome(outcomeByDay, byLag: lag)
        guard let e = BehaviorInsights.effect(behaviorDays: behaviorDays,
                                              controlDays: controlDays,
                                              outcomeByDay: shifted,
                                              behavior: behavior,
                                              outcome: outcome),
              Swift.min(e.nWith, e.nWithout) >= BehaviorInsights.minGroupForSignificance else { return nil }
        let pairs = Swift.min(e.nWith, e.nWithout)
        return RankedEffect(behavior: behavior, outcome: outcome, lag: lag,
                            effect: e, confidence: confidence(forPairs: pairs))
    }

    // MARK: - Lag alignment

    /// Re-key the outcome series so behaviour day D is paired with the outcome that landed
    /// `lag` days later: out'[D] = out[D+lag]. We move the VALUE from key D+lag back to key D
    /// by shifting each existing key BACKWARD by `lag` (shiftDay(day, by: -lag)). Then a plain
    /// BehaviorInsights split on behaviour day D reads the D+lag outcome — the same join
    /// ActivityCostEngine performs for D+1, generalised. `lag == 0` is the identity map.
    static func shiftedOutcome(_ outcomeByDay: [String: Double], byLag lag: Int) -> [String: Double] {
        if lag == 0 { return outcomeByDay }
        var out: [String: Double] = [:]
        out.reserveCapacity(outcomeByDay.count)
        for (day, value) in outcomeByDay {
            // The outcome ON day `day` belongs to behaviour day `day - lag`.
            if let behaviourKey = CorrelationEngine.shiftDay(day, by: -lag) {
                out[behaviourKey] = value
            }
        }
        return out
    }

    // MARK: - Confidence

    /// Confidence from the smaller group's paired-day count: below the group gate →
    /// `.calibrating`; gate…<solidPairs → `.building`; ≥ solidPairs → `.solid`.
    static func confidence(forPairs pairs: Int) -> ScoreConfidence {
        if pairs < calibratingBelow { return .calibrating }
        return pairs >= solidPairs ? .solid : .building
    }

    // MARK: - Ranking

    /// Stable rank: significant first, |cohensD| desc, then behaviour and outcome ascending.
    static func sorted(_ rows: [RankedEffect]) -> [RankedEffect] {
        rows.sorted { a, b in
            if a.isSignificant != b.isSignificant { return a.isSignificant }
            let la = abs(a.effect.cohensD), lb = abs(b.effect.cohensD)
            if la != lb { return la > lb }
            if a.behavior != b.behavior { return a.behavior < b.behavior }
            return a.outcome < b.outcome
        }
    }
}
