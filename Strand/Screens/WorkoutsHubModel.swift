import Foundation
import WhoopStore
import StrandDesign

// MARK: - Workouts hub: pure presentation rules
//
// What the Workouts hub and the day view decide before anything is drawn: which Strain a row shows and whose it
// is, how a calendar week adds up, which number leads a row, how a day reads ("Today", "Tue, Oct 6"). Pure values
// in, pure values out, so the rules are tested without a view.

// MARK: Strain display

/// The Strain a workout row shows, and whose number it is. DISPLAY ONLY.
///
/// `StrainResolver.workoutStrainForDisplay` decides the value and its provenance. A weekly average, a sum or a
/// trend never reads this: those keep using `StrainResolver.canonicalWorkout`, which still refuses an imported
/// WHOOP value.
enum WorkoutStrainBadge: Equatable {
    /// NOOP's own Strain V2, on the 0...21 display scale.
    case noop(String)
    /// WHOOP's own number for an imported WHOOP workout, on the same display scale. Labelled "WHOOP" wherever it
    /// is shown, so it is never mistaken for a NOOP score.
    case whoop(String)

    var text: String {
        switch self {
        case .noop(let text), .whoop(let text): return text
        }
    }

    var isWhoop: Bool {
        if case .whoop = self { return true }
        return false
    }

    static func make(for row: WorkoutRow) -> WorkoutStrainBadge? {
        guard let shown = StrainResolver.workoutStrainForDisplay(row) else { return nil }
        let text = StrainScale.formatted(shown.storedValue)
        switch shown.provenance {
        case .noop: return .noop(text)
        case .whoop: return .whoop(text)
        }
    }
}

// MARK: Week summary

/// One calendar week of workouts: what happened each day and what it adds up to.
///
/// The average Strain counts NOOP's own scores only (`StrainResolver.canonicalWorkout`). An imported WHOOP value is
/// shown on its row, never averaged into a NOOP number, and a week with no NOOP-scored session has no average.
struct WorkoutWeekSummary: Equatable {
    struct Day: Equatable, Identifiable {
        /// Midnight at the start of the day, in the calendar the week was built with.
        let start: Date
        let sessions: Int
        let activeSeconds: Double
        let isToday: Bool
        /// A day after today: nothing can have happened on it yet.
        let isFuture: Bool

        var id: Date { start }
        var hasWorkouts: Bool { sessions > 0 && activeSeconds > 0 }
    }

    /// First instant of the week and the first instant of the next one.
    let interval: DateInterval
    /// Seven days in calendar order, starting on the calendar's first weekday.
    let days: [Day]
    let sessionCount: Int
    let activeSeconds: Double
    let energyKcal: Double
    /// Mean of the week's NOOP-scored (canonical) Strain on the stored 0...100 axis, or nil when no session this
    /// week carries one.
    let averageStrainStored: Double?

    var hasSessions: Bool { sessionCount > 0 }

    static func make(rows: [WorkoutRow], now: Date, calendar: Calendar = .current) -> WorkoutWeekSummary {
        let today = calendar.startOfDay(for: now)
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            ?? DateInterval(start: today, duration: 7 * 86_400)

        var starts: [Date] = []
        var cursor = calendar.startOfDay(for: interval.start)
        for _ in 0..<7 {
            starts.append(cursor)
            cursor = calendar.date(byAdding: .day, value: 1, to: cursor) ?? cursor.addingTimeInterval(86_400)
        }

        var sessionsByDay = [Int](repeating: 0, count: 7)
        var secondsByDay = [Double](repeating: 0, count: 7)
        var totalSessions = 0
        var totalSeconds = 0.0
        var totalKcal = 0.0
        var strains: [Double] = []

        for row in rows {
            let date = Date(timeIntervalSince1970: TimeInterval(row.startTs))
            guard date >= interval.start, date < interval.end else { continue }
            // The day a workout began on owns it, even when it runs past midnight.
            let dayStart = calendar.startOfDay(for: date)
            guard let index = starts.lastIndex(where: { $0 <= dayStart }) else { continue }
            let seconds = WorkoutFacts.activeSeconds(row) ?? 0
            sessionsByDay[index] += 1
            secondsByDay[index] += seconds
            totalSessions += 1
            totalSeconds += seconds
            totalKcal += max(0, row.energyKcal ?? 0)
            if let stored = StrainResolver.canonicalWorkout(row)?.storedValue { strains.append(stored) }
        }

        let days = starts.indices.map { index in
            Day(start: starts[index], sessions: sessionsByDay[index], activeSeconds: secondsByDay[index],
                isToday: starts[index] == today, isFuture: starts[index] > today)
        }
        return WorkoutWeekSummary(
            interval: interval, days: days, sessionCount: totalSessions, activeSeconds: totalSeconds,
            energyKcal: totalKcal,
            averageStrainStored: strains.isEmpty ? nil : strains.reduce(0, +) / Double(strains.count))
    }
}

extension WorkoutWeekSummary {
    /// A plausible week, for the loading skeleton: the shape of the real section before any row is read. Its numbers
    /// are never read aloud and are drawn as placeholders.
    static func placeholder(now: Date, calendar: Calendar = .current) -> WorkoutWeekSummary {
        let base = make(rows: [], now: now, calendar: calendar)
        let sample: [Double] = [2_700, 3_600, 5_400, 0, 1_800, 3_000, 0]
        let days = base.days.enumerated().map { index, day in
            Day(start: day.start, sessions: sample[index] > 0 ? 1 : 0, activeSeconds: sample[index],
                isToday: day.isToday, isFuture: day.isFuture)
        }
        return WorkoutWeekSummary(
            interval: base.interval, days: days, sessionCount: 5, activeSeconds: sample.reduce(0, +),
            energyKcal: 1_900, averageStrainStored: 55)
    }
}

// MARK: Row facts

/// The numbers a workout row can lead with.
enum WorkoutFacts {
    /// Seconds the workout lasted: its recorded duration, else the span between start and end. Nil when neither is
    /// a positive length.
    static func activeSeconds(_ row: WorkoutRow) -> Double? {
        if let recorded = row.durationS, recorded > 0 { return recorded }
        let span = Double(row.endTs - row.startTs)
        return span > 0 ? span : nil
    }

    /// Which metric leads a row's trailing column: how far for a session with a distance, else how long, else how
    /// much energy.
    enum Lead: Equatable { case distance, duration, energy }

    static func lead(for row: WorkoutRow) -> Lead? {
        if let distance = row.distanceM, distance > 0 { return .distance }
        if activeSeconds(row) != nil { return .duration }
        if let kcal = row.energyKcal, kcal > 0 { return .energy }
        return nil
    }
}

/// How far "when" reaches in a row's second line.
enum WorkoutRowWhen: Equatable {
    /// The day alone: "Today", "Yesterday", "Tue, Oct 6".
    case day
    /// The start time alone, for a list that already sits under one day.
    case time
    /// Both, as two facts: "Yesterday · 6:12 PM".
    case dayAndTime
}

/// How much a row says besides its lead.
enum WorkoutRowDetail: Equatable {
    /// One supporting fact.
    case compact
    /// Every supporting fact the row has.
    case full
}

/// A workout row, ready to draw.
struct WorkoutRowPresentation: Equatable {
    let title: String
    let symbol: String
    /// The lead metric for the trailing column, or nil when the row has no number worth leading with.
    let primary: String?
    /// The lines under the title, most important first. A line is a list of facts, most important first: the row
    /// shows as many of a line's facts as fit on one line and drops the rest from the end. A fact never breaks across
    /// lines ("338 kcal" keeps its number and its unit together).
    let lines: [[String]]
    let strain: WorkoutStrainBadge?
    let source: WorkoutSource

    /// Every fact the lines carry, in reading order.
    var facts: [String] { lines.flatMap { $0 } }

    /// The spoken form: everything the row shows, in reading order.
    var accessibilityLabel: String {
        var parts = [title] + facts
        if let primary { parts.append(primary) }
        switch strain {
        case .noop(let text)?: parts.append(String(localized: "Strain \(text)"))
        case .whoop(let text)?: parts.append(String(localized: "WHOOP strain \(text)"))
        case nil: break
        }
        return parts.joined(separator: ", ")
    }

    static func make(
        _ row: WorkoutRow,
        unitSystem: UnitSystem,
        when: WorkoutRowWhen = .day,
        detail: WorkoutRowDetail = .compact,
        includesSource: Bool = false,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WorkoutRowPresentation {
        let start = Date(timeIntervalSince1970: TimeInterval(row.startTs))
        let lead = WorkoutFacts.lead(for: row)

        var primary: String?
        switch lead {
        case .distance?: primary = row.distanceM.map { UnitFormatter.distanceFromMeters($0, system: unitSystem) }
        case .duration?: primary = WorkoutFacts.activeSeconds(row).map(WorkoutFormat.duration)
        case .energy?: primary = row.energyKcal.map(WorkoutFormat.energy)
        case nil: primary = nil
        }

        var first: [String] = []
        let day = WorkoutFormat.day(start, now: now, calendar: calendar)
        switch when {
        case .day: first.append(day)
        case .time: first.append(AppClock.hourMinute(start))
        case .dayAndTime: first += [day, AppClock.hourMinute(start)]
        }

        // Supporting facts, in the order a person asks for them: how long, how hard on the body, how fast the
        // heart ran. The lead is already in the trailing column, so it is never repeated here.
        var supporting: [String] = []
        if lead != .duration, let seconds = WorkoutFacts.activeSeconds(row) { supporting.append(WorkoutFormat.duration(seconds)) }
        if detail == .full, lead == .distance, let pace = WorkoutPace.perUnit(row, system: unitSystem) {
            supporting.append(WorkoutFormat.pace(pace, system: unitSystem))
        }
        if lead != .energy, let kcal = row.energyKcal, kcal > 0 { supporting.append(WorkoutFormat.energy(kcal)) }
        if detail == .full, let hr = row.avgHr, hr > 0 { supporting.append(String(localized: "\(hr) bpm")) }

        let lines: [[String]]
        switch detail {
        case .compact:
            // One line: when, and the one fact that says most.
            lines = [first + supporting.prefix(1)]
        case .full:
            // Two lines: when it was and where it came from, then what it came to.
            if includesSource { first.append(WorkoutFormat.sourceName(row.source)) }
            lines = supporting.isEmpty ? [first] : [first, supporting]
        }

        return WorkoutRowPresentation(
            title: WorkoutSource.displaySport(row.sport), symbol: sportSymbol(row.sport),
            primary: primary, lines: lines.map { $0.map(WorkoutFormat.unbreakable) },
            strain: WorkoutStrainBadge.make(for: row), source: WorkoutSource.classify(row.source))
    }
}

// MARK: Formatting

/// Display strings for workout numbers. Dates and durations go through `FormatStyle`, which localises them and
/// keeps its own caches; the clock goes through `AppClock`, which honours the app's 12/24-hour setting.
enum WorkoutFormat {
    enum DayKind: Equatable { case today, yesterday, other }

    static func dayKind(of date: Date, now: Date, calendar: Calendar) -> DayKind {
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0: return .today
        case 1: return .yesterday
        default: return .other
        }
    }

    /// "Today", "Yesterday", else "Tue, Oct 6". The two named days come from the system's relative date formatter,
    /// so they are the words the person's language uses; that formatter reads the real clock, which is the only
    /// clock the app has.
    static func day(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch dayKind(of: date, now: now, calendar: calendar) {
        case .today: return relativeDayFormatter.string(from: Date())
        case .yesterday:
            let yesterday = calendar.date(byAdding: .day, value: -1, to: Date()) ?? Date().addingTimeInterval(-86_400)
            return relativeDayFormatter.string(from: yesterday)
        case .other: return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
    }

    /// "Fri, Oct 9": the date a screen's header names.
    static func headerDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    /// "Oct 4 – 10": the span of a week.
    static func weekRange(_ interval: DateInterval) -> String {
        let last = interval.end.addingTimeInterval(-1)
        return (interval.start..<last).formatted(.interval.month(.abbreviated).day())
    }

    /// "3h 12m", "34m". A session under a minute reads as one minute, never "0m".
    static func duration(_ seconds: Double) -> String {
        let rounded = max(60, (seconds / 60).rounded() * 60)
        return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
    }

    /// "3 hours, 12 minutes": the spoken form of a duration.
    static func spokenDuration(_ seconds: Double) -> String {
        let rounded = max(60, (seconds / 60).rounded() * 60)
        return Duration.seconds(rounded).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    /// "5:49 /km": a pace and the distance unit it is per.
    static func pace(_ perUnit: String, system: UnitSystem) -> String {
        let unit = system == .imperial ? String(localized: "/mi") : String(localized: "/km")
        return "\(perUnit) \(unit)"
    }

    /// The text with every space made non-breaking, so a fact ("338 kcal", "7:10 AM") wraps between facts and never
    /// inside one.
    static func unbreakable(_ text: String) -> String {
        text.replacingOccurrences(of: " ", with: "\u{00A0}")
    }

    static func energy(_ kcal: Double) -> String {
        String(localized: "\(grouped(kcal)) kcal")
    }

    static func grouped(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    /// Where a workout came from, as a short name.
    static func sourceName(_ source: String) -> String {
        switch WorkoutSource.classify(source) {
        case .whoop: return String(localized: "WHOOP")
        case .apple: return String(localized: "Apple Health")
        case .detected: return String(localized: "Detected")
        case .manual: return String(localized: "Manual")
        case .lifting: return String(localized: "Lifting import")
        case .activityFile: return String(localized: "Activity file")
        }
    }

    /// "Today" / "Yesterday" in the person's language. Created once; formatters are expensive to build.
    private static let relativeDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: Row trace

enum WorkoutTrace {
    /// How many points a row's heart-rate trace is drawn with: about one per two points of its width.
    static let rowPoints = 26

    /// `values` reduced to at most `points` by averaging equal runs of them: a trace that small shows the shape of the
    /// effort (the climb, the plateau, the easing off), not every set and every rest of it.
    static func downsampled(_ values: [Double], to points: Int) -> [Double] {
        guard points > 0, values.count > points else { return values }
        return (0..<points).map { index in
            let lower = index * values.count / points
            let upper = max(lower + 1, (index + 1) * values.count / points)
            let run = values[lower..<upper]
            return run.reduce(0, +) / Double(run.count)
        }
    }
}

// MARK: Last lift

/// The most recent lifting session, as the hub's Lift section mentions it.
struct WorkoutLastLift: Equatable {
    /// The routine's name as it was when the session ran, or nil for a freehand session.
    let title: String?
    let start: Date
    let durationSeconds: Double?
    /// Sets that count: warm-ups are recorded but never counted.
    let workingSets: Int

    static func make(session: LiftSessionRow, sets: [LiftSetRow]) -> WorkoutLastLift {
        let end = session.endTs ?? session.startTs
        let name = session.programName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkoutLastLift(
            title: (name?.isEmpty ?? true) ? nil : name,
            start: Date(timeIntervalSince1970: TimeInterval(session.startTs)),
            durationSeconds: end > session.startTs ? Double(end - session.startTs) : nil,
            workingSets: sets.filter { !$0.isWarmup }.count)
    }
}
