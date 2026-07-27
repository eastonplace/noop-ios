import Foundation

/// Bounds shared by every persisted sleep-session writer and every scoring reader. A sleep session is
/// meaningful only when it is at least 30 minutes but no longer than 16 hours; the upper cap prevents a
/// malformed clock/edit from becoming a "main night" and poisoning recovery or learned sleep timing.
public enum SleepSessionWindow {
    public static let minimumDurationSeconds = 30 * 60
    public static let maximumDurationSeconds = 16 * 60 * 60

    /// Strict, user-visible sleep bounds. Use for edits, manual sessions, recovery writes, and analytics.
    public static func isValid(start: Int, end: Int) -> Bool {
        guard let duration = duration(start: start, end: end) else { return false }
        return duration >= minimumDurationSeconds && duration <= maximumDurationSeconds
    }

    /// Inbound provider records may represent a short partial/nap capture. Keep those rows available for
    /// diagnostics, but never persist a zero/overflowing or overlong window that could corrupt history.
    public static func hasPlausibleBounds(start: Int, end: Int) -> Bool {
        guard let duration = duration(start: start, end: end) else { return false }
        return duration <= maximumDurationSeconds
    }

    private static func duration(start: Int, end: Int) -> Int? {
        let (value, overflow) = end.subtractingReportingOverflow(start)
        return !overflow && value > 0 ? value : nil
    }
}
