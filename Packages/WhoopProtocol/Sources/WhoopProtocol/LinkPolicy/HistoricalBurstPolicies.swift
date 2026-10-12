import Foundation

/// Battery/radio backoff signal for any offload exit that produced no fresh durable receipt work.
/// Replays, metadata-only completions, and zero-progress timeouts all advance the same bounded streak;
/// one fresh inserted receipt clears it immediately.
public struct HistoricalEmptyBackoffTracker: Sendable {
    public init() {}

    public private(set) var consecutiveEmpty = 0

    public mutating func record(freshProgress: Bool) {
        if freshProgress {
            consecutiveEmpty = 0
        } else {
            consecutiveEmpty = min(consecutiveEmpty + 1, 2)
        }
    }

    public mutating func recordDisconnect(inFlight: Bool, freshProgress: Bool) {
        guard inFlight else { return }
        record(freshProgress: freshProgress)
    }
}

/// One monotonic deadline for the complete connected radio burst. Each session receives only the time
/// remaining before that deadline, so repeated watchdog re-arms cannot reset either selected ceiling.
public struct HistoricalRadioDeadline: Equatable, Sendable {
    public let startedAt: TimeInterval
    public let budgetSeconds: TimeInterval
    public let uptimeDeadline: TimeInterval

    public init(startedAt: TimeInterval, budgetSeconds: TimeInterval) {
        self.startedAt = startedAt
        self.budgetSeconds = max(0, budgetSeconds)
        uptimeDeadline = startedAt + max(0, budgetSeconds)
    }

    public func expandingBudget(to requestedBudgetSeconds: TimeInterval) -> Self {
        let expanded = max(budgetSeconds, requestedBudgetSeconds)
        guard expanded > budgetSeconds else { return self }
        return Self(startedAt: startedAt, budgetSeconds: expanded)
    }

    public func remaining(at uptime: TimeInterval) -> TimeInterval {
        max(0, uptimeDeadline - uptime)
    }

    public func sessionTimeout(at uptime: TimeInterval, idleTimeout: TimeInterval) -> TimeInterval {
        min(max(0, idleTimeout), remaining(at: uptime))
    }
}

/// Every radio session consumes the hard pass budget. Productivity is tracked separately so duplicate-
/// only fresh receipts keep a burst productive while replay/console sessions remain zero progress.
public struct HistoricalBurstPassTracker: Equatable, Sendable {
    public init() {}

    public private(set) var totalPasses = 0
    public private(set) var productivePasses = 0

    public mutating func startPass() { totalPasses += 1 }
    public mutating func finishPass(freshSourceProgress: Bool) {
        if freshSourceProgress { productivePasses += 1 }
    }
    public mutating func reset() {
        totalPasses = 0
        productivePasses = 0
    }
}

/// Decides whether a backfill session that ended on the 60s IDLE cap (not a true HISTORY_COMPLETE)
/// should immediately re-kick another offload instead of tearing down to wait the 15-min periodic floor
/// (#364). The real bug: the strap offloads OLDEST-first at ~60s/session, so on a deep backlog (e.g. the
/// app was off for days) each connection drains only ~one session's worth of the OLDEST data, then waits
/// 15 minutes — so "last night" can take many connections to reach even while the strap stays connected
/// the whole time. Auto-continuing closes that gap: keep re-offloading back-to-back while the strap is
/// still connected, there's demonstrably more backlog, and we're still making progress.
///
/// Pure + value-typed so the decision is unit-testable without a CoreBluetooth seam (Backfill
/// ContinuationTests). Mirrored byte-for-behaviour on Android (WhoopBleClient.shouldAutoContinue).
///
/// The guards (ALL must hold):
///  1. `stillConnected` — connected + bonded; a dropped link goes through the normal reconnect path.
///  2. backlog remains — the strap's newest banked record (`strapNewestTs`, from GET_DATA_RANGE) is
///     still AHEAD of our receipt-backed data frontier (`ourFrontierTs` = max normalized or mapped-raw
///     timestamp) by more than
///     `behindGapSeconds`. Comparing the frontier (not the trim u32, which climbs on empty ENDs even
///     when stuck) is what separates "more to fetch" from "caught up / off-wrist" — same idiom as
///     StuckStrapDetector. nil on either side ⇒ unknown ⇒ don't auto-continue (let the floor handle it).
///  3. `lastTrimAdvanced` — the just-ended session actually moved the strap's trim cursor. If the cursor
///     is frozen (strap handing back console-only / refusing to trim), re-kicking would spin forever
///     burning battery; stop and let the periodic floor retry slowly.
///  4. This pass inserted fresh receipt-backed records; a replay or empty pass contributes zero.
///  5. trim + fingerprint + durable frontier is not a repeat of the previous pass.
///  6. The six-pass and three-minute continuous-radio ceilings have not been reached.
///
/// #1012: a FUTURE-dated `strapNewestTs` (more than `futureSkewSeconds` past the wall clock, #928) not
/// only nulls guard 2a — it also STOPS guard 2b. A future-clock strap banks future-dated records, so the
/// rows it hands over are future-timestamped too and "real rows persisted" is no evidence of genuine
/// backlog; 2b would chase the future-dated range through the whole cap (six back-to-back passes, each to
/// its idle timeout — the reported ~15-min sync). The stale/PAST-epoch case 2b actually exists for (#451)
/// reads BEHIND the frontier, never future-dated, so it is untouched.
public struct BackfillContinuation: Sendable {
    /// Conservative hard cap on consecutive auto-continues per connection (resets on disconnect). Raising
    /// this above six remains a physical-device energy/radio qualification gate.
    public static let defaultMaxTotalPasses = 6
    /// Hard monotonic radio budget for one auto-continued burst. It is independent of wall-clock changes
    /// and bounds a productive-but-pathological strap even before the pass cap is reached.
    public static let defaultMaxContinuousRadioSeconds: TimeInterval = 3 * 60
    /// Do not send another SEND_HISTORICAL_DATA command unless the burst can still provide at least half
    /// of one normal 60-second offload window. Shorter fragments spend radio time on command/START setup
    /// but are unlikely to return a useful chunk before the hard burst deadline.
    public static let defaultMinimumUsefulRemainingRadioSeconds: TimeInterval = 30
    /// How far ahead the strap must be (seconds) before "more backlog remains" is real, not clock noise.
    /// Matches StuckStrapDetector.behindGapSeconds (5 min) so the two agree on "behind".
    public static let defaultBehindGapSeconds = 300
    /// #928: how far past the WALL CLOCK the strap-reported "newest" may sit before it is implausible.
    /// A strap clock set in the FUTURE (wandering RTC relatch) makes dataRangeNewestUnix read ahead of
    /// every real frontier, so guard 2a would report backlog forever and burn the whole cap in EMPTY
    /// offloads on every connect. 48 h absorbs genuine timezone confusion and mild drift; nothing
    /// legitimate banks records two days ahead of the phone's clock.
    public static let defaultFutureSkewSeconds = 48 * 3600

    /// #1012: is the strap-reported "newest banked record" FUTURE-dated beyond the skew allowance — more
    /// than `futureSkewSeconds` past the wall clock? The strap's clock is then almost certainly set in the
    /// future (#928), so its range answer AND its freshly-persisted rows are untrustworthy as backlog
    /// evidence. Pure, and shared between `shouldAutoContinue` (it gates 2a AND 2b) and the call site's
    /// honest stop log so the two can never disagree on the reason. nil ⇒ false: an unanswered range is
    /// UNKNOWN, not future-dated, and 2b's stale-epoch rescue (#451) still applies to it.
    public static func isFutureDatedNewest(_ strapNewestTs: Int?, wallNowUnix: Int,
                                    futureSkewSeconds: Int = defaultFutureSkewSeconds) -> Bool {
        guard let n = strapNewestTs else { return false }
        return n > wallNowUnix + futureSkewSeconds
    }

    public static func hasMinimumUsefulRemainingRadioBudget(
        _ remainingSeconds: TimeInterval,
        minimumUsefulSeconds: TimeInterval = defaultMinimumUsefulRemainingRadioSeconds
    ) -> Bool {
        remainingSeconds >= minimumUsefulSeconds
    }

    /// `stillConnected`: link up + command channel usable. `strapNewestTs`: newest record the strap holds
    /// (GET_DATA_RANGE). `ourFrontierTs`: newest record WE'VE persisted across normalized and mapped-raw
    /// receipts. `wallNowUnix`: the
    /// REAL wall clock at decision time (#928 future-clock plausibility check; passed in so the predicate
    /// stays pure). `lastTrimAdvanced`: the just-ended session moved the trim cursor. `consecutiveCount`:
    /// auto-continues already done this connection. Returns true to immediately re-kick beginBackfill;
    /// false to tear down to the floor.
    public static func shouldAutoContinue(stillConnected: Bool,
                                   strapNewestTs: Int?,
                                   ourFrontierTs: Int?,
                                   wallNowUnix: Int,
                                   rowsPersistedThisSession: Int = 0,
                                   lastTrimAdvanced: Bool,
                                   passSignatureRepeated: Bool = false,
                                   continuousRadioSeconds: TimeInterval = 0,
                                   totalPasses: Int,
                                   maxTotalPasses: Int = defaultMaxTotalPasses,
                                   maxContinuousRadioSeconds: TimeInterval = defaultMaxContinuousRadioSeconds,
                                   minimumUsefulRemainingRadioSeconds: TimeInterval =
                                       defaultMinimumUsefulRemainingRadioSeconds,
                                   behindGapSeconds: Int = defaultBehindGapSeconds,
                                   futureSkewSeconds: Int = defaultFutureSkewSeconds) -> Bool {
        guard stillConnected else { return false }                 // 1
        guard totalPasses < maxTotalPasses else { return false }   // 4 (cap)
        guard continuousRadioSeconds < maxContinuousRadioSeconds else { return false }
        guard hasMinimumUsefulRemainingRadioBudget(
            maxContinuousRadioSeconds - continuousRadioSeconds,
            minimumUsefulSeconds: minimumUsefulRemainingRadioSeconds
        ) else { return false }
        guard !passSignatureRepeated else { return false }
        guard lastTrimAdvanced else { return false }               // 3 (don't spin on a frozen cursor)
        // A durable frontier from an earlier pass can remain behind the strap. It does not authorize a
        // new radio pass unless THIS session inserted fresh normalized or mapped-raw records.
        guard rowsPersistedThisSession > 0 else { return false }
        // #928: a strap clock set in the FUTURE makes "newest" read ahead of ANY real frontier, so 2a
        // would report backlog forever and drive up to the full cap in EMPTY offloads on every connect.
        // A newest more than futureSkewSeconds past the wall clock is implausible: exclude it from 2a.
        let futureDated = isFutureDatedNewest(strapNewestTs, wallNowUnix: wallNowUnix,
                                              futureSkewSeconds: futureSkewSeconds)
        let plausibleNewest = futureDated ? nil : strapNewestTs
        // 2a: the strap reports newer data than we hold — reliable WHEN its clock epoch is sane.
        if let newest = plausibleNewest, let frontier = ourFrontierTs, (newest - frontier) > behindGapSeconds {
            return true
        }
        // #1012: a future-dated newest also gates 2b, not just 2a. A strap whose clock is set ahead
        // (#928) BANKED future-dated records, so the rows this session persisted are themselves
        // future-timestamped — "real rows" is NOT evidence of genuine backlog there, and 2b used to
        // chase the future-dated range through the whole cap (six back-to-back passes, each run to its
        // idle timeout: the reported ~15-min sync). Stop after this single pass; the periodic floor
        // keeps draining across connects, restoring the pre-#928 single-pass behaviour. The stale/
        // PAST-epoch case 2b exists for (#451) reads BEHIND the frontier, never future-dated, so it
        // falls through untouched below.
        if futureDated { return false }
        // 2b (#451): GET_DATA_RANGE's "newest" can read a STALE / wrong-epoch value — a strap that was
        // fully discharged (or carries a previous owner's history) banks records across multiple clock
        // epochs, and the data-range "newest" can latch an OLD one (e.g. 2024 when the real newest is 2026).
        // That false "we're already past it" would stop the drain after ONE session and make the user
        // tap the strap to re-trigger (exactly #364 / #451). But guard #3 already proved the trim advanced,
        // so if this session also PERSISTED REAL SENSOR ROWS the strap is demonstrably still handing over
        // real backlog — keep going. Empty / console-only ENDs persist 0 rows, so a genuinely stuck or
        // caught-up strap still won't spin, and the consecutive cap bounds it either way.
        return rowsPersistedThisSession > 0
    }
}

/// Coalesces the diagnostic history-chunk counter before it touches `LiveState`. The exact ACK count stays
/// local for liveness decisions, while SwiftUI sees at most four whole-screen invalidations per second.
public struct HistoricalProgressThrottle: Equatable, Sendable {
    public private(set) var acknowledged = 0
    private var lastPublished = 0
    private var lastPublishedAt: TimeInterval?
    public let minimumPublishInterval: TimeInterval

    public init(minimumPublishInterval: TimeInterval = 0.25) {
        self.minimumPublishInterval = minimumPublishInterval
    }

    public mutating func begin() {
        acknowledged = 0
        lastPublished = 0
        lastPublishedAt = nil
    }

    public mutating func acknowledge(now: TimeInterval) -> Int? {
        acknowledged += 1
        return publishIfDue(now: now)
    }

    public mutating func flush(now: TimeInterval) -> Int? {
        guard acknowledged != lastPublished else { return nil }
        lastPublished = acknowledged
        lastPublishedAt = now
        return acknowledged
    }

    private mutating func publishIfDue(now: TimeInterval) -> Int? {
        guard lastPublishedAt.map({ now - $0 >= minimumPublishInterval }) ?? true else { return nil }
        lastPublished = acknowledged
        lastPublishedAt = now
        return acknowledged
    }
}
