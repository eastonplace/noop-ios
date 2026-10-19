import Foundation

/// Strength Strain v1: NOOP's own formula for the muscular part of a lift's Strain.
///
/// This is pure arithmetic over the sets a person logged. It reads no store, no clock and no heart rate, so
/// every number can be redone by hand and every function is deterministic down to the bit. It is NOOP's own
/// formula. It is not WHOOP's: WHOOP publishes neither its weights nor its formula, and nothing here claims
/// parity with them. The shape follows what WHOOP and the sports-science literature say in public:
/// - Muscular load is volume times intensity. Volume is reps times the *effective* mass moved (the bar plus
///   the part of the body that moves), and intensity is how close the set was to failure (reps in reserve).
/// - A movement profile weights what the lift trains: a squat counts for more than a curl.
/// - The muscular load joins heart-rate load *before* the 0...21 curve, never as an added score.
///
/// Where NOOP departs from WHOOP, on purpose:
/// 1. No personal history baseline. Volume is normalised by body weight, which is deterministic and has no
///    reference cliffs or outlier poisoning.
/// 2. No rep speed. The strap exposes no rep velocity.
/// 3. Warm-ups are excluded, and isometric holds and stretches stay heart-rate only.
/// 4. Two lifts in one day share one muscular cap, applied inside ``combine(hrStored:muscularLoad:)``.
///
/// Weights are used exactly as logged, in kilograms. A dumbbell weight is the weight in ONE hand, as the
/// logging screen asks for it, so a bilateral dumbbell press earns about half the credit of the same total
/// load on a barbell. That is the stated convention, not an oversight.
///
/// Single point of tuning: every constant is one `static let`. Changing any of them means bumping ``version``,
/// which re-runs the backfill that stores the scores.
///
/// Pure and nonisolated: a plain enum with no actor, safe to call from any task.
public enum StrengthStrain {

    // MARK: - Constants

    /// The formula version. A bump re-runs the backfill under a new job key.
    public static let version = 1
    /// Reps counted per set. High-rep, low-load work must not swamp heavy work.
    public static let countedRepsCap = 15
    /// Reps that move the effort term. Epley is valid near 10 reps or fewer (Reynolds 2006); 12 is the edge of
    /// the RTS table. Effort stops falling above it, so a set's dose never falls as reps rise.
    public static let effortRepsCap = 12
    /// The RPE used when none was logged, or when it is non-finite or not above 0. The live logger defaults a
    /// new set to RPE 8.
    public static let defaultRPE = 8.0
    /// The lowest RPE that counts. Anything easier is treated as this.
    public static let minRPE = 5.0
    /// The highest RPE that counts (failure).
    public static let maxRPE = 10.0
    /// The most muscular load one session or day can add (M_MAX). Lifting alone tops out at 14.18 on the 0...21
    /// scale, and a hard heart-rate day of 14 plus the maximum is 18.73, so 21 stays very hard to reach. Calibrated
    /// on the owner's own WHOOP Strength Trainer history.
    public static let maxMuscularLoad = 36.0
    /// Body-weights of dose at which the muscular load reaches 63% of ``maxMuscularLoad`` (V0).
    public static let volumeScale = 70.0
    /// The lightest body weight used, in kilograms. Guards a typo from inflating every volume.
    public static let minBodyweightKg = 30.0
    /// The heaviest body weight used, in kilograms.
    public static let maxBodyweightKg = 250.0
    /// The body weight used when the profile has none (the app's default profile weight).
    public static let defaultBodyweightKg = 75.0
    /// Effective weight above this is not a plausible single set; it is skipped as `implausible`.
    public static let maxEffectiveWeightKg = 500.0
    /// Reps above this are not a plausible single set; they are skipped as `implausible`.
    public static let maxReps = 100
    /// 45-degree sled machines report the sled's load; only sin(45 degrees) of it acts along the lift.
    public static let sledScale = 0.71
    /// The bonus each known secondary muscle adds to a movement's mass factor (multiplicative).
    public static let secondaryWeight = 0.1
    /// The most the secondary-muscle bonus can add to a movement's mass factor.
    public static let secondaryCap = 0.4
    /// The mass weight of an unknown or missing primary muscle (the set is counted as unmapped).
    public static let unknownPrimaryMass = 0.6
    /// The discount for single-joint isolation moves, so a calf raise scores below a curl and a leg extension
    /// below a bench press.
    public static let singleJointFactor = 0.6
    /// The share of body weight moved in a pull-up, chin-up, dip or muscle-up (ExRx segment model, 0.928).
    public static let hangDipFraction = 0.93
    /// The share of body weight moved in a standard push-up (Ebben 2011 force plate).
    public static let pushUpStandardFraction = 0.64
    /// The share of body weight moved in a bent-knee push-up (Ebben 2011).
    public static let pushUpKneeFraction = 0.49
    /// The share of body weight moved in a wall push-up (Ebben 2011, hands raised 61 cm, as a proxy).
    public static let pushUpWallFraction = 0.41
    /// The share of body weight moved in an incline push-up (Ebben 2011, hands raised 30 cm).
    public static let pushUpInclineFraction = 0.55
    /// The share of body weight moved in a decline push-up (Ebben 2011, feet raised 30 cm).
    public static let pushUpDeclineFraction = 0.70
    /// The share of body weight moved in a standing lower-body lift (ExRx squat and deadlift, 0.7705).
    public static let lowerBodyFraction = 0.77
    /// The share of body weight moved in core and other bodyweight moves (conservative).
    public static let otherBodyweightFraction = 0.30

    /// The reps-to-failure constant of the Epley estimate: failure at 30 reps is roughly 0% of one rep max.
    private static let epleyReps = 30.0

    // MARK: - Types

    /// Why a set earned no dose.
    public enum SkipReason: String, CaseIterable, Codable, Sendable {
        case warmup, noReps, invalid, stretch, isometric, cardio, noWeight, implausible
    }

    /// How an exercise's load is made of external weight and body weight.
    public enum LoadKind: Equatable, Sendable {
        /// External weight plus a share of body weight that moves with it (0 for most gym lifts).
        case external(bodyFraction: Double)
        /// A share of body weight, plus any logged weight as added load.
        case bodyweight(fraction: Double)
        /// A share of body weight, minus any logged weight as assistance.
        case assisted(fraction: Double)
        /// Earns no dose.
        case skip(SkipReason)
    }

    /// One logged set, with everything the formula needs and nothing it does not.
    public struct SetInput: Equatable, Sendable {
        public var exerciseName: String
        public var equipment: String?
        public var primaryMuscle: String?
        public var secondaryMuscles: [String]
        public var reps: Int
        /// Kilograms, as logged (one hand's weight for a dumbbell). Nil means no weight was logged.
        public var weightKg: Double?
        public var rpe: Double?
        public var isWarmup: Bool

        public init(exerciseName: String, equipment: String?,
                    primaryMuscle: String?, secondaryMuscles: [String],
                    reps: Int, weightKg: Double?, rpe: Double?, isWarmup: Bool) {
            self.exerciseName = exerciseName
            self.equipment = equipment
            self.primaryMuscle = primaryMuscle
            self.secondaryMuscles = secondaryMuscles
            self.reps = reps
            self.weightKg = weightKg
            self.rpe = rpe
            self.isWarmup = isWarmup
        }
    }

    /// One set's evaluation. Fields the evaluation never reached (it stopped at `skip`) are 0.
    public struct SetResult: Equatable, Sendable {
        public let dose: Double
        public let effectiveWeightKg: Double
        public let effort: Double
        public let massFactor: Double
        public let skip: SkipReason?
        /// The set's primary muscle was missing or unknown, so it used ``unknownPrimaryMass``.
        public let unmappedPrimary: Bool
    }

    /// A session's evaluation.
    public struct SessionResult: Equatable, Sendable {
        public let formulaVersion: Int
        public let bodyweightKg: Double
        /// Sum of every set's dose, added smallest first so the sum does not depend on set order.
        public let dose: Double
        /// `dose` per kilogram of body weight.
        public let volume: Double
        /// The muscular load on the same load scale as heart-rate load, 0...``maxMuscularLoad``.
        public let muscularLoad: Double
        /// Sets that are not warm-ups.
        public let workingSets: Int
        public let warmupSets: Int
        /// Sets that earned a dose.
        public let countedSets: Int
        /// Counted sets whose primary muscle was missing or unknown.
        public let unmappedSets: Int
        /// Every skipped set by reason, warm-ups included.
        public let skipped: [SkipReason: Int]
        /// One result per input set, in input order.
        public let sets: [SetResult]
    }

    /// A score before and after the sets, on the 0...21 display scale.
    public struct Split: Equatable, Sendable {
        public let heartRateDisplay: Double
        public let combinedDisplay: Double
        /// What the logged sets add on top of heart rate.
        public var setsAddDisplay: Double { combinedDisplay - heartRateDisplay }

        public init(heartRateDisplay: Double, combinedDisplay: Double) {
            self.heartRateDisplay = heartRateDisplay
            self.combinedDisplay = combinedDisplay
        }
    }

    // MARK: - Token lists (classifier and mass factor)

    /// Names that hang from a bar or dip: a share of body weight moves.
    static let hangTokens = ["pull up", "pull-up", "pullup", "chin up", "chin-up", "chinup", "muscle up", "muscle-up"]
    /// Names that look like a hang or dip but are not.
    static let hangExclusionTokens = ["bench", "floor", "scapula", "leg curl"]
    static let pushUpTokens = ["push up", "push-up", "pushup"]
    /// Held positions: no reps to speak of, so heart rate only.
    static let isometricTokens = ["plank", "dead hang", "hold", "l-sit", "wall sit", "isometric", "planche",
                                  "front lever", "back lever", "maltese"]
    static let coreTokens = ["sit up", "sit-up", "situp", "crunch", "plank", "leg raise", "knee raise",
                             "hyperextension", "back extension", "v up", "v-up", "russian twist", "hollow",
                             "dead bug", "flutter"]
    /// Standing lower-body names; "calf raise" is deliberately not here.
    static let lowerTokens = ["squat", "lunge", "deadlift", "step up", "step-up", "good morning", "clean", "snatch",
                              "thruster", "split squat", "jump", "burpee", "swing"]
    /// Postures in which the body is not lifted.
    static let seatedTokens = ["seated", "sitting", "lying", "supine", "prone", "kneeling", "on knees",
                               "leg press", "calf press"]
    static let singleJointTokens = ["extension", "curl", "raise", "fly", "flye", "kickback", "pushdown", "push down",
                                    "abduction", "adduction", "shrug", "crossover", "pec deck"]
    static let multiJointTokens = ["press", "row", "dip"]
    /// A primary muscle that means the exercise is cardio, which scores heart rate only.
    static let cardioPrimaryTokens = ["cardiovascular system", "cardio"]

    /// Mass weight by muscle token (primary-muscle weight; the same table weights secondaries).
    private static let muscleMassByToken: [String: Double] = {
        let groups: [(mass: Double, tokens: [String])] = [
            (1.0, ["glutes", "quads", "quadriceps", "hamstrings", "legs", "posterior chain"]),
            (0.85, ["lats", "latissimus dorsi", "upper back", "upperback", "back", "pectorals", "chest",
                    "upper chest"]),
            (0.6, ["delts", "deltoids", "shoulders", "front deltoids", "side deltoids", "rear deltoids",
                   "front delts", "side delts", "rear delts", "frontdelts", "sidedelts", "reardelts", "traps",
                   "trapezius", "rhomboids", "lower back", "lowerback", "spine", "adductors", "abductors",
                   "inner thighs", "groin", "hip flexors", "serratus anterior"]),
            (0.35, ["biceps", "triceps", "brachialis", "forearms", "wrist flexors", "wrist extensors", "wrists",
                    "hands", "grip muscles", "grip/posture", "grip", "shins", "ankles", "ankle stabilizers",
                    "feet", "abs", "abdominals", "lower abs", "obliques", "core", "neck", "levator scapulae",
                    "sternocleidomastoid", "rotator cuff"]),
            (0.25, ["calves", "soleus"]),
        ]
        var table: [String: Double] = [:]
        for group in groups { for token in group.tokens { table[token] = group.mass } }
        return table
    }()

    private static func has(_ text: String, _ tokens: [String]) -> Bool {
        tokens.contains { text.contains($0) }
    }

    private static func normalizedMuscle(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespaces).lowercased()
    }

    // MARK: - Classifier

    /// Is this a 45-degree sled or a hack squat or leg press machine, where only part of the load acts on the lift?
    public static func isAngled(exerciseName: String, equipment: String?) -> Bool {
        let n = exerciseName.lowercased()
        let e = (equipment ?? "").lowercased()
        return angled(n, e)
    }

    private static func angled(_ n: String, _ e: String) -> Bool {
        e.contains("sled") || n.contains("sled") || n.contains("45")
            || ((n.contains("hack squat") || n.contains("leg press")) && e == "machine")
    }

    /// The share of body weight a push-up variant moves.
    public static func pushUpFraction(_ exerciseName: String) -> Double {
        let n = exerciseName.lowercased()
        if n.contains("knee") { return pushUpKneeFraction }
        if n.contains("wall") { return pushUpWallFraction }
        if n.contains("incline") { return pushUpInclineFraction }
        if n.contains("decline") { return pushUpDeclineFraction }
        return pushUpStandardFraction
    }

    /// How an exercise's load is made up, from its name and its own equipment. The order of the checks matters.
    public static func classify(exerciseName: String, equipment: String?) -> LoadKind {
        let n = exerciseName.lowercased()
        let e = (equipment ?? "").lowercased()
        if n.contains("stretch") { return .skip(.stretch) }

        let hangDip = (has(n, hangTokens) || n.contains("dip")) && !has(n, hangExclusionTokens)
        if n.contains("assisted") && hangDip { return .assisted(fraction: hangDipFraction) }

        let bodyweightQualified = e.contains("body weight") || e.contains("bodyweight")
            || e == "weighted" || e == "bar" || e == "assisted"
        var lowerFraction: Double?
        if has(n, lowerTokens) && !has(n, seatedTokens) {
            lowerFraction = angled(n, e) ? lowerBodyFraction * sledScale : lowerBodyFraction
        }

        if bodyweightQualified {
            if hangDip { return .bodyweight(fraction: hangDipFraction) }
            if has(n, pushUpTokens) { return .bodyweight(fraction: pushUpFraction(n)) }
            if has(n, isometricTokens) { return .skip(.isometric) }
            if has(n, coreTokens) { return .bodyweight(fraction: otherBodyweightFraction) }
            if let lowerFraction { return .bodyweight(fraction: lowerFraction) }
            if e == "weighted" { return .external(bodyFraction: 0) }
            return .bodyweight(fraction: otherBodyweightFraction)
        }
        if let lowerFraction { return .external(bodyFraction: lowerFraction) }
        return .external(bodyFraction: 0)
    }

    // MARK: - Mass factor

    /// Is this a single-joint isolation move (a curl, a raise, a leg extension)? Compound names win.
    public static func isSingleJoint(_ exerciseName: String) -> Bool {
        let n = exerciseName.lowercased()
        return has(n, singleJointTokens) && !has(n, lowerTokens) && !has(n, hangTokens)
            && !has(n, pushUpTokens) && !has(n, multiJointTokens)
    }

    /// The mass weight of a muscle token, or nil when the token is unknown.
    public static func muscleMass(_ token: String) -> Double? {
        muscleMassByToken[normalizedMuscle(token)]
    }

    /// The movement profile: `J x m(primary) x (1 + min(0.4, 0.1 x sum of m(secondary)))`.
    ///
    /// The sum runs over distinct known secondaries other than the primary, in list order. A cardio primary has no
    /// factor (`isCardio`); a missing or unknown primary uses ``unknownPrimaryMass`` and is flagged `unmapped`.
    public static func massFactor(exerciseName: String, primary: String?, secondary: [String])
        -> (factor: Double, isCardio: Bool, unmapped: Bool) {
        let p = normalizedMuscle(primary ?? "")
        if cardioPrimaryTokens.contains(p) { return (0, true, false) }

        let known = muscleMassByToken[p]
        let primaryMass = known ?? unknownPrimaryMass
        var seen = Set<String>()
        var secondarySum = 0.0
        for raw in secondary {
            let token = normalizedMuscle(raw)
            guard token != p, !seen.contains(token), let mass = muscleMassByToken[token] else { continue }
            seen.insert(token)
            secondarySum += mass
        }
        let joint = isSingleJoint(exerciseName) ? singleJointFactor : 1.0
        let factor = joint * primaryMass * (1 + min(secondaryCap, secondaryWeight * secondarySum))
        return (factor, false, known == nil)
    }

    // MARK: - Set evaluation

    /// The body weight used for a session: clamped to 30...250 kg, 75 when missing or not finite.
    public static func bodyweight(_ kg: Double?) -> Double {
        guard let kg, kg.isFinite else { return defaultBodyweightKg }
        return min(maxBodyweightKg, max(minBodyweightKg, kg))
    }

    /// The effort term E: Epley's percent of one rep max at reps-to-failure = reps + reps in reserve.
    /// `rpe` is clamped to 5...10 and replaced by 8 when nil, non-finite or not above 0. E is non-decreasing in
    /// RPE and constant once reps reach 12.
    public static func effort(reps: Int, rpe: Double?) -> Double {
        let adjusted: Double
        if let rpe, rpe.isFinite, rpe > 0 {
            adjusted = min(maxRPE, max(minRPE, rpe))
        } else {
            adjusted = defaultRPE
        }
        let counted = Double(min(max(reps, 0), effortRepsCap))
        return epleyReps / (epleyReps + counted + (maxRPE - adjusted))
    }

    /// The weight a set moves, in kilograms, for its load kind. `weightKg` is the logged weight (0 when none).
    ///
    /// - external: logged weight (scaled on an angled machine) plus the exercise's share of body weight. A move
    ///   that carries body weight still counts at 0 kg; only a move with no body share and no weight is `noWeight`.
    /// - bodyweight: the body share plus any logged weight as added load.
    /// - assisted: the body share minus any logged weight as assistance; `noWeight` when nothing is left.
    public static func effectiveWeight(kind: LoadKind, weightKg: Double, bodyweightKg: Double, angled: Bool)
        -> (kg: Double, skip: SkipReason?) {
        let logged = max(0, weightKg)
        switch kind {
        case .skip(let reason):
            return (0, reason)
        case .external(let fraction):
            let kg = logged * (angled ? sledScale : 1) + fraction * bodyweightKg
            return kg > 0 ? (kg, nil) : (0, .noWeight)
        case .bodyweight(let fraction):
            return (fraction * bodyweightKg + logged, nil)
        case .assisted(let fraction):
            let kg = max(0, fraction * bodyweightKg - logged)
            return kg > 0 ? (kg, nil) : (0, .noWeight)
        }
    }

    /// One set's dose. The first rule that applies sets the skip reason and the dose is 0:
    /// warm-up, no reps, non-finite weight, stretch or isometric, cardio, no weight, implausible, non-finite dose.
    /// Otherwise `dose = min(reps, 15) x W_eff x E x F`.
    public static func evaluate(_ set: SetInput, bodyweightKg: Double) -> SetResult {
        let bw = bodyweight(bodyweightKg)

        func skipped(_ reason: SkipReason, weight: Double = 0, effort: Double = 0, factor: Double = 0,
                     unmapped: Bool = false) -> SetResult {
            SetResult(dose: 0, effectiveWeightKg: weight, effort: effort, massFactor: factor,
                      skip: reason, unmappedPrimary: unmapped)
        }

        if set.isWarmup { return skipped(.warmup) }
        if set.reps < 1 { return skipped(.noReps) }
        if let weight = set.weightKg, !weight.isFinite { return skipped(.invalid) }

        let kind = classify(exerciseName: set.exerciseName, equipment: set.equipment)
        if case .skip(let reason) = kind { return skipped(reason) }

        let mass = massFactor(exerciseName: set.exerciseName, primary: set.primaryMuscle,
                              secondary: set.secondaryMuscles)
        if mass.isCardio { return skipped(.cardio) }

        let isAngledMachine = isAngled(exerciseName: set.exerciseName, equipment: set.equipment)
        let weight = effectiveWeight(kind: kind, weightKg: set.weightKg ?? 0, bodyweightKg: bw,
                                     angled: isAngledMachine)
        if let reason = weight.skip {
            return skipped(reason, factor: mass.factor, unmapped: mass.unmapped)
        }
        let effortTerm = effort(reps: set.reps, rpe: set.rpe)
        if set.reps > maxReps || weight.kg > maxEffectiveWeightKg {
            return skipped(.implausible, weight: weight.kg, effort: effortTerm, factor: mass.factor,
                           unmapped: mass.unmapped)
        }
        let dose = Double(min(set.reps, countedRepsCap)) * weight.kg * effortTerm * mass.factor
        guard dose.isFinite else {
            return skipped(.invalid, weight: weight.kg, effort: effortTerm, factor: mass.factor,
                           unmapped: mass.unmapped)
        }
        return SetResult(dose: dose, effectiveWeightKg: weight.kg, effort: effortTerm, massFactor: mass.factor,
                         skip: nil, unmappedPrimary: mass.unmapped)
    }

    // MARK: - Session

    /// Scores a session's sets. The dose is summed smallest first, so shuffling the sets never changes a bit.
    public static func evaluate(sets: [SetInput], bodyweightKg: Double?) -> SessionResult {
        let bw = bodyweight(bodyweightKg)
        let results = sets.map { evaluate($0, bodyweightKg: bw) }

        var skipped: [SkipReason: Int] = [:]
        var warmups = 0
        var counted = 0
        var unmapped = 0
        for (input, result) in zip(sets, results) {
            if input.isWarmup { warmups += 1 }
            if let reason = result.skip {
                skipped[reason, default: 0] += 1
            } else if result.dose > 0 {
                counted += 1
                if result.unmappedPrimary { unmapped += 1 }
            }
        }
        let dose = results.map(\.dose).sorted().reduce(0, +)
        let volume = dose / bw
        return SessionResult(formulaVersion: version, bodyweightKg: bw, dose: dose, volume: volume,
                             muscularLoad: muscularLoad(volume: volume),
                             workingSets: sets.count - warmups, warmupSets: warmups,
                             countedSets: counted, unmappedSets: unmapped, skipped: skipped, sets: results)
    }

    /// `M = 36 x (1 - exp(-V / 70))` for a positive finite volume V (in body-weights); 0 otherwise.
    public static func muscularLoad(volume: Double) -> Double {
        guard volume > 0, volume.isFinite else { return 0 }
        return maxMuscularLoad * (1 - exp(-volume / volumeScale))
    }

    // MARK: - Combination with heart rate

    /// Adds a muscular load to a heart-rate score. Both are loads on the one saturating curve, so the heart-rate
    /// score is turned back into its load, the muscular load (capped at ``maxMuscularLoad``) is added, and the
    /// sum goes through the curve again. `h` and the result are on the stored 0...100 scale.
    ///
    /// Never lowers a score and never exceeds 100. A muscular load that is not a positive finite number returns
    /// `h` unchanged, bit for bit. Defined for h in 0...100; a heart-rate score of 100 stays 100.
    public static func combine(hrStored h: Double, muscularLoad m: Double) -> Double {
        combinedStored(h, m)
    }

    /// The one implementation behind every overload (a private name, so internal calls are never ambiguous).
    private static func combinedStored(_ h: Double, _ m: Double) -> Double {
        guard h.isFinite, m.isFinite, m > 0 else { return h }
        let dh = min(StrainScorerV2.displayValue(fromStored: h), StrainScorerV2.displayMaximum - 1e-9)
        let heartRateLoad = -StrainScorerV2.saturationConstant * log(1 - dh / StrainScorerV2.displayMaximum)
        let display = StrainScorerV2.displayStrain(forEffectiveLoad: heartRateLoad + min(m, maxMuscularLoad))
        return max(h, StrainScorerV2.storedValue(fromDisplay: display))
    }

    /// ``combine(hrStored:muscularLoad:)`` for a score that may be absent: no score stays no score.
    public static func combine(hrStored h: Double?, muscularLoad m: Double) -> Double? {
        guard let h else { return nil }
        return combinedStored(h, m)
    }

    /// ``combine(hrStored:muscularLoad:)`` on the 0...21 display scale. A muscular load that is not positive and
    /// finite returns `hrDisplay` unchanged.
    public static func combinedDisplay(hrDisplay: Double, muscularLoad: Double) -> Double {
        guard hrDisplay.isFinite, muscularLoad.isFinite, muscularLoad > 0 else { return hrDisplay }
        let stored = combinedStored(StrainScorerV2.storedValue(fromDisplay: hrDisplay), muscularLoad)
        return max(hrDisplay, StrainScorerV2.displayValue(fromStored: stored))
    }

    /// The muscular load of a day: the finite loads above 0, added smallest first so the order they arrive in
    /// never changes a bit.
    public static func dayMuscularLoad(_ loads: [Double]) -> Double {
        loads.filter { $0.isFinite && $0 > 0 }.sorted().reduce(0, +)
    }

    /// A day's stored score with the day's muscular load added, when the day's components are known.
    ///
    /// Only the cardiovascular component takes the muscular load: `max(step floor, energy floor,
    /// combine(cardio, M))`. The floors are what a quiet day is worth on its own, so they stay max-combined and
    /// a step-floor-dominated day gains only what the lift adds beyond the floor. A day with no score stays nil,
    /// and a muscular load that is not positive and finite returns the score unchanged, bit for bit. The result
    /// is never below the score.
    ///
    /// When only a stored day score is known (no components), use ``combine(hrStored:muscularLoad:)``: it treats
    /// the whole score as heart-rate load, which over-credits a floor-dominated day slightly. That inversion is
    /// the fallback, not the rule. Components with a score but no cardio component fall back to it here.
    public static func combineDay(components: StrainScorerV2.DayStrainComponents, muscularLoad m: Double) -> Double? {
        guard let score = components.score else { return nil }
        guard m.isFinite, m > 0 else { return score }
        guard let cardio = components.cardio else { return combinedStored(score, m) }
        let combinedCardio = combinedStored(StrainScorerV2.storedValue(fromDisplay: cardio), m)
        let stepFloor = StrainScorerV2.storedValue(fromDisplay: components.steps ?? 0)
        let energyFloor = StrainScorerV2.storedValue(fromDisplay: components.energy ?? 0)
        return max(score, stepFloor, energyFloor, combinedCardio)
    }

    /// Heart rate alone versus heart rate plus sets, for a stored score.
    public static func split(hrStored: Double, muscularLoad: Double) -> Split {
        Split(heartRateDisplay: StrainScorerV2.displayValue(fromStored: hrStored),
              combinedDisplay: StrainScorerV2.displayValue(
                fromStored: combinedStored(hrStored, muscularLoad)))
    }

    /// Heart rate alone versus heart rate plus sets, for a day with known components (floors included).
    /// Nil when the day has no score.
    public static func split(components: StrainScorerV2.DayStrainComponents, muscularLoad: Double) -> Split? {
        guard let score = components.score,
              let combined = combineDay(components: components, muscularLoad: muscularLoad) else { return nil }
        return Split(heartRateDisplay: StrainScorerV2.displayValue(fromStored: score),
                     combinedDisplay: StrainScorerV2.displayValue(fromStored: combined))
    }
}
