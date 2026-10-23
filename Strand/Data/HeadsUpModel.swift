import Foundation
import StrandAnalytics
import WhoopStore

// HeadsUpModel.swift — everything the Heads-Up card on Today and its detail page draw, built from the same math as
// the alert. `IllnessSignalEngine` stays the only judge of the level; this file only gathers its inputs once (the
// four overnight signals against the person's own baseline and the Journal causes that can explain them), keeps the
// readings the engine discards (the normal signals, the history, the baseline progress) and replays the same
// evaluation over the last two weeks for the history chart. Pure and DB-free: AppModel hands it the day rows and the
// recent Journal and publishes the result. On-device estimate, never a diagnosis.

/// The Heads-Up read for one moment: the phase the surface is in, the four signals and the recent history.
struct HeadsUpSnapshot: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Heads-Up is turned off (`behavior.illnessWatch`).
        case off
        /// Not enough nights for a trusted baseline yet: progress only, never a warning.
        case learning(nights: Int)
        /// No reliable current comparison: an established history lost usable inputs, or its read failed.
        case unavailable
        /// A trusted read, at the engine's level.
        case scored(IllnessSignalEngine.Level)
    }

    enum SignalKind: String, CaseIterable, Sendable {
        case restingHR, hrv, skinTemp, respiration
    }

    /// One signal over the recent window. `z` is signed in the signal's own direction (a fall in HRV is negative);
    /// `fired` is whether it counts toward the read (illness-ward beyond the engine's threshold).
    struct Signal: Equatable, Sendable, Identifiable {
        var id: SignalKind { kind }
        let kind: SignalKind
        /// Mean of the last 2 nights, in the signal's units (skin temperature is a °C deviation).
        let latest: Double?
        /// The personal baseline centre (0 for skin temperature, which is stored as a deviation).
        let usual: Double?
        let z: Double?
        let fired: Bool
        /// The person's normal range in the signal's units, nil while the baseline is still building.
        let normalBand: ClosedRange<Double>?
        /// The last `historyLength` nights, oldest first; nil where nothing was recorded.
        let history: [Double?]
    }

    struct DayScore: Equatable, Sendable, Identifiable {
        var id: String { day }
        let day: String
        let score: Double
        let level: IllnessSignalEngine.Level
    }

    /// Journal answers that can explain the signals away. Travel is not listed: nothing detects it yet.
    enum Cause: String, CaseIterable, Sendable {
        case alcohol, hardWorkout, sauna, stress
    }

    let phase: Phase
    /// The newest day the read covers.
    let day: String?
    /// The engine's 0–100 score (softened when a cause explains it).
    let score: Double
    /// The score before softening, only when a logged cause softened it.
    let rawScore: Double?
    let signals: [Signal]
    /// Causes logged in the read's window.
    let causes: Set<Cause>
    /// Causes the Journal answered no to in the read's window (and never yes), so the page can tell "ruled out"
    /// from "not asked".
    var answeredNo: Set<Cause> = []
    /// The parallel distance's confidence word, only on a raised read.
    let confidence: String?
    /// The last `historyLength` mornings, oldest first.
    let history: [DayScore]
    /// The newest day "feeling sick" was logged in the read's window.
    let unwellDay: String?

    static let nightsNeeded = Baselines.minNightsTrust
    static let historyLength = 14

    /// Off still lists the four signals (with no readings), so its page can say what Heads-Up would read.
    static let off = HeadsUpSnapshot(
        phase: .off, day: nil, score: 0, rawScore: nil,
        signals: SignalKind.allCases.map {
            Signal(kind: $0, latest: nil, usual: nil, z: nil, fired: false, normalBand: nil, history: [])
        },
        causes: [], confidence: nil, history: [], unwellDay: nil)

    /// A failed history read has no trustworthy comparison, even if the previous surface had one.
    static func unavailable(day: String?) -> HeadsUpSnapshot {
        HeadsUpSnapshot(phase: .unavailable, day: day, score: 0, rawScore: nil, signals: off.signals,
                        causes: [], confidence: nil, history: [], unwellDay: nil)
    }

    var level: IllnessSignalEngine.Level? {
        if case .scored(let level) = phase { return level }
        return nil
    }

    var firedCount: Int { signals.filter(\.fired).count }
    var presentCount: Int { signals.filter { $0.z != nil }.count }
}

enum HeadsUpBuilder {
    /// The Journal answers in a read's window that the engine can use.
    struct JournalContext: Equatable, Sendable {
        var causes: Set<HeadsUpSnapshot.Cause> = []
        /// Causes answered no and never yes in the window: shown as "No", never fed to the engine.
        var answeredNo: Set<HeadsUpSnapshot.Cause> = []
        var unwellDay: String?
        var alreadyUnwell: Bool { unwellDay != nil }
    }

    /// The engine's decision for one window plus everything the surface needs that the engine does not keep.
    struct Evaluation: Equatable, Sendable {
        let result: IllnessSignalEngine.Result
        let distance: IllnessDistance.Result
        let signals: [HeadsUpSnapshot.Signal]
        /// The HRV or resting-HR baseline is trusted: the engine's gate for raising anything.
        let trusted: Bool
        /// The HRV or resting-HR baseline has enough nights, whether or not the last 2 nights were recorded (or the
        /// baseline is momentarily provisional or stale). A ready baseline is never "learning" again.
        let baselineReady: Bool
        /// Valid nights in the larger of the HRV and resting-HR baselines.
        let baselineNights: Int
    }

    // MARK: Journal causes

    static let alcoholWords: Set<String> = [
        "alcohol", "alcoholic", "beer", "beers", "wine", "liquor", "spirits", "cocktail", "cocktails",
    ]
    static let workoutWords: Set<String> = ["workout", "workouts", "train", "trained", "training", "exercise", "exercised"]
    static let saunaWords: Set<String> = ["sauna"]
    static let stressWords: Set<String> = ["stress", "stressed", "stressful"]
    static let unwellWords: Set<String> = ["sick", "ill", "illness", "unwell"]

    /// The question's words, lower-cased and split on anything that is not a letter. Matching whole words keeps
    /// "pills" from reading as "ill" and "strain" from reading as "train".
    static func words(_ question: String) -> Set<String> {
        Set(question.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
    }

    /// The causes a question is about, by whole words.
    private static func causes(of question: String) -> Set<HeadsUpSnapshot.Cause> {
        let questionWords = words(question)
        var found: Set<HeadsUpSnapshot.Cause> = []
        if !questionWords.isDisjoint(with: alcoholWords) { found.insert(.alcohol) }
        if !questionWords.isDisjoint(with: workoutWords) { found.insert(.hardWorkout) }
        if !questionWords.isDisjoint(with: saunaWords) { found.insert(.sauna) }
        if !questionWords.isDisjoint(with: stressWords) { found.insert(.stress) }
        return found
    }

    /// The causes answered yes on any of `days`, and the ones answered only no.
    static func context(days: Set<String>, journal: [JournalEntry]) -> JournalContext {
        var context = JournalContext()
        for entry in journal where days.contains(entry.day) {
            if entry.answeredYes {
                context.causes.formUnion(causes(of: entry.question))
                if !words(entry.question).isDisjoint(with: unwellWords), context.unwellDay.map({ entry.day > $0 }) ?? true {
                    context.unwellDay = entry.day
                }
            } else {
                context.answeredNo.formUnion(causes(of: entry.question))
            }
        }
        context.answeredNo.subtract(context.causes)
        return context
    }

    // MARK: One window

    /// Evaluate the newest window of `days` (oldest → newest): the last 2 nights against a baseline of up to 28
    /// nights that ends 3 days back. The baseline is trusted from 14 valid nights (`Baselines.minNightsTrust`); the
    /// extra nights up to 28 only refine it. The same inputs, thresholds and labels the alert has always used.
    static func evaluate(_ days: [DailyMetric], context: JournalContext) -> Evaluation {
        let recent = Array(days.suffix(2))
        let base = Array(days.suffix(31).dropLast(3))
        let window = Array(days.suffix(HeadsUpSnapshot.historyLength))

        let rhr = baselineSignal(.restingHR, cfgKey: "resting_hr", illnessUp: true,
                                 recent: recent, base: base, window: window) { $0.restingHr.map(Double.init) }
        let hrv = baselineSignal(.hrv, cfgKey: "hrv", illnessUp: false,
                                 recent: recent, base: base, window: window) { $0.avgHrv }
        let resp = baselineSignal(.respiration, cfgKey: "resp", illnessUp: true,
                                  recent: recent, base: base, window: window) { $0.respRateBpm }
        let skin = skinSignal(recent: recent, window: window)

        let inputs = IllnessSignalEngine.Inputs(restingHR: rhr.reading, skinTemp: skin.reading,
                                                hrv: hrv.reading, respiration: resp.reading)
        // The parallel distance on the same illness-ward vector. It never gates; it only grades a raised read.
        let distance = IllnessDistance.evaluate(
            features: IllnessDistance.FeatureVector(restingHR: presentZ(rhr.reading), rmssd: presentZ(hrv.reading),
                                                    skinTemp: presentZ(skin.reading),
                                                    respiration: presentZ(resp.reading)),
            correlation: nil)
        let trusted = rhr.trusted || hrv.trusted
        let engineContext = IllnessSignalEngine.Context(
            alcohol: context.causes.contains(.alcohol), stress: context.causes.contains(.stress),
            sauna: context.causes.contains(.sauna), hardOrLateWorkout: context.causes.contains(.hardWorkout),
            alreadyUnwell: context.alreadyUnwell, baselineTrusted: trusted)
        let result = IllnessSignalEngine.evaluate(inputs, context: engineContext,
                                                  firedLabels: labels(rhr: rhr.signal, hrv: hrv.signal,
                                                                      skin: skin.signal, resp: resp.signal))
        return Evaluation(result: result, distance: distance,
                          signals: [rhr.signal, hrv.signal, skin.signal, resp.signal],
                          trusted: trusted,
                          baselineReady: max(rhr.nights, hrv.nights) >= HeadsUpSnapshot.nightsNeeded,
                          baselineNights: max(rhr.nights, hrv.nights))
    }

    private struct SignalRead {
        let reading: IllnessSignalEngine.SignalReading?
        let trusted: Bool
        let nights: Int
        let signal: HeadsUpSnapshot.Signal
    }

    private static func finite(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func mean(_ values: [Double]) -> Double? {
        let values = values.filter(\.isFinite)
        guard !values.isEmpty else { return nil }
        let sum = values.reduce(0, +)
        // Keep ordinary arithmetic unchanged; scale before summing only when the sum would overflow.
        let average = sum.isFinite ? sum / Double(values.count)
            : values.reduce(0) { $0 + $1 / Double(values.count) }
        return finite(average)
    }

    /// The parallel distance squares each feature. An overflowing comparison is missing, never a signal.
    private static func usableZ(_ value: Double) -> Bool {
        value.isFinite && value * value <= Double.greatestFiniteMagnitude / Double(HeadsUpSnapshot.SignalKind.allCases.count)
    }

    private static func presentZ(_ reading: IllnessSignalEngine.SignalReading?) -> Double? {
        guard let reading, reading.present else { return nil }
        return reading.zIllnessward
    }

    /// One baselined signal (resting HR, HRV, respiration). No recent value leaves it out of the engine entirely; an
    /// unusable baseline puts it in as absent, exactly as the alert always has.
    private static func baselineSignal(_ kind: HeadsUpSnapshot.SignalKind, cfgKey: String, illnessUp: Bool,
                                       recent: [DailyMetric], base: [DailyMetric], window: [DailyMetric],
                                       value: (DailyMetric) -> Double?) -> SignalRead {
        let history = window.map { finite(value($0)) }
        guard let cfg = Baselines.metricCfg[cfgKey] else {
            return SignalRead(reading: nil, trusted: false, nights: 0,
                              signal: HeadsUpSnapshot.Signal(kind: kind, latest: nil, usual: nil, z: nil, fired: false,
                                                             normalBand: nil, history: history))
        }
        let state = Baselines.foldHistory(base.map { finite(value($0)) }, cfg: cfg)
        let usual = state.usable ? state.baseline : nil
        // The normal range is where the engine stops counting a move: its threshold in the baseline's robust units
        // (`Baselines.deviation` divides by 1.253 × spread).
        let band: ClosedRange<Double>?
        if state.usable {
            let reach = IllnessSignalEngine.signalZThreshold * max(1.253 * state.spread, 1e-9)
            band = (state.baseline - reach)...(state.baseline + reach)
        } else {
            band = nil
        }
        guard let latest = mean(recent.compactMap(value)) else {
            return SignalRead(reading: nil, trusted: false, nights: state.nValid,
                              signal: HeadsUpSnapshot.Signal(kind: kind, latest: nil, usual: usual, z: nil, fired: false,
                                                             normalBand: band, history: history))
        }
        guard state.usable else {
            return SignalRead(reading: IllnessSignalEngine.SignalReading(zIllnessward: 0, present: false),
                              trusted: false, nights: state.nValid,
                              signal: HeadsUpSnapshot.Signal(kind: kind, latest: latest, usual: nil, z: nil,
                                                             fired: false, normalBand: nil, history: history))
        }
        let z = Baselines.deviation(latest, state: state).z
        guard usableZ(z) else {
            return SignalRead(reading: nil, trusted: false, nights: state.nValid,
                              signal: HeadsUpSnapshot.Signal(kind: kind, latest: latest, usual: usual, z: nil,
                                                             fired: false, normalBand: band, history: history))
        }
        let illnessward = illnessUp ? z : -z
        return SignalRead(reading: IllnessSignalEngine.SignalReading(zIllnessward: illnessward),
                          trusted: state.trusted, nights: state.nValid,
                          signal: HeadsUpSnapshot.Signal(kind: kind, latest: latest, usual: usual, z: z,
                                                         fired: illnessward > IllnessSignalEngine.signalZThreshold,
                                                         normalBand: band, history: history))
    }

    /// Skin temperature is already stored as a °C deviation, so it is scored against a zero-centred spread of
    /// 0.3 °C (the skin-temperature floor spread) rather than a separate baseline.
    static let skinSpread = 0.3

    private static func skinSignal(recent: [DailyMetric], window: [DailyMetric]) -> SignalRead {
        let history = window.map { finite($0.skinTempDevC) }
        let reach = IllnessSignalEngine.signalZThreshold * skinSpread
        guard let latest = mean(recent.compactMap(\.skinTempDevC)) else {
            return SignalRead(reading: nil, trusted: false, nights: 0,
                              signal: HeadsUpSnapshot.Signal(kind: .skinTemp, latest: nil, usual: 0, z: nil, fired: false,
                                                             normalBand: -reach...reach, history: history))
        }
        let z = latest / skinSpread
        guard usableZ(z) else {
            return SignalRead(reading: nil, trusted: false, nights: 0,
                              signal: HeadsUpSnapshot.Signal(kind: .skinTemp, latest: latest, usual: 0, z: nil,
                                                             fired: false, normalBand: -reach...reach, history: history))
        }
        return SignalRead(reading: IllnessSignalEngine.SignalReading(zIllnessward: z), trusted: true, nights: 0,
                          signal: HeadsUpSnapshot.Signal(kind: .skinTemp, latest: latest, usual: 0, z: z,
                                                         fired: z > IllnessSignalEngine.signalZThreshold,
                                                         normalBand: -reach...reach, history: history))
    }

    /// The phrases the engine shows for the signals that fire, each measured against the same baseline centre the
    /// card and detail page show.
    private static func labels(rhr: HeadsUpSnapshot.Signal, hrv: HeadsUpSnapshot.Signal,
                               skin: HeadsUpSnapshot.Signal, resp: HeadsUpSnapshot.Signal) -> [String: String] {
        var labels: [String: String] = [:]
        if let latest = rhr.latest, let usual = rhr.usual, latest > usual,
           let rise = Int(exactly: (latest - usual).rounded()) {
            labels["restingHR"] = "RHR +\(rise)"
        }
        if let latest = hrv.latest, let usual = hrv.usual, usual > 0, latest < usual,
           let fall = Int(exactly: ((1 - latest / usual) * 100).rounded()) {
            labels["hrv"] = "HRV \u{2212}\(fall)%"
        }
        if let latest = skin.latest, latest > 0 {
            labels["skinTemp"] = "skin temp +\(String(format: "%.1f", latest)) °C"
        }
        if let latest = resp.latest, let usual = resp.usual, latest > usual {
            labels["respiration"] = "respiration +\(String(format: "%.1f", latest - usual)) rpm"
        }
        return labels
    }

    // MARK: Snapshot

    /// The history read is independent of the dashboard cache and bounded to 180 calendar days. This preserves
    /// established history across a gap without scanning the complete library on each refresh.
    static func historyBounds(through day: String) -> ClosedRange<String>? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let end = formatter.date(from: day), formatter.string(from: end) == day,
              let start = formatter.calendar.date(byAdding: .day, value: -179, to: end) else { return nil }
        return formatter.string(from: start)...day
    }

    /// Inclusive Journal bounds for all replayed mornings and their two-row reading windows. Stored rows can
    /// end long before today or have gaps, so a calendar-day lookback cannot cover this replay reliably.
    static func journalBounds(_ days: [DailyMetric]) -> ClosedRange<String>? {
        guard let newest = days.last?.day else { return nil }
        let first = max(0, days.count - HeadsUpSnapshot.historyLength - 1)
        return days[first].day...newest
    }

    /// A mature read in the retained history must not return to initial learning when gaps remove trust.
    /// Replay the same rolling baseline windows, rather than counting raw rows that might contain no readings.
    private static func baselineWasEstablished(_ days: [DailyMetric]) -> Bool {
        let firstRead = HeadsUpSnapshot.nightsNeeded + 3
        guard days.count >= firstRead else { return false }
        for end in firstRead...days.count {
            let base = days[max(0, end - 31)..<(end - 3)]
            for key in ["resting_hr", "hrv"] {
                guard let cfg = Baselines.metricCfg[key] else { continue }
                let values = base.map { key == "resting_hr" ? $0.restingHr.map(Double.init) : $0.avgHrv }
                if Baselines.foldHistory(values, cfg: cfg).nValid >= HeadsUpSnapshot.nightsNeeded { return true }
            }
        }
        return false
    }

    /// The full snapshot plus the newest evaluation (nil when Heads-Up is off or the history is too short to read,
    /// where the alert has never published anything). `days` is oldest → newest; `journal` needs the last few weeks.
    static func snapshot(days: [DailyMetric], journal: [JournalEntry], enabled: Bool)
        -> (snapshot: HeadsUpSnapshot, latest: Evaluation?) {
        guard enabled else { return (.off, nil) }
        let latestContext = context(days: Set(days.suffix(2).map(\.day)), journal: journal)
        let latest = evaluate(days, context: latestContext)
        // Learning progress always counts the nights the baseline itself holds (the window ends 3 days back), so it
        // only ever rises and reaches the target exactly when the first trusted read is possible.
        guard days.count >= HeadsUpSnapshot.nightsNeeded else {
            return (learning(nights: latest.baselineNights, day: days.last?.day, signals: latest.signals), nil)
        }
        guard latest.trusted else {
            if latest.baselineReady || baselineWasEstablished(days) {
                return (HeadsUpSnapshot(phase: .unavailable, day: days.last?.day, score: 0, rawScore: nil,
                                        signals: uncompared(latest.signals), causes: latestContext.causes,
                                        answeredNo: latestContext.answeredNo, confidence: nil, history: [],
                                        unwellDay: latestContext.unwellDay), latest)
            }
            return (learning(nights: latest.baselineNights, day: days.last?.day, signals: latest.signals), latest)
        }
        let result = latest.result
        let snapshot = HeadsUpSnapshot(
            phase: .scored(result.level),
            day: days.last?.day,
            score: boundedScore(result.score),
            rawScore: result.level == .suppressed
                ? boundedScore(result.score / IllnessSignalEngine.confounderDampen) : nil,
            signals: latest.signals,
            causes: latestContext.causes,
            answeredNo: latestContext.answeredNo,
            confidence: result.level == .raised ? IllnessConfidence.band(latest.distance.distance) : nil,
            history: history(days, journal: journal),
            unwellDay: latestContext.unwellDay)
        return (snapshot, latest)
    }

    private static func learning(nights: Int, day: String?, signals: [HeadsUpSnapshot.Signal]) -> HeadsUpSnapshot {
        let capped = min(max(0, nights), HeadsUpSnapshot.nightsNeeded - 1)
        // While the baseline builds there is no normal range to judge against, so nothing is marked as up or down.
        return HeadsUpSnapshot(phase: .learning(nights: capped), day: day, score: 0, rawScore: nil,
                               signals: uncompared(signals), causes: [], confidence: nil, history: [], unwellDay: nil)
    }

    private static func boundedScore(_ score: Double) -> Double {
        score.isFinite ? min(100, max(0, score)) : 0
    }

    private static func uncompared(_ signals: [HeadsUpSnapshot.Signal]) -> [HeadsUpSnapshot.Signal] {
        signals.map {
            HeadsUpSnapshot.Signal(kind: $0.kind, latest: $0.latest, usual: nil, z: nil, fired: false,
                                   normalBand: nil, history: $0.history)
        }
    }

    /// The same evaluation replayed for each of the last `historyLength` mornings, oldest first. A morning without a
    /// trusted baseline reads as zero: the alert would not have spoken then either.
    static func history(_ days: [DailyMetric], journal: [JournalEntry]) -> [HeadsUpSnapshot.DayScore] {
        guard !days.isEmpty else { return [] }
        var scores: [HeadsUpSnapshot.DayScore] = []
        for back in stride(from: HeadsUpSnapshot.historyLength - 1, through: 0, by: -1) {
            let end = days.count - back
            guard end >= 2 else { continue }
            let slice = Array(days[max(0, end - 31)..<end])
            let evaluation = evaluate(slice, context: context(days: Set(slice.suffix(2).map(\.day)), journal: journal))
            let day = slice[slice.count - 1].day
            if evaluation.trusted {
                scores.append(HeadsUpSnapshot.DayScore(day: day, score: boundedScore(evaluation.result.score),
                                                       level: evaluation.result.level))
            } else {
                scores.append(HeadsUpSnapshot.DayScore(day: day, score: 0, level: .quiet))
            }
        }
        return scores
    }
}
