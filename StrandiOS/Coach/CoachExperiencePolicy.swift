import Foundation

/// Routing is a request policy, not a second source of health calculations.
/// Every planned read still goes through LocalCoachEngine's consent, source and read-budget checks.
enum CoachEvidencePlan: Equatable, Sendable {
    case general
    case read(tool: String, days: Int)
    case needsNarrowerRange
}

enum CoachEvidencePolicy {
    static let maximumDays = 31
    static let rangeExplanation = "Coach can inspect up to 31 days per request. Choose a shorter period, or open Trends for longer history. Explicit dates must be valid and end today or earlier."

    static func permitsPersonalRead(consent: Bool, recordsUpdating: Bool) -> Bool {
        consent && !recordsUpdating
    }

    static func plan(for question: String, now: Date = Date(), calendar inputCalendar: Calendar = .autoupdatingCurrent) -> CoachEvidencePlan {
        let calendar = civilCalendar(inputCalendar)
        let text = question.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let words = Set(text.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let personal = !words.isDisjoint(with: ["my", "mine", "recorded", "records"])
            || text.contains("help me plan") || text.contains("should i")
            || text.contains("recent workouts") || text.contains("latest activity")
            || (words.contains("i") && !words.isDisjoint(with: ["sleep", "slept", "recover", "recovered", "train", "trained", "run", "ran"]))
        guard personal else { return .general }

        let window = requestedWindow(in: text, now: now, calendar: calendar)
        guard let days = window else { return .needsNarrowerRange }
        let tool: String
        if text.contains("how much history") || text.contains("data coverage") || text.contains("data freshness") {
            tool = "data_freshness"
        } else if text.contains("daily outlook") || text.contains("daily brief") || text.contains("plan today") {
            return .read(tool: "current_day", days: 1)
        } else if !words.isDisjoint(with: ["nutrition", "macros", "protein", "intake", "eaten", "food"]) {
            tool = "nutrition"
        } else if !words.isDisjoint(with: ["habits", "journal", "associations"]) {
            tool = "journal_associations"
        } else if text.contains("zones") {
            tool = "workout_zones"
        } else if text.contains("training load") || text.contains("overtraining") {
            tool = "training_load"
        } else if !words.isDisjoint(with: ["workout", "workouts", "training", "train", "trained", "activity", "sessions", "run", "runs", "ran", "lifting"]) {
            tool = "workout_history"
        } else if !words.isDisjoint(with: ["recovery", "hrv", "rhr", "strain", "trend", "trends"]) {
            tool = words.contains("ready") || words.contains("readiness") ? "readiness" : "metric_trends"
        } else if !words.isDisjoint(with: ["sleep", "slept", "sleeping", "nights"]) {
            tool = "sleep_history"
        } else if !words.isDisjoint(with: ["ready", "readiness"]) {
            tool = "readiness"
        } else {
            tool = "current_day"
        }
        return .read(tool: tool, days: days)
    }

    /// Place explicit civil dates before the filter so the engine's byte cap cannot remove them.
    /// The data service understands ISO dates, rather than relative words such as yesterday.
    static func readQuery(for question: String, days: Int, now: Date = Date(),
                          calendar inputCalendar: Calendar = .autoupdatingCurrent) -> String {
        let calendar = civilCalendar(inputCalendar)
        let pattern = #"\b\d{4}-\d{1,2}-\d{1,2}\b"#
        let dates = matches(pattern, in: question).map { $0[0] }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var end = calendar.startOfDay(for: now)
        let lower = question.lowercased()
        if lower.contains("yesterday") && !lower.contains("today") {
            end = calendar.date(byAdding: .day, value: -1, to: end) ?? end
        }
        var start = calendar.date(byAdding: .day, value: 1 - min(maximumDays, max(1, days)), to: end) ?? end
        if let period = relativeCalendarWindow(in: lower, now: now, calendar: calendar) {
            start = period.lowerBound
            end = period.upperBound
        }
        let first = dates.first ?? formatter.string(from: start)
        let last = dates.last ?? formatter.string(from: end)
        let expression = try? NSRegularExpression(pattern: pattern)
        let filter = expression?.stringByReplacingMatches(in: question,
            range: NSRange(question.startIndex..., in: question), withTemplate: "") ?? question
        let window = first == last ? first : first + " through " + last
        return window + " " + filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Explicit ranges are checked before a store query. A large or invalid range never quietly becomes "recent".
    private static func requestedWindow(in rawText: String, now: Date, calendar: Calendar) -> Int? {
        // An age ("I'm 40 years old") is a personal detail, not a read window.
        let agePattern = #"\b(?:\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s*-?\s*(?:years?|yrs?)\s*-?\s*(?:old|of age|young)\b"#
        let text = rawText.replacingOccurrences(of: agePattern, with: " ", options: .regularExpression)
        let datePattern = #"\b\d{4}-\d{1,2}-\d{1,2}\b"#
        let dateStrings = matches(datePattern, in: text).map { $0[0] }
        if !dateStrings.isEmpty {
            guard dateStrings.count <= 2 else { return nil }
            let dates = dateStrings.compactMap { raw -> Date? in
                let values = raw.split(separator: "-").compactMap { Int($0) }
                guard raw.count == 10, values.count == 3,
                      let date = calendar.date(from: DateComponents(year: values[0], month: values[1], day: values[2])) else { return nil }
                let components = calendar.dateComponents([.year, .month, .day], from: date)
                guard components.year == values[0], components.month == values[1], components.day == values[2] else { return nil }
                return date
            }
            guard dates.count == dateStrings.count, let first = dates.first, let last = dates.last,
                  first <= last, last <= calendar.startOfDay(for: now) else { return nil }
            let count = (calendar.dateComponents([.day], from: first, to: last).day ?? maximumDays) + 1
            return (1...maximumDays).contains(count) ? count : nil
        }
        let durationPattern = #"\b(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\s*(days?|weeks?|months?|years?)\b"#
        let numberWords = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                           "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10]
        let durations = matches(durationPattern, in: text)
        if !durations.isEmpty {
            var windows: [Int] = []
            for groups in durations {
                guard groups.count == 3, let number = Int(groups[1]) ?? numberWords[groups[1]],
                      (1...maximumDays).contains(number) else { return nil }
                let multiplier = groups[2].hasPrefix("week") ? 7 : groups[2].hasPrefix("month") ? 31 : groups[2].hasPrefix("year") ? 365 : 1
                let days = number * multiplier
                guard days <= maximumDays else { return nil }
                windows.append(days)
            }
            let comparesPrior = (text.contains("compar") || text.contains("versus"))
                && (text.contains("previous") || text.contains("prior"))
            let count = comparesPrior ? (windows.count > 1 ? windows.reduce(0, +) : (windows.first ?? 1) * 2)
                : windows.max() ?? 1
            return count <= maximumDays ? count : nil
        }
        if text.contains("year") || text.contains("all time") || text.contains("all my history")
            || text.contains("months") || text.contains("quarter") { return nil }
        if let period = relativeCalendarWindow(in: text, now: now, calendar: calendar) {
            let count = (calendar.dateComponents([.day], from: period.lowerBound, to: period.upperBound).day ?? maximumDays) + 1
            return (1...maximumDays).contains(count) ? count : nil
        }
        if text.contains("month") { return 31 }
        if text.contains("week") { return text.contains("compar") || text.contains("versus") ? 14 : 7 }
        if text.contains("today") && text.contains("yesterday") { return 2 }
        if text.contains("today") || text.contains("yesterday") || text.contains("last night") { return 1 }
        return 14
    }

    /// Calendar phrases keep calendar bounds. "Past seven days" remains a rolling window.
    /// Sleep is stored under the wake day, so "last night" stays on today's record.
    private static func relativeCalendarWindow(in text: String, now: Date,
                                               calendar: Calendar) -> ClosedRange<Date>? {
        let today = calendar.startOfDay(for: now)
        let comparison = text.contains("compar") || text.contains("versus") || text.contains("this week")
            || text.contains("this month")
        if text.contains("last week"), let week = calendar.dateInterval(of: .weekOfYear, for: today),
           let first = calendar.date(byAdding: .day, value: -7, to: week.start),
           let last = calendar.date(byAdding: .day, value: -1, to: week.start) {
            return first...(comparison ? today : last)
        }
        if text.contains("last month"), let month = calendar.dateInterval(of: .month, for: today),
           let first = calendar.date(byAdding: .month, value: -1, to: month.start),
           let last = calendar.date(byAdding: .day, value: -1, to: month.start) {
            return first...(comparison ? today : last)
        }
        if text.contains("this week"), let week = calendar.dateInterval(of: .weekOfYear, for: today) {
            return week.start...today
        }
        if text.contains("this month"), let month = calendar.dateInterval(of: .month, for: today) {
            return month.start...today
        }
        return nil
    }

    /// Store keys always use Gregorian civil dates, even with another device calendar.
    private static func civilCalendar(_ input: Calendar) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.timeZone
        calendar.locale = input.locale
        calendar.firstWeekday = input.firstWeekday
        calendar.minimumDaysInFirstWeek = input.minimumDaysInFirstWeek
        return calendar
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}

/// Only observable operations appear here. These values never imply access to model thoughts.
enum CoachResponseStage: Equatable, Sendable {
    case idle, preparing, checkingAccess
    case reading(tool: String, days: Int)
    case evidenceReady, writing, complete, stopped, failed

    var isActive: Bool {
        switch self {
        case .preparing, .checkingAccess, .reading, .evidenceReady, .writing: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .idle: ""
        case .preparing: "Preparing your answer"
        case .checkingAccess: "Checking local data access"
        case .reading(let tool, _): "Reading " + Self.toolTitle(tool)
        case .evidenceReady: "Record check complete"
        case .writing: "Writing the explanation"
        case .complete: "Answer ready"
        case .stopped: "Response stopped"
        case .failed: "Could not finish this answer"
        }
    }

    var detail: String {
        switch self {
        case .reading(_, let days): "Requested window: \(days) \(days == 1 ? "day" : "days")"
        case .checkingAccess: "Checking the selected source and your permission"
        case .evidenceReady: "Using the available dated evidence"
        case .preparing, .writing: "On this iPhone"
        case .failed: "Your question is kept. You can try again."
        case .stopped: "The partial answer is kept."
        case .idle, .complete: ""
        }
    }

    private static func toolTitle(_ tool: String) -> String {
        switch tool {
        case "current_day": "your daily records"
        case "workout_history": "workout history"
        case "workout_zones": "workout zones"
        case "training_load": "training history"
        case "sleep_history": "sleep history"
        case "readiness": "recovery records"
        case "metric_trends": "metric history"
        case "nutrition": "recorded nutrition"
        case "journal_associations": "journal records"
        case "data_freshness": "record dates"
        case "exercise_catalog": "the exercise catalog"
        case "metric_explanations": "the metric guide"
        case "app_diagnostics": "app diagnostics"
        default: "available records"
        }
    }
}

/// Rejects late events after cancellation and events owned by a prior request.
struct CoachResponseProgress: Equatable, Sendable {
    private(set) var operationID: UUID?
    private(set) var stage: CoachResponseStage = .idle

    mutating func begin(_ id: UUID) {
        operationID = id
        stage = .preparing
    }

    @discardableResult
    mutating func advance(_ next: CoachResponseStage, operation id: UUID) -> Bool {
        guard operationID == id, stage.isActive, stage != next else { return false }
        stage = next
        if !next.isActive { operationID = nil }
        return true
    }

    mutating func reset() { self = Self() }
}

/// Content growth and keyboard layout must not look like the reader scrolled into history.
struct CoachScrollPolicy: Equatable, Sendable {
    private(set) var followsLatest = true
    static let nearBottomDistance: Double = 56

    mutating func observe(distanceFromBottom: Double, userIsDragging: Bool) {
        guard distanceFromBottom.isFinite else { return }
        if distanceFromBottom <= Self.nearBottomDistance {
            followsLatest = true
        } else if userIsDragging {
            followsLatest = false
        }
    }

    mutating func pauseFollowing() { followsLatest = false }
    mutating func jumpToLatest() { followsLatest = true }
}
