import Foundation
import StrandAnalytics
import WhoopStore

// InsightsReport.swift — the one place Insights are computed, for the Trends section, the full
// Insights page and the Coach prompt alike.
//
// Inputs are the user's own history on this device: automatic factors (AutoFactors, from sleep
// timing, sleep length, workouts, strain and steps) and explicit Journal yes/no answers. Both are
// keyed by the morning they affect, so every factor x outcome test runs at EffectRanker's fixed
// lag 0, and the whole family is corrected together (Benjamini–Hochberg). Nothing is stored.

/// The four daily outcomes Insights read.
enum InsightOutcome: String, CaseIterable, Identifiable, Sendable {
    case recovery, hrv, sleep, rhr

    var id: String { rawValue }

    /// metricSeries key.
    var key: String {
        switch self {
        case .recovery: return "recovery"
        case .hrv: return "hrv"
        case .sleep: return "sleep_performance"
        case .rhr: return "rhr"
        }
    }

    /// Section title on the Insights page.
    var title: String {
        switch self {
        case .recovery: return String(localized: "Recovery")
        case .hrv: return String(localized: "HRV")
        case .sleep: return String(localized: "Sleep")
        case .rhr: return String(localized: "Resting heart rate")
        }
    }

    /// The outcome as it reads inside a sentence ("your recovery averaged…").
    var inSentence: String {
        switch self {
        case .recovery: return String(localized: "recovery")
        case .hrv: return String(localized: "HRV")
        case .sleep: return String(localized: "sleep score")
        case .rhr: return String(localized: "resting heart rate")
        }
    }

    var symbol: String {
        switch self {
        case .recovery: return "heart.fill"
        case .hrv: return "waveform.path.ecg"
        case .sleep: return "moon.fill"
        case .rhr: return "heart.text.square"
        }
    }

    var higherIsBetter: Bool { self != .rhr }

    func format(_ v: Double) -> String {
        switch self {
        case .recovery, .sleep: return "\(Int(v.rounded()))%"
        case .hrv: return "\(Int(v.rounded())) ms"
        case .rhr: return "\(Int(v.rounded())) bpm"
        }
    }

    /// The size of a difference as it reads in a sentence: points for the 0–100 scores (a percent of a
    /// percent misleads), relative percent for HRV, beats per minute for resting heart rate.
    func amount(_ e: BehaviorEffect) -> String {
        switch self {
        case .recovery, .sleep:
            let points = max(1, Int(abs(e.delta).rounded()))
            return points == 1 ? String(localized: "1 point") : String(localized: "\(points) points")
        case .rhr:
            let bpm = abs(e.delta)
            return bpm < 10 ? String(format: "%.1f bpm", bpm) : "\(Int(bpm.rounded())) bpm"
        case .hrv:
            let pct = abs(e.pctChange ?? 0)
            return "\(max(1, Int(pct.rounded())))%"
        }
    }

    /// The signed difference for a row's trailing number: "+8 pts", "−16%", "+1.6 bpm".
    func signedAmount(_ e: BehaviorEffect) -> String {
        let sign = e.delta < 0 ? "\u{2212}" : "+"
        switch self {
        case .recovery, .sleep:
            return String(localized: "\(sign)\(max(1, Int(abs(e.delta).rounded()))) pts")
        case .rhr:
            let bpm = abs(e.delta)
            return "\(sign)" + (bpm < 10 ? String(format: "%.1f bpm", bpm) : "\(Int(bpm.rounded())) bpm")
        case .hrv:
            return "\(sign)\(max(1, Int(abs(e.pctChange ?? 0).rounded())))%"
        }
    }

    /// "62% vs 54%"
    func pair(_ e: BehaviorEffect) -> String {
        String(localized: "\(format(e.meanWith)) vs \(format(e.meanWithout))")
    }
}

/// Where a factor came from.
enum InsightSource: Equatable, Sendable {
    case data(AutoFactor)
    case journal(question: String)

    var isJournal: Bool { if case .journal = self { return true } else { return false } }

    var label: String {
        isJournal ? String(localized: "From your Journal") : String(localized: "From your data")
    }

    /// A stable id for the factor (also the EffectRanker behaviour label).
    var factorID: String {
        switch self {
        case .data(let f): return f.rawValue
        case .journal(let q): return "journal.\(q)"
        }
    }
}

/// One factor x outcome result, with its words.
struct InsightRow: Identifiable, Equatable, Sendable {
    let source: InsightSource
    let outcome: InsightOutcome
    let effect: RankedEffect
    /// "11:30 PM" for the early-bedtime factor, nil otherwise.
    let bedtime: String?

    var id: String { "\(source.factorID)|\(outcome.rawValue)" }
    var isSignificant: Bool { effect.isSignificant }

    /// Did the factor line up with the better side of the outcome?
    var movedGood: Bool { (effect.effect.delta > 0) == outcome.higherIsBetter }

    var sentence: String { InsightWords.sentence(source: source, outcome: outcome, effect: effect.effect, bedtime: bedtime) }
    var withLabel: String { InsightWords.sideLabels(source, bedtime: bedtime).with }
    var withoutLabel: String { InsightWords.sideLabels(source, bedtime: bedtime).without }

    /// "31 vs 26 nights"
    var countsText: String {
        InsightWords.counts(source, nWith: effect.effect.nWith, nWithout: effect.effect.nWithout)
    }

    var confidenceWord: String {
        switch effect.confidence {
        case .solid: return String(localized: "Solid")
        case .building: return String(localized: "Building")
        case .calibrating: return String(localized: "Calibrating")
        }
    }
}

/// A factor that was checked but showed no clear difference on any outcome.
struct UnclearFactor: Identifiable, Equatable, Sendable {
    let source: InsightSource
    let name: String
    /// The most days or nights it was compared over.
    let checked: Int
    var id: String { source.factorID }
    var checkedText: String {
        switch source {
        case .data(let f) where InsightWords.isNightFactor(f): return String(localized: "Checked \(checked) nights")
        default: return String(localized: "Checked \(checked) days")
        }
    }
}

struct InsightsReport: Equatable, Sendable {
    /// Every computed row, significant first.
    let rows: [InsightRow]
    /// Days with at least one outcome value.
    let daysOfData: Int
    let unclear: [UnclearFactor]

    static let empty = InsightsReport(rows: [], daysOfData: 0, unclear: [])

    /// Below this many days the page says Insights are still warming up instead of "no patterns".
    static let minimumDays = 14

    /// The findings to show, surest first: Solid before Building before Calibrating, then the larger effect.
    var significant: [InsightRow] {
        rows.filter(\.isSignificant).enumerated().sorted { a, b in
            let ra = Self.rank(a.element.effect.confidence), rb = Self.rank(b.element.effect.confidence)
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
    }

    private static func rank(_ c: ScoreConfidence) -> Int {
        switch c {
        case .solid: return 0
        case .building: return 1
        case .calibrating: return 2
        }
    }
    var hasEnoughData: Bool { daysOfData >= Self.minimumDays }

    func significant(for outcome: InsightOutcome) -> [InsightRow] {
        significant.filter { $0.outcome == outcome }
    }
}

// MARK: - Building

/// Everything the report is built from, already read from the Repository.
struct InsightsInputs: Sendable {
    var outcomes: [InsightOutcome: [String: Double]] = [:]
    var journal: [JournalEntry] = []
    var nights: [AutoFactorNight] = []
    var days: [AutoFactorDay] = []
    var workouts: [AutoFactorWorkout] = []
    var calendar: Calendar = .current
}

enum InsightsReportBuilder {

    static func build(_ inputs: InsightsInputs) -> InsightsReport {
        let auto = AutoFactors.derive(nights: inputs.nights, days: inputs.days,
                                      workouts: inputs.workouts, calendar: inputs.calendar)
        let bedtime = auto.bedtimeThresholdMinutes.map { bedtimeText($0, calendar: inputs.calendar) }

        // Factor → (source, yes, no)
        var factors: [(source: InsightSource, yes: Set<String>, no: Set<String>)] = []
        for f in AutoFactor.allCases {
            if let s = auto.splits[f] { factors.append((.data(f), s.yes, s.no)) }
        }
        var yesByQ: [String: Set<String>] = [:], noByQ: [String: Set<String>] = [:]
        for e in inputs.journal {
            if e.answeredYes { yesByQ[e.question, default: []].insert(e.day) }
            else { noByQ[e.question, default: []].insert(e.day) }
        }
        for q in Set(yesByQ.keys).union(noByQ.keys).sorted() {
            factors.append((.journal(question: q), yesByQ[q] ?? [], noByQ[q] ?? []))
        }

        var tests: [EffectRanker.FactorTest] = []
        var sourceByID: [String: InsightSource] = [:]
        var outcomeByName: [String: InsightOutcome] = [:]
        for outcome in InsightOutcome.allCases {
            let values = inputs.outcomes[outcome] ?? [:]
            guard !values.isEmpty else { continue }
            outcomeByName[outcome.rawValue] = outcome
            for factor in factors {
                if case .data(let f) = factor.source, !f.isTested(againstOutcomeKey: outcome.key) { continue }
                sourceByID[factor.source.factorID] = factor.source
                tests.append(.init(behavior: factor.source.factorID, yesDays: factor.yes, noDays: factor.no,
                                   outcome: outcome.rawValue, outcomeByDay: values))
            }
        }

        let ranked = EffectRanker.rankFamily(tests)
        let rows: [InsightRow] = ranked.compactMap { r in
            guard let source = sourceByID[r.behavior], let outcome = outcomeByName[r.outcome] else { return nil }
            let isBedtime = { if case .data(.earlyBedtime) = source { return true } else { return false } }()
            return InsightRow(source: source, outcome: outcome, effect: r, bedtime: isBedtime ? bedtime : nil)
        }

        // Factors with computed tests but nothing significant.
        let significantIDs = Set(rows.filter(\.isSignificant).map(\.source.factorID))
        var checked: [String: (InsightSource, Int)] = [:]
        for row in rows where !significantIDs.contains(row.source.factorID) {
            let n = row.effect.effect.nWith + row.effect.effect.nWithout
            if n > (checked[row.source.factorID]?.1 ?? 0) { checked[row.source.factorID] = (row.source, n) }
        }
        let unclear = checked.values
            .map { UnclearFactor(source: $0.0, name: InsightWords.factorName($0.0), checked: $0.1) }
            .sorted { $0.source.isJournal == $1.source.isJournal ? $0.name < $1.name : !$0.source.isJournal }

        let daysOfData = Set(inputs.outcomes.values.flatMap(\.keys)).count
        return InsightsReport(rows: rows, daysOfData: daysOfData, unclear: unclear)
    }

    /// "11:30 PM" in the user's locale for minutes after midnight of the behaviour day.
    static func bedtimeText(_ minutes: Int, calendar: Calendar) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        let anchor = calendar.startOfDay(for: Date(timeIntervalSince1970: 0))
        let date = calendar.date(byAdding: .minute, value: m, to: anchor) ?? anchor
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = calendar.timeZone
        style.locale = calendar.locale ?? .autoupdatingCurrent
        return date.formatted(style)
    }
}

// MARK: - Loading

enum InsightsLoader {
    /// How far back Insights look. Long enough for seasons of habits, short enough to stay current
    /// and to keep the read bounded.
    static let historyDays = 180

    @MainActor
    static func load(repo: Repository) async -> InsightsReport {
        let inputs = await readInputs(repo: repo)
        return await Task.detached(priority: .utility) { InsightsReportBuilder.build(inputs) }.value
    }

    @MainActor
    static func readInputs(repo: Repository) async -> InsightsInputs {
        let now = Date()
        let lo = Int(Repository.dateByAddingCalendarDays(-historyDays, to: now).timeIntervalSince1970)
        let hi = Int(Repository.dateByAddingCalendarDays(1, to: now).timeIntervalSince1970)
        let earliest = Repository.localDayKey(Repository.dateByAddingCalendarDays(-historyDays, to: now))

        async let journalLoad = repo.journalEntries(days: historyDays)
        async let recoveryLoad = repo.series(key: "recovery", source: "my-whoop")
        async let hrvLoad = repo.series(key: "hrv", source: "my-whoop")
        async let sleepLoad = repo.series(key: "sleep_performance", source: "my-whoop")
        async let rhrLoad = repo.series(key: "rhr", source: "my-whoop")
        async let sleepsLoad = repo.allSleepSessions(days: historyDays)
        async let workoutsLoad = repo.workoutRows(from: lo, to: hi, reconcileHR: false)

        async let historyLoad = repo.dailyMetrics(fromDay: earliest,
                                                  toDay: Repository.localDayKey(Repository.dateByAddingCalendarDays(1, to: now)))
        async let appleLoad = repo.appleDailyRows(days: historyDays)

        // The published `days` cover the recent dashboard window; older rows come from the store.
        // Published rows win where both exist.
        var byDay: [String: DailyMetric] = [:]
        for d in await historyLoad { byDay[d.day] = d }
        for d in repo.days where d.day >= earliest { byDay[d.day] = d }
        let merged = byDay.values.sorted { $0.day < $1.day }
        let loaded: [InsightOutcome: [(day: String, value: Double)]] = [
            .recovery: await recoveryLoad, .hrv: await hrvLoad, .sleep: await sleepLoad, .rhr: await rhrLoad,
        ]
        var inputs = InsightsInputs()
        for outcome in InsightOutcome.allCases {
            var dict: [String: Double] = [:]
            for row in loaded[outcome] ?? [] where row.day >= earliest { dict[row.day] = row.value }
            // Strap-only fallback, as the Insights hub has always done.
            for d in merged where dict[d.day] == nil {
                let v: Double? = switch outcome {
                case .recovery: d.recovery
                case .hrv: d.avgHrv
                case .rhr: d.restingHr.map(Double.init)
                case .sleep: nil
                }
                if let v { dict[d.day] = v }
            }
            inputs.outcomes[outcome] = dict
        }

        inputs.journal = await journalLoad
        inputs.nights = (await sleepsLoad).map { s in
            AutoFactorNight(wakeDay: Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(s.endTs))),
                            onsetTs: s.effectiveStartTs, endTs: s.endTs)
        }
        inputs.workouts = (await workoutsLoad).map { AutoFactorWorkout(startTs: $0.startTs, endTs: $0.endTs) }
        var appleSteps: [String: Int] = [:]
        for row in await appleLoad { if let steps = row.steps { appleSteps[row.day] = steps } }
        for (day, point) in repo.canonicalHealth.appleDailyByDay { if let steps = point.steps { appleSteps[day] = steps } }
        inputs.days = merged.map { d in
            let steps = d.steps.map(Double.init) ?? appleSteps[d.day].map(Double.init)
            return AutoFactorDay(day: d.day, totalSleepMin: d.totalSleepMin, strain: d.strain, steps: steps)
        }
        inputs.calendar = .current
        return inputs
    }
}

// MARK: - Words

enum InsightWords {

    static func isNightFactor(_ f: AutoFactor) -> Bool {
        switch f {
        case .earlyBedtime, .consistentBedtime, .sevenHours, .sleepDebt, .lateWorkout: return true
        case .highStrain, .highSteps: return false
        }
    }

    static func factorName(_ source: InsightSource) -> String {
        switch source {
        case .journal(let q): return journalQuestionTitle(q)
        case .data(let f):
            switch f {
            case .earlyBedtime: return String(localized: "Early bedtime")
            case .consistentBedtime: return String(localized: "Consistent bedtime")
            case .sevenHours: return String(localized: "Slept 7 hours or more")
            case .sleepDebt: return String(localized: "Carrying sleep debt")
            case .lateWorkout: return String(localized: "Late workout")
            case .highStrain: return String(localized: "High-strain day")
            case .highSteps: return String(localized: "High-step day")
            }
        }
    }

    /// The Journal tile's name for a question ("Did you drink any alcohol?" → "Alcohol"), so Insights,
    /// the Journal and Edit questions all call it the same thing.
    static func journalQuestionTitle(_ question: String) -> String {
        coachingShortDisplayName(for: JournalCatalogItem(canonical: question, displayName: nil, kind: .bool,
                                                         group: .other, sortIndex: 0, hidden: false, custom: false))
    }

    static func sideLabels(_ source: InsightSource, bedtime: String?) -> (with: String, without: String) {
        switch source {
        case .journal: return (String(localized: "Yes"), String(localized: "No"))
        case .data(let f):
            switch f {
            case .earlyBedtime:
                return (String(localized: "Before \(bedtime ?? "")"), String(localized: "Later"))
            case .consistentBedtime: return (String(localized: "Usual time"), String(localized: "Off by 30+ min"))
            case .sevenHours: return (String(localized: "7 h or more"), String(localized: "Under 7 h"))
            case .sleepDebt: return (String(localized: "In sleep debt"), String(localized: "Not in debt"))
            case .lateWorkout: return (String(localized: "Late workout"), String(localized: "No late workout"))
            case .highStrain: return (String(localized: "After high strain"), String(localized: "Other days"))
            case .highSteps: return (String(localized: "After high steps"), String(localized: "Other days"))
            }
        }
    }

    static func counts(_ source: InsightSource, nWith: Int, nWithout: Int) -> String {
        if case .data(let f) = source, isNightFactor(f) {
            return String(localized: "\(nWith) vs \(nWithout) nights")
        }
        return String(localized: "\(nWith) vs \(nWithout) days")
    }

    /// One whole sentence per factor and direction, so translators never see stitched fragments.
    static func sentence(source: InsightSource, outcome: InsightOutcome, effect e: BehaviorEffect,
                         bedtime: String?) -> String {
        let what = outcome.inSentence
        let amount = outcome.amount(e)
        let pair = outcome.pair(e)
        let higher = e.delta >= 0
        switch source {
        case .journal(let q):
            let name = journalQuestionTitle(q)
            return higher
                ? String(localized: "On days you logged \(name), your \(what) averaged \(amount) higher (\(pair)).")
                : String(localized: "On days you logged \(name), your \(what) averaged \(amount) lower (\(pair)).")
        case .data(let f):
            switch f {
            case .earlyBedtime:
                let time = bedtime ?? ""
                return higher
                    ? String(localized: "On nights you went to bed before \(time), your \(what) averaged \(amount) higher (\(pair)).")
                    : String(localized: "On nights you went to bed before \(time), your \(what) averaged \(amount) lower (\(pair)).")
            case .consistentBedtime:
                return higher
                    ? String(localized: "On nights you went to bed within 30 minutes of your usual time, your \(what) averaged \(amount) higher (\(pair)).")
                    : String(localized: "On nights you went to bed within 30 minutes of your usual time, your \(what) averaged \(amount) lower (\(pair)).")
            case .sevenHours:
                return higher
                    ? String(localized: "After nights with 7 hours of sleep or more, your \(what) averaged \(amount) higher (\(pair)).")
                    : String(localized: "After nights with 7 hours of sleep or more, your \(what) averaged \(amount) lower (\(pair)).")
            case .sleepDebt:
                return higher
                    ? String(localized: "When you were carrying sleep debt, your \(what) averaged \(amount) higher (\(pair)).")
                    : String(localized: "When you were carrying sleep debt, your \(what) averaged \(amount) lower (\(pair)).")
            case .lateWorkout:
                return higher
                    ? String(localized: "After a workout that ended within 3 hours of bed, your \(what) averaged \(amount) higher (\(pair)).")
                    : String(localized: "After a workout that ended within 3 hours of bed, your \(what) averaged \(amount) lower (\(pair)).")
            case .highStrain:
                return higher
                    ? String(localized: "On mornings after a high-strain day, your \(what) averaged \(amount) higher (\(pair)).")
                    : String(localized: "On mornings after a high-strain day, your \(what) averaged \(amount) lower (\(pair)).")
            case .highSteps:
                return higher
                    ? String(localized: "On mornings after a high-step day, your \(what) averaged \(amount) higher (\(pair)).")
                    : String(localized: "On mornings after a high-step day, your \(what) averaged \(amount) lower (\(pair)).")
            }
        }
    }
}

// MARK: - Row and hero words

extension InsightRow {
    /// The factor as a row title: "In bed before 11:30 PM", "Workout within 3 h of bed", "Alcohol".
    var rowTitle: String { InsightWords.rowTitle(source, bedtime: bedtime) }
    var symbol: String { InsightWords.symbol(source) }
    /// "62% vs 54% · 87 vs 33 nights · Solid"
    var detailLine: String { "\(outcome.pair(effect.effect)) · \(countsText) · \(confidenceWord)" }
    /// "+8 pts", "−16%"
    var deltaText: String { outcome.signedAmount(effect.effect) }
    /// "+8 pts recovery", for the compact Trends rows.
    var deltaWithOutcome: String { String(localized: "\(deltaText) \(outcome.inSentence)") }
    /// The hero's headline when this is the strongest finding.
    var headline: String { InsightWords.headline(source, outcome: outcome) }
}

extension InsightWords {
    static func rowTitle(_ source: InsightSource, bedtime: String?) -> String {
        switch source {
        case .journal(let q): return journalQuestionTitle(q)
        case .data(let f):
            switch f {
            case .earlyBedtime: return String(localized: "In bed before \(bedtime ?? "")")
            case .consistentBedtime: return String(localized: "Bed within 30 min of usual")
            case .sevenHours: return String(localized: "7 hours of sleep or more")
            case .sleepDebt: return String(localized: "Carrying sleep debt")
            case .lateWorkout: return String(localized: "Workout within 3 h of bed")
            case .highStrain: return String(localized: "High-strain day")
            case .highSteps: return String(localized: "High-step day")
            }
        }
    }

    static func symbol(_ source: InsightSource) -> String {
        switch source {
        case .journal(let q):
            let s = q.lowercased()
            if s.contains("alcohol") || s.contains("drink") { return "wineglass" }
            if s.contains("caffeine") || s.contains("coffee") { return "cup.and.saucer" }
            if s.contains("stress") { return "brain.head.profile" }
            if s.contains("screen") { return "iphone" }
            if s.contains("eat") || s.contains("meal") { return "fork.knife" }
            if s.contains("sauna") { return "flame" }
            if s.contains("sick") || s.contains("ill") { return "thermometer.medium" }
            if s.contains("read") { return "book" }
            if s.contains("magnesium") { return "pills" }
            return "square.and.pencil"
        case .data(let f):
            switch f {
            case .earlyBedtime: return "bed.double"
            case .consistentBedtime: return "clock"
            case .sevenHours: return "moon.zzz"
            case .sleepDebt: return "moon"
            case .lateWorkout: return "figure.run"
            case .highStrain: return "flame"
            case .highSteps: return "figure.walk"
            }
        }
    }

    /// Whole headlines per factor and outcome word, so no fragment is stitched.
    static func headline(_ source: InsightSource, outcome: InsightOutcome) -> String {
        let what = outcome.inSentence
        switch source {
        case .journal(let q):
            return String(localized: "\(journalQuestionTitle(q)) moves your \(what) most")
        case .data(let f):
            switch f {
            case .earlyBedtime: return String(localized: "Your bedtime moves your \(what) most")
            case .consistentBedtime: return String(localized: "A steady bedtime moves your \(what) most")
            case .sevenHours: return String(localized: "Sleep length moves your \(what) most")
            case .sleepDebt: return String(localized: "Sleep debt moves your \(what) most")
            case .lateWorkout: return String(localized: "Late workouts move your \(what) most")
            case .highStrain: return String(localized: "Hard days move your \(what) most")
            case .highSteps: return String(localized: "Busy days on your feet move your \(what) most")
            }
        }
    }
}
