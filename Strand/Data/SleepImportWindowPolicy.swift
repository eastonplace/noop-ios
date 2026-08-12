import Foundation
import WhoopProtocol

/// The single production ingress rule for imported sleep-session windows.
///
/// The low-level cache remains capable of retaining legacy/provider rows for repair and diagnostics, but
/// every app importer must pass this boundary before creating a new `CachedSleepSession`. That keeps the
/// user-visible and scoring contract consistent: a session is at least 30 minutes and no longer than 16
/// hours, and its timestamps are exactly representable by the Double-backed analytics pipeline.
enum SleepImportWindowPolicy {
    private static let exactDoubleUnixTimestampLimit = 9_007_199_254_740_991

    static func accepts(start: Int, end: Int) -> Bool {
        guard start >= -exactDoubleUnixTimestampLimit,
              start <= exactDoubleUnixTimestampLimit,
              end >= -exactDoubleUnixTimestampLimit,
              end <= exactDoubleUnixTimestampLimit
        else { return false }
        return SleepSessionWindow.isValid(start: start, end: end)
    }

    static func acceptedUnixSeconds(start: Date, end: Date) -> (start: Int, end: Int)? {
        let startSeconds = start.timeIntervalSince1970
        let endSeconds = end.timeIntervalSince1970
        guard startSeconds.isFinite,
              endSeconds.isFinite,
              startSeconds >= -Double(exactDoubleUnixTimestampLimit),
              startSeconds <= Double(exactDoubleUnixTimestampLimit),
              endSeconds >= -Double(exactDoubleUnixTimestampLimit),
              endSeconds <= Double(exactDoubleUnixTimestampLimit)
        else { return nil }
        let startTs = Int(startSeconds)
        let endTs = Int(endSeconds)
        return accepts(start: startTs, end: endTs) ? (startTs, endTs) : nil
    }
}
