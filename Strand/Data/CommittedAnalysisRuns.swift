import Foundation

/// One contiguous local-day window the existing analysis engine can score without widening its scope.
///
/// The historical receipt planner may identify disjoint affected days.  The engine accepts a contiguous
/// relative window, so this value preserves the exact set by splitting it into the smallest possible runs.
struct CommittedAnalysisRun: Equatable, Sendable {
    let startOffset: Int
    let maxDays: Int
    let days: Set<AnalysisCivilDay>
}

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

/// Converts an explicit affected-day set into the engine's existing relative-day request format.
///
/// This is deliberately calendar arithmetic, not 86,400-second arithmetic.  A run therefore remains exact
/// across daylight-saving transitions.  A future or unrepresentable day fails closed so the durable receipt
/// stays pending rather than acknowledging a day the engine cannot have scored.
enum CommittedAnalysisRunPlanner {
    static func runs(
        for affectedDays: Set<AnalysisCivilDay>,
        reference: Date,
        calendar: Calendar
    ) throws -> [CommittedAnalysisRun] {
        guard calendar.identifier == .gregorian else {
            throw CommittedAnalysisRunError.nonGregorianCalendar
        }
        guard !affectedDays.isEmpty else {
            return []
        }

        let referenceStart = calendar.startOfDay(for: reference)
        var daysByOffset: [Int: AnalysisCivilDay] = [:]
        for day in affectedDays {
            guard let dayStart = day.date(in: calendar),
                  let offset = calendar.dateComponents(
                    [.day],
                    from: dayStart,
                    to: referenceStart
                  ).day
            else {
                throw CommittedAnalysisRunError.unrepresentableCivilDay
            }
            guard offset >= 0 else {
                throw CommittedAnalysisRunError.futureCivilDay
            }
            guard offset < IntelligenceAnalysisRequest.maximumWindowDays else {
                throw CommittedAnalysisRunError.tooFarInPast
            }
            daysByOffset[offset] = day
        }

        let offsets = daysByOffset.keys.sorted()
        var result: [CommittedAnalysisRun] = []
        var runStart = offsets[0]
        var runEnd = offsets[0]
        var runDays: Set<AnalysisCivilDay> = [daysByOffset[offsets[0]]!]

        for offset in offsets.dropFirst() {
            if offset == runEnd + 1 {
                runEnd = offset
                runDays.insert(daysByOffset[offset]!)
                continue
            }

            result.append(CommittedAnalysisRun(
                startOffset: runStart,
                maxDays: runEnd - runStart + 1,
                days: runDays
            ))
            runStart = offset
            runEnd = offset
            runDays = [daysByOffset[offset]!]
        }

        result.append(CommittedAnalysisRun(
            startOffset: runStart,
            maxDays: runEnd - runStart + 1,
            days: runDays
        ))
        return result
    }
}
