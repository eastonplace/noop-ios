import XCTest
import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// Pins StrengthStrain v1: the effort term, the load-kind classifier, the movement profile, the worked
/// examples, and the combination with heart rate (including the day floors).
final class StrengthStrainTests: XCTestCase {

    private typealias SS = StrengthStrain
    private typealias Catalog = StrengthStrainCatalog

    // MARK: - Effort (4.2)

    func testEffortTable() {
        let rpes: [Double?] = [nil, 5, 8, 8.5, 10, 11, .nan, 0, -1]
        for reps in [5, 8, 10, 12, 13, 20] {
            for rpe in rpes {
                let adjusted: Double
                if let rpe, rpe.isFinite, rpe > 0 { adjusted = min(10, max(5, rpe)) } else { adjusted = 8 }
                let expected = 30 / (30 + Double(min(reps, 12)) + (10 - adjusted))
                XCTAssertEqual(SS.effort(reps: reps, rpe: rpe), expected, accuracy: 1e-12,
                               "reps \(reps) rpe \(String(describing: rpe))")
            }
        }
        for rpe in rpes {
            XCTAssertEqual(SS.effort(reps: 12, rpe: rpe).bitPattern, SS.effort(reps: 13, rpe: rpe).bitPattern)
            XCTAssertEqual(SS.effort(reps: 12, rpe: rpe).bitPattern, SS.effort(reps: 20, rpe: rpe).bitPattern)
        }
    }

    func testEffortRangeAndMonotonicInRPE() {
        for reps in 1...100 {
            var previous = 0.0
            for rpe in stride(from: 5.0, through: 10.0, by: 0.5) {
                let e = SS.effort(reps: reps, rpe: rpe)
                XCTAssertGreaterThanOrEqual(e, 0.638, "reps \(reps) rpe \(rpe)")
                XCTAssertLessThanOrEqual(e, 0.968, "reps \(reps) rpe \(rpe)")
                XCTAssertGreaterThanOrEqual(e, previous)
                previous = e
            }
        }
    }

    // MARK: - Classifier (4.3)

    func testClassifierOrder() {
        let rows: [(String, String, SS.LoadKind)] = [
            ("hamstring stretch", "body weight", .skip(.stretch)),
            ("scapula pull-up", "body weight", .bodyweight(fraction: 0.30)),
            ("bench dip", "body weight", .bodyweight(fraction: 0.30)),
            ("assisted chin-up", "leverage machine", .assisted(fraction: 0.93)),
            ("pull-up", "body weight", .bodyweight(fraction: 0.93)),
            ("chest dip", "body weight", .bodyweight(fraction: 0.93)),
            ("weighted front raise", "weighted", .external(bodyFraction: 0)),
            ("front plank", "body weight", .skip(.isometric)),
            ("crunch floor", "body weight", .bodyweight(fraction: 0.30)),
            ("assisted sit-up", "assisted", .bodyweight(fraction: 0.30)),
            ("jump squat", "body weight", .bodyweight(fraction: 0.77)),
            ("dumbbell lunge", "dumbbell", .external(bodyFraction: 0.77)),
            ("smith squat", "smith machine", .external(bodyFraction: 0.77)),
            ("sled hack squat", "sled machine", .external(bodyFraction: 0.77 * 0.71)),
            ("sled 45° leg press", "sled machine", .external(bodyFraction: 0)),
            ("barbell seated calf raise", "barbell", .external(bodyFraction: 0)),
            ("barbell squat (on knees)", "barbell", .external(bodyFraction: 0)),
            ("barbell bench press", "barbell", .external(bodyFraction: 0)),
            ("Hanging Knee Raise", "Bodyweight", .bodyweight(fraction: 0.30)),
            ("Calf Raise", "Machine", .external(bodyFraction: 0)),
        ]
        for (name, equipment, expected) in rows {
            XCTAssertEqual(SS.classify(exerciseName: name, equipment: equipment), expected,
                           "\(name); \(equipment)")
        }
        // The angled fraction is the constants multiplied at run time, never a literal.
        XCTAssertEqual(SS.classify(exerciseName: "sled hack squat", equipment: "sled machine"),
                       .external(bodyFraction: SS.lowerBodyFraction * SS.sledScale))
        // Missing equipment reads as an external lift.
        XCTAssertEqual(SS.classify(exerciseName: "Bench press", equipment: nil), .external(bodyFraction: 0))
        XCTAssertEqual(SS.classify(exerciseName: "Back squat", equipment: nil), .external(bodyFraction: 0.77))
    }

    func testPostureFractions() {
        XCTAssertEqual(SS.pushUpFraction("push-up"), 0.64)
        XCTAssertEqual(SS.pushUpFraction("incline push-up"), 0.55)
        XCTAssertEqual(SS.pushUpFraction("decline push-up"), 0.70)
        XCTAssertEqual(SS.pushUpFraction("kneeling push-up (male)"), 0.49)
        XCTAssertEqual(SS.pushUpFraction("push-up (wall)"), 0.41)
    }

    // MARK: - Effective weight (4.3, ADDENDUM A8)

    func testEffectiveWeightKinds() {
        // (catalog name, logged kg, expected kind, expected W_eff) at body weight 80.
        let rows: [(String, Double, SS.LoadKind, Double)] = [
            ("barbell full squat", 100, .external(bodyFraction: 0.77), 161.6),
            ("smith squat", 100, .external(bodyFraction: 0.77), 161.6),
            ("smith deadlift", 100, .external(bodyFraction: 0.77), 161.6),
            ("cable deadlift", 100, .external(bodyFraction: 0.77), 161.6),
            ("sled hack squat", 100, .external(bodyFraction: 0.77 * 0.71), 114.736),
            ("barbell seated calf raise", 100, .external(bodyFraction: 0), 100),
            ("dumbbell seated calf raise", 20, .external(bodyFraction: 0), 20),
            ("barbell squat (on knees)", 100, .external(bodyFraction: 0), 100),
            ("barbell seated good morning", 100, .external(bodyFraction: 0), 100),
            ("assisted pull-up", 30, .assisted(fraction: 0.93), 44.4),
            ("pull-up", 10, .bodyweight(fraction: 0.93), 84.4),
            ("assisted sit-up", 0, .bodyweight(fraction: 0.30), 24.0),
            ("incline push-up", 0, .bodyweight(fraction: 0.55), 44.0),
            ("decline push-up", 0, .bodyweight(fraction: 0.70), 56.0),
            ("kneeling push-up (male)", 0, .bodyweight(fraction: 0.49), 39.2),
            ("push-up (wall)", 0, .bodyweight(fraction: 0.41), 32.8),
            ("dumbbell lunge with bicep curl", 100, .external(bodyFraction: 0.77), 161.6),
        ]
        for (name, kg, kind, weff) in rows {
            let record = Catalog.record(name)
            let classified = SS.classify(exerciseName: record.name, equipment: record.equipment)
            XCTAssertEqual(classified, kind, name)
            let angled = SS.isAngled(exerciseName: record.name, equipment: record.equipment)
            let result = SS.effectiveWeight(kind: classified, weightKg: kg, bodyweightKg: 80, angled: angled)
            XCTAssertNil(result.skip, name)
            XCTAssertEqual(result.kg, weff, accuracy: 1e-9, name)
            let set = SS.evaluate(record.set(reps: 10, kg: kg), bodyweightKg: 80)
            XCTAssertEqual(set.effectiveWeightKg, weff, accuracy: 1e-9, name)
        }
        // The angled sled leg press has no body term: only the sled's sin(45) share of the logged load.
        let legPress = SS.effectiveWeight(kind: .external(bodyFraction: 0), weightKg: 100, bodyweightKg: 80, angled: true)
        XCTAssertEqual(legPress.kg, 71.0, accuracy: 1e-9)
        XCTAssertTrue(SS.isAngled(exerciseName: "sled 45° leg press", equipment: "sled machine"))
        XCTAssertTrue(SS.isAngled(exerciseName: "hack squat", equipment: "Machine"))
        XCTAssertFalse(SS.isAngled(exerciseName: "barbell full squat", equipment: "barbell"))

        // ADDENDUM A8 (a move that carries body weight counts at 0 kg), assistance, and the body-weight clamp.
        bodyweightLoadedMovesCountAtZeroKg()
        assistedMoveNeedsLessAssistanceThanBodyweight()
        bodyweightClamp()
    }

    /// ADDENDUM A8: a move that carries body weight counts at 0 kg; only f == 0 and w <= 0 is `noWeight`.
    private func bodyweightLoadedMovesCountAtZeroKg() {
        let loaded = SS.effectiveWeight(kind: .external(bodyFraction: 0.77), weightKg: 0, bodyweightKg: 80, angled: false)
        XCTAssertNil(loaded.skip)
        XCTAssertEqual(loaded.kg, 0.77 * 80, accuracy: 1e-12)
        let negative = SS.effectiveWeight(kind: .external(bodyFraction: 0.77), weightKg: -20, bodyweightKg: 80, angled: false)
        XCTAssertNil(negative.skip)
        XCTAssertEqual(negative.kg, 0.77 * 80, accuracy: 1e-12)
        let angled = SS.effectiveWeight(kind: .external(bodyFraction: 0.77 * 0.71), weightKg: 0, bodyweightKg: 80, angled: true)
        XCTAssertNil(angled.skip)
        XCTAssertEqual(angled.kg, 0.77 * 0.71 * 80, accuracy: 1e-12)

        for weight in [0.0, -5] {
            let bare = SS.effectiveWeight(kind: .external(bodyFraction: 0), weightKg: weight, bodyweightKg: 80, angled: false)
            XCTAssertEqual(bare.skip, .noWeight)
            XCTAssertEqual(bare.kg, 0)
        }
        // Through a whole set: a barbell squat logged with no weight still counts.
        let squat = Catalog.set("barbell full squat", reps: 8, kg: nil)
        let result = SS.evaluate(squat, bodyweightKg: 80)
        XCTAssertNil(result.skip)
        XCTAssertGreaterThan(result.dose, 0)
        XCTAssertEqual(result.effectiveWeightKg, 0.77 * 80, accuracy: 1e-12)
        // A bench press logged with no weight does not.
        XCTAssertEqual(SS.evaluate(Catalog.set("barbell bench press", reps: 8, kg: nil), bodyweightKg: 80).skip, .noWeight)
        XCTAssertEqual(SS.evaluate(Catalog.set("barbell bench press", reps: 8, kg: 0), bodyweightKg: 80).skip, .noWeight)
    }

    /// The catalog-wide form of the starter-bank 0 kg pass: every record whose load carries body weight is
    /// counted with no weight logged (the starter-bank pass proper lives with the app tests).
    func testEveryBodyweightLoadedCatalogRecordCountsAtZeroKg() {
        var checked = 0
        for record in Catalog.records {
            let kind = SS.classify(exerciseName: record.name, equipment: record.equipment)
            let carriesBody: Bool
            switch kind {
            case .external(let f): carriesBody = f > 0
            case .bodyweight: carriesBody = true
            case .assisted, .skip: carriesBody = false
            }
            guard carriesBody, !record.factor.isCardio else { continue }
            let result = SS.evaluate(record.set(reps: 10, kg: 0), bodyweightKg: 80)
            XCTAssertNil(result.skip, "\(record.name) (\(record.equipment)) should count at 0 kg")
            XCTAssertGreaterThan(result.dose, 0, record.name)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 300)
    }

    private func assistedMoveNeedsLessAssistanceThanBodyweight() {
        let assist = SS.effectiveWeight(kind: .assisted(fraction: 0.93), weightKg: 0.93 * 80, bodyweightKg: 80, angled: false)
        XCTAssertEqual(assist.skip, .noWeight)
        let over = SS.effectiveWeight(kind: .assisted(fraction: 0.93), weightKg: 200, bodyweightKg: 80, angled: false)
        XCTAssertEqual(over.skip, .noWeight)
        let none = SS.effectiveWeight(kind: .assisted(fraction: 0.93), weightKg: 0, bodyweightKg: 80, angled: false)
        XCTAssertNil(none.skip)
        XCTAssertEqual(none.kg, 0.93 * 80, accuracy: 1e-12)
    }

    private func bodyweightClamp() {
        XCTAssertEqual(SS.bodyweight(nil), 75)
        XCTAssertEqual(SS.bodyweight(10), 30)
        XCTAssertEqual(SS.bodyweight(400), 250)
        XCTAssertEqual(SS.bodyweight(.nan), 75)
        XCTAssertEqual(SS.bodyweight(.infinity), 75)
        XCTAssertEqual(SS.bodyweight(82.5), 82.5)
        XCTAssertEqual(SS.evaluate(sets: [], bodyweightKg: 400).bodyweightKg, 250)
        XCTAssertEqual(SS.evaluate(sets: [], bodyweightKg: nil).bodyweightKg, 75)
    }

    // MARK: - Movement profile (4.4)

    func testMassFactorPinned() {
        let rows: [(String, Double)] = [
            ("barbell full squat", 1.26),
            ("dumbbell lunge", 1.225),
            ("barbell deadlift", 1.16),
            ("barbell romanian deadlift", 1.16),
            ("push-up", 0.9605),
            ("barbell bench press", 0.93075),
            ("barbell bent over row", 0.9095),
            ("pull-up", 0.9095),
            ("lever leg extension", 0.66),
            ("lever seated leg curl", 0.615),
            ("dumbbell fly", 0.5406),
            ("dumbbell lateral raise", 0.3816),
            ("barbell shrug", 0.3816),
            ("barbell curl", 0.21735),
            ("cable pushdown", 0.21735),
            ("barbell standing calf raise", 0.18),
            ("dumbbell seated calf raise", 0.165),
        ]
        for (name, expected) in rows {
            let mass = Catalog.record(name).factor
            XCTAssertFalse(mass.isCardio, name)
            XCTAssertFalse(mass.unmapped, name)
            XCTAssertEqual(mass.factor, expected, accuracy: 1e-12, name)
        }
    }

    func testMuscleMassTable() {
        XCTAssertEqual(SS.muscleMass("Glutes"), 1.0)
        XCTAssertEqual(SS.muscleMass(" pectorals "), 0.85)
        XCTAssertEqual(SS.muscleMass("frontDelts"), 0.6)
        XCTAssertEqual(SS.muscleMass("triceps"), 0.35)
        XCTAssertEqual(SS.muscleMass("calves"), 0.25)
        XCTAssertEqual(SS.muscleMass("soleus"), 0.25)
        XCTAssertNil(SS.muscleMass("cardiovascular system"))
        XCTAssertNil(SS.muscleMass("not a muscle"))
        XCTAssertNil(SS.muscleMass(""))
    }

    func testMassFactorSpecialPrimaries() {
        let cardio = SS.massFactor(exerciseName: "run", primary: "cardiovascular system", secondary: ["quads"])
        XCTAssertTrue(cardio.isCardio)
        XCTAssertFalse(cardio.unmapped)
        XCTAssertTrue(SS.massFactor(exerciseName: "bike", primary: " Cardio ", secondary: []).isCardio)

        for primary in [nil, "", "  ", "not a muscle"] as [String?] {
            let mass = SS.massFactor(exerciseName: "barbell bench press", primary: primary, secondary: [])
            XCTAssertFalse(mass.isCardio)
            XCTAssertTrue(mass.unmapped, "primary \(String(describing: primary))")
            XCTAssertEqual(mass.factor, 0.6, accuracy: 1e-12)
        }
        // Distinct known secondaries only: a repeat, the primary itself, an unknown and a cardio token add nothing.
        let once = SS.massFactor(exerciseName: "barbell bench press", primary: "pectorals", secondary: ["triceps"])
        let noisy = SS.massFactor(exerciseName: "barbell bench press", primary: "pectorals",
                                  secondary: ["triceps", "Triceps", "pectorals", "nonsense", "cardio"])
        XCTAssertEqual(once.factor, noisy.factor)
        // The secondary bonus is capped at 40%.
        let many = SS.massFactor(exerciseName: "barbell full squat", primary: "glutes",
                                 secondary: ["quads", "hamstrings", "legs", "posterior chain", "lats"])
        XCTAssertEqual(many.factor, 1.0 * (1 + 0.4), accuracy: 1e-12)
    }

    func testSingleJointFactor() {
        for name in ["barbell curl", "lever leg extension", "dumbbell lateral raise", "cable pushdown",
                     "barbell shrug", "dumbbell fly"] {
            XCTAssertTrue(SS.isSingleJoint(name), name)
        }
        for name in ["dumbbell lunge with bicep curl", "barbell bench press", "pull-up", "push-up",
                     "barbell bent over row"] {
            XCTAssertFalse(SS.isSingleJoint(name), name)
        }
        XCTAssertEqual(Catalog.record("barbell curl").factor.factor,
                       0.6 * 0.35 * (1 + 0.1 * 0.35), accuracy: 1e-12)
        XCTAssertEqual(Catalog.record("dumbbell lunge with bicep curl").factor.factor,
                       0.35 * (1 + 0.1 * 2), accuracy: 1e-12)
    }

    func testMovementOrderingF() {
        let f = { (name: String) in Catalog.record(name).factor.factor }
        XCTAssertGreaterThanOrEqual(f("barbell full squat"), f("barbell deadlift"))
        XCTAssertGreaterThan(f("barbell deadlift"), f("barbell bench press"))
        XCTAssertGreaterThan(f("barbell bench press"), f("barbell bent over row"))
        XCTAssertGreaterThan(f("barbell bent over row"), f("barbell curl"))
        XCTAssertGreaterThan(f("barbell curl"), f("barbell standing calf raise"))
        XCTAssertLessThan(f("lever leg extension"), f("barbell bench press"))

        // Any calf-primary single-joint move scores at most 0.6 x 0.25 x 1.4 = 0.21, below a curl.
        var checked = 0
        for record in Catalog.records where record.target == "calves" && SS.isSingleJoint(record.name) {
            XCTAssertLessThanOrEqual(record.factor.factor, 0.21 + 1e-12, record.name)
            checked += 1
        }
        XCTAssertGreaterThan(checked, 5)
    }

    func testMovementOrderingMatchedDose() {
        // 60 kg x 10 @ RPE 8, body weight 80 (E = 0.714286).
        let rows: [(String, Double, Double)] = [
            ("barbell full squat", 121.6, 1094.4),
            ("barbell deadlift", 121.6, 1007.5429),
            ("barbell bench press", 60, 398.8929),
            ("barbell bent over row", 60, 389.7857),
            ("lever leg extension", 60, 282.8571),
            ("barbell curl", 60, 93.15),
            ("barbell standing calf raise", 60, 77.1429),
        ]
        var previous = Double.infinity
        for (name, weff, dose) in rows {
            let result = SS.evaluate(Catalog.set(name, reps: 10, kg: 60, rpe: 8), bodyweightKg: 80)
            XCTAssertEqual(result.effort, 0.714286, accuracy: 1e-6, name)
            XCTAssertEqual(result.effectiveWeightKg, weff, accuracy: 1e-9, name)
            XCTAssertEqual(result.dose, dose, accuracy: 1e-4, name)
            XCTAssertLessThan(result.dose, previous, "\(name) breaks the strict order")
            previous = result.dose
        }
    }

    // MARK: - Set evaluation order (4.5)

    func testSkipReasonsFollowTheSpecifiedOrder() {
        let squat = Catalog.record("barbell full squat")
        func make(reps: Int = 5, kg: Double? = 100, warmup: Bool = false) -> SS.SetInput {
            squat.set(reps: reps, kg: kg, warmup: warmup)
        }
        XCTAssertEqual(SS.evaluate(make(reps: 0, warmup: true), bodyweightKg: 80).skip, .warmup)
        XCTAssertEqual(SS.evaluate(make(reps: 0), bodyweightKg: 80).skip, .noReps)
        XCTAssertEqual(SS.evaluate(make(reps: -3), bodyweightKg: 80).skip, .noReps)
        XCTAssertEqual(SS.evaluate(make(kg: .nan), bodyweightKg: 80).skip, .invalid)
        XCTAssertEqual(SS.evaluate(make(kg: .infinity), bodyweightKg: 80).skip, .invalid)
        // A non-finite weight on a stretch is `invalid` first, as the weight check precedes the classifier.
        let stretch = Catalog.record("assisted lying calves stretch")
        XCTAssertEqual(SS.evaluate(stretch.set(reps: 5, kg: .nan), bodyweightKg: 80).skip, .invalid)
        XCTAssertEqual(SS.evaluate(stretch.set(reps: 5, kg: 0), bodyweightKg: 80).skip, .stretch)
        let plank = SS.SetInput(exerciseName: "front plank", equipment: "body weight", primaryMuscle: "abs",
                                secondaryMuscles: [], reps: 1, weightKg: nil, rpe: nil, isWarmup: false)
        XCTAssertEqual(SS.evaluate(plank, bodyweightKg: 80).skip, .isometric)
        let cardio = SS.SetInput(exerciseName: "run", equipment: "body weight", primaryMuscle: "cardiovascular system",
                                 secondaryMuscles: [], reps: 10, weightKg: 0, rpe: 8, isWarmup: false)
        XCTAssertEqual(SS.evaluate(cardio, bodyweightKg: 80).skip, .cardio)
        XCTAssertEqual(SS.evaluate(Catalog.set("barbell bench press", reps: 5, kg: nil), bodyweightKg: 80).skip, .noWeight)
        XCTAssertEqual(SS.evaluate(make(reps: 101), bodyweightKg: 80).skip, .implausible)
        XCTAssertEqual(SS.evaluate(make(kg: 600), bodyweightKg: 80).skip, .implausible)
        XCTAssertEqual(SS.evaluate(make(reps: 100, kg: 100), bodyweightKg: 80).skip, nil)
        // 500 kg of effective weight is allowed; the cap is strict.
        let edge = SS.SetInput(exerciseName: "barbell bench press", equipment: "barbell", primaryMuscle: "pectorals",
                               secondaryMuscles: [], reps: 5, weightKg: 500, rpe: 8, isWarmup: false)
        XCTAssertNil(SS.evaluate(edge, bodyweightKg: 80).skip)
        var over = edge
        over.weightKg = 500.0001
        XCTAssertEqual(SS.evaluate(over, bodyweightKg: 80).skip, .implausible)
        // Every skip leaves a zero dose.
        XCTAssertEqual(SS.evaluate(make(reps: 101), bodyweightKg: 80).dose, 0)
    }

    func testDoseCountsAtMostFifteenRepsAndEffortStopsAtTwelve() {
        let bench = Catalog.record("barbell bench press")
        func dose(_ reps: Int) -> Double { SS.evaluate(bench.set(reps: reps, kg: 60, rpe: 8), bodyweightKg: 80).dose }
        XCTAssertLessThan(dose(11), dose(12))
        XCTAssertEqual(dose(13) / dose(12), 13.0 / 12.0, accuracy: 1e-12)
        XCTAssertLessThan(dose(14), dose(15))
        XCTAssertEqual(dose(15).bitPattern, dose(16).bitPattern)
        XCTAssertEqual(dose(15).bitPattern, dose(100).bitPattern)
    }

    func testMissingRPEUsesTheDefaultAndUnratedMathIsTheSame() {
        let bench = Catalog.record("barbell bench press")
        let missing = SS.evaluate(bench.set(reps: 8, kg: 70, rpe: nil), bodyweightKg: 80)
        let eight = SS.evaluate(bench.set(reps: 8, kg: 70, rpe: 8), bodyweightKg: 80)
        XCTAssertEqual(missing.dose.bitPattern, eight.dose.bitPattern)
    }

    func testUnmappedSetsAreCounted() {
        let sets = [
            SS.SetInput(exerciseName: "barbell bench press", equipment: "barbell", primaryMuscle: nil,
                        secondaryMuscles: [], reps: 8, weightKg: 60, rpe: 8, isWarmup: false),
            SS.SetInput(exerciseName: "barbell bench press", equipment: "barbell", primaryMuscle: "pectorals",
                        secondaryMuscles: [], reps: 8, weightKg: 60, rpe: 8, isWarmup: false),
        ]
        let session = SS.evaluate(sets: sets, bodyweightKg: 80)
        XCTAssertEqual(session.unmappedSets, 1)
        XCTAssertEqual(session.countedSets, 2)
        XCTAssertTrue(session.sets[0].unmappedPrimary)
        XCTAssertFalse(session.sets[1].unmappedPrimary)
    }

    // MARK: - Worked examples (4.8)

    /// Examples 1 to 7 of the plan, each at its stated tolerance; the helpers below carry the numbers.
    func testWorkedExamples() {
        workedExample1HeavyLegs()
        workedExample2IsolationArms()
        workedExample3Bodyweight()
        workedExample4MockupPushDay()
        workedExample5NoWorkingSetsLeavesTheScoreBitIdentical()
        workedExample6DemoUpperBodyA()
        workedExample7VeryBigDay()
    }

    /// Runs a session and checks D, V, M, the stored and display result and the set counts.
    private func check(_ sets: [SS.SetInput], bodyweight: Double, hrDisplay: Double,
                       dose: Double, volume: Double, muscular: Double, stored: Double, display: Double,
                       working: Int, warmups: Int, counted: Int,
                       file: StaticString = #filePath, line: UInt = #line) {
        let session = SS.evaluate(sets: sets, bodyweightKg: bodyweight)
        XCTAssertEqual(session.formulaVersion, 1, file: file, line: line)
        XCTAssertEqual(session.dose, dose, accuracy: 0.01, "D", file: file, line: line)
        XCTAssertEqual(session.volume, volume, accuracy: 1e-6, "V", file: file, line: line)
        XCTAssertEqual(session.muscularLoad, muscular, accuracy: 1e-6, "M", file: file, line: line)
        let hrStored = StrainScorerV2.storedValue(fromDisplay: hrDisplay)
        let combined = SS.combine(hrStored: hrStored, muscularLoad: session.muscularLoad)
        XCTAssertEqual(combined, stored, accuracy: 1e-6, "stored", file: file, line: line)
        XCTAssertEqual(StrainScorerV2.displayValue(fromStored: combined), display, accuracy: 1e-6,
                       "display", file: file, line: line)
        XCTAssertEqual(session.workingSets, working, file: file, line: line)
        XCTAssertEqual(session.warmupSets, warmups, file: file, line: line)
        XCTAssertEqual(session.countedSets, counted, file: file, line: line)
    }

    private func assertSet(_ result: SS.SetResult, weight: Double, effort: Double, factor: Double, dose: Double,
                           _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(result.effectiveWeightKg, weight, accuracy: 1e-6, "\(message) W", file: file, line: line)
        XCTAssertEqual(result.effort, effort, accuracy: 1e-6, "\(message) E", file: file, line: line)
        XCTAssertEqual(result.massFactor, factor, accuracy: 1e-12, "\(message) F", file: file, line: line)
        XCTAssertEqual(result.dose, dose, accuracy: 0.01, "\(message) dose", file: file, line: line)
    }

    private func workedExample1HeavyLegs() {
        let sets = Catalog.sets("barbell full squat", count: 5, reps: 5, kg: 140)
            + Catalog.sets("barbell full squat", count: 2, reps: 5, kg: 70, warmup: true)
            + Catalog.sets("barbell romanian deadlift", count: 3, reps: 8, kg: 100)
            + Catalog.sets("dumbbell lunge", count: 3, reps: 10, kg: 24)
        check(sets, bodyweight: 80, hrDisplay: 4.0, dose: 10770.1810, volume: 134.627262, muscular: 30.739257,
              stored: 69.022556, display: 14.494737, working: 11, warmups: 2, counted: 11)
        let session = SS.evaluate(sets: sets, bodyweightKg: 80)
        assertSet(session.sets[0], weight: 201.6, effort: 0.810811, factor: 1.26, dose: 1029.7946, "squat")
        assertSet(session.sets[7], weight: 161.6, effort: 0.75, factor: 1.16, dose: 1124.7360, "RDL")
        assertSet(session.sets[10], weight: 85.6, effort: 0.714286, factor: 1.225, dose: 749.0, "lunge")
    }

    private func workedExample2IsolationArms() {
        let sets = Catalog.sets("barbell curl", count: 4, reps: 12, kg: 30)
            + Catalog.sets("cable pushdown", count: 4, reps: 12, kg: 25)
            + Catalog.sets("dumbbell lateral raise", count: 4, reps: 15, kg: 10)
        check(sets, bodyweight: 80, hrDisplay: 2.0, dose: 547.3391, volume: 6.841739, muscular: 3.352124,
              stored: 18.522014, display: 3.889623, working: 12, warmups: 0, counted: 12)
        let session = SS.evaluate(sets: sets, bodyweightKg: 80)
        XCTAssertEqual(session.sets[0].effort, 0.681818, accuracy: 1e-6)
        XCTAssertEqual(session.sets[0].massFactor, 0.21735, accuracy: 1e-12)
        XCTAssertEqual(session.sets[0].dose, 53.3495, accuracy: 0.001)
        XCTAssertEqual(session.sets[4].dose, 44.4580, accuracy: 0.001)
        XCTAssertEqual(session.sets[8].dose, 39.0273, accuracy: 0.001)
    }

    private func workedExample3Bodyweight() {
        let sets = Catalog.sets("pull-up", count: 4, reps: 8, kg: 0)
            + Catalog.sets("push-up", count: 4, reps: 20, kg: 0)
            + Catalog.sets("chest dip", count: 3, reps: 10, kg: 0)
            + Catalog.sets("walking lunge", count: 3, reps: 20, kg: 0)
        check(sets, bodyweight: 80, hrDisplay: 3.0, dose: 7434.9455, volume: 92.936819, muscular: 26.456597,
              stored: 62.503378, display: 13.125709, working: 14, warmups: 0, counted: 14)
        let session = SS.evaluate(sets: sets, bodyweightKg: 80)
        assertSet(session.sets[0], weight: 74.4, effort: 0.75, factor: 0.9095, dose: 406.0008, "pull-up")
        assertSet(session.sets[4], weight: 51.2, effort: 0.681818, factor: 0.9605, dose: 502.9527, "push-up")
        assertSet(session.sets[8], weight: 74.4, effort: 0.714286, factor: 0.93075, dose: 494.6271, "dip")
        XCTAssertEqual(session.sets[11].effectiveWeightKg, 61.6, accuracy: 1e-9)
        XCTAssertEqual(session.sets[11].massFactor, 1.225, accuracy: 1e-12)
        XCTAssertEqual(session.sets[11].dose, 771.75, accuracy: 0.01)
    }

    private func workedExample4MockupPushDay() {
        let sets = Catalog.sets("barbell bench press", count: 4, reps: 8, kg: 80, rpe: 8.5)
            + Catalog.sets("barbell bench press", count: 3, reps: 5, kg: 40, rpe: nil, warmup: true)
            + Catalog.sets("dumbbell incline bench press", count: 3, reps: 10, kg: 30, rpe: 8.5)
            + Catalog.sets("barbell standing wide military press", count: 3, reps: 8, kg: 45, rpe: 8.5)
            + Catalog.sets("dumbbell lateral raise", count: 3, reps: 15, kg: 10)
            + Catalog.sets("cable pushdown", count: 3, reps: 12, kg: 30, rpe: 8.5)
            + Catalog.sets("cable incline fly", count: 2, reps: 12, kg: 15, rpe: 8.5)
        check(sets, bodyweight: 80, hrDisplay: 6.4, dose: 3384.0388, volume: 42.300485, muscular: 16.327410,
              stored: 58.260926, display: 12.234795, working: 18, warmups: 3, counted: 18)
        check(sets, bodyweight: 80, hrDisplay: 2.5, dose: 3384.0388, volume: 42.300485, muscular: 16.327410,
              stored: 47.111448, display: 9.893404,
              working: 18, warmups: 3, counted: 18)
        let session = SS.evaluate(sets: sets, bodyweightKg: 80)
        assertSet(session.sets[0], weight: 80, effort: 0.759494, factor: 0.93075, dose: 452.4152, "bench")
        XCTAssertEqual(session.sets[7].dose, 201.8494, accuracy: 0.001)
        assertSet(session.sets[10], weight: 45, effort: 0.759494, factor: 0.672, dose: 183.7367, "military press")
        XCTAssertEqual(session.sets[13].massFactor, 0.3816, accuracy: 1e-12)
        XCTAssertEqual(session.sets[16].dose, 53.9628, accuracy: 0.001)
        XCTAssertEqual(session.sets[19].massFactor, 0.55845, accuracy: 1e-12)
        XCTAssertEqual(session.sets[19].dose, 69.3248, accuracy: 0.001)
    }

    /// A day with only warm-ups has no muscular load, so the score is the heart-rate score bit for bit.
    private func workedExample5NoWorkingSetsLeavesTheScoreBitIdentical() {
        let sets = Catalog.sets("barbell bench press", count: 3, reps: 5, kg: 40, warmup: true)
        let session = SS.evaluate(sets: sets, bodyweightKg: 80)
        XCTAssertEqual(session.muscularLoad, 0)
        XCTAssertEqual(session.dose, 0)
        XCTAssertEqual(session.workingSets, 0)
        XCTAssertEqual(session.warmupSets, 3)
        XCTAssertEqual(session.countedSets, 0)
        XCTAssertEqual(session.skipped[.warmup], 3)
        let hrStored = StrainScorerV2.storedValue(fromDisplay: 5.0)
        XCTAssertEqual(hrStored, 23.809524, accuracy: 1e-6)
        let combined = SS.combine(hrStored: hrStored, muscularLoad: session.muscularLoad)
        XCTAssertEqual(combined.bitPattern, hrStored.bitPattern)
    }

    /// "Upper body A" from the demo seeder: body weight 75, no RPE, no equipment, the seeder's own muscle tokens.
    private func workedExample6DemoUpperBodyA() {
        func lift(_ name: String, primary: String, secondary: [String], _ sets: [(Double, Int, Bool)]) -> [SS.SetInput] {
            sets.map { kg, reps, warmup in
                SS.SetInput(exerciseName: name, equipment: nil, primaryMuscle: primary, secondaryMuscles: secondary,
                            reps: reps, weightKg: kg, rpe: nil, isWarmup: warmup)
            }
        }
        let sets = lift("Bench press", primary: "chest", secondary: ["frontDelts", "triceps"],
                        [(40, 10, true), (70, 8, false), (72.5, 8, false), (72.5, 7, false), (70, 8, false)])
            + lift("Barbell row", primary: "upperBack", secondary: ["lats", "biceps"],
                   [(60, 10, false), (60, 10, false), (62.5, 8, false)])
            + lift("Overhead press", primary: "frontDelts", secondary: ["triceps", "sideDelts"],
                   [(40, 8, false), (40, 8, false), (42.5, 6, false)])
            + lift("Lat pulldown", primary: "lats", secondary: ["biceps"],
                   [(55, 12, false), (55, 12, false), (57.5, 10, false)])
        check(sets, bodyweight: 75, hrDisplay: 9.996, dose: 4323.7821, volume: 57.650428, muscular: 20.201083,
              stored: 72.127996, display: 15.146879, working: 13, warmups: 1, counted: 13)
        XCTAssertEqual(StrainScorerV2.storedValue(fromDisplay: 9.996), 47.6, accuracy: 1e-9)
        let session = SS.evaluate(sets: sets, bodyweightKg: 75)
        XCTAssertEqual(session.sets[1].massFactor, 0.93075, accuracy: 1e-12)
        XCTAssertEqual(session.sets[5].massFactor, 0.952, accuracy: 1e-12)
        XCTAssertEqual(session.sets[8].massFactor, 0.657, accuracy: 1e-12)
        XCTAssertEqual(session.sets[11].massFactor, 0.87975, accuracy: 1e-12)
        XCTAssertEqual(session.unmappedSets, 0)
    }

    private func workedExample7VeryBigDay() {
        let sets = Catalog.sets("barbell full squat", count: 5, reps: 5, kg: 160, rpe: 9)
            + Catalog.sets("barbell deadlift", count: 5, reps: 5, kg: 180, rpe: 9)
            + Catalog.sets("barbell bench press", count: 5, reps: 5, kg: 110, rpe: 9)
            + Catalog.sets("barbell bent over row", count: 4, reps: 8, kg: 90)
            + Catalog.sets("dumbbell lunge", count: 4, reps: 10, kg: 30)
            + Catalog.sets("pull-up", count: 4, reps: 8, kg: 10)
        let session = SS.evaluate(sets: sets, bodyweightKg: 80)
        XCTAssertEqual(session.volume, 260.017983, accuracy: 1e-6)
        XCTAssertEqual(session.muscularLoad, 35.122803, accuracy: 1e-6)
        let combined = SS.combine(hrStored: StrainScorerV2.storedValue(fromDisplay: 5.0), muscularLoad: session.muscularLoad)
        XCTAssertEqual(StrainScorerV2.displayValue(fromStored: combined), 15.661199, accuracy: 1e-6)
    }

    // MARK: - Session behaviour

    func testSessionSkipCountsAndShuffleExactness() {
        var sets = Catalog.sets("barbell full squat", count: 3, reps: 5, kg: 100)
        sets += Catalog.sets("barbell full squat", count: 1, reps: 5, kg: 60, warmup: true)
        sets += [Catalog.set("barbell bench press", reps: 5, kg: nil), Catalog.set("barbell curl", reps: 0, kg: 20),
                 Catalog.set("hamstring stretch", reps: 1, kg: nil), Catalog.set("barbell curl", reps: 10, kg: .nan)]
        let session = SS.evaluate(sets: sets, bodyweightKg: 80)
        XCTAssertEqual(session.skipped, [.warmup: 1, .noWeight: 1, .noReps: 1, .stretch: 1, .invalid: 1])
        XCTAssertEqual(session.workingSets, 7)
        XCTAssertEqual(session.countedSets, 3)
        XCTAssertEqual(session.sets.count, sets.count)
        let reversed = SS.evaluate(sets: sets.reversed(), bodyweightKg: 80)
        XCTAssertEqual(reversed.dose.bitPattern, session.dose.bitPattern)
        XCTAssertEqual(reversed.muscularLoad.bitPattern, session.muscularLoad.bitPattern)
    }

    func testMuscularLoadCurve() {
        XCTAssertEqual(SS.muscularLoad(volume: 0), 0)
        XCTAssertEqual(SS.muscularLoad(volume: -5), 0)
        XCTAssertEqual(SS.muscularLoad(volume: .nan), 0)
        XCTAssertEqual(SS.muscularLoad(volume: .infinity), 0)
        XCTAssertEqual(SS.muscularLoad(volume: 70), 36 * (1 - exp(-1.0)), accuracy: 1e-12)
        XCTAssertLessThanOrEqual(SS.muscularLoad(volume: 1e9), 36)
        XCTAssertEqual(SS.muscularLoad(volume: 1e9), 36, accuracy: 1e-12)
    }

    // MARK: - Combination (4.6, 4.7)

    func testCombineIdentitiesAndBounds() {
        for h in [0.0, 9.523810, 47.6, 100.0] {
            for m in [0.0, -1.0, .nan, .infinity, -.infinity] as [Double] {
                XCTAssertEqual(SS.combine(hrStored: h, muscularLoad: m).bitPattern, h.bitPattern,
                               "h \(h) m \(m)")
                XCTAssertEqual(SS.combinedDisplay(hrDisplay: h * 21 / 100, muscularLoad: m).bitPattern,
                               (h * 21 / 100).bitPattern)
            }
        }
        XCTAssertEqual(SS.combine(hrStored: 100, muscularLoad: 36), 100)
        XCTAssertEqual(SS.combine(hrStored: 100, muscularLoad: 1e308), 100)

        // The bounds table: heart-rate display -> combined display at the full 36.
        let bounds: [(Double, Double)] = [
            (0, 14.182298), (2, 14.831603), (5, 15.805561), (10, 17.428823),
            (14, 18.727433), (18, 20.026043), (20.5, 20.837674), (21, 21),
        ]
        for (hr, combined) in bounds {
            let stored = SS.combine(hrStored: StrainScorerV2.storedValue(fromDisplay: hr), muscularLoad: 36)
            XCTAssertEqual(StrainScorerV2.displayValue(fromStored: stored), combined, accuracy: 1e-6, "hr \(hr)")
            XCTAssertEqual(SS.combinedDisplay(hrDisplay: hr, muscularLoad: 36), combined, accuracy: 1e-6, "hr \(hr)")
            // Past the cap nothing more is added.
            XCTAssertEqual(SS.combine(hrStored: StrainScorerV2.storedValue(fromDisplay: hr), muscularLoad: 80).bitPattern,
                           stored.bitPattern)
        }
        XCTAssertNil(SS.combine(hrStored: nil, muscularLoad: 10))
        let plain: Double = SS.combine(hrStored: 40.0, muscularLoad: 10)
        let wrapped: Double? = SS.combine(hrStored: Optional(40.0), muscularLoad: 10)
        XCTAssertEqual(wrapped, plain)
        XCTAssertGreaterThan(SS.combine(hrStored: 40, muscularLoad: 10), 40)
        XCTAssertTrue(SS.combine(hrStored: Double.nan, muscularLoad: 10).isNaN)
    }

    func testSplit() {
        let split = SS.split(hrStored: StrainScorerV2.storedValue(fromDisplay: 4.0), muscularLoad: 30.739257)
        XCTAssertEqual(split.heartRateDisplay, 4.0, accuracy: 1e-12)
        XCTAssertEqual(split.combinedDisplay, 14.494737, accuracy: 1e-6)
        XCTAssertEqual(split.setsAddDisplay, 10.494737, accuracy: 1e-6)
        let none = SS.split(hrStored: 30, muscularLoad: 0)
        XCTAssertEqual(none.setsAddDisplay, 0)
    }

    func testDayMuscularLoadOrdering() {
        XCTAssertEqual(SS.dayMuscularLoad([3, .nan, -1, 1e-300, 7, 0]).bitPattern,
                       SS.dayMuscularLoad([7, 1e-300, 3]).bitPattern)
        XCTAssertEqual(SS.dayMuscularLoad([]), 0)
        XCTAssertEqual(SS.dayMuscularLoad([.nan, .infinity, -2, 0]), 0)
        var rng = SplitMix64(seed: 0x5EED_2360)
        for _ in 0..<200 {
            var loads = (0..<10).map { _ in rng.double(in: 0.001...36) * pow(10, Double(rng.int(in: -6...2))) }
            let reference = SS.dayMuscularLoad(loads).bitPattern
            for _ in 0..<5 {
                // Fisher-Yates with the seeded generator.
                for index in stride(from: loads.count - 1, to: 0, by: -1) {
                    loads.swapAt(index, rng.int(in: 0...index))
                }
                XCTAssertEqual(SS.dayMuscularLoad(loads).bitPattern, reference)
            }
        }
    }

    // MARK: - Day combine with floors (ADDENDUM A7)

    private func dayComponents(_ day: String, _ context: String) -> StrainScorerV2.DayStrainComponents {
        let samples = StrainDayFixtures.days.first { $0.name == day }!.samples
        let value = StrainDayFixtures.contexts.first { $0.name == context }!.value
        return StrainScorerV2.dayStrainComponents(samples, maxHR: StrainDayFixtures.maxHR,
                                                  restingHR: StrainDayFixtures.restingHR, context: value)
    }

    private func stored(_ display: Double) -> Double { StrainScorerV2.storedValue(fromDisplay: display) }

    /// A step-floor-dominated day plus a lift gives max(floor, combine(cardio, M)), not combine(floor, M).
    func testStepFloorDominatedDayIsMaxOfFloorAndCombinedCardio() {
        let components = dayComponents("resting 6 h", "big steps")
        XCTAssertEqual(components.dominant, .steps)
        let cardio = components.cardio!, steps = components.steps!
        XCTAssertGreaterThan(steps, cardio)
        let floor = stored(steps)

        // A big lift: combined cardio clears the floor, so the lift decides the day.
        let big = SS.combineDay(components: components, muscularLoad: 20)!
        let combinedCardio = SS.combine(hrStored: stored(cardio), muscularLoad: 20)
        XCTAssertGreaterThan(combinedCardio, floor)
        XCTAssertEqual(big.bitPattern, combinedCardio.bitPattern)
        let inverted = SS.combine(hrStored: components.score!, muscularLoad: 20)
        XCTAssertGreaterThan(inverted, big, "inverting the stored floor over-credits the lift")

        // A small lift: combined cardio stays under the floor, so the day is exactly its floor score.
        let small = SS.combineDay(components: components, muscularLoad: 2)!
        XCTAssertLessThan(SS.combine(hrStored: stored(cardio), muscularLoad: 2), floor)
        XCTAssertEqual(small.bitPattern, components.score!.bitPattern)
        XCTAssertGreaterThan(SS.combine(hrStored: components.score!, muscularLoad: 2), small)
    }

    func testEnergyFloorKeepsItsOwnFloor() {
        let components = dayComponents("resting 6 h", "big energy")
        XCTAssertEqual(components.dominant, .energy)
        let small = SS.combineDay(components: components, muscularLoad: 1)!
        XCTAssertEqual(small.bitPattern, components.score!.bitPattern)
        let big = SS.combineDay(components: components, muscularLoad: 36)!
        XCTAssertEqual(big, max(stored(components.energy!), stored(components.steps ?? 0),
                                SS.combine(hrStored: stored(components.cardio!), muscularLoad: 36)))
        XCTAssertGreaterThan(big, components.score!)
    }

    /// When cardio decides the day the floors are irrelevant and both paths agree to the bit.
    func testCardioDominatedDayMatchesTheStoredScoreInversion() {
        let components = dayComponents("hard hour in a resting day", "all three")
        XCTAssertEqual(components.dominant, .cardio)
        for m in [0.5, 5, 16.3, 36, 80] {
            XCTAssertEqual(SS.combineDay(components: components, muscularLoad: m)!.bitPattern,
                           SS.combine(hrStored: components.score!, muscularLoad: m).bitPattern, "m \(m)")
        }
    }

    func testDayCombineIdentityAndUnscoredDays() {
        for (day, context) in [("hard hour in a resting day", "all three"), ("resting 6 h", "big steps"),
                               ("light walking 8 h", "sleep only"), ("resting 6 h", "zeros")] {
            let components = dayComponents(day, context)
            let score = components.score!
            for m in [0.0, -1.0, .nan, .infinity] as [Double] {
                XCTAssertEqual(SS.combineDay(components: components, muscularLoad: m)!.bitPattern, score.bitPattern,
                               "\(day) \(context) m \(m)")
            }
            for m in [0.5, 10, 36, 1e9] {
                let combined = SS.combineDay(components: components, muscularLoad: m)!
                XCTAssertGreaterThanOrEqual(combined, score)
                XCTAssertLessThanOrEqual(combined, 100)
            }
        }
        let unscored = dayComponents("empty", "bare")
        XCTAssertNil(unscored.score)
        XCTAssertNil(SS.combineDay(components: unscored, muscularLoad: 20))
        XCTAssertNil(SS.combineDay(components: .unscored, muscularLoad: 0))
        XCTAssertNil(SS.split(components: unscored, muscularLoad: 20))
    }

    /// The documented fallback: with a score but no cardio component, the stored score is inverted as cardio.
    func testComponentsWithoutCardioFallBackToTheStoredScoreInversion() {
        let partial = StrainScorerV2.DayStrainComponents(cardio: nil, steps: 5, energy: nil, score: 30, dominant: nil)
        XCTAssertEqual(SS.combineDay(components: partial, muscularLoad: 12)!.bitPattern,
                       SS.combine(hrStored: 30, muscularLoad: 12).bitPattern)
        XCTAssertEqual(SS.combineDay(components: partial, muscularLoad: 0)!.bitPattern, Double(30).bitPattern)
    }

    func testDaySplitUsesTheFloors() {
        let components = dayComponents("resting 6 h", "big steps")
        let split = SS.split(components: components, muscularLoad: 2)!
        XCTAssertEqual(split.heartRateDisplay, StrainScorerV2.displayValue(fromStored: components.score!))
        XCTAssertEqual(split.setsAddDisplay, 0)
        let big = SS.split(components: components, muscularLoad: 20)!
        XCTAssertGreaterThan(big.setsAddDisplay, 0)
    }
}
