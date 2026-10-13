import Foundation

/// BLE-11 / CC-6: when the live Collector may start a flush.
///
/// `batchStartedAt` used to move only after an insert succeeded and nothing tracked whether a flush was
/// already running, so once the 30 s mark passed every arriving frame spawned another flush, and a failing
/// store retried on every frame while the re-buffered batch grew without limit. Now at most one cadence
/// flush runs at a time, a request made while it runs is coalesced into a single follow-up, and failures
/// back off 5, 10, 30, then 60 s.
public struct FlushScheduler: Equatable, Sendable {
    public static let failureBackoffSeconds: [TimeInterval] = [5, 10, 30, 60]

    public private(set) var inFlight = false
    public private(set) var needsFollowUp = false
    public private(set) var consecutiveFailures = 0
    public private(set) var retryNotBefore: TimeInterval?

    public init() {}

    /// A cadence threshold was hit at `now`. Returns true when the caller must start a flush; false when
    /// one is already running (it will loop once more when it finishes) or a failure backoff is pending.
    public mutating func request(now: TimeInterval) -> Bool {
        if inFlight {
            needsFollowUp = true
            return false
        }
        if let retryNotBefore, now < retryNotBefore { return false }
        inFlight = true
        return true
    }

    /// The running flush finished. Returns true when it must run once more (frames arrived meanwhile and
    /// the insert succeeded); false when the flush is done. A failure never loops immediately: the next
    /// attempt waits for the backoff.
    public mutating func finish(success: Bool, now: TimeInterval) -> Bool {
        if success {
            consecutiveFailures = 0
            retryNotBefore = nil
        } else {
            let ladder = Self.failureBackoffSeconds
            retryNotBefore = now + ladder[min(consecutiveFailures, ladder.count - 1)]
            consecutiveFailures += 1
        }
        let again = success && needsFollowUp
        needsFollowUp = false
        inFlight = again
        return again
    }

    /// How many of the oldest entries to drop so a buffer of `count` stays within `cap`.
    public static func overflow(count: Int, cap: Int) -> Int {
        max(0, count - max(0, cap))
    }
}
