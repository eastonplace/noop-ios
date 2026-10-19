import XCTest
import Foundation
@testable import StrandAnalytics

/// Seeded property tests for StrengthStrain (seed `0x5EED_2360`, at least 2,000 valid cases each).
///
/// Property domain, stated on purpose because the claims are not true outside it:
/// - reps 1...100 and W_eff <= 500 (a case that crosses `implausible` is skipped by design and excluded);
/// - RPE in 1...12, or nil (nil, non-finite and <= 0 all mean the default 8, which is not monotone against
///   an explicit 0.1 that clamps to 5, so explicit RPEs below 1 are outside the domain);
/// - muscular load M finite, heart-rate score h in 0...100 (`combine(h, +infinity)` is the identity by contract,
///   while `combine(h, 1e308)` is capped at 36, so monotonicity in M is stated over finite M).
final class StrengthStrainPropertyTests: XCTestCase {

    private typealias SS = StrengthStrain
    private typealias Catalog = StrengthStrainCatalog

    private let seed: UInt64 = 0x5EED_2360
    private let requiredCases = 2_000

    /// Catalog records that can earn a dose: not skipped by the classifier and not cardio.
    private let playable: [Catalog.Record] = Catalog.records.filter {
        if case .skip = StrengthStrain.classify(exerciseName: $0.name, equipment: $0.equipment) { return false }
        return !$0.factor.isCardio
    }

    private func isAssisted(_ record: Catalog.Record) -> Bool {
        if case .assisted = SS.classify(exerciseName: record.name, equipment: record.equipment) { return true }
        return false
    }

    private func randomRPE(_ rng: inout SplitMix64) -> Double? {
        rng.bool(0.15) ? nil : rng.double(in: 1...12)
    }

    private func randomWeight(_ rng: inout SplitMix64) -> Double {
        rng.bool(0.1) ? 0 : rng.double(in: 0...250)
    }

    private func randomBodyweight(_ rng: inout SplitMix64) -> Double { rng.double(in: 30...250) }

    private func randomSet(_ rng: inout SplitMix64, warmups: Double = 0.2) -> SS.SetInput {
        let record = rng.pick(playable)
        return record.set(reps: rng.int(in: 1...30), kg: randomWeight(&rng), rpe: randomRPE(&rng),
                          warmup: rng.bool(warmups))
    }

    private func randomSession(_ rng: inout SplitMix64, maxSets: Int = 12) -> [SS.SetInput] {
        (0..<rng.int(in: 1...maxSets)).map { _ in randomSet(&rng) }
    }

    /// Runs `body` until it has reported `requiredCases` valid cases (it returns false for an excluded case).
    private func runCases(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                          _ body: (inout SplitMix64) -> Bool) {
        var rng = SplitMix64(seed: seed)
        var valid = 0
        var attempts = 0
        while valid < requiredCases, attempts < 200_000 {
            attempts += 1
            if body(&rng) { valid += 1 }
        }
        XCTAssertGreaterThanOrEqual(valid, requiredCases, "\(name): only \(valid) valid cases in \(attempts) draws",
                                    file: file, line: line)
    }

    // MARK: - 1. Monotonic

    func testDoseIsNonDecreasingInReps() {
        runCases("reps") { rng in
            let record = rng.pick(playable)
            let kg = randomWeight(&rng), rpe = randomRPE(&rng), bw = randomBodyweight(&rng)
            let low = rng.int(in: 1...100)
            let high = rng.int(in: low...100)
            let a = SS.evaluate(record.set(reps: low, kg: kg, rpe: rpe), bodyweightKg: bw)
            let b = SS.evaluate(record.set(reps: high, kg: kg, rpe: rpe), bodyweightKg: bw)
            if a.skip == .implausible || b.skip == .implausible || b.skip != nil { return false }
            XCTAssertLessThanOrEqual(a.dose, b.dose, "\(record.name) \(low)->\(high) reps")
            return true
        }
    }

    func testDoseIsNonDecreasingInWeightExceptAssistance() {
        runCases("weight") { rng in
            let record = rng.pick(playable)
            if isAssisted(record) { return false }
            let rpe = randomRPE(&rng), bw = randomBodyweight(&rng), reps = rng.int(in: 1...30)
            let low = randomWeight(&rng)
            let high = low + rng.double(in: 0...100)
            let a = SS.evaluate(record.set(reps: reps, kg: low, rpe: rpe), bodyweightKg: bw)
            let b = SS.evaluate(record.set(reps: reps, kg: high, rpe: rpe), bodyweightKg: bw)
            if a.skip == .implausible || b.skip == .implausible || b.skip != nil { return false }
            XCTAssertLessThanOrEqual(a.dose, b.dose, "\(record.name) \(low)->\(high) kg")
            return true
        }
    }

    func testAssistanceLowersDose() {
        let assisted = playable.filter(isAssisted)
        XCTAssertFalse(assisted.isEmpty)
        runCases("assistance") { rng in
            let record = rng.pick(assisted)
            let bw = randomBodyweight(&rng), reps = rng.int(in: 1...30), rpe = randomRPE(&rng)
            let low = rng.double(in: 0...(0.93 * bw))
            let high = low + rng.double(in: 0...(0.93 * bw - low))
            let a = SS.evaluate(record.set(reps: reps, kg: low, rpe: rpe), bodyweightKg: bw)
            let b = SS.evaluate(record.set(reps: reps, kg: high, rpe: rpe), bodyweightKg: bw)
            guard a.skip == nil else { return false }
            // More assistance never raises the dose; once it cancels the body share the set is `noWeight`.
            XCTAssertGreaterThanOrEqual(a.dose, b.dose)
            return true
        }
    }

    func testDoseIsNonDecreasingInRPE() {
        runCases("rpe") { rng in
            let record = rng.pick(playable)
            let kg = randomWeight(&rng), bw = randomBodyweight(&rng), reps = rng.int(in: 1...30)
            let low = rng.double(in: 1...12)
            let high = rng.double(in: low...12)
            let a = SS.evaluate(record.set(reps: reps, kg: kg, rpe: low), bodyweightKg: bw)
            let b = SS.evaluate(record.set(reps: reps, kg: kg, rpe: high), bodyweightKg: bw)
            if a.skip == .implausible || b.skip != nil { return false }
            XCTAssertLessThanOrEqual(a.dose, b.dose, "\(record.name) rpe \(low)->\(high)")
            return true
        }
    }

    func testDoseIsNonDecreasingWhenAKnownSecondaryIsAdded() {
        let tokens = ["glutes", "quads", "hamstrings", "lats", "chest", "shoulders", "traps", "biceps", "triceps",
                      "forearms", "abs", "core", "calves", "soleus", "lower back", "obliques", "adductors"]
        runCases("secondary") { rng in
            let record = rng.pick(playable)
            let kg = randomWeight(&rng), bw = randomBodyweight(&rng), reps = rng.int(in: 1...30)
            let rpe = randomRPE(&rng)
            let before = record.set(reps: reps, kg: kg, rpe: rpe)
            var after = before
            after.secondaryMuscles.append(rng.pick(tokens))
            let a = SS.evaluate(before, bodyweightKg: bw)
            let b = SS.evaluate(after, bodyweightKg: bw)
            if a.skip != nil || b.skip != nil { return false }
            XCTAssertLessThanOrEqual(a.massFactor, b.massFactor)
            XCTAssertLessThanOrEqual(a.dose, b.dose, "\(record.name)")
            return true
        }
    }

    func testSessionLoadIsNonDecreasingWhenAWorkingSetIsAdded() {
        runCases("add a set") { rng in
            let sets = randomSession(&rng)
            var extra = randomSet(&rng, warmups: 0)
            extra.isWarmup = false
            let bw = rng.bool() ? randomBodyweight(&rng) : nil
            let before = SS.evaluate(sets: sets, bodyweightKg: bw)
            let position = rng.int(in: 0...sets.count)
            var grown = sets
            grown.insert(extra, at: position)
            let after = SS.evaluate(sets: grown, bodyweightKg: bw)
            XCTAssertGreaterThanOrEqual(after.dose, before.dose)
            XCTAssertGreaterThanOrEqual(after.muscularLoad, before.muscularLoad)
            return after.sets[position].skip == nil
        }
    }

    func testCombineIsNonDecreasingInHeartRateAndInMuscularLoad() {
        runCases("combine monotone") { rng in
            let m = rng.bool(0.1) ? rng.double(in: -5...0) : rng.double(in: 0...60)
            let h1 = rng.bool(0.05) ? 0 : rng.double(in: 0...100)
            let h2 = rng.bool(0.05) ? 100 : rng.double(in: h1...100)
            XCTAssertLessThanOrEqual(SS.combine(hrStored: h1, muscularLoad: m),
                                     SS.combine(hrStored: h2, muscularLoad: m), "h \(h1)->\(h2) m \(m)")
            let h = rng.double(in: 0...100)
            let m2 = rng.double(in: m...(m + 60))
            XCTAssertLessThanOrEqual(SS.combine(hrStored: h, muscularLoad: m),
                                     SS.combine(hrStored: h, muscularLoad: m2), "h \(h) m \(m)->\(m2)")
            return true
        }
    }

    // MARK: - 2. Bounded

    func testMuscularLoadAndCombineAreBounded() {
        runCases("bounded") { rng in
            let session = SS.evaluate(sets: randomSession(&rng), bodyweightKg: rng.bool() ? randomBodyweight(&rng) : nil)
            XCTAssertGreaterThanOrEqual(session.muscularLoad, 0)
            XCTAssertLessThanOrEqual(session.muscularLoad, 36)
            let h = rng.bool(0.1) ? (rng.bool() ? 0 : 100) : rng.double(in: 0...100)
            let m = session.muscularLoad
            let combined = SS.combine(hrStored: h, muscularLoad: m)
            XCTAssertGreaterThanOrEqual(combined, h)
            XCTAssertLessThanOrEqual(combined, 100)
            XCTAssertEqual(SS.combine(hrStored: 100, muscularLoad: m), 100)
            let display = SS.combinedDisplay(hrDisplay: h * 21 / 100, muscularLoad: m)
            XCTAssertGreaterThanOrEqual(display, h * 21 / 100)
            XCTAssertLessThanOrEqual(display, 21)
            return true
        }
    }

    /// NaN, infinities and huge numbers give a finite dose or a skip reason, never a crash or a NaN.
    func testGarbageInputsGiveFiniteOutputOrASkipReason() {
        let weights: [Double?] = [nil, .nan, .infinity, -.infinity, 1e308, -1e308, 1e-320, -1e-320, 0, -0.0, 499.9, 500, 1e6]
        let reps = [Int.min, -1, 0, 1, 12, 15, 16, 100, 101, Int.max]
        let rpes: [Double?] = [nil, .nan, .infinity, -.infinity, 1e308, -1e308, 0, -1, 4.99, 5, 10, 10.01, 1e-320]
        let bodyweights: [Double?] = [nil, .nan, .infinity, -1, 0, 1e308, 75]
        runCases("garbage") { rng in
            let record = rng.pick(playable)
            let set = record.set(reps: rng.bool(0.6) ? rng.pick(reps) : rng.int(in: -5...200),
                                 kg: rng.bool(0.7) ? rng.pick(weights) : rng.double(in: -100...700),
                                 rpe: rng.bool(0.7) ? rng.pick(rpes) : rng.double(in: -2...14),
                                 warmup: rng.bool(0.1))
            let bw = rng.pick(bodyweights)
            let result = SS.evaluate(set, bodyweightKg: SS.bodyweight(bw))
            XCTAssertTrue(result.dose.isFinite)
            XCTAssertGreaterThanOrEqual(result.dose, 0)
            XCTAssertTrue(result.effectiveWeightKg.isFinite)
            XCTAssertTrue(result.effort.isFinite)
            XCTAssertTrue(result.massFactor.isFinite)
            if result.dose == 0 { XCTAssertNotNil(result.skip, "a zero dose must carry a reason") }
            if result.skip != nil { XCTAssertEqual(result.dose, 0) }

            let session = SS.evaluate(sets: [set, randomSet(&rng)], bodyweightKg: bw)
            XCTAssertTrue(session.dose.isFinite)
            XCTAssertTrue(session.volume.isFinite)
            XCTAssertTrue(session.muscularLoad.isFinite)
            XCTAssertGreaterThanOrEqual(session.muscularLoad, 0)
            XCTAssertLessThanOrEqual(session.muscularLoad, 36)
            XCTAssertTrue((30.0...250.0).contains(session.bodyweightKg))
            return true
        }
        // Non-finite inputs to the pure functions.
        for m in [Double.nan, .infinity, -.infinity, 1e308, -1e308] {
            let combined = SS.combine(hrStored: 50, muscularLoad: m)
            XCTAssertTrue(combined.isFinite)
            XCTAssertGreaterThanOrEqual(combined, 50)
            XCTAssertLessThanOrEqual(combined, 100)
        }
        XCTAssertEqual(SS.muscularLoad(volume: 1e308), 36, accuracy: 1e-12)
    }

    // MARK: - 3. Deterministic

    func testSameInputGivesTheSameBitsAndShufflingChangesNothing() {
        runCases("deterministic") { rng in
            var sets = randomSession(&rng)
            let bw = rng.bool() ? randomBodyweight(&rng) : nil
            let reference = SS.evaluate(sets: sets, bodyweightKg: bw)
            let again = SS.evaluate(sets: sets, bodyweightKg: bw)
            XCTAssertEqual(reference, again)
            for _ in 0..<3 {
                for index in stride(from: sets.count - 1, to: 0, by: -1) {
                    sets.swapAt(index, rng.int(in: 0...index))
                }
                let shuffled = SS.evaluate(sets: sets, bodyweightKg: bw)
                XCTAssertEqual(shuffled.dose.bitPattern, reference.dose.bitPattern)
                XCTAssertEqual(shuffled.volume.bitPattern, reference.volume.bitPattern)
                XCTAssertEqual(shuffled.muscularLoad.bitPattern, reference.muscularLoad.bitPattern)
                XCTAssertEqual(shuffled.countedSets, reference.countedSets)
                XCTAssertEqual(shuffled.skipped, reference.skipped)
            }
            return true
        }
    }

    // MARK: - 4. Identity

    func testNonPositiveOrNonFiniteMuscularLoadLeavesTheScoreBitIdentical() {
        let loads: [Double] = [0, -0.0, -1e-300, -1, -36, -1e308, .nan, .infinity, -.infinity]
        runCases("identity") { rng in
            let h = rng.bool(0.1) ? rng.pick([0, 100, 47.6, 9.52381]) : rng.double(in: 0...100)
            let m = rng.pick(loads)
            XCTAssertEqual(SS.combine(hrStored: h, muscularLoad: m).bitPattern, h.bitPattern)
            XCTAssertEqual(SS.combine(hrStored: Optional(h), muscularLoad: m)?.bitPattern, h.bitPattern)
            let display = h * 21 / 100
            XCTAssertEqual(SS.combinedDisplay(hrDisplay: display, muscularLoad: m).bitPattern, display.bitPattern)
            return true
        }
    }

    // MARK: - 5. Warm-ups excluded, 6. No sets

    func testFlippingAWarmupFlagZeroesTheSet() {
        runCases("warm-up") { rng in
            var set = randomSet(&rng, warmups: 0)
            let bw = randomBodyweight(&rng)
            let working = SS.evaluate(set, bodyweightKg: bw)
            set.isWarmup = true
            let warm = SS.evaluate(set, bodyweightKg: bw)
            XCTAssertEqual(warm.dose, 0)
            XCTAssertEqual(warm.skip, .warmup)
            let both = SS.evaluate(sets: [set, set], bodyweightKg: bw)
            XCTAssertEqual(both.muscularLoad, 0)
            XCTAssertEqual(both.countedSets, 0)
            XCTAssertEqual(both.workingSets, 0)
            XCTAssertEqual(both.warmupSets, 2)
            return working.skip == nil
        }
    }

    func testNoSetsMeansNoMuscularLoad() {
        for bodyweight in [nil, 30, 75, 250, Double.nan] as [Double?] {
            let session = SS.evaluate(sets: [], bodyweightKg: bodyweight)
            XCTAssertEqual(session.dose, 0)
            XCTAssertEqual(session.volume, 0)
            XCTAssertEqual(session.muscularLoad, 0)
            XCTAssertEqual(session.workingSets, 0)
            XCTAssertEqual(session.countedSets, 0)
            XCTAssertTrue(session.skipped.isEmpty)
            XCTAssertTrue(session.sets.isEmpty)
        }
    }

    // MARK: - SM-1: the 12 and 15 rep boundaries

    func testDoseNeverFallsAsRepsRiseAcrossTheBoundaries() {
        for record in playable.prefix(400) {
            let kg = 60.0
            var previous = 0.0
            for reps in 1...30 {
                let result = SS.evaluate(record.set(reps: reps, kg: kg, rpe: 8), bodyweightKg: 80)
                guard result.skip == nil else { previous = 0; continue }
                XCTAssertGreaterThanOrEqual(result.dose, previous, "\(record.name) at \(reps) reps")
                previous = result.dose
            }
        }
    }
}
