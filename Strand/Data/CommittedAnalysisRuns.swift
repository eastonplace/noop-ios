import Foundation

/// Immutable clock context for an exact historical analysis run.
///
/// Receipt admission records the local Gregorian time zone that turned raw timestamps into civil days. The
/// engine must use that same context when translating those days back into relative offsets. Otherwise a
/// timezone change or a midnight race could silently score a neighboring day.
struct CommittedAnalysisExecutionContext: Codable, Equatable, Sendable {
    let reference: Date
    let timeZoneIdentifier: String

    init(reference: Date, timeZoneIdentifier: String) throws {
        guard reference.timeIntervalSinceReferenceDate.isFinite,
              !timeZoneIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              TimeZone(identifier: timeZoneIdentifier) != nil else {
            throw CommittedAnalysisRunError.invalidExecutionContext
        }
        self.reference = reference
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    func gregorianCalendar() throws -> Calendar {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw CommittedAnalysisRunError.invalidExecutionContext
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

enum CommittedAnalysisRunError: Error, Equatable, Sendable {
    case nonGregorianCalendar
    case unrepresentableCivilDay
    case futureCivilDay
    case tooFarInPast
    case invalidExecutionContext
}
