import Foundation

public enum CivilDayError: Error, Equatable, Sendable {
    case nonGregorianCalendar
    case invalidDay(String)
    case unrepresentableDate
    case invalidCount
    case invalidRolloverHour
    case tooManyDays
}

/// A real Gregorian calendar day. It intentionally stores components rather than a `Date`, so a day is
/// never silently reinterpreted through a different time zone.
public struct CivilDay: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard year >= 1, month >= 1, day >= 1,
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            throw CivilDayError.invalidDay(String(format: "%04d-%02d-%02d", year, month, day))
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else {
            throw CivilDayError.invalidDay(String(format: "%04d-%02d-%02d", year, month, day))
        }
        self.year = year
        self.month = month
        self.day = day
    }

    public init(key: String) throws {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            throw CivilDayError.invalidDay(key)
        }
        try self.init(year: year, month: month, day: day)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let year = try container.decode(Int.self, forKey: .year)
        let month = try container.decode(Int.self, forKey: .month)
        let day = try container.decode(Int.self, forKey: .day)
        do {
            try self.init(year: year, month: month, day: day)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .day,
                in: container,
                debugDescription: "CivilDay must contain a real Gregorian date."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case year
        case month
        case day
    }

    public var key: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public var description: String { key }

    public static func < (lhs: CivilDay, rhs: CivilDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public func date(in calendar: Calendar) throws -> Date {
        guard calendar.identifier == .gregorian else { throw CivilDayError.nonGregorianCalendar }
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            throw CivilDayError.unrepresentableDate
        }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard components.year == year, components.month == month, components.day == day else {
            throw CivilDayError.unrepresentableDate
        }
        return date
    }
}

public struct CivilDayInterval: Equatable, Sendable {
    public let day: CivilDay
    public let start: Date
    public let end: Date

    public init(day: CivilDay, start: Date, end: Date) {
        self.day = day
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// All day arithmetic in the Phase 3/4 path must pass through this type. It never steps by 86,400 seconds.
public struct HealthCalendar: Sendable {
    public let timeZoneIdentifier: String
    public let logicalDayRolloverHour: Int

    public init(timeZoneIdentifier: String, logicalDayRolloverHour: Int = 4) throws {
        guard TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw CivilDayError.unrepresentableDate
        }
        guard (0..<24).contains(logicalDayRolloverHour) else {
            throw CivilDayError.invalidRolloverHour
        }
        self.timeZoneIdentifier = timeZoneIdentifier
        self.logicalDayRolloverHour = logicalDayRolloverHour
    }

    public var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX")
        value.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return value
    }

    public func civilDay(containing date: Date) throws -> CivilDay {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            throw CivilDayError.unrepresentableDate
        }
        return try CivilDay(year: year, month: month, day: day)
    }

    /// NOOP's physiological day rolls at local 04:00 by default. Shifting calendar components, rather than
    /// subtracting a fixed day duration, keeps the result correct through daylight-saving transitions.
    public func physiologicalDay(containing date: Date) throws -> CivilDay {
        // Compare local clock components instead of subtracting elapsed hours. On spring-forward day,
        // 04:00 minus four elapsed hours is 23:00 on the prior civil day; on fall-back day, 03:59 minus
        // four elapsed hours can remain on the same civil day. Both results violate the fixed 04:00 local
        // product boundary. Civil-day arithmetic keeps the rollover stable through both transitions.
        let civil = try civilDay(containing: date)
        guard calendar.component(.hour, from: date) < logicalDayRolloverHour else { return civil }
        return try adding(days: -1, to: civil)
    }

    public func interval(for day: CivilDay) throws -> CivilDayInterval {
        let start = try day.date(in: calendar)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw CivilDayError.unrepresentableDate
        }
        return CivilDayInterval(day: day, start: start, end: end)
    }

    public func adding(days: Int, to day: CivilDay) throws -> CivilDay {
        let start = try day.date(in: calendar)
        guard let next = calendar.date(byAdding: .day, value: days, to: start) else {
            throw CivilDayError.unrepresentableDate
        }
        return try civilDay(containing: next)
    }

    public func days(from first: CivilDay, through last: CivilDay, limit: Int = 4_000) throws -> [CivilDay] {
        guard limit > 0 else { throw CivilDayError.invalidCount }
        let firstDate = try first.date(in: calendar)
        let lastDate = try last.date(in: calendar)
        guard firstDate <= lastDate else { return [] }
        guard let distance = calendar.dateComponents([.day], from: firstDate, to: lastDate).day,
              distance >= 0 else {
            throw CivilDayError.unrepresentableDate
        }
        guard distance < limit else { throw CivilDayError.tooManyDays }
        return try (0...distance).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDate) else {
                throw CivilDayError.unrepresentableDate
            }
            return try civilDay(containing: date)
        }
    }

    public func recentDays(count: Int, endingAt date: Date) throws -> [CivilDay] {
        guard count > 0 else { throw CivilDayError.invalidCount }
        let end = try civilDay(containing: date)
        let start = try adding(days: -(count - 1), to: end)
        return try days(from: start, through: end, limit: count + 1)
    }
}
