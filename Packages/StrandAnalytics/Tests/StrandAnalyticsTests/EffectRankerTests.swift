import XCTest
@testable import StrandAnalytics

/// EffectRanker — the fixed-lag, family-corrected "what moves you" ranker. The oracle for the Android
/// EffectRankerTest; keep the two in lockstep (same fixtures, same numbers).
final class EffectRankerTests: XCTestCase {

    private func explicitControls(_ outcome: [String: Double], excluding behaviorDays: Set<String>) -> Set<String> {
        Set(outcome.keys).subtracting(behaviorDays)
    }

    private func ymd(_ y: Int, _ m: Int, _ d: Int) -> String { String(format: "%04d-%02d-%02d", y, m, d) }

    private func row(_ rows: [RankedEffect], _ behavior: String) -> RankedEffect? {
        rows.first { $0.behavior == behavior }
    }

    /// Deterministic per-calendar-day jitter in {-2,-1,0,1,2} so the with/without groups carry
    /// real within-group spread (a perfectly-constant group yields a pooled SD of 0 and Cohen's d
    /// of 0 by design). Trivially mirrored in Kotlin from the day-of-month.
    private func jitter(_ dayOfMonth: Int) -> Double { Double((dayOfMonth * 7) % 5 - 2) }

    func testNonfiniteOutcomesCannotClearTheGroupGate() {
        let yes = Set((0..<5).map { "yes-\($0)" })
        let no = Set((0..<5).map { "no-\($0)" })
        for invalid in [Double.infinity, -.infinity, .nan] {
            var values = Dictionary(uniqueKeysWithValues: yes.map { ($0, 60.0) } + no.map { ($0, 80.0) })
            values["yes-0"] = invalid
            let effect = BehaviorInsights.effect(behaviorDays: yes, controlDays: no, outcomeByDay: values,
                                                 behavior: "test", outcome: "hrv")
            XCTAssertEqual(effect?.nWith, 4)
            XCTAssertFalse(effect?.significant ?? true)
            XCTAssertTrue(EffectRanker.rankFamily([.init(behavior: "test", yesDays: yes, noDays: no,
                                                         outcome: "hrv", outcomeByDay: values)]).isEmpty)
        }
    }

    func testFiniteOverflowCannotBecomeASignificantEffect() {
        let yes = Set((0..<5).map { "yes-\($0)" })
        let no = Set((0..<5).map { "no-\($0)" })
        for extreme in [Double.greatestFiniteMagnitude, 1e200] {
            let values = Dictionary(uniqueKeysWithValues: yes.sorted().enumerated().map { ($0.element, $0.offset == 0 ? 0 : extreme) } + no.map { ($0, 60.0) })
            XCTAssertNil(BehaviorInsights.effect(behaviorDays: yes, controlDays: no, outcomeByDay: values,
                                                  behavior: "test", outcome: "hrv"))
        }
    }

    // MARK: - Fixed lag: no searching across lags

    /// The outcome the morning after each behaviour day (D+1) is depressed (≈50) while every other
    /// day sits at baseline (≈70). The ranker must NOT go looking for that lag on its own: at the
    /// default lag 0 it reports the same-key effect, and only an explicit lag 1 finds the dip.
    func testFixedLagDoesNotSearchForTheBestLag() {
        var outcome: [String: Double] = [:]
        var behaviorDays: Set<String> = []
        for i in 0..<6 { behaviorDays.insert(ymd(2026, 6, 1 + 4 * i)) }
        for d in 1...30 { outcome[ymd(2026, 6, d)] = 70 + jitter(d) }
        for d in 1...8 { outcome[ymd(2026, 7, d)] = 70 + jitter(d) }
        for i in 0..<6 {
            let dip = 2 + 4 * i
            outcome[ymd(2026, 6, dip)] = 50 + jitter(dip)
        }

        let atZero = EffectRanker.rank(behaviors: ["Alcohol": behaviorDays],
                                       controls: ["Alcohol": explicitControls(outcome, excluding: behaviorDays)],
                                       outcomeByDay: outcome, outcome: "Charge")
        let zero = row(atZero, "Alcohol")
        XCTAssertEqual(zero?.lag, 0)
        XCTAssertGreaterThan(zero!.effect.cohensD, 0, "lag 0 must not report the next-morning dip")
        XCTAssertEqual(abs(zero!.effect.cohensD), abs(effectAtLag(behaviorDays, outcome, 0)!.cohensD), accuracy: 1e-12)

        let shifted = EffectRanker.shiftedOutcome(outcome, byLag: 1)
        let atOne = EffectRanker.rank(behaviors: ["Alcohol": behaviorDays],
                                      controls: ["Alcohol": explicitControls(shifted, excluding: behaviorDays)],
                                      outcomeByDay: outcome, outcome: "Charge", lag: 1)
        let one = row(atOne, "Alcohol")
        XCTAssertEqual(one?.lag, 1)
        XCTAssertEqual(one?.leadLagText, "next morning")
        XCTAssertLessThan(one!.effect.cohensD, 0)
        XCTAssertTrue(one!.effect.significant)
        XCTAssertLessThan(one!.effect.meanWith, 55)
        XCTAssertGreaterThan(one!.effect.meanWithout, 65)
    }

    // MARK: - Family correction

    /// Twenty null factors plus one real one. Uncorrected, some nulls can slip under 0.05; after
    /// Benjamini–Hochberg only the real factor stays significant, and every row carries its q.
    func testFamilyCorrectionKeepsOnlyTheRealEffect() {
        var outcome: [String: Double] = [:]
        for d in 1...60 {
            let day = CorrelationEngine.shiftDay("2026-01-01", by: d)!
            outcome[day] = 60 + Double((d * 37) % 11) - 5
        }
        let keys = outcome.keys.sorted()
        var tests: [EffectRanker.FactorTest] = []
        // Real: every third day is 15 points higher.
        var real = Set<String>()
        for (i, k) in keys.enumerated() where i % 3 == 0 { real.insert(k); outcome[k]! += 15 }
        tests.append(.init(behavior: "Real", yesDays: real, noDays: Set(keys).subtracting(real),
                           outcome: "Recovery", outcomeByDay: outcome))
        for f in 0..<20 {
            var yes = Set<String>()
            for (i, k) in keys.enumerated() where (i * (f + 3) + f) % 4 == 0 && !real.contains(k) { yes.insert(k) }
            tests.append(.init(behavior: "Null \(f)", yesDays: yes,
                               noDays: Set(keys).subtracting(yes).subtracting(real),
                               outcome: "Recovery", outcomeByDay: outcome))
        }
        let ranked = EffectRanker.rankFamily(tests)
        XCTAssertTrue(ranked.allSatisfy { $0.adjustedP != nil })
        XCTAssertEqual(ranked.first?.behavior, "Real")
        XCTAssertEqual(ranked.filter(\.isSignificant).map(\.behavior), ["Real"])
        for r in ranked { XCTAssertGreaterThanOrEqual(r.adjustedP!, r.effect.pApprox - 1e-12) }
    }

    func testBenjaminiHochbergMatchesTheTextbookExample() {
        // m = 5: q_i = min over j >= i of p_(j) * m / j.
        let q = MultipleComparisons.benjaminiHochberg([0.01, 0.04, 0.03, 0.005, 0.5])
        let expected = [0.025, 0.05, 0.05, 0.025, 0.5]
        for (a, b) in zip(q, expected) { XCTAssertEqual(a, b, accuracy: 1e-12) }
        XCTAssertEqual(MultipleComparisons.benjaminiHochberg([]), [])
        XCTAssertEqual(MultipleComparisons.benjaminiHochberg([.nan]), [1])
    }

    /// Test-only: the BehaviorEffect at a specific lag, via the engine's own shift alignment.
    private func effectAtLag(_ behaviorDays: Set<String>, _ outcome: [String: Double],
                             _ lag: Int) -> BehaviorEffect? {
        let shifted = EffectRanker.shiftedOutcome(outcome, byLag: lag)
        return BehaviorInsights.effect(behaviorDays: behaviorDays,
                                       controlDays: explicitControls(shifted, excluding: behaviorDays),
                                       outcomeByDay: shifted,
                                       behavior: "Alcohol", outcome: "Charge")
    }

    // MARK: - Group gate suppresses thin behaviours

    /// A behaviour logged on only 3 days can never clear min(nWith,nWithout) ≥ 5 at any lag, so
    /// it is dropped entirely (no fabricated row).
    func testThinBehaviourIsDropped() {
        var outcome: [String: Double] = [:]
        var thin: Set<String> = []
        for d in 1...3 {                       // only 3 behaviour days → nWith ≤ 3 < 5
            let day = ymd(2026, 6, d)
            thin.insert(day)
            outcome[day] = 50 + jitter(d)
            outcome[ymd(2026, 6, d + 1)] = 50 + jitter(d + 1)
        }
        for d in 1...8 { outcome[ymd(2026, 7, d)] = 70 + jitter(d) }   // plenty of "without"

        let out = EffectRanker.rank(behaviors: ["Sparse": thin],
                                    controls: ["Sparse": explicitControls(outcome, excluding: thin)],
                                    outcomeByDay: outcome, outcome: "Charge")
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Ranking order matches BehaviorInsights.rank (significant first, |d| desc, name asc)

    /// Two behaviours, both lag-0 same-day effects, with different effect magnitudes. The bigger
    /// |cohensD| ranks first; a name tiebreak applies only on identical effects.
    func testRankingOrder() {
        var outcome: [String: Double] = [:]
        // "Big": large same-day separation (with ≈ 50, without ≈ 70). Jitter gives real spread.
        var big: Set<String> = []
        for d in 1...6 {
            let day = ymd(2026, 1, d)
            big.insert(day)
            outcome[day] = 50 + jitter(d)
        }
        // "Small": modest same-day separation (with ≈ 66, without ≈ 70).
        var small: Set<String> = []
        for d in 1...6 {
            let day = ymd(2026, 3, d)
            small.insert(day)
            outcome[day] = 66 + jitter(d)
        }
        // Shared "without" baseline at 70 (a block neither behaviour touches at any lag).
        for d in 10...20 { outcome[ymd(2026, 5, d)] = 70 + jitter(d) }

        let out = EffectRanker.rank(behaviors: ["Big": big, "Small": small],
                                    controls: [
                                        "Big": explicitControls(outcome, excluding: big),
                                        "Small": explicitControls(outcome, excluding: small),
                                    ],
                                    outcomeByDay: outcome, outcome: "Charge")
        XCTAssertEqual(out.map { $0.behavior }, ["Big", "Small"])   // |d| Big > Small
        XCTAssertEqual(row(out, "Big")!.lag, 0)                     // the fixed default lag
        XCTAssertEqual(row(out, "Small")!.lag, 0)
    }

    // MARK: - Confidence tiers from paired-day count

    func testConfidenceTiers() {
        XCTAssertEqual(EffectRanker.confidence(forPairs: 4), .calibrating)  // < gate (5)
        XCTAssertEqual(EffectRanker.confidence(forPairs: 5), .building)     // gate…<10
        XCTAssertEqual(EffectRanker.confidence(forPairs: 9), .building)
        XCTAssertEqual(EffectRanker.confidence(forPairs: 10), .solid)       // ≥ 10
    }

    // MARK: - shiftedOutcome alignment (lag 0 is identity, lag re-keys backward)

    func testShiftedOutcomeAlignment() {
        let outcome: [String: Double] = [ymd(2026, 6, 2): 55, ymd(2026, 6, 3): 60]
        // lag 0 → identity.
        XCTAssertEqual(EffectRanker.shiftedOutcome(outcome, byLag: 0), outcome)
        // lag 1 → the value ON day D moves to key D−1, so behaviour day D pairs with outcome D+1.
        let s1 = EffectRanker.shiftedOutcome(outcome, byLag: 1)
        XCTAssertEqual(s1[ymd(2026, 6, 1)], 55)   // outcome of 06-02 keyed under 06-01
        XCTAssertEqual(s1[ymd(2026, 6, 2)], 60)   // outcome of 06-03 keyed under 06-02
        XCTAssertNil(s1[ymd(2026, 6, 3)])
    }

    // MARK: - sentence appends the lead/lag clause

    func testSentenceAppendsLeadLag() {
        let e = BehaviorEffect(behavior: "Alcohol", outcome: "Charge",
                               meanWith: 50, meanWithout: 70, delta: -20,
                               pctChange: -100.0 * 20.0 / 70.0, nWith: 6, nWithout: 8,
                               cohensD: -2.0, pApprox: 0.001, significant: true)
        let r = RankedEffect(behavior: "Alcohol", outcome: "Charge", lag: 1,
                             effect: e, confidence: .building)
        XCTAssertTrue(r.sentence().hasSuffix("(next morning)."))
    }
}
