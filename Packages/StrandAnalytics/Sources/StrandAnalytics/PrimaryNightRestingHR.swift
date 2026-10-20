import Foundation

/// Daily resting HR uses the longest sleep session's existing lowest-sustained 5-min floor.
/// Adapted from upstream #2522; the whole-session mean remains in the separate shadow-only
/// `PrimarySessionRestingHR` analyzer.
public enum PrimaryNightRestingHR {
    /// Shared by fresh analysis and repair from persisted sessions. Callers supply effective edited
    /// bounds when present and the already-gated per-session floor. Select the session before reading
    /// its value: a missing primary floor stays nil, even if a shorter nap has valid HR. The first
    /// session wins a duration tie; malformed nonpositive or overflowing spans are ignored.
    public static func floor(
        _ sessions: [(start: Int, end: Int, restingHR: Int?)]
    ) -> Int? {
        var longestDuration = 0
        var restingHR: Int?
        for session in sessions {
            let (duration, overflow) = session.end.subtractingReportingOverflow(session.start)
            guard !overflow, duration > longestDuration else { continue }
            longestDuration = duration
            restingHR = session.restingHR
        }
        return restingHR
    }
}
