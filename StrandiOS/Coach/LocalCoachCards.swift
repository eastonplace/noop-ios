#if os(iOS)
import Foundation
import StrandAnalytics

/// One dated observation in a card's mini series. `day` is the civil `yyyy-MM-dd` record key from the
/// canonical cache, so a night that was never recorded is simply absent (never zero-filled).
struct CoachSeriesPoint: Codable, Equatable, Sendable {
    var day: String
    var value: Double
}

/// A deterministic, tool-derived visual summary shown under a Coach answer. Every number comes from
/// Swift reading the user's records (`LocalCoachDataService`), never from the language model.
///
/// Honesty rules shared by all cards: any value that can be missing is `Optional` (nil, never 0),
/// every card names the record date it describes, and `isStale` says the newest record is older than
/// the end of the window that was read. Effort is always the canonical stored 0...100 value here; the
/// view converts it to the user's display scale.
///
/// This type is outside any FoundationModels gate and has no model-facing surface.
enum LocalCoachCard: Codable, Equatable, Sendable, Identifiable {
    typealias JournalAssociation = JournalAssociationAnalysis.Insight
    struct Recovery: Codable, Equatable, Sendable {
        var day: String
        var isStale: Bool
        /// Recorded 0...100 score.
        var score: Double?
        var hrvMs: Double?
        var restingHr: Double?
        var sleepMinutes: Double?
    }

    struct Sleep: Codable, Equatable, Sendable {
        var day: String
        var isStale: Bool
        var totalMinutes: Double?
        var deepMinutes: Double?
        var remMinutes: Double?
        var lightMinutes: Double?
        /// 0...100.
        var efficiencyPercent: Double?
        /// Recent observed nights (minutes asleep), oldest first. Unrecorded nights are absent.
        var recentNights: [CoachSeriesPoint]
    }

    struct Trend: Codable, Equatable, Sendable {
        /// Tool metric id: recovery, strain (Effort), sleep, hrv or rhr.
        var metricID: String
        var title: String
        /// Unit of `points`. Effort keeps the canonical "/100".
        var unit: String
        /// Day of the newest observation.
        var day: String
        var isStale: Bool
        var points: [CoachSeriesPoint]
        var latest: Double?
        var average: Double?
        var minimum: Double?
        var maximum: Double?
    }

    struct Effort: Codable, Equatable, Sendable {
        var day: String
        var isStale: Bool
        /// Canonical stored Effort, 0...100.
        var value: Double?
        /// Workouts read for the window; nil when unknown or the read cap truncated the count.
        var workoutCount: Int?
        var windowDays: Int
    }

    struct WorkoutItem: Codable, Equatable, Sendable {
        var sport: String
        /// Unix seconds.
        var startTs: Int
        var durationS: Double?
        var avgHr: Double?
        /// Canonical stored Effort, 0...100 (only NOOP Strain V2 workouts carry one).
        var effort: Double?
    }

    struct Workouts: Codable, Equatable, Sendable {
        /// Civil date of the newest workout shown.
        var day: String
        var isStale: Bool
        var items: [WorkoutItem]
        /// The window that was read (civil dates), shown instead of a single record date.
        var windowFrom: String? = nil
        var windowThrough: String? = nil
    }

    struct StatItem: Codable, Equatable, Sendable {
        var label: String
        var value: String
    }

    struct Stats: Codable, Equatable, Sendable {
        var title: String
        var day: String?
        var isStale: Bool
        var items: [StatItem]
    }

    case recovery(Recovery)
    case sleep(Sleep)
    case trend(Trend)
    case effort(Effort)
    case workouts(Workouts)
    case stats(Stats)
    case journalAssociation(JournalAssociation)

    /// Stable per kind + day/metric so the same record read by two tools collapses to one card.
    var id: String {
        switch self {
        case .recovery(let card): return "recovery:\(card.day)"
        case .sleep(let card): return "sleep:\(card.day)"
        case .trend(let card): return "trend:\(card.metricID):\(card.day)"
        case .effort(let card): return "effort:\(card.day)"
        case .workouts(let card): return "workouts:\(card.items.first?.startTs ?? 0)"
        case .stats(let card): return "stats:\(card.title):\(card.day ?? "")"
        case .journalAssociation(let card):
            return "journalAssociation:\(card.questionKey ?? card.state.rawValue):\(card.windowFrom):\(card.windowThrough)"
        }
    }

    /// Short kind name used for accessibility identifiers (`coach.card.<kind>`).
    var kind: String {
        switch self {
        case .recovery: return "recovery"
        case .sleep: return "sleep"
        case .trend: return "trend"
        case .effort: return "effort"
        case .workouts: return "workouts"
        case .stats: return "stats"
        case .journalAssociation: return "journalAssociation"
        }
    }

    /// Civil date of the newest record the card describes.
    var day: String? {
        switch self {
        case .recovery(let card): return card.day
        case .sleep(let card): return card.day
        case .trend(let card): return card.day
        case .effort(let card): return card.day
        case .workouts(let card): return card.day
        case .stats(let card): return card.day
        case .journalAssociation(let card): return card.latestDay
        }
    }

    var isStale: Bool {
        switch self {
        case .recovery(let card): return card.isStale
        case .sleep(let card): return card.isStale
        case .trend(let card): return card.isStale
        case .effort(let card): return card.isStale
        case .workouts(let card): return card.isStale
        case .stats(let card): return card.isStale
        case .journalAssociation: return false // Historical association, not a claim about current readiness.
        }
    }

    /// Engine-side cap and dedupe: keeps the first card for each id, at most `limit` in total.
    static func merging(_ existing: [LocalCoachCard], with incoming: [LocalCoachCard], limit: Int = 4) -> [LocalCoachCard] {
        var merged = existing
        var seen = Set(existing.map(\.id))
        for card in incoming where merged.count < limit && seen.insert(card.id).inserted {
            merged.append(card)
        }
        return merged
    }

    /// At most three habits, with the requested habit first and stable alphabetical order after it.
    /// Never rank cards by the size or direction of an effect; that would invite cherry-picking.
    static func journalAssociationCards(_ insights: [JournalAssociation], query: String) -> [LocalCoachCard] {
        let generic: Set<String> = ["did", "you", "have", "take", "your", "before", "after", "close",
                                    "what", "which", "with", "from", "days", "late", "feel", "drink"]
        let request = query.lowercased()
        func isRequested(_ insight: JournalAssociation) -> Bool {
            let words = (insight.questionKey ?? "").split(whereSeparator: { !$0.isLetter }).map(String.init)
            return words.contains { $0.count >= 4 && !generic.contains($0) && request.contains($0) }
        }
        return insights.sorted {
            let left = isRequested($0), right = isRequested($1)
            if left != right { return left }
            return ($0.questionKey ?? "") < ($1.questionKey ?? "")
        }.prefix(3).map(LocalCoachCard.journalAssociation)
    }
}

/// Number and duration wording shared by the card views, the export text and the accessibility labels.
enum LocalCoachCardFormat {
    static func journalFollowUp(_ card: LocalCoachCard.JournalAssociation) -> String {
        let subject = card.question.map { "the logged habit “\(String($0.prefix(200)))”" } ?? "my explicitly logged habits"
        return "Explain the recorded journal association for \(subject) from \(card.windowFrom) through \(card.windowThrough). Distinguish association from causation, explain the comparison's limits, and tell me what data is still missing."
    }

    static func journalStatus(_ card: LocalCoachCard.JournalAssociation) -> String {
        switch card.state {
        case .available:
            return "Descriptive association only—not causation or a statistical-significance claim."
        case .insufficientData:
            return "Need at least 3 matched yes days and at least 3 matched explicit-no days before showing a comparison."
        case .truncated:
            return "Incomplete read: the \(JournalAssociationAnalysis.maximumRowsPerSource)-record per-source cap was exceeded. Group counts withheld; no numeric comparison is available. Try a shorter date range."
        case .noBooleanAnswers:
            return "No comparable explicit yes/no answers in this window. Quantity entries are not boolean answers."
        }
    }

    static func journalSamples(_ card: LocalCoachCard.JournalAssociation) -> String {
        guard card.state != .truncated else { return "Group counts withheld because the read is incomplete." }
        func count(_ value: Int?) -> String { value.map(String.init) ?? "not available" }
        return "Matched recovery days: yes \(count(card.matchedYesCount)), no \(count(card.matchedNoCount)); logged answers: yes \(count(card.loggedYesCount)), no \(count(card.loggedNoCount)); missing recovery \(count(card.missingRecoveryCount)); conflicting answer days \(count(card.conflictingDayCount))."
    }
    /// "7h 42m", "45m". Nil, non-finite or negative durations are "—" (never "0m"). Worded through the catalog
    /// entries Sleep uses for the same figure, so it reads in the person's language.
    static func duration(minutes: Double?) -> String {
        guard let minutes, minutes.isFinite, minutes >= 0 else { return "—" }
        let total = Int(minutes.rounded())
        return total < 60 ? String(localized: "\(total)m") : String(localized: "\(total / 60)h \(total % 60)m")
    }

    static func duration(seconds: Double?) -> String {
        duration(minutes: seconds.map { $0 / 60 })
    }

    static func whole(_ value: Double?, unit: String? = nil) -> String {
        guard let value, value.isFinite else { return "—" }
        let text = String(Int(value.rounded()))
        guard let unit else { return text }
        // "82/100" and "91%" attach directly; "64 ms" keeps a space.
        return unit.hasPrefix("/") || unit == "%" ? text + unit : text + " " + unit
    }

    static func oneDecimal(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// "Today", "Yesterday", "Oct 3" (adds the year when it is not the current one, "Sep 30, 2025").
    /// Always the record's real date. Unparseable keys are returned untouched rather than guessed.
    static func dayLabel(_ day: String, now: Date = Date()) -> String {
        guard let date = LocalCoachWindow.date(day) else { return day }
        return dayLabel(date, now: now)
    }

    /// The same label for a date that is already parsed, so a caller that needs the date as well reads the key once.
    static func dayLabel(_ date: Date, now: Date = Date()) -> String {
        let calendar = LocalCoachWindow.calendar
        let age = calendar.dateComponents([.day], from: date, to: calendar.startOfDay(for: now)).day ?? 0
        if age == 0 { return String(localized: "Today") }
        if age == 1 { return String(localized: "Yesterday") }
        return humanDay(date, now: now)
    }

    /// "Oct 8" or "Aug 22, 2025": a plain calendar date with no relative wording.
    static func humanDay(_ day: String, now: Date = Date()) -> String {
        guard let date = LocalCoachWindow.date(day) else { return day }
        return humanDay(date, now: now)
    }

    static func humanDay(_ date: Date, now: Date = Date()) -> String {
        let sameYear = LocalCoachWindow.calendar.component(.year, from: date)
            == LocalCoachWindow.calendar.component(.year, from: now)
        return date.formatted(sameYear ? .dateTime.month(.abbreviated).day()
                                       : .dateTime.month(.abbreviated).day().year())
    }

    /// Stat values that are record dates (stored as `yyyy-MM-dd`) read as plain dates; anything else is unchanged.
    static func displayValue(_ value: String, now: Date = Date()) -> String {
        LocalCoachWindow.date(value) == nil ? value : humanDay(value, now: now)
    }

    /// "Last 7 days" when the window ends today, otherwise the real range ("Sep 1 - Sep 3").
    static func windowLabel(from: String, through: String, now: Date = Date()) -> String? {
        guard let start = LocalCoachWindow.date(from), let end = LocalCoachWindow.date(through), start <= end else { return nil }
        let calendar = LocalCoachWindow.calendar
        if LocalCoachWindow.key(now) == through {
            let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
            return days == 1 ? String(localized: "Today") : String(localized: "Last \(days) days")
        }
        return from == through ? humanDay(from, now: now) : "\(humanDay(from, now: now)) - \(humanDay(through, now: now))"
    }

    /// "Wed 6:30 AM" for a workout start time (unix seconds). The clock follows the app's 12/24-hour setting.
    static func startLabel(_ startTs: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(startTs))
        return date.formatted(.dateTime.weekday(.abbreviated)) + " " + AppClock.hourMinute(date)
    }

    /// One plain-text line per card for `exportConversation`. Canonical Effort stays on 0...100 here,
    /// matching the tool text the model and the export already use.
    static func exportLine(_ card: LocalCoachCard) -> String {
        switch card {
        case .recovery(let card):
            return "Recovery card (\(card.day)\(card.isStale ? ", stale" : "")): recovery \(whole(card.score, unit: "/100")), HRV \(whole(card.hrvMs, unit: "ms")), resting HR \(whole(card.restingHr, unit: "bpm")), sleep \(duration(minutes: card.sleepMinutes))"
        case .sleep(let card):
            return "Sleep card (\(card.day)\(card.isStale ? ", stale" : "")): sleep \(duration(minutes: card.totalMinutes)), deep \(duration(minutes: card.deepMinutes)), REM \(duration(minutes: card.remMinutes)), light \(duration(minutes: card.lightMinutes)), efficiency \(whole(card.efficiencyPercent, unit: "%"))"
        case .trend(let card):
            return "\(card.title) trend card (newest \(card.day)\(card.isStale ? ", stale" : "")): latest \(oneDecimal(card.latest)) \(card.unit), average \(oneDecimal(card.average)), range \(oneDecimal(card.minimum))-\(oneDecimal(card.maximum)) across \(card.points.count) observed days"
        case .effort(let card):
            return "Effort card (\(card.day)\(card.isStale ? ", stale" : "")): canonical effort \(whole(card.value, unit: "/100")), \(card.workoutCount.map { "\($0) workouts" } ?? "workout count not available") in \(card.windowDays) days"
        case .workouts(let card):
            let items = card.items.map { "\($0.sport) \(duration(seconds: $0.durationS))" }.joined(separator: "; ")
            return "Workouts card (newest \(card.day)\(card.isStale ? ", stale" : "")): \(items)"
        case .stats(let card):
            let items = card.items.map { "\($0.label) \($0.value)" }.joined(separator: "; ")
            return "\(card.title) card\(card.day.map { " (\($0)\(card.isStale ? ", stale" : ""))" } ?? ""): \(items)"
        case .journalAssociation(let card):
            var parts = ["Journal association card (\(card.windowFrom) through \(card.windowThrough)): \(card.question ?? "Journal data coverage").",
                         journalStatus(card), journalSamples(card)]
            if card.state == .available, let difference = card.difference {
                parts.append("Same-wake-day recovery: yes mean \(oneDecimal(card.yesMean))/100, no mean \(oneDecimal(card.noMean))/100; difference \(oneDecimal(difference)) points (yes minus no).")
            }
            if card.excludedNumericAnswerCount > 0 {
                parts.append("\(card.excludedNumericAnswerCount) records from numeric questions excluded from boolean comparisons.")
            }
            parts.append("Journal sources: \((card.sources.isEmpty ? card.sourcesRead : card.sources).joined(separator: ", ")). Recovery source: \(card.recoverySource).")
            if !card.truncatedSources.isEmpty { parts.append("Incomplete sources: \(card.truncatedSources.joined(separator: ", ")).") }
            parts.append("Unlogged days are excluded, not treated as no. The canonical recovery cache may cover less than the requested window. Association is not causation.")
            return parts.joined(separator: " ")
        }
    }
}

extension LocalCoachCard {
    /// Clearly synthetic cards for the preview engine and screenshots: one of each kind, dated relative
    /// to `now`. They are never produced by a tool, never sent to a model and never read from a record.
    static func previewSamples(now: Date = Date()) -> (readiness: [LocalCoachCard], training: [LocalCoachCard], coverage: [LocalCoachCard]) {
        let calendar = LocalCoachWindow.calendar
        func day(_ ago: Int) -> String {
            LocalCoachWindow.key(calendar.date(byAdding: .day, value: -ago, to: now) ?? now)
        }
        func series(_ values: [(ago: Int, value: Double)]) -> [CoachSeriesPoint] {
            values.map { CoachSeriesPoint(day: day($0.ago), value: $0.value) }
        }
        let readiness: [LocalCoachCard] = [
            .recovery(.init(day: day(0), isStale: false, score: 82, hrvMs: 64, restingHr: 52, sleepMinutes: 462)),
            .sleep(.init(day: day(0), isStale: false, totalMinutes: 462, deepMinutes: 96, remMinutes: 112,
                         lightMinutes: 254, efficiencyPercent: 91,
                         recentNights: series([(7, 408), (6, 432), (5, 421), (3, 468), (2, 451), (1, 447), (0, 462)])))
        ]
        let training: [LocalCoachCard] = [
            .effort(.init(day: day(0), isStale: false, value: 58, workoutCount: 3, windowDays: 7)),
            .workouts(.init(day: day(0), isStale: false, items: [
                .init(sport: "Running", startTs: Int(now.timeIntervalSince1970) - 6 * 3_600, durationS: 2_700, avgHr: 152, effort: 62),
                .init(sport: "Strength training", startTs: Int(now.timeIntervalSince1970) - 2 * 86_400, durationS: 3_120, avgHr: 118, effort: 41),
                .init(sport: "Cycling", startTs: Int(now.timeIntervalSince1970) - 4 * 86_400, durationS: 2_280, avgHr: nil, effort: nil)
            ], windowFrom: day(6), windowThrough: day(0))),
            .trend(.init(metricID: "recovery", title: "Recovery", unit: "/100", day: day(3), isStale: true,
                         points: series([(15, 65), (14, 72), (13, 68), (11, 79), (10, 74), (9, 80), (7, 71), (6, 77),
                                         (5, 83), (4, 76), (3, 82)]),
                         latest: 82, average: 75.2, minimum: 65, maximum: 83)),
            .trend(.init(metricID: "hrv", title: "HRV", unit: "ms", day: day(0), isStale: false,
                         points: series([(13, 55), (12, 59), (11, 58), (9, 63), (8, 61), (7, 62), (5, 57), (4, 60),
                                         (3, 66), (2, 61), (1, 63), (0, 64)]),
                         latest: 64, average: 60.8, minimum: 55, maximum: 66))
        ]
        let coverage: [LocalCoachCard] = [
            .stats(.init(title: "Data coverage", day: day(0), isStale: false, items: [
                .init(label: "Latest record", value: day(0)),
                .init(label: "Earliest record", value: day(412)),
                .init(label: "History span", value: "413 days")
            ]))
        ]
        return (readiness, training, coverage)
    }
}

/// Cards are decorative extras. A card this build cannot read (for example one written by a newer
/// build) must never make the whole conversation state unreadable, because an unreadable state blocks
/// every future save. Decode each card on its own and drop the ones that fail.
private struct LocalCoachLossyCard: Decodable {
    let card: LocalCoachCard?
    init(from decoder: Decoder) throws { card = try? LocalCoachCard(from: decoder) }
}

extension LocalCoachMessage {
    /// Hand-written so a missing or unreadable `cards` key never fails decoding. Encoding stays synthesized.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        role = try values.decode(Role.self, forKey: .role)
        text = try values.decode(String.self, forKey: .text)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        evidence = try values.decode([LocalCoachEvidence].self, forKey: .evidence)
        toolNames = try values.decode([String].self, forKey: .toolNames)
        isInterrupted = try values.decode(Bool.self, forKey: .isInterrupted)
        let decoded = (try? values.decodeIfPresent([LocalCoachLossyCard].self, forKey: .cards))?.compactMap(\.card)
        cards = (decoded?.isEmpty ?? true) ? nil : decoded
    }
}
#endif
