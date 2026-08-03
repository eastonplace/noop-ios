import Foundation

/// A calendar day identified by its year/month/day components in the calendar supplied to the planner.
///
/// The value does not retain a `Date` or a time zone. A caller must use the same `Calendar` that assigned
/// the day when it turns the value back into a date. This keeps travel-time-zone changes explicit instead of
/// freezing a launch-time formatter into the analysis contract.
struct AnalysisCivilDay: Codable, Comparable, CustomStringConvertible, Equatable, Hashable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(date: Date, calendar: Calendar) {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    var dateComponents: DateComponents {
        DateComponents(year: year, month: month, day: day)
    }

    func date(in calendar: Calendar) -> Date? {
        calendar.date(from: dateComponents)
    }

    var key: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var description: String { key }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }
}

enum CommittedAnalysisWindowError: Error, Equatable, Sendable {
    case invertedTimestampRange
    case invalidLogicalDayRolloverHour
    case unrepresentableCivilDay
}

/// Pure input and expansion rules for one committed-data analysis request.
///
/// The timestamp range is expanded across local civil midnights, not elapsed 24-hour periods. The endpoint
/// physiological days are also included because the app's logical day rolls at local 04:00. Explicit touch
/// and timestamp-heal days are retained verbatim so a nap, a main night, or a cleanup can declare its own
/// daily projections without this seam guessing at sleep semantics.
struct CommittedAnalysisWindow: Codable, Equatable, Sendable {
    static let defaultLogicalDayRolloverHour = 4

    let minimumTimestamp: Date?
    let maximumTimestamp: Date?
    let touchedCivilDays: Set<AnalysisCivilDay>
    let timestampHealDays: Set<AnalysisCivilDay>

    init(
        minimumTimestamp: Date? = nil,
        maximumTimestamp: Date? = nil,
        touchedCivilDays: Set<AnalysisCivilDay> = [],
        timestampHealDays: Set<AnalysisCivilDay> = []
    ) {
        self.minimumTimestamp = minimumTimestamp
        self.maximumTimestamp = maximumTimestamp
        self.touchedCivilDays = touchedCivilDays
        self.timestampHealDays = timestampHealDays
    }

    /// Return every daily projection that a later coordinator must consider.
    ///
    /// `Calendar` owns both local-midnight arithmetic and the 04:00 logical boundary. In particular, a
    /// spring-forward day and a fall-back day still advance by one civil day even though their elapsed
    /// durations are 23 and 25 hours.
    func affectedDays(
        using inputCalendar: Calendar,
        logicalDayRolloverHour: Int = Self.defaultLogicalDayRolloverHour
    ) throws -> Set<AnalysisCivilDay> {
        guard (0..<24).contains(logicalDayRolloverHour) else {
            throw CommittedAnalysisWindowError.invalidLogicalDayRolloverHour
        }

        var affected = touchedCivilDays
        affected.formUnion(timestampHealDays)

        guard minimumTimestamp != nil || maximumTimestamp != nil else {
            return affected
        }

        let lowerTimestamp = minimumTimestamp ?? maximumTimestamp!
        let upperTimestamp = maximumTimestamp ?? minimumTimestamp!
        guard lowerTimestamp <= upperTimestamp else {
            throw CommittedAnalysisWindowError.invertedTimestampRange
        }
        guard lowerTimestamp.timeIntervalSinceReferenceDate.isFinite,
              upperTimestamp.timeIntervalSinceReferenceDate.isFinite else {
            throw CommittedAnalysisWindowError.unrepresentableCivilDay
        }

        let calendar = inputCalendar
        let minimumCivilStart = calendar.startOfDay(for: lowerTimestamp)
        let maximumCivilStart = calendar.startOfDay(for: upperTimestamp)
        let civilDayDistance = calendar.dateComponents(
            [.day],
            from: minimumCivilStart,
            to: maximumCivilStart
        ).day

        guard let civilDayDistance, civilDayDistance >= 0 else {
            throw CommittedAnalysisWindowError.unrepresentableCivilDay
        }

        // Enumerate local calendar days. Never replace this with 86,400-second stepping: DST days and
        // historical timezone rules do not all have that elapsed duration.
        for offset in 0...civilDayDistance {
            guard let civilStart = calendar.date(
                byAdding: .day,
                value: offset,
                to: minimumCivilStart
            ), let day = AnalysisCivilDay(date: civilStart, calendar: calendar) else {
                throw CommittedAnalysisWindowError.unrepresentableCivilDay
            }
            affected.insert(day)
        }

        // Include both endpoint physiological days. This covers a range that is entirely before 04:00,
        // where its current logical day is the previous civil day, and a range that crosses midnight.
        for timestamp in [lowerTimestamp, upperTimestamp] {
            let civilStart = calendar.startOfDay(for: timestamp)
            let physiologicalStart: Date
            if calendar.component(.hour, from: timestamp) < logicalDayRolloverHour {
                guard let previousCivilStart = calendar.date(
                    byAdding: .day,
                    value: -1,
                    to: civilStart
                ) else {
                    throw CommittedAnalysisWindowError.unrepresentableCivilDay
                }
                physiologicalStart = previousCivilStart
            } else {
                physiologicalStart = civilStart
            }

            guard let physiologicalDay = AnalysisCivilDay(
                date: physiologicalStart,
                calendar: calendar
            ) else {
                throw CommittedAnalysisWindowError.unrepresentableCivilDay
            }
            affected.insert(physiologicalDay)
        }

        return affected
    }

    static func affectedDays(
        minimumTimestamp: Date? = nil,
        maximumTimestamp: Date? = nil,
        touchedCivilDays: Set<AnalysisCivilDay> = [],
        timestampHealDays: Set<AnalysisCivilDay> = [],
        using calendar: Calendar,
        logicalDayRolloverHour: Int = Self.defaultLogicalDayRolloverHour
    ) throws -> Set<AnalysisCivilDay> {
        try Self(
            minimumTimestamp: minimumTimestamp,
            maximumTimestamp: maximumTimestamp,
            touchedCivilDays: touchedCivilDays,
            timestampHealDays: timestampHealDays
        ).affectedDays(using: calendar, logicalDayRolloverHour: logicalDayRolloverHour)
    }
}
