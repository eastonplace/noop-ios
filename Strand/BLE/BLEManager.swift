import Foundation
import CoreBluetooth
import WhoopProtocol
import WhoopStore
import StrandAnalytics
import NoopPhase34Core
// #78/#747 hole-4: the one-shot bond-loop salvage probe listens for the app-foreground notification,
// which lives in UIKit on iOS and AppKit on macOS (see installForegroundSalvageProbe).
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Detects a marginal Bluetooth radio that can't sustain the WHOOP 4 R10/R11 raw realtime stream
/// (#80). On a flaky radio (2016 Mac / OpenCore) the link dies the *instant* NOOP arms that
/// high-bandwidth burst, then the auto-rescan reconnects, re-arms, and dies again — an endless loop.
///
/// The tell is a CONNECTION TIMEOUT that lands shortly after we armed realtime: arm → die → rescan →
/// arm → die. We don't trip on a single drop (links die for benign reasons), but on >= `tripThreshold`
/// CONSECUTIVE arm-then-quick-timeout cycles. Once tripped, the caller skips arming R10/R11 on the next
/// connect and relies on the independent low-bandwidth 0x2A37 standard HR profile, which NOOP already
/// subscribes — live HR survives on a radio that otherwise couldn't, and even if 0x2A37 stays silent the
/// arm/die loop stops. Pure + value-typed so the decision is unit-testable without a CoreBluetooth seam.
struct MarginalRadioDetector {
    /// How many consecutive arm-then-quick-timeout cycles before we fall back to standard-HR-only.
    /// 2 (not 1): one drop is noise; two in a row right after arming is the radio buckling under the burst.
    let tripThreshold: Int
    /// A timeout only counts as "right after arming" if it lands within this window. A drop minutes into a
    /// healthy session is unrelated to the arm burst and must NOT be blamed on it (that would mis-trip a
    /// good radio whose link merely flaps later).
    let quickTimeoutWindow: TimeInterval

    private(set) var consecutiveArmTimeouts = 0
    /// True once we've tripped: the next connect should skip the R10/R11 arm and run standard-HR-only.
    private(set) var tripped = false

    init(tripThreshold: Int = 2, quickTimeoutWindow: TimeInterval = 20) {
        self.tripThreshold = tripThreshold
        self.quickTimeoutWindow = quickTimeoutWindow
    }

    /// A connection ended. `wasArmed` = we had armed R10/R11 this connection; `secondsSinceArm` = how long
    /// after arming the link ended (nil if we never armed); `timedOut` = the drop looks like a connection
    /// timeout (vs. an intentional disconnect, a bond reset, etc.). Returns true if THIS event tripped the
    /// fallback (a freshly-crossed threshold), so the caller can log/surface it exactly once.
    mutating func connectionEnded(wasArmed: Bool, secondsSinceArm: TimeInterval?, timedOut: Bool) -> Bool {
        // Only a timeout that lands within the window after we actually armed the burst is evidence the
        // radio choked on the arm. Anything else (clean session that later flapped, non-timeout error,
        // never armed) breaks the streak — a single healthy spell should clear prior suspicion.
        let armCausedTimeout = wasArmed && timedOut
            && (secondsSinceArm.map { $0 <= quickTimeoutWindow } ?? false)
        guard armCausedTimeout else {
            consecutiveArmTimeouts = 0
            return false
        }
        consecutiveArmTimeouts += 1
        if !tripped && consecutiveArmTimeouts >= tripThreshold {
            tripped = true
            return true        // freshly tripped — caller logs/surfaces once
        }
        return false
    }

    /// Clear all suspicion: a clean session is flowing, or the user explicitly re-requested the full
    /// stream (Live re-open / manual Start HR). Lets a transient radio hiccup recover instead of
    /// permanently pinning the user to standard-HR mode.
    mutating func reset() {
        consecutiveArmTimeouts = 0
        tripped = false
    }
}

/// Detects a WHOOP 4 "bond-loop" (#617): the strap bonds successfully, then the encrypted link drops
/// ~1s later with a CONNECTION TIMEOUT (`CBError.connectionTimeout`), the auto-rescan reconnects, it
/// bonds again, and dies again — an endless bond→timeout cycle on macOS/iOS that never settles and never
/// tells the user why.
///
/// The tell is a TIMEOUT drop that lands shortly after a GENUINE bond: bond → die-soon → rescan → bond →
/// die-soon. A bond that survives well past the window is healthy and breaks the streak — links flap for
/// benign reasons minutes in, and a late drop must NOT be blamed on the bond. We don't trip on a single
/// cycle (one quick drop is noise); we trip on >= `tripThreshold` CONSECUTIVE bond-then-quick-timeout
/// cycles. Once tripped, BLEManager surfaces the EXISTING re-pair guide (`state.reconnectGuide`) so the
/// user gets the forget-and-re-pair steps instead of watching a silent loop drain the battery.
///
/// Pure + value-typed so the decision is unit-testable without a CoreBluetooth seam — same shape as
/// `MarginalRadioDetector`.
struct PostBondTimeoutLoopDetector {
    /// How many consecutive bond-then-quick-timeout cycles before we surface the re-pair guide.
    /// 2 (not 1): one quick post-bond drop is noise; two in a row is the loop, not a fluke.
    let tripThreshold: Int
    /// A timeout only counts as "right after bonding" if it lands within this window of the bond. A drop
    /// well into a healthy session is unrelated to bonding and must NOT count (that would mis-trip a good
    /// link that merely flapped later). Generous vs the radio detector's 20s: the loop's signature is a
    /// near-immediate (~1s) drop, but pre-loop links can limp a few seconds before timing out.
    let quickTimeoutWindow: TimeInterval

    private(set) var consecutiveBondTimeouts = 0
    /// True once we've tripped: BLEManager has surfaced (or should surface) the re-pair guide.
    private(set) var tripped = false

    init(tripThreshold: Int = 2, quickTimeoutWindow: TimeInterval = 8) {
        self.tripThreshold = tripThreshold
        self.quickTimeoutWindow = quickTimeoutWindow
    }

    /// A connection ended. `wasBonded` = the link reached a genuine encrypted bond this connection;
    /// `secondsSinceBond` = how long after bonding the link ended (nil if we never bonded); `timedOut` =
    /// the drop looks like a connection timeout (vs an intentional disconnect, a bond reset, a clean close).
    /// Returns true if THIS event tripped the loop (a freshly-crossed threshold), so the caller can
    /// log/surface the guide exactly once.
    mutating func connectionEnded(wasBonded: Bool, secondsSinceBond: TimeInterval?, timedOut: Bool) -> Bool {
        // Only a timeout that lands within the window after we actually bonded is evidence of the loop.
        // Anything else (never bonded, non-timeout close, a drop long after a healthy bond) breaks the
        // streak — a single healthy spell should clear prior suspicion.
        let bondThenQuickTimeout = wasBonded && timedOut
            && (secondsSinceBond.map { $0 <= quickTimeoutWindow } ?? false)
        guard bondThenQuickTimeout else {
            consecutiveBondTimeouts = 0
            return false
        }
        consecutiveBondTimeouts += 1
        if !tripped && consecutiveBondTimeouts >= tripThreshold {
            tripped = true
            return true        // freshly tripped — caller surfaces the re-pair guide once
        }
        return false
    }

    /// Clear all suspicion: a clean session is flowing, or the user explicitly disconnected. Lets a
    /// transient bond hiccup recover instead of permanently flagging the link as bond-looping.
    mutating func reset() {
        consecutiveBondTimeouts = 0
        tripped = false
    }
}

/// #747 / #750: decides when a strap that keeps REFUSING the encrypted bond ("Encryption/Authentication is
/// insufficient", no genuine bond in between) has refused enough times that hammering it further is
/// pointless. Two responsibilities, both pure so they're unit-testable without a CoreBluetooth seam:
///
///  - #747 PAUSE: after `giveUpThreshold` consecutive refusals the auto-reconnect should STOP re-kicking
///    (it can't bond without the user freeing the strap / re-pairing), so the caller pauses the rescan and
///    surfaces an honest hint instead of looping forever and draining the battery.
///  - #750 EPITAPH: at the same moment, emit ONE summary "epitaph" line recording how the bond attempt
///    died (the streak + an opaque, install-local id), so a shared strap log carries the cause without any
///    PII (no MAC, no serial, just the count and a short opaque token).
///
/// The streak accumulates across the reconnect loop (a disconnect does NOT reset it) and is cleared only by
/// a genuine bond or an explicit user reconnect, exactly like BLEManager's existing `bondRefusalStreak`.
struct BondRefusalGiveUp {
    /// Consecutive bond refusals before we pause auto-reconnect + write the epitaph. 5 (not 2, where the
    /// pairing HINT already shows): the hint asks the user to act; we give them several reconnect cycles to
    /// do it before we stop hammering. A genuinely held/stale strap reaches 5 within a couple of minutes.
    let giveUpThreshold: Int

    private(set) var refusals = 0
    /// True once `giveUpThreshold` is reached: auto-reconnect should pause and the epitaph has been (or
    /// should be) written. Stays true until `reset()` so the pause holds across the loop.
    private(set) var gaveUp = false

    init(giveUpThreshold: Int = 5) { self.giveUpThreshold = giveUpThreshold }

    /// Record one bond refusal. Returns true if THIS refusal freshly crossed the give-up threshold (so the
    /// caller pauses the reconnect + writes the epitaph exactly once).
    mutating func recordRefusal() -> Bool {
        refusals += 1
        if !gaveUp && refusals >= giveUpThreshold {
            gaveUp = true
            return true
        }
        return false
    }

    /// Clear the streak: a genuine bond landed, or the user explicitly reconnected. Re-arms auto-reconnect.
    mutating func reset() {
        refusals = 0
        gaveUp = false
    }

    /// #750: the one-line bond-refusal EPITAPH. Records the streak + an OPAQUE install-local id only, never
    /// a MAC or serial. `opaqueId` should be a short token derived from the CoreBluetooth-local peripheral
    /// UUID (per-install, not the hardware address), which carries no PII. Pure so a fixture pins it. No
    /// em-dash (project rule). Byte-identical to the Android twin.
    static func epitaphLine(refusals: Int, opaqueId: String) -> String {
        "Bond epitaph: the strap [\(opaqueId)] refused the encrypted bond \(refusals)x in a row with no successful bond - giving up auto-reconnect to stop hammering it. It is almost certainly held by the official WHOOP app or a stale phone pairing. Free it (close the WHOOP app, put the strap in pairing mode, forget it in Bluetooth settings) then reconnect in NOOP."
    }

    /// #747: the honest user-facing hint shown when auto-reconnect pauses. Tells them WHY it stopped and how
    /// to get going again. Pure; no em-dash. Byte-identical to the Android twin.
    static func pausedHint() -> String {
        "NOOP stopped retrying because your strap keeps refusing to pair. It is likely still held by the official WHOOP app, or your phone is holding an old pairing. Close the WHOOP app, put the strap in pairing mode (tap until the LEDs flash blue), and if it is listed in your Bluetooth settings choose Forget This Device. Then tap Connect to try again."
    }

    /// #750: a short OPAQUE token from a CoreBluetooth-local peripheral UUID for the epitaph. The CB UUID is
    /// per-install (NOT the hardware MAC), and we keep only its first 8 hex chars, so the token is stable
    /// within a log but carries no device-identifying PII. Pure + deterministic. Twin of the Android helper.
    static func opaqueId(fromLocalUUID uuid: String) -> String {
        let hex = uuid.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(8))
    }
}

/// Decides when a completed sync that handed over only the strap's console/diagnostic output (no sensor
/// records) is sustained enough to warn that the strap's clock has lost sync and it isn't banking to flash
/// (#77 / #91 / #120). A SINGLE empty cycle is common on a perfectly healthy strap — the strap can hand
/// back a console-only window, especially under heavy live-HR polling — so warning on one cycle
/// false-alarms users whose clock is fine (#126). We require CONSECUTIVE empty cycles; any cycle that banks
/// real sensor records clears the streak. Pure value type → unit-testable without a CoreBluetooth seam.
struct EmptySyncTracker {
    /// Consecutive console-only completed syncs before the clock-lost banner shows. 3 (not 1): a genuinely
    /// un-banking strap is console-only on EVERY cycle, so 3 is reached within minutes, while a transient
    /// empty cycle amid healthy ones never accumulates.
    let threshold: Int
    private(set) var consecutiveEmptySyncs = 0

    init(threshold: Int = 3) { self.threshold = threshold }

    /// Record a COMPLETED (HISTORY_COMPLETE) offload. `bankedSensorRecords` = the strap handed over real
    /// sensor records this cycle (decoded, or undecodable-but-archived — either way the clock is banking).
    /// `consoleOnly` = it handed over only diagnostic frames and no sensor records. Returns true only once
    /// emptiness is SUSTAINED (≥ threshold consecutive console-only cycles) — the caller shows the
    /// "clock has lost sync" banner only then. Any banking cycle, or a caught-up cycle with nothing to
    /// offload, clears the streak.
    mutating func recordCompletedSync(bankedSensorRecords: Bool, consoleOnly: Bool) -> Bool {
        guard consoleOnly, !bankedSensorRecords else {
            consecutiveEmptySyncs = 0
            return false
        }
        consecutiveEmptySyncs += 1
        return consecutiveEmptySyncs >= threshold
    }
}

/// #580: a connected WHOOP 5/MG whose firmware acks SEND_HISTORICAL_DATA but emits ZERO type-0x2F
/// offload frames. Live HR streams fine over the standard 0x2A37 profile, but the historical offload is
/// empty, so every session runs the 60s idle watchdog out to a "timeout" and surfaces the WHOOP-4
/// "strap went quiet" sync error — even though nothing is wrong, the 5/MG history offload is simply
/// experimental/unsupported on that firmware. Worse, the empty offload leaves the link idle, so the
/// 120s liveness watchdog can bounce-disconnect/rescan every ~2 min in a thrash loop.
///
/// This pure tracker counts CONSECUTIVE empty 5/MG offloads (a timeout with no offload frames and no
/// rows persisted). Once `quietThreshold` is reached it reports the strap as "history-empty" so the
/// caller can (a) surface an honest "connected, history sync experimental on 5.0" state instead of a
/// sync error, and (b) back off the bounce loop. Any offload that DOES hand over real records clears the
/// streak — so a strap that later starts banking recovers immediately. Value type → unit-testable
/// (Whoop5EmptyOffloadTrackerTests) without a CoreBluetooth seam. Mirrored on Android.
struct Whoop5EmptyOffloadTracker {
    /// Consecutive empty 5/MG offloads before we treat the strap as history-empty (experimental). 2 (not
    /// 1): the very first offload after connect can race the strap waking its flash, so one empty cycle is
    /// noise; two in a row is the firmware genuinely not serving history.
    let quietThreshold: Int

    private(set) var consecutiveEmpty = 0
    /// True once `quietThreshold` consecutive empty offloads have been seen — the link is up + live HR is
    /// flowing but the 5/MG history offload is empty. Drives the honest home-state flag AND the bounce
    /// backoff. Cleared the moment any offload banks real records.
    private(set) var historyEmpty = false

    init(quietThreshold: Int = 2) { self.quietThreshold = quietThreshold }

    /// Record a completed/timed-out 5/MG offload. `bankedRecords` = this offload routed real offload
    /// frames / persisted rows (the strap IS handing over history). Returns true if THIS call freshly
    /// crossed the threshold (so the caller can log/surface once). A banking offload resets everything.
    mutating func recordOffload(bankedRecords: Bool) -> Bool {
        guard !bankedRecords else {
            consecutiveEmpty = 0
            historyEmpty = false
            return false
        }
        consecutiveEmpty += 1
        if !historyEmpty && consecutiveEmpty >= quietThreshold {
            historyEmpty = true
            return true     // freshly crossed — caller logs/surfaces once
        }
        return false
    }

    /// Clear all suspicion — a fresh connect, or the user explicitly re-requested a sync. Lets a strap
    /// that starts banking (or a transient empty spell) recover without waiting out the streak.
    mutating func reset() {
        consecutiveEmpty = 0
        historyEmpty = false
    }
}

/// Battery/radio backoff signal for any offload exit that produced no fresh durable receipt work.
/// Replays, metadata-only completions, and zero-progress timeouts all advance the same bounded streak;
/// one fresh inserted receipt clears it immediately.
struct HistoricalEmptyBackoffTracker {
    private(set) var consecutiveEmpty = 0

    mutating func record(freshProgress: Bool) {
        if freshProgress {
            consecutiveEmpty = 0
        } else {
            consecutiveEmpty = min(consecutiveEmpty + 1, 2)
        }
    }

    mutating func recordDisconnect(inFlight: Bool, freshProgress: Bool) {
        guard inFlight else { return }
        record(freshProgress: freshProgress)
    }
}

/// One monotonic deadline for the complete connected radio burst. Each session receives only the time
/// remaining before that deadline, so repeated watchdog re-arms cannot extend the 180-second ceiling.
struct HistoricalRadioDeadline: Equatable {
    let uptimeDeadline: TimeInterval

    init(startedAt: TimeInterval, budgetSeconds: TimeInterval) {
        uptimeDeadline = startedAt + max(0, budgetSeconds)
    }

    func remaining(at uptime: TimeInterval) -> TimeInterval {
        max(0, uptimeDeadline - uptime)
    }

    func sessionTimeout(at uptime: TimeInterval, idleTimeout: TimeInterval) -> TimeInterval {
        min(max(0, idleTimeout), remaining(at: uptime))
    }
}

/// Every radio session consumes the hard pass budget. Productivity is tracked separately so duplicate-
/// only fresh receipts keep a burst productive while replay/console sessions remain zero progress.
struct HistoricalBurstPassTracker: Equatable {
    private(set) var totalPasses = 0
    private(set) var productivePasses = 0

    mutating func startPass() { totalPasses += 1 }
    mutating func finishPass(freshSourceProgress: Bool) {
        if freshSourceProgress { productivePasses += 1 }
    }
    mutating func reset() {
        totalPasses = 0
        productivePasses = 0
    }
}

/// Receipt frontier fenced by the complete durable source identity used by a continuation decision.
struct HistoricalSourceFrontier: Equatable {
    let scope: HistoricalReceiptWatermark.Scope
    let normalizedMaxTs: Int?
    let mappedRawMaxTs: Int?

    var maxTs: Int? {
        [normalizedMaxTs, mappedRawMaxTs].compactMap { $0 }.max()
    }

    static func aggregate(
        receipts: [HistoricalDataCommitReceipt],
        databaseInstanceId: String,
        cursorScope: HistoricalCursorScope
    ) -> Self {
        let identity = HistoricalReceiptWatermark.SourceIdentity(
            deviceId: cursorScope.deviceId,
            lineage: cursorScope.lineage,
            epoch: Int64(cursorScope.cursorEpoch),
            trimScope: cursorScope.trimScope
        )
        var normalized: Int?
        for receipt in receipts where
            receipt.databaseInstanceId == databaseInstanceId
                && receipt.deviceId == cursorScope.deviceId
                && receipt.lineage == cursorScope.lineage
                && receipt.cursorEpoch == cursorScope.cursorEpoch
                && receipt.trimScope == cursorScope.trimScope {
            normalized = [normalized, receipt.maxDecodedTs].compactMap { $0 }.max()
        }
        return Self(
            scope: HistoricalReceiptWatermark.Scope(
                databaseInstanceId: databaseInstanceId,
                sourceIdentity: identity
            ),
            normalizedMaxTs: normalized,
            // Receipts retain exact raw-range evidence, including timestamps deliberately rejected by
            // the plausibility/content gate. Only the materialization job's trusted frontier may publish
            // mapped progress; this receipt-only compatibility helper therefore fails closed.
            mappedRawMaxTs: nil
        )
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
struct BackfillContinuation {
    /// Conservative hard cap on consecutive auto-continues per connection (resets on disconnect). Raising
    /// this above six remains a physical-device energy/radio qualification gate.
    static let defaultMaxTotalPasses = 6
    /// Hard monotonic radio budget for one auto-continued burst. It is independent of wall-clock changes
    /// and bounds a productive-but-pathological strap even before the pass cap is reached.
    static let defaultMaxContinuousRadioSeconds: TimeInterval = 3 * 60
    /// Do not send another SEND_HISTORICAL_DATA command unless the burst can still provide at least half
    /// of one normal 60-second offload window. Shorter fragments spend radio time on command/START setup
    /// but are unlikely to return a useful chunk before the hard burst deadline.
    static let defaultMinimumUsefulRemainingRadioSeconds: TimeInterval = 30
    /// How far ahead the strap must be (seconds) before "more backlog remains" is real, not clock noise.
    /// Matches StuckStrapDetector.behindGapSeconds (5 min) so the two agree on "behind".
    static let defaultBehindGapSeconds = 300
    /// #928: how far past the WALL CLOCK the strap-reported "newest" may sit before it is implausible.
    /// A strap clock set in the FUTURE (wandering RTC relatch) makes dataRangeNewestUnix read ahead of
    /// every real frontier, so guard 2a would report backlog forever and burn the whole cap in EMPTY
    /// offloads on every connect. 48 h absorbs genuine timezone confusion and mild drift; nothing
    /// legitimate banks records two days ahead of the phone's clock.
    static let defaultFutureSkewSeconds = 48 * 3600

    /// #1012: is the strap-reported "newest banked record" FUTURE-dated beyond the skew allowance — more
    /// than `futureSkewSeconds` past the wall clock? The strap's clock is then almost certainly set in the
    /// future (#928), so its range answer AND its freshly-persisted rows are untrustworthy as backlog
    /// evidence. Pure, and shared between `shouldAutoContinue` (it gates 2a AND 2b) and the call site's
    /// honest stop log so the two can never disagree on the reason. nil ⇒ false: an unanswered range is
    /// UNKNOWN, not future-dated, and 2b's stale-epoch rescue (#451) still applies to it.
    static func isFutureDatedNewest(_ strapNewestTs: Int?, wallNowUnix: Int,
                                    futureSkewSeconds: Int = defaultFutureSkewSeconds) -> Bool {
        guard let n = strapNewestTs else { return false }
        return n > wallNowUnix + futureSkewSeconds
    }

    static func hasMinimumUsefulRemainingRadioBudget(
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
    static func shouldAutoContinue(stillConnected: Bool,
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

/// Durable progress identity for one completed offload pass. Equality means the strap handed back the
/// same acknowledged trim/content/frontier and an immediate retry would only replay work.
struct HistoricalPassSignature: Equatable {
    let scope: HistoricalReceiptWatermark.Scope
    let trim: UInt32
    let fingerprint: String
    let durableFrontierTs: Int
}

/// Coalesces materialization wake-ups while one bounded worker pass is active. An ACK that creates a
/// second job during the active pass leaves one durable follow-up wake instead of being dropped.
struct HistoricalMaterializationWakeState: Equatable {
    private(set) var isRunning = false
    private(set) var wakePending = false

    /// Returns true when the caller owns starting a worker pass.
    mutating func request() -> Bool {
        wakePending = true
        guard !isRunning else { return false }
        isRunning = true
        wakePending = false
        return true
    }

    /// Completes the active pass. Returns true when a coalesced wake owns one immediate follow-up pass.
    mutating func finish() -> Bool {
        isRunning = false
        guard wakePending else { return false }
        isRunning = true
        wakePending = false
        return true
    }

    mutating func cancel() {
        isRunning = false
        wakePending = false
    }

    /// The store is authoritative about due work left after the claim. Continue only when this pass
    /// shrank the eligible queue; an all-retryable batch must stop and wait for its retry deadline.
    static func shouldRequestDrainFollowUp(
        hasMoreDueWork: Bool,
        completed: Int,
        quarantined: Int
    ) -> Bool {
        hasMoreDueWork && (completed > 0 || quarantined > 0)
    }

    static func nextRetryAttempt(
        resultAttemptAt: Int?,
        storeAttemptAt: Int?
    ) -> Int? {
        resultAttemptAt ?? storeAttemptAt
    }

    /// An exact replay may be the first wake after a crash between receipt commit and materialization.
    /// The store supplies whether that exact coordinate is currently due; replay remains zero BLE progress.
    static func shouldWakeAfterAcknowledgment(
        receipt: HistoricalDataCommitReceipt,
        outcome: HistoricalCommitOutcome,
        due: Bool
    ) -> Bool {
        guard due, case .materializationRequired = receipt.rawStatus else { return false }
        switch outcome {
        case .inserted, .replayed: return true
        }
    }
}

struct HistoricalMaterializationOwnership: Equatable, Sendable {
    let storeGeneration: Int
    let workerGeneration: Int
}

/// Tracks whether one connected series of historical-offload sessions produced data that needs the
/// post-backfill scoring/refresh pass. A deep backlog may span several 60-second sessions; publishing on
/// every session makes the dashboard compete with the next session's writes, while publishing only on
/// `HISTORY_COMPLETE` strands durable rows after an idle timeout. Consume exactly once when the burst
/// actually stops, keeping the UI's "last synced" status truthful.
struct BackfillBurstPublication: Equatable {
    struct Finalization: Equatable {
        let watermark: HistoricalReceiptWatermark?
    }

    private(set) var needsPublication = false
    private var persistedPasses = 0
    private(set) var commitWatermark: HistoricalReceiptWatermark?
    /// Only scopes with productive rows are refresh scopes. Empty receipts can still advance those
    /// scopes, but an empty-only burst must never arm a later publication with a stale coordinate.
    private var productiveScopes: Set<HistoricalReceiptWatermark.Scope> = []

    /// Record the durable receipt identity. The display/session source is not allowed to relabel it.
    mutating func record(receipt: HistoricalDataCommitReceipt) {
        let candidate = HistoricalReceiptWatermark(receipt: receipt)
        commitWatermark = (commitWatermark ?? HistoricalReceiptWatermark(coordinates: []))
            .including(receipt: receipt)
        let hasMappedRaw = if case .materializationRequired = receipt.rawStatus {
            receipt.rawRange.frameCount > 0
        } else {
            false
        }
        if (receipt.insertedRows.total > 0 || hasMappedRaw),
           let scope = candidate.coordinates.first?.scope {
            productiveScopes.insert(scope)
            needsPublication = true
        }
    }

    /// Records one durable session. The returned value is cheap UI progress only: it does not start
    /// analysis or refresh Repository, both of which remain deferred to one burst-finalization edge.
    @discardableResult
    mutating func record(rowsPersisted: Int, requiresTimestampHeal: Bool,
                         latestFrontierUnix: Int? = nil,
                         at timestamp: TimeInterval = Date().timeIntervalSince1970) -> HistoricalSyncPassProgress? {
        needsPublication = needsPublication || rowsPersisted > 0 || requiresTimestampHeal
        guard rowsPersisted > 0 else { return nil }
        persistedPasses += 1
        return HistoricalSyncPassProgress(rowsPersisted: rowsPersisted,
                                          passNumber: persistedPasses,
                                          latestFrontierUnix: latestFrontierUnix,
                                          commitWatermark: commitWatermark?.filtered(to: productiveScopes),
                                          publishedAt: timestamp)
    }

    mutating func consumeFinalization() -> Finalization? {
        // Reset even when there is no publication. An empty-only receipt must not survive into a later
        // timestamp-heal publication and masquerade as productive durable work.
        let finalization = needsPublication
            ? Finalization(watermark: commitWatermark?.filtered(to: productiveScopes))
            : nil
        reset()
        return finalization
    }

    mutating func consume() -> Bool {
        consumeFinalization() != nil
    }

    mutating func reset() {
        needsPublication = false
        persistedPasses = 0
        commitWatermark = nil
        productiveScopes.removeAll(keepingCapacity: true)
    }
}

/// Coalesces the diagnostic history-chunk counter before it touches `LiveState`. The exact ACK count stays
/// local for liveness decisions, while SwiftUI sees at most four whole-screen invalidations per second.
struct HistoricalProgressThrottle: Equatable {
    private(set) var acknowledged = 0
    private var lastPublished = 0
    private var lastPublishedAt: TimeInterval?
    let minimumPublishInterval: TimeInterval

    init(minimumPublishInterval: TimeInterval = 0.25) {
        self.minimumPublishInterval = minimumPublishInterval
    }

    mutating func begin() {
        acknowledged = 0
        lastPublished = 0
        lastPublishedAt = nil
    }

    mutating func acknowledge(now: TimeInterval) -> Int? {
        acknowledged += 1
        return publishIfDue(now: now)
    }

    mutating func flush(now: TimeInterval) -> Int? {
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

/// #927: the "overnight only" schedule for Continuous HRV capture. When the user opts in, the dense
/// R10/R11 + TOGGLE realtime R-R stream that continuous capture holds armed 24/7 is armed only inside a
/// nightly window, roughly halving the battery cost (overnight is where the HRV/recovery/sleep value is;
/// daytime Stress just gets sparser readings, since Stress reads this realtime R-R stream).
///
/// The window reuses the app's quiet-hours convention byte-for-byte (the NotificationSettingsStore keys,
/// the same defaults, and the same wrap-aware membership as SedentaryDetector.windowContains and the
/// Android NotifPrefs.inQuietHours): minutes since LOCAL midnight, inclusive start, exclusive end, and
/// the window may cross midnight (22:00 → 07:00 by default). Local wall time keeps it DST-agnostic the
/// same way quiet hours are: a DST jump moves the wall clock, the window definition never changes.
///
/// The MODE is composed from the two persisted booleans so existing users need no migration:
///   continuous OFF                → stream never held open (unchanged)
///   continuous ON, overnight OFF  → ALWAYS: armed 24/7 (the pre-#927 behaviour; overnight defaults off)
///   continuous ON, overnight ON   → OVERNIGHT: armed only inside the window
///
/// Pure + value-typed so the predicate is unit-testable (ContinuousHrvScheduleTests). BLEManager
/// RE-DERIVES it at every arm site (reconcile / keep-alive tick / post-bond arm) instead of caching it,
/// so a reconnect outside the window can never re-arm the flood from a stale precomputed want.
struct ContinuousHrvSchedule {
    /// The reused quiet-hours window keys (written by NotificationSettingsStore; the same reuse idiom as
    /// InactivityPrefs.NotifK) and their defaults (22:00 / 07:00).
    static let quietStartKey = "notif.quietStartMinutes"
    static let quietEndKey = "notif.quietEndMinutes"
    static let defaultStartMinutes = 22 * 60
    static let defaultEndMinutes = 7 * 60

    /// Wrap-aware membership: is `minuteOfDay` inside `[startMin, endMin)`, where the window may cross
    /// midnight? Byte-for-byte the quiet-hours semantics (SedentaryDetector.windowContains / the Android
    /// NotifPrefs.inQuietHours): start <= end is the plain daytime interval; start > end wraps midnight.
    static func windowContains(_ minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        if startMin <= endMin { return minuteOfDay >= startMin && minuteOfDay < endMin }
        return minuteOfDay >= startMin || minuteOfDay < endMin
    }

    /// The composed want: should the continuous-capture stream be held open at local wall-clock minute
    /// `minuteOfDay`? False when the feature is off; true 24/7 in ALWAYS mode (overnightOnly false, the
    /// pre-#927 behaviour every existing user reads with no migration); window-gated in OVERNIGHT mode.
    static func streamWanted(continuousHrv: Bool, overnightOnly: Bool,
                             minuteOfDay: Int, startMin: Int, endMin: Int) -> Bool {
        guard continuousHrv else { return false }
        guard overnightOnly else { return true }
        return windowContains(minuteOfDay, startMin: startMin, endMin: endMin)
    }
}

/// CoreBluetooth engine for the WHOOP 4.0: scan-by-service → connect → discover →
/// BOND (one confirmed write) → subscribe → reassemble char-05 frames → FrameRouter.
/// Cannot run in the simulator; verified manually on-device (Task C6).
@MainActor
public final class BLEManager: NSObject, ObservableObject {

    // MARK: GATT UUIDs (authoritative, from FINDINGS.md)
    static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")
    static let whoop5Service   = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a") // WHOOP 5.0 / MG
    static let cmdWriteChar    = CBUUID(string: "61080002-8d6d-82b8-614a-1c8cb0f8dcc6") // CMD → strap
    static let cmdNotifyChar   = CBUUID(string: "61080003-8d6d-82b8-614a-1c8cb0f8dcc6") // responses
    static let eventNotifyChar = CBUUID(string: "61080004-8d6d-82b8-614a-1c8cb0f8dcc6") // events
    static let dataNotifyChar  = CBUUID(string: "61080005-8d6d-82b8-614a-1c8cb0f8dcc6") // data (frag)
    // WHOOP 5.0 / MG ("puffin") characteristics under the fd4b service. EXPERIMENTAL — see the
    // whoop5 connect path in didDiscoverCharacteristics. fd4b0002 takes the static CLIENT_HELLO.
    static let whoop5CmdWriteChar = CBUUID(string: "fd4b0002-cce1-4033-93ce-002d5875f58a")
    static let whoop5NotifyChars: [CBUUID] = [
        CBUUID(string: "fd4b0003-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0004-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0005-cce1-4033-93ce-002d5875f58a"),
        CBUUID(string: "fd4b0007-cce1-4033-93ce-002d5875f58a"),
    ]
    static let heartRateService = CBUUID(string: "180D")
    static let heartRateChar    = CBUUID(string: "2A37") // HR + R-R (works unbonded)
    static let batteryService   = CBUUID(string: "180F")
    static let batteryChar      = CBUUID(string: "2A19")

    static let restoreID = "com.openwhoop.ble.central"

    // MARK: Published state
    public let state: LiveState
    private let router: FrameRouter
    private var collector: Collector?

    // MARK: Upload / server sync — REMOVED for Strand (standalone, fully on-device).

    // MARK: Backfill
    private var backfiller: Backfiller?
    private var dataStore: WhoopStore?
    private var restoreInProgress = false
    private var historicalMaterializationStoreGeneration = 0
    /// True while a historical offload session is in progress (frames route to Backfiller).
    private var backfilling = false
    /// One immutable admission for the physical BLE link currently allowed to ACK historical receipts.
    /// A receipt from any older connection, peripheral, or registry lineage must stay durable-but-unacked.
    private struct HistoricalBackfillAdmission: Equatable {
        let scope: HistoricalCursorScope
        let peripheralID: UUID
        let connectGeneration: Int
        let secureSessionID: Whoop5SecureSessionID?
        let storeGeneration: Int
        /// Distinguishes two historical sessions on the same physical BLE connection. A late write
        /// callback must not confirm a replacement session that happens to use the same trim.
        let sessionGeneration: Int
    }
    /// Ownership captured at the public history-request seam. This prevents a request admitted under one
    /// secure attempt or store instance from being started after either owner has been replaced.
    private struct HistoricalSyncRequestOwnership: Equatable {
        let secureSessionID: Whoop5SecureSessionID?
        let storeGeneration: Int
    }
    /// The single safe-trim ACK currently waiting for CoreBluetooth's `.withResponse` completion.
    /// Backfiller serializes chunk completion, so there can never be more than one legitimate request.
    private struct PendingHistoricalAck {
        let admission: HistoricalBackfillAdmission
        let trim: UInt32
        let characteristicUUID: CBUUID
        let continuation: CheckedContinuation<Bool, Never>
    }
    /// The identity captured when a safe-trim write leaves this process. It binds the callback to one
    /// physical connection and one historical session, rather than only to a reused peripheral UUID.
    private struct HistoricalAckWriteIdentity: Equatable {
        let admission: HistoricalBackfillAdmission
        let trim: UInt32
    }
    /// CoreBluetooth confirms writes in order per characteristic. Track every `.withResponse` command so
    /// an earlier non-history callback can never be mistaken for the safe-trim ACK that follows it. Keep
    /// retired entries until their callback arrives: an old callback must consume its own entry, never a
    /// new connection's write.
    enum ConfirmedWritePurpose: Equatable, Sendable {
        case bondHandshake
        case clientHello
        case protocolProof
        case genericCommand
        case historicalAck
    }

    private struct ConfirmedCommandWrite {
        let id: UUID
        let peripheralID: UUID
        let characteristicUUID: CBUUID
        let characteristicIdentity: UUID
        let connectGeneration: Int
        let secureAttemptEpoch: UInt64?
        let purpose: ConfirmedWritePurpose
        let command: UInt8
        let requestSequence: UInt8
        let historicalAck: HistoricalAckWriteIdentity?
    }
    private struct QueuedWhoop5ConfirmedWrite {
        let owner: ConfirmedCommandWrite
        let data: Data
        let peripheral: CBPeripheral
        let characteristic: CBCharacteristic
    }
    private var admittedHistoricalBackfill: HistoricalBackfillAdmission?
    private var historicalSessionGeneration = 0
    private var pendingHistoricalAck: PendingHistoricalAck?
    private var confirmedCommandWrites: [ConfirmedCommandWrite] = []
    private var queuedWhoop5ConfirmedWrites: [QueuedWhoop5ConfirmedWrite] = []
    private var activeWhoop5ConfirmedWriteID: UUID?
    private var whoop5ConfirmedWriteTimeout: DispatchWorkItem?
    private var characteristicIdentities: [ObjectIdentifier: UUID] = [:]
    private var historicalAckTimeout: DispatchWorkItem?
    static let historicalAckConfirmationTimeout: TimeInterval = 8
    static let whoop5ConfirmedWriteTimeout: TimeInterval = 8
    static let whoop5SecureStageTimeoutSeconds: TimeInterval = 12
    /// Wall time of the most recent offload frame OR HISTORY_COMPLETE — drives the #174 deep-packet
    /// cooldown. A type-0x2F frame arriving just after a backfill ends (backfilling already flipped
    /// false) is a TRAILING historical frame, not the live R22 stream; it must not be miscounted as a
    /// "live deep packet". nil until the first offload frame this process.
    private var lastOffloadFrameAt: Date?
    private var loggedWhoop5OffloadDeepPacket = false
    private var loggedWhoop5TrailingDeepPacket = false
    /// Window after the last offload frame/HISTORY_COMPLETE during which a type-0x2F frame is treated
    /// as trailing-historical, not live. ~10 s comfortably covers the post-completion drain lull.
    static let deepPacketLiveCooldownSeconds: TimeInterval = 10
    /// How far back the inactivity reminder (#419) reads gravity on each offload completion (4 h
    /// comfortably spans the threshold + re-nudge cadence and a separating Active break for bout
    /// continuity). Mirrors the Android WhoopBleClient.INACTIVITY_LOOKBACK_S.
    static let inactivityLookbackSeconds = 4 * 3600
    /// Safety-net detector: strap reports newer data than us AND our frontier frozen 10 min ⇒ flag for
    /// reboot. behindGapSeconds avoids false positives when off-wrist / caught up. Insurance only.
    private var stuckDetector = StuckStrapDetector(stuckAfterSeconds: 600, behindGapSeconds: 300)
    /// Newest record unix the strap reports having (from the GET_DATA_RANGE response); refreshed each
    /// offload. Compared against our frontier to tell "stuck" from "off-wrist/caught-up".
    private var strapNewestTs: Int?
    /// Fires if the strap goes silent mid-offload; re-armed on every frame during backfill.
    private var backfillTimeout: DispatchWorkItem?
    /// Periodic opportunistic upload while connected. Without it, upload only fires at connect +
    /// backfill-exit, so during a long live session decoded rows pile up locally and the server
    /// (dashboard) lags. Started on bond, cancelled on disconnect.
    private var uploadTimer: DispatchSourceTimer?
    static let uploadIntervalSeconds = 30
    /// Periodic re-trigger of the type-47 historical offload. This is the PRIMARY continuous metric
    /// source (mirrors how WHOOP syncs): the strap's 14-day biometric store is re-offloaded every
    /// `backfillIntervalSeconds` while connected+bonded, rather than once per connect. Started on
    /// bond, cancelled on disconnect. Plain SEND_HISTORICAL_DATA returns the type-47 store (no
    /// high-freq-sync), so each periodic tick just routes through requestSync(.periodic) → beginBackfill
    /// (SEND_HISTORICAL_DATA + watchdog), subject to the BackfillPolicy floor.
    private var backfillTimer: DispatchSourceTimer?
    /// Wall-clock target represented by `backfillTimer`. Keeping the target lets battery updates that do
    /// not cross the power-saving boundary avoid cancelling and recreating an identical timer.
    private var backfillTimerDeadlineAt: TimeInterval?
    // BackfillPolicy.periodicFloorSeconds is the real floor (a recent event-triggered sync moves the
    // absolute deadline). 900s = 15 min, matching WHOOP.
    static let backfillIntervalSeconds = 900
    /// #477: stretched offload cadence while low on power (45 min). The strap banks to flash meanwhile,
    /// so this only delays sync (larger batches), never loses data. Mirrors Android
    /// `LOW_BATTERY_BACKFILL_INTERVAL_MS`.
    static let lowBatteryBackfillIntervalSeconds = 2700
    /// If an already-due timer cannot begin because a transient gate is closed (for example, the store is
    /// still protected), retry soon without spinning a zero-delay timer loop.
    static let backfillRetryDelaySeconds: TimeInterval = 30

    /// Pure battery-adaptive gate (#477), the twin of Android `WhoopBleClient.idleThrottleActive`. Keyed
    /// on the STRAP's battery: armed by `thresholdPct` > 0, engages while the strap is discharging at/below
    /// `thresholdPct`. The phone's own Low Power Mode deliberately does NOT trigger it. Charging never engages.
    static func lowPowerThrottleActive(batteryPct: Int, charging: Bool, thresholdPct: Int) -> Bool {
        thresholdPct > 0 && !charging && batteryPct <= thresholdPct
    }

    /// Pure offload-interval decision (#477), the twin of Android `offloadIntervalMsFor`.
    static func offloadInterval(baseSeconds: Int, lowSeconds: Int,
                                batteryPct: Int, charging: Bool, thresholdPct: Int) -> Int {
        lowPowerThrottleActive(batteryPct: batteryPct, charging: charging, thresholdPct: thresholdPct)
            ? max(baseSeconds, lowSeconds) : baseSeconds
    }

    /// Keep-alive: re-arm realtime, poll battery, and bounce a stalled link so streaming
    /// never silently dies. Started on bond, cancelled on disconnect.
    private var keepAliveTimer: DispatchSourceTimer?
    static let keepAliveIntervalSeconds = 30
    private var keepAliveTick = 0
    /// If a persisted/missing strap-family preference points at the wrong service, a service-filtered
    /// BLE scan can run forever even though the strap is nearby (the common "won't reconnect after an
    /// update" report). Rotate between WHOOP families after a short miss and persist whichever family
    /// actually advertises. (PR#195)
    private var scanFallbackWorkItem: DispatchWorkItem?
    /// True only while the normal connection scan was deliberately broadened under the explicit
    /// Connection Test Centre diagnostic. CoreBluetooth can omit advertised service UUIDs, which is
    /// tolerated for a production scan pinned to one known service but is unsafe once an unsupported
    /// family is also in the scan filter: without an advertised UUID we cannot prove which family
    /// woke this callback, so the diagnostic path fails closed before GATT.
    private var diagnosticScanIncludesUnsupportedFamilies = false
    static let scanFallbackDelaySeconds: TimeInterval = 8
    /// Last time ANY notification arrived — drives the liveness watchdog.
    private var lastDataAt = Date()
    /// True while a Live/Health screen is on-screen and wants the realtime stream. One of the two
    /// inputs to `wantsRealtime`. Driven by `startRealtime()` / `stopRealtime()`.
    private var screenWantsRealtime = false
    /// True while the "Continuous HRV capture" preference wants the realtime stream held open even with
    /// no Live screen visible, so the strap banks dense beat-to-beat R-R 24/7 (better overnight
    /// HRV/recovery/sleep). The second input to `wantsRealtime`. Default off; set by
    /// `setKeepRealtimeForData(_:)`. Mirrors the Android `keepStreamForData`. #927: this is the RAW
    /// preference intent; the effective want is window-gated through `continuousCaptureWantsNow()` when
    /// "overnight only" is on, re-derived at every arm site.
    private var keepRealtimeForData = false
    /// #477 battery (parity with Android): STRAP battery-% at/below which the periodic offload cadence
    /// stretches to `lowBatteryBackfillIntervalSeconds` (0 = off), and at/below which the background
    /// continuous-HRV stream is released. Both key off the STRAP's charge (not the phone's), and both are
    /// benign (no link risk). Set from Settings via `setLowBatteryOffloadThrottle`/`setPauseCaptureOnPowerSave`.
    private var lowBatteryOffloadPct = 0
    /// STRAP battery-% at/below which the continuous-HRV pause engages (0 = off) — like the offload lever.
    private var pauseCaptureBatteryPct = 0
    /// Derived want: the (heavy) realtime stream should be armed while EITHER a screen wants it OR the
    /// continuous-capture preference wants it. Keep-alive re-arms it; the post-bond branch arms it on
    /// connect. Recomputed only inside `reconcileRealtime()`.
    private var wantsRealtime = false
    /// What we last told the strap (armed = TOGGLE_REALTIME_HR 1). Lets `reconcileRealtime()` send the
    /// toggle only on the false↔true edge instead of on every input change. Cleared on disconnect — the
    /// strap forgets the toggle across a connection, and the post-bond branch re-arms from `wantsRealtime`.
    private var realtimeArmed = false
    /// #80 marginal-radio fallback: tracks consecutive arm-then-quick-timeout cycles. When it trips,
    /// `standardHRFallback` goes true and the next connect skips arming R10/R11 (relies on 0x2A37).
    private var marginalRadio = MarginalRadioDetector()
    /// #617 bond-loop detector: tracks consecutive bond-then-quick-timeout cycles on a WHOOP 4. When it
    /// trips, BLEManager surfaces the existing re-pair guide (`state.reconnectGuide`) instead of looping
    /// silently. Reset on a clean session / intentional disconnect / a successful connect.
    private var postBondLoop = PostBondTimeoutLoopDetector()
    /// Wall time the encrypted bond was established this connection, to measure how soon a drop follows
    /// the bond (the #617 bond-loop tell). nil until bonded; cleared on disconnect.
    private var bondedAt: Date?
    /// Monotonic per-connection token, bumped on every didConnect. The #711 bond-loop stabilization check
    /// captures it and clears the re-pair guide only if it is UNCHANGED when the check fires, i.e. the SAME
    /// continuous connection survived. CoreBluetooth reuses the CBPeripheral object across reconnects, so a
    /// `===` identity check would NOT tell a healthy session apart from a later loop cycle. Named distinctly
    /// from Repository.swift's v7.0.3 refreshGen publish token so the two never get confused.
    private var connectGeneration = 0
    /// Source admission epoch for historical work. It advances on a new physical connection or active
    /// source switch, so a late completion cannot inherit a later source's identity.
    private var historicalSourceEpoch: Int64 = 0
    // MARK: Connection & Sync test mode (Test Centre) - diagnostic-only counters
    //
    // These exist purely to feed the .connection-tagged diagnostic lines + readout when that test mode is
    // active; they change NO connect / bond / offload behaviour. Every emit site that reads them is gated
    // behind TestCentre.active(.connection) BEFORE any string is built, so the counters are still
    // maintained cheaply (a Date()/Int) but nothing tagged is ever produced when the mode is off.
    /// Wall time the current connect attempt began (the scan/connect call), to measure connect latency at
    /// didConnect. nil between attempts; set when connect() kicks the radio.
    private var connectAttemptStartedAt: Date?
    /// Count of INVOLUNTARY reconnects this run (a drop or failed-connect that was not user-initiated),
    /// surfaced as the reconnect-churn count. Reset by an intentional disconnect.
    private var connReconnectCount = 0
    /// #126 false-alarm guard: tracks CONSECUTIVE console-only completed syncs so the "clock has lost
    /// sync" banner only fires on sustained emptiness, not a single transient empty cycle on a healthy strap.
    private var emptySyncTracker = EmptySyncTracker()
    /// #580: tracks CONSECUTIVE empty 5/MG offloads so a 5/MG whose firmware serves no history offload (but
    /// streams live HR fine) reads as "history sync experimental on 5.0" instead of a sync error, and the
    /// 120s bounce loop backs off while live HR is flowing. Reset on connect / a banking offload.
    private var whoop5EmptyOffload = Whoop5EmptyOffloadTracker()
    private var historicalEmptyBackoff = HistoricalEmptyBackoffTracker()
    /// When true, SKIP arming the R10/R11 raw realtime stream on connect — the radio couldn't sustain
    /// it (see MarginalRadioDetector). Live HR then comes only from the already-subscribed low-bandwidth
    /// 0x2A37 standard-HR profile. Per-session: set by the detector, cleared on a clean reconnect (a
    /// connection that actually carried data) or when the user re-opens Live / taps Start HR.
    private var standardHRFallback = false
    /// Wall time we last armed the R10/R11 realtime burst this connection, to measure how soon a drop
    /// follows the arm (the marginal-radio tell). nil until armed; cleared on disconnect.
    private var realtimeArmedAt: Date?
    /// Last-offload-attempt time (unix seconds), persisted so the rate limiter survives relaunch
    /// (matches WHOOP's DATA_SYNC_WORKER_LAST_WORK_TIME watermark).
    static let backfillLastAtKey = "backfillLastAt"
    /// Prevents a second backfill from starting on a same-process reconnect to the same strap.
    private var backfillStarted = false
    /// #364 auto-continue: how many times we've immediately re-kicked a backfill after a 60s idle-cap OR
    /// Total radio sessions and productive sessions in this connected burst. Every session consumes the
    /// six-pass budget; only fresh sensor receipts establish productivity.
    private var historicalBurstPasses = HistoricalBurstPassTracker()
    /// Set only by a newly inserted receipt whose decoded sensor payload was non-empty. The Backfiller's
    /// mapped-raw tally is combined at session exit, after its plausibility gate has run.
    private var historicalSessionInsertedSensorReceipt = false
    /// #364 spin-detector: the trim cursor as of the END of the previous backfill session this
    /// connection. exitBackfilling compares the current Backfiller.lastAckedTrim against this to decide
    /// whether the just-ended session actually advanced the strap's trim (progress) or froze (stop
    /// re-kicking). nil until the first session ends; reset on disconnect.
    private var lastSessionEndTrim: UInt32?
    private var lastHistoricalPassSignature: HistoricalPassSignature?
    /// Monotonic deadline shared by every session in the current burst.
    private var historicalRadioDeadline: HistoricalRadioDeadline?
    private var historicalMaterializationTask: Task<Void, Never>?
    private var historicalMaterializationTaskOwnership: HistoricalMaterializationOwnership?
    private var historicalMaterializationWake = HistoricalMaterializationWakeState()
    private var historicalMaterializationWorkerGeneration = 0
    private var historicalMaterializationRetryTask: Task<Void, Never>?
    private typealias HistoricalMaterializationDueCheck = @Sendable (WhoopStore, String) async -> Bool
    private typealias HistoricalMaterializationRun = @Sendable (WhoopStore) async throws
        -> HistoricalMaterializationRunSummary
    private var historicalMaterializationDueCheck: HistoricalMaterializationDueCheck = { store, receiptId in
        (try? await store.isHistoricalMaterializationDue(receiptId: receiptId)) ?? false
    }
    private var historicalMaterializationRun: HistoricalMaterializationRun = { store in
        try await store.materializePendingHistoricalRaw()
    }
    /// Runs the connect handshake exactly once per connection. Confirmed-write purpose tokens keep later
    /// callbacks out of the handshake path. Keep this guard as defense in depth. Reset on disconnect.
    private var connectHandshakeDone = false
    /// #34: true once the cmd-notify characteristic (61080003) has CONFIRMED it's subscribed
    /// (`didUpdateNotificationStateFor` fired for it with `isNotifying == true`) — as opposed to merely
    /// requested. Together with `connectHandshakeDone`, gates `state.connectSettled` (see LiveState.swift)
    /// so the alarm re-arm doesn't fire GET_ALARM_TIME before the strap's reply channel is actually live.
    /// Reset on disconnect alongside `connectHandshakeDone`.
    private var cmdNotifyConfirmedActive = false
    /// #34: latches once `state.connectSettled` has been bumped for the CURRENT connection, so a
    /// didUpdateNotificationStateFor re-fire (or any other later call into the check) can't double-bump.
    /// Reset on disconnect.
    private var connectSettledSignaled = false
    /// Re-entrancy guard for captureRawAccel: true while a bounded on-demand window is running.
    /// A second tap is a no-op until the active capture's asyncAfter block fires and clears this.
    private var rawCaptureInFlight = false
    /// Ordered queue of frames awaiting drain through the serial Backfiller task. WHOOP 5 frames retain
    /// the secure owner captured at delegate receipt so an actor hop cannot route them into a later session.
    private struct AdmittedBackfillFrame {
        let bytes: [UInt8]
        let whoop5Admission: Whoop5HistoricalSessionAdmission?
    }
    private var backfillFrameQueue: [AdmittedBackfillFrame] = []
    /// Accumulates durable writes across an auto-continued history burst. The dashboard is notified once
    /// only after `maybeAutoContinueBackfill` proves the burst has quiesced.
    private var backfillBurstPublication = BackfillBurstPublication()
    /// Exact ACK count plus a coalesced UI publication edge for a fast historical offload.
    private var historicalProgress = HistoricalProgressThrottle()
    /// True while the drain task is running (prevents a second drain task from launching).
    private var backfillDraining = false
    /// Keep each main-actor drain slice small enough that SwiftUI can process input/paint between slices.
    private static let backfillDrainBatchSize = 12

    /// Records WHOOP 5/MG puffin frames to a JSON file for protocol mapping. Passive (read-only on the
    /// strap) and gated by the Settings → Experimental "Record puffin frames" toggle; a no-op for
    /// WHOOP 4.0 and when the toggle is off. Lazy so it shares `state` after init. (Cherry-picked from
    /// @j0b-dev's PR #20.)
    private lazy var puffinRecorder = PuffinFrameRecorder(state: state)
    private lazy var puffinEventLog = PuffinEventLog()

    /// Durable log of the WHOOP 5/MG high-rate R22 deep buffers (type-0x2F ≥ 1 KB) for #423 reverse-
    /// engineering. Gated on the same capture toggle; no-op otherwise.
    private lazy var puffinDeepBufferLog = PuffinDeepBufferLog()

    /// Force the puffin capture buffer to disk so the Settings export/reveal targets a current file.
    public func flushPuffinCaptures() { puffinRecorder.flush() }

    // MARK: CoreBluetooth
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Multi-WHOOP: when non-nil, the scan/discover path connects ONLY to the peripheral whose
    /// `identifier == preferredPeripheralUUID` and ignores every other discovered WHOOP. When nil
    /// (the only state a single-WHOOP user is ever in) the discover path is byte-for-byte unchanged —
    /// it connects to the FIRST WHOOP discovered. Set by the app via `setPreferredPeripheral(_:)` to
    /// the active device's persisted `peripheralId`. Purely additive; nothing reads it on the nil path.
    private var preferredPeripheralUUID: UUID?
    /// Multi-WHOOP Add-a-WHOOP wizard: while true, `didDiscover` POPULATES `discoveredWhoops` instead
    /// of auto-connecting — an explicit, separate "present the nearby straps" mode the wizard turns on
    /// (`scanForWhoops()`) then off (`stopWhoopScan()`). Default false leaves the auto-connect path
    /// untouched. Must never overlap the normal connect flow (the wizard owns the central while true).
    private var isPresentingScan = false
    /// The CBPeripheral.identifier.uuidString of the WHOOP we most recently CONNECTED to (`didConnect`).
    /// Published so the app/AppModel can persist it onto the active registry device
    /// (`registry.setPeripheralId`) — letting "my-whoop" adopt its strap's id on first connect and a
    /// specific WHOOP confirm its identity. BLEManager stays decoupled: it never writes the registry.
    @Published public private(set) var connectedPeripheralUUID: String?
    /// Multi-WHOOP Add-a-WHOOP wizard surface: straps seen while `isPresentingScan` is true, WITHOUT
    /// auto-connecting. Cleared at the start of each `scanForWhoops()`. Empty/unused on the default path.
    @Published public private(set) var discoveredWhoops: [(uuid: String, name: String, rssi: Int)] = []
    /// Peripheral captured during `willRestoreState`; cleared in `didConnect`.
    /// Non-nil signals that `centralManagerDidUpdateState` should reconnect this
    /// specific peripheral rather than starting a fresh scan.
    private var restoredPeripheral: CBPeripheral?
    /// #280: true while `lastSyncError` currently holds a radio-state message (off / unauthorized /
    /// unsupported) that `centralManagerDidUpdateState` set. Lets the poweredOn transition clear ONLY
    /// that message, never a genuine mid-sync error (e.g. "Sync interrupted").
    private var radioStateErrorShown = false
    /// #391: pending one-shot escalation armed when the central reports `.unauthorized` while the TCC
    /// grant reads as granted (the macOS cold-start settling window). Canceled by ANY later state
    /// callback (the settle resolved); if it fires instead, the state never settled — the wedged-grant
    /// shape (#429) — and the #295 re-grant banner is shown after all.
    private var unauthorizedSettleWork: DispatchWorkItem?
    private var cmdCharacteristic: CBCharacteristic?
    private var cmdNotifyCharacteristic: CBCharacteristic?
    private var eventNotifyCharacteristic: CBCharacteristic?
    private var dataNotifyCharacteristic: CBCharacteristic?
    private var heartRateCharacteristic: CBCharacteristic?
    private var batteryCharacteristic: CBCharacteristic?
    /// EXPERIMENTAL WHOOP 5.0/MG puffin notify chars (fd4b0003/4/5/7), remembered at discovery so we
    /// can re-subscribe them AFTER bonding — the strap refuses them ("Authentication is insufficient")
    /// until the link is encrypted (issue #17).
    private var whoop5NotifyCharacteristics: [CBCharacteristic] = []
    /// CoreBluetooth object instances that proved this secure attempt. Once CLIENT_HELLO starts,
    /// duplicate discovery may repeat these exact objects but must never replace them in place.
    private var whoop5FrozenCommandCharacteristic: CBCharacteristic?
    private var whoop5FrozenNotifyCharacteristics: [String: CBCharacteristic] = [:]
    /// Restored subscriptions must be toggled off and back on so this attempt receives fresh callbacks.
    private var whoop5NotifyRearmOffPending: Set<String> = []
    private var whoop5SecureStageTimeout: DispatchWorkItem?
    private var whoop5SecureStageDeadlineID: UUID?
    private var reassembler = Reassembler()
    private var seq: UInt8 = 0
    private var didBond = false
    private var whoop5SecureSession = Whoop5SecureSession()
    private var whoop5R22Attempt: Whoop5R22Attempt?
    private var pendingWhoop5HapticResponses: Set<UInt8> = []
    /// WHOOP 5/MG only: realtime HR has been armed (puffin TOGGLE_REALTIME_HR sent) once this connection.
    private var whoop5RealtimeArmed = false
    /// Once-per-connection guard for the 5/MG offload kick (connectHandshakeDone + requestSync +
    /// startBackfillTimer). Keep it as defense in depth behind confirmed-write purpose ownership.
    private var whoop5SessionStarted = false
    /// Backfill ACKs can arrive hundreds or thousands of times in one offload. Keep the strap log
    /// readable and avoid forcing SwiftUI to auto-scroll on every ACK row.
    private var historicalAckLogCounter = 0
    private var clockRequested = false
    /// Bounded per-physical-connection GET_CLOCK recovery. The planner is pure; this manager owns the
    /// command writes, response deadline, and the one allowed approximate correlation.
    private var clockRecovery = StrapClockRecoveryPlanner()
    private var clockRecoveryTimeout: DispatchWorkItem?
    private static let clockRecoveryTimeoutSeconds: TimeInterval = 4
    private var intentionalDisconnect = false
    /// Consecutive `didFailToConnect` count, for the auto-reconnect backoff (#414). Reset to 0 on a
    /// successful connect; grows the reschedule delay so a strap that's genuinely out of range doesn't
    /// hammer Bluetooth (vs the disconnect path's flat 3s, which is fine for an already-bonded drop).
    private var failedConnectAttempts = 0
    /// Multi-WHOOP stale-pin recovery (#52). The identifier of the last peripheral that reached a GENUINE
    /// encrypted bond this run. When the pinned strap keeps refusing the bond but THIS one bonds fine, it's
    /// the live working strap the registry pin should point at. nil until any strap genuinely bonds.
    private var lastBondedPeripheralUUID: UUID?
    /// #78: consecutive "Encryption/Authentication is insufficient" CLIENT_HELLO refusals with NO genuine
    /// bond in between. When the strap genuinely refuses the encrypted bond (held by the WHOOP app, or a
    /// stale iOS pairing), this climbs and we surface actionable pairing-mode guidance; a single transient
    /// refusal right after a good bond (#74) stays quiet. Reset to 0 on any genuine bond, NOT on disconnect
    /// (so it accumulates across the reconnect loop). Distinct from `pinnedBondRefusals`, which is gated to
    /// the multi-WHOOP pinned peripheral and drives the #52 stale-pin handoff.
    private var bondRefusalStreak = 0
    /// #747 / #750: after the bond is refused persistently, pause auto-reconnect (stop hammering) and write
    /// a one-line epitaph. Fed by the SAME refusal events as `bondRefusalStreak`; its higher give-up
    /// threshold fires once the pairing HINT has had several cycles to be acted on. Reset on a genuine bond
    /// or an explicit user reconnect (so a manual retry re-arms auto-reconnect).
    private var bondGiveUp = BondRefusalGiveUp()
    /// True while auto-reconnect is PAUSED by the #747 give-up. The disconnect-rescan and the
    /// failed-connect backoff both consult this and skip scheduling a reconnect; a manual connect()/
    /// disconnect() clears it via `bondGiveUp.reset()`. Distinct from `intentionalDisconnect` so a paused
    /// link still reports its state honestly rather than looking like a user teardown.
    private var autoReconnectPausedForBondLoop = false
    /// When the bond-loop pause last tripped (or last salvage-probed). Drives the #78 hole-4 salvage
    /// probe's 10-minute floor (`shouldSalvageProbe`): a paused strap the user has since FREED self-heals
    /// on the next app-foreground instead of staying disconnected until a manual Connect, while a strap
    /// that's still held gets at most one bounded attempt per foreground per floor window. Set wherever
    /// the pause trips (#747 give-up + the #617 bond-then-quick-timeout detector, deliberately both:
    /// probing a #617-paused link costs one bounded cycle and self-heals the same way); nil whenever the
    /// pause clears. Never persisted.
    private var bondLoopPausedAt: Date?
    /// NotificationCenter token for the app-foreground salvage probe (installForegroundSalvageProbe).
    private var foregroundSalvageObserver: NSObjectProtocol?
    /// Multi-WHOOP stale-pin recovery (#52). Consecutive "Encryption/Authentication is insufficient" bond
    /// refusals on the CURRENTLY PINNED peripheral. A stale registry pin (pointing at a strap that bonds to
    /// the official app / isn't really here) makes `connect()` drop the strap that DOES bond and loop
    /// forever on the dead pin. Counts up here; cleared by any genuine bond (a healthy pin never accrues).
    private var pinnedBondRefusals = 0
    /// Refusals on the pinned strap before we hand the pin off to a different, live-bonding strap (#52). 3
    /// (not 1): a single "insufficient" can be a transient just-works race; three in a row on the pin while
    /// ANOTHER strap bonds fine is an unrecoverable stale pin. Mirrors the EmptySync/marginal-radio idiom.
    private let pinBondRefusalLimit = 3
    /// The strap we're mid-handoff onto during a #52 re-adoption (set in `readoptWorkingStrap`, cleared
    /// when that strap re-bonds in `noteGenuineBond`). Gates the one-time `connectedPeripheralUUID`
    /// re-publish that confirms the re-adoption to SourceCoordinator. nil whenever no handoff is in flight.
    private var readoptingTo: UUID?
    /// The strap family the user chose to pair. Drives which service we scan for
    /// and which service we discover after connecting. Hydrated from the persisted
    /// pick so restoration/reconnect after a relaunch target the right strap.
    private var selectedModel: WhoopModel = .persisted
    private var lastStandardHRLogAt: Date?

    /// True when the selected/connected strap is a WHOOP 5/MG. Read-only window onto the private
    /// `selectedModel` so a view can tell whether the firmware-alarm path is the experimental 5/MG one
    /// (see `armStrapAlarm`, which only arms a 5/MG when Experimental is on). #864: the iOS Smart-alarm
    /// UI needs this so it stops telling a 5/MG owner the strap is armed when, without Experimental, it
    /// isn't. Mirrors the Android `LiveState.whoop5Detected` signal the equivalent screen reads.
    var isWhoop5: Bool { selectedModel.deviceFamily == .whoop5 }

    /// True when the selected/connected strap is a WHOOP 4.0. Read-only window onto the private
    /// `selectedModel`, used to gate the 4.0-only reboot probe (Test Centre → Connection) in the UI.
    var isWhoop4: Bool { selectedModel.deviceFamily == .whoop4 }

    /// Stable device id; matches the server's existing device for sync parity. Overridable.
    /// Seeded from the init argument, then refined once in bootstrapStore() to the device registry's
    /// active id (still "my-whoop" today) before any store writes use it — see bootstrapStore().
    private(set) var deviceId: String
    /// Captured (device↔wall) correlation from GET_CLOCK; nil until the response lands.
    private(set) var clockRef: ClockRef?
    /// A Data Range fallback can keep historical decoding moving, but it is not a real GET_CLOCK
    /// correlation. A delayed real response must therefore replace it instead of being ignored.
    private var clockRefIsApproximate = false

    /// The strap's OWN clock extrapolated to right now (its RTC at the last GET_CLOCK + elapsed since).
    /// Used to judge live-gesture freshness in the strap's clock domain rather than wall time — so a
    /// real-time gesture is "now" and a replayed historical one is "old" REGARDLESS of how stale the
    /// strap RTC is (fix #72's straps). Falls back to wall-now when GET_CLOCK hasn't landed.
    private var strapClockNow: Int {
        let wallNow = Int(Date().timeIntervalSince1970)
        guard let ref = clockRef else { return wallNow }
        return ref.device + (wallNow - ref.wall)
    }

    public init(state: LiveState, deviceId: String = "my-whoop") {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        // WhoopStore.init is now async, so it can't run here.
        // bootstrapStore() is called once the CBCentralManager reaches poweredOn
        // (see centralManagerDidUpdateState), which guarantees the store is ready
        // before any BLE data arrives.
        self.collector = nil
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Restore identifier + background-capable central (foundation for M3 state restoration).
        #if os(iOS)
        // iOS background state preservation/restoration: the restore identifier is what makes
        // CoreBluetooth relaunch the app into the background and deliver willRestoreState after
        // a suspend-then-jettison. Without it, willRestoreState is never called.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
        #else
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
        installPowerStateScheduling()
        // #78 hole-4: a paused-for-bond-loop strap gets one bounded salvage attempt per app-foreground.
        installForegroundSalvageProbe()
    }

    /// Build the WhoopStore + Collector + Backfiller asynchronously. Safe to call multiple
    /// times — bails out early if the collector is already initialised.
    func bootstrapStore() async {
        guard collector == nil, !restoreInProgress else { return }
        let openingStoreGeneration = historicalMaterializationStoreGeneration
        // Surface store-open failures instead of swallowing them with `try?` (#222): a silent failure
        // here left `backfiller` nil forever and the only visible symptom was the downstream
        // "store not ready" tick, with no clue why. On iOS a background reconnect that opens the
        // data-protected store while the device is locked throws SQLITE_IOERR/CANTOPEN — logging the
        // code proves it; the periodic tick (see beginBackfill) re-attempts so it self-heals on unlock.
        let path: String
        do {
            path = try StorePaths.defaultDatabasePath()
        } catch {
            log("Backfill: bootstrap FAILED resolving DB path — \(error)")
            return
        }
        let store: WhoopStore
        do {
            store = try await WhoopStore(path: path)
        } catch {
            let ns = error as NSError
            log("Backfill: bootstrap FAILED opening store — \(ns.domain) code=\(ns.code): \(ns.localizedDescription)")
            return
        }
        guard !restoreInProgress,
              collector == nil,
              historicalMaterializationStoreGeneration == openingStoreGeneration else { return }
        historicalMaterializationStoreGeneration &+= 1
        dataStore = store
        // Route deviceId through the device registry: use the active device's id (migration v15 seeds
        // a single 'my-whoop' row as active, so this is still "my-whoop" today — zero behaviour change).
        // Guarded + best-effort: if the registry is empty/unreadable, deviceId stays as it was, so no
        // crash and no behaviour change. registryWriter is nonisolated/Sendable (the Pool manages
        // its own concurrency).
        if let activeId = try? DeviceRegistryStore(dbQueue: store.registryWriter).activeDeviceId(),
           !activeId.isEmpty {
            self.deviceId = activeId
        }
        try? await store.upsertDevice(id: deviceId, mac: nil, name: "WHOOP 4.0")
        // Research toggle — OFF by default. When disabled the app is decoded-only and never
        // persists raw frames. Flip "enableRawCapture" in UserDefaults to capture raw again.
        let enableRawCapture = UserDefaults.standard.bool(forKey: "enableRawCapture")
        collector = Collector(store: store, deviceId: deviceId,
                              enableRawCapture: enableRawCapture)
        // The store can finish bootstrapping AFTER connect(model:) already ran (both wait on
        // poweredOn), so apply the family/clock configuration here too — whichever runs last wins.
        configureCollectorFamily()
        backfiller = Backfiller(store: store, deviceId: deviceId,
                                ackTrim: { [weak self] scope, trim, endData in
                                    guard let self else { return false }
                                    return await self.ackHistoricalChunk(
                                        scope: scope,
                                        trim: trim,
                                        endData: endData)
                                },
                                enableRawCapture: enableRawCapture,
                                log: { [weak self] s in self?.log(s) },
                                rejectedSink: { [weak self] frames, trim, family in
                                    self?.archiveRejectedFrames(frames, trim: trim, family: family) ?? true
                                },
                                onHistoricalCommitContext: { [weak self] context in
                                    self?.recordHistoricalCommit(context)
                                },
                                onHistoricalAcknowledged: { [weak self, weak store] receipt, outcome in
                                    Task { @MainActor [weak self, weak store] in
                                        guard let self, let store else { return }
                                        await self.wakeHistoricalMaterializationAfterAcknowledgment(
                                            receipt: receipt,
                                            outcome: outcome,
                                            store: store
                                        )
                                    }
                                },
                                onChunk: { [weak self] decoded, console in
                                    if decoded { self?.state.decodedChunksThisSession += 1 }
                                    if console { self?.state.consoleChunksThisSession += 1 }
                                },
                                // Connection & Sync test mode (Test Centre): the cheap gate + tagged sink the
                                // Backfiller checks before building any .connection diagnostic line. The gate is
                                // one UserDefaults bool; nothing is emitted (or built) when the mode is off.
                                connectionActive: { TestCentre.active(.connection) },
                                connectionLog: { [weak self] s in self?.state.append(log: s, domain: .connection) },
                                // UNIVERSAL clock-drift: bank the strap's historical layout so the export's
                                // universal clock-drift line is firmware-aware on every export. Unconditional.
                                firmwareLayout: { [weak self] v in self?.state.setStrapFirmwareLayout(v) },
                                onFailure: { [weak self] failure in self?.handleBackfillFailure(failure) },
                                isWhoop5AdmissionCurrent: { [weak self] admission in
                                    self?.isCurrentWhoop5HistoricalAdmission(admission) == true
                                },
                                ackTrimForWhoop5Admission: { [weak self] scope, trim, endData, admission in
                                    guard let self,
                                          self.isCurrentWhoop5HistoricalAdmission(admission) else { return false }
                                    return await self.ackHistoricalChunk(
                                        scope: scope,
                                        trim: trim,
                                        endData: endData)
                                })
        // Strand: no server uploader/sync — all data stays on-device.
        scheduleHistoricalMaterialization(on: store)

        // Retro-decode: when the decoder gains a historical layout (e.g. WHOOP 4.0 v25), re-run every
        // archived undecodable frame through it and insert whatever now decodes — the only path by
        // which already-acked banked history backfills after an update. Run ONCE per app version (no
        // manual decoder-version constant to forget to bump); idempotent if it re-runs (rows dedupe
        // by ts) and the archive is small, so the once-per-update cost is negligible. (#152)
        // Note: the archive carries no deviceId, so replayed rows attribute to the current strap.
        let replayKey = "rejectArchiveReplayedAppVersion"
        if UserDefaults.standard.string(forKey: replayKey) != AppChangelog.currentVersion {
            do {
                let rows = try await rejectedHistoryArchive.replay(into: store, deviceId: deviceId)
                if rows > 0 { log("Backfill: retro-decoded \(rows) record(s) from the reject archive after an update.") }
                // Advance the gate ONLY on success — a failed insert must retry next launch, because
                // the archive holds the only surviving copy of these records. (#152)
                UserDefaults.standard.set(AppChangelog.currentVersion, forKey: replayKey)
            } catch {
                log("Backfill: reject-archive retro-decode deferred (store insert failed) — will retry next launch.")
            }
        }

        // Battery "~X days left" seed (#7): `LiveState.batterySamples` is fed ONLY by live BLE events, so
        // after a reconnect the runtime estimate restarted from an empty buffer and ignored the discharge
        // history already on disk (Android seeds from its persisted battery table over a 14-day window;
        // iOS/macOS did not = divergence). Read the persisted SoC series for the active device over the last
        // 14 days and seed the live buffer once the store is up. The setter de-dupes against any points
        // already banked from live events this session, so a seed that races the first live reading is safe.
        // nil-SoC rows are dropped here (the buffer is non-optional %); a read failure is non-fatal, the
        // estimate just cold-starts as before.
        let seedNow = Int(Date().timeIntervalSince1970)
        let fourteenDays = 14 * 24 * 3600
        if let rows = try? await store.batterySamples(
            deviceId: deviceId, from: seedNow - fourteenDays, to: seedNow, limit: 2000) {
            let seed = rows.compactMap { row -> (ts: Int, soc: Double)? in
                guard let soc = row.soc else { return nil }
                return (ts: row.ts, soc: soc)
            }
            state.seedBatterySamples(seed)
        }
    }

    /// Designated initializer for testing and preview use: accepts a pre-built Collector.
    init(state: LiveState, deviceId: String = "my-whoop", collector: Collector?) {
        self.state = state
        self.deviceId = deviceId
        self.router = FrameRouter(state: state)
        self.collector = collector
        super.init()
        state.lastSyncedAt = UserDefaults.standard.object(forKey: "lastSyncedAt") as? Double
        // Restore identifier + background-capable central (mirrors the production initializer
        // so a restored manager matches by identifier; only exercised by tests/previews).
        #if os(iOS)
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: BLEManager.restoreID])
        #else
        // Strand (macOS desktop): no state-restoration identifier (iOS background feature).
        central = CBCentralManager(delegate: self, queue: .main)
        #endif
        // Strap-as-clock: an incoming EVENT packet kicks a rate-limited catch-up sync.
        router.onSyncTrigger = { [weak self] in self?.requestSync(.strap) }
        installPowerStateScheduling()
        // #78 hole-4: a paused-for-bond-loop strap gets one bounded salvage attempt per app-foreground.
        installForegroundSalvageProbe()
    }

    // MARK: Public API

    /// USER-initiated connect (the Connect button, the scan flow, Add-a-WHOOP). The ONLY entry that
    /// re-arms a bond-loop give-up: a user gesture is an explicit "try again", so the streak + pause
    /// clear and auto-reconnect works again if it bonds. System-initiated paths (Bluetooth poweredOn,
    /// the deferred reconnect timers, the salvage probe) MUST use `connectFromSystem()` instead - the
    /// old single entry point let every poweredOn event (a Bluetooth toggle, a bluetoothd restart)
    /// silently un-pause the give-up and re-run the full refusal hammer, forever, one burst per event
    /// (#78 hole-2; Android's onBluetoothRadioOn always had the correct one-attempt-latched shape).
    public func connect(model: WhoopModel = .persisted) {
        // #747/#750: re-arm on the user's explicit retry: clear the give-up streak + pause so this fresh
        // attempt isn't immediately re-paused and the auto-reconnect works again if it bonds.
        if autoReconnectPausedForBondLoop {
            bondGiveUp.reset()
            autoReconnectPausedForBondLoop = false
            bondLoopPausedAt = nil
        }
        connectCore(model: model)
    }

    /// SYSTEM-initiated connect: byte-identical to `connect()` except it NEVER resets the bond-loop
    /// give-up (#78 hole-2). While paused this makes at most one bounded attempt (Android
    /// onBluetoothRadioOn parity): a refusal during it cannot write a second epitaph
    /// (`BondRefusalGiveUp.gaveUp` latches, `recordRefusal()` returns false) and the paused disconnect
    /// path schedules nothing afterwards, so the hammer loop cannot restart. A genuine bond still fully
    /// resets via the didWriteValueFor path, so a strap freed since the give-up self-heals.
    func connectFromSystem(model: WhoopModel = .persisted) {
        connectCore(model: model)
    }

    private func connectCore(model: WhoopModel) {
        intentionalDisconnect = false
        // Connection test mode: stamp when this connect attempt began so didConnect can report the connect
        // latency. A plain Date() assignment, no behaviour change; only read behind the .connection gate.
        connectAttemptStartedAt = Date()
        selectedModel = model
        // Battery "~X days left" fallback (#713): a 5/MG runs far longer than a 4.0, so point the estimator's
        // rated-life fallback at the connected family. The Today badge reads state.batteryEstimate (which uses
        // state.batteryRatedHours); without this it always assumed WHOOP 4.0 (108h).
        state.batteryRatedHours = model.deviceFamily == .whoop5
            ? BatteryEstimator.ratedLifeHoursWhoop5 : BatteryEstimator.ratedLifeHoursWhoop4
        // Frame the inbound stream for the chosen family (WHOOP 4.0 CRC8 vs WHOOP 5.0 CRC16/puffin)
        // and tell the router which decoder to use. Fresh per connection so no stale bytes carry over.
        reassembler = Reassembler(family: model.deviceFamily)
        router.family = model.deviceFamily
        // Live 5/MG persistence: point the Collector's decode at the selected family and install the
        // identity clock ref for a 5/MG (its live timestamps are already real unix). WHOOP 4.0 keeps
        // the GET_CLOCK correlation flow untouched. Re-applied after bootstrapStore builds the
        // collector so whichever runs last wins.
        configureCollectorFamily()
        guard central.state == .poweredOn else {
            log("Bluetooth not powered on (state=\(central.state.rawValue)); cannot scan yet")
            return
        }
        // Reuse the already-held peripheral ONLY if it's the strap we're pinned to. Without this guard a
        // multi-WHOOP switch attached straight back to the previously-held strap, ignoring the new active
        // device (registry said B, radio stayed on A). No pin (single-WHOOP) → always true, unchanged.
        if let p = peripheral, p.state == .connected, isPreferredPeripheral(p) {
            p.delegate = self
            whoop5SecureSession.refresh(peripheralID: p.identifier, connectGeneration: connectGeneration)
            if selectedModel.deviceFamily != .whoop5 {
                log("Already connected to \(model.displayName) — refreshing services and notifications")
                discoverPrimaryServices(on: p)
                enableLiveNotifications(reason: "manual refresh")
            } else {
                switch Self.whoop5ConnectedRefreshAction(for: whoop5SecureSession.state) {
                case .continueDiscovery:
                    log("Already connected to \(model.displayName) — continuing secure discovery")
                    discoverPrimaryServices(on: p)
                case .coalesceAttempt:
                    log("Already connected to \(model.displayName) — secure attempt already active; coalescing refresh")
                case .refreshLiveOnly:
                    log("Already connected to \(model.displayName) — secure session preserved; refreshing live notifications only")
                    enableLiveNotifications(reason: "manual refresh")
                case .reconnect:
                    if let sessionID = currentWhoop5SecureSessionID {
                        failWhoop5SecureSession(sessionID, reason: "connected refresh found a failed secure attempt")
                    } else {
                        central.cancelPeripheralConnection(p)
                    }
                }
            }
            return
        }
        // Existing OS-level connections for this WHOOP family. CoreBluetooth keeps a bonded strap connected
        // across app sessions, and `retrieveConnectedPeripherals(...).first` previously adopted WHICHEVER
        // WHOOP macOS already had open — bypassing the scan (the only place the preferred-strap pin was
        // read), so a switch could never move off the wrong strap. Now: with a pin set, drop every OTHER
        // open WHOOP (so it stops holding the link) and attach ONLY to the pinned one. No pin → first-wins,
        // exactly as before. #52: this drop is what abandoned a strap that bonds fine when the pin was
        // STALE — `readoptWorkingStrap()` repoints the pin to the live-bonding strap first, so after a
        // handoff this loop drops the dead strap and attaches to the working one instead of vice-versa.
        let existing = central.retrieveConnectedPeripherals(withServices: [model.scanService])
        if preferredPeripheralUUID != nil {
            for other in existing where !isPreferredPeripheral(other) {
                log("Dropping non-active WHOOP connection \(other.identifier) — not the selected strap")
                central.cancelPeripheralConnection(other)
            }
        }
        if let p = existing.first(where: { isPreferredPeripheral($0) }) {
            log("Found existing \(model.displayName) connection \(p.identifier) — attaching")
            preparePeripheral(p)
            // Attach OUR OWN session even when CoreBluetooth reports the strap .connected. On Apple
            // platforms an LE link is shared system-wide, so a strap held by the WHOOP app, a prior NOOP
            // session, or the OS itself reads .connected while NOOP has NO session of its own yet. The old
            // .connected branch flipped state.connected = true and jumped straight to discovery + live
            // notifications, which then silently delivered nothing: the UI claimed "connected" but no data
            // ever flowed (#689). Routing through connect(_:) instead fires didConnect almost immediately
            // for an already-system-connected peripheral, which runs the normal discover, bond and notify
            // flow and only flips state.connected once OUR link is actually up, so we never falsely report
            // "connected" either.
            central.connect(p, options: nil)
            return
        }
        // Pinned to a specific strap that isn't already open → connect it DIRECTLY by identifier. A scan
        // would let any in-range WHOOP satisfy the connect and could land on the wrong one; the targeted
        // retrieve can only ever return the strap we asked for.
        if let preferred = preferredPeripheralUUID,
           let p = central.retrievePeripherals(withIdentifiers: [preferred]).first {
            log("Connecting to selected strap \(preferred) — targeted")
            preparePeripheral(p)
            central.connect(p, options: nil)
            return
        }
        startScan(for: model, allowFallback: true)
    }

    public func disconnect() {
        intentionalDisconnect = true
        cancelScanFallback()
        // Cancel an unanswered GET_CLOCK recovery before the link begins its asynchronous teardown.
        // `didDisconnect` repeats this reset for non-user disconnects; doing it here prevents a timer
        // from issuing a stale retry while CoreBluetooth still reports the old link as connected.
        resetClockRecoveryForConnection()
        strapNewestTs = nil
        // A user-initiated teardown is a clean slate: clear any #80 marginal-radio fallback so the next
        // (manual) reconnect attempts the full R10/R11 stream again rather than inheriting old suspicion.
        marginalRadio.reset()
        postBondLoop.reset()   // #617: a clean teardown clears the bond-loop streak so a manual reconnect starts fresh
        bondGiveUp.reset()     // #747/#750: a clean teardown clears the bond-refusal give-up + un-pauses auto-reconnect
        autoReconnectPausedForBondLoop = false
        bondLoopPausedAt = nil
        state.reconnectGuide = nil   // #711: a user-initiated teardown resolves the re-pair guide (no longer looping)
        readoptingTo = nil   // #52: a clean teardown abandons any in-flight pin handoff
        standardHRFallback = false
        state.standardHRMode = nil
        // `cancelPeripheralConnection` is asynchronous. Resolve a suspended safe-trim continuation before
        // asking CoreBluetooth to tear down the link, not eight seconds later in its callback or timeout.
        invalidateHistoricalBackfill(reason: "connection cancellation was requested")
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        central.stopScan()
    }

    /// #78: fully RELEASE a strap when the user removes it from the Devices screen. Archiving the registry
    /// row alone left the strap connected — NOOP kept re-grabbing it (the 3s disconnect→reconnect timer, the
    /// targeted-connect pin, and iOS state restoration ALL still pointed at it), so it stayed connected and
    /// the user could never put it into pairing mode to re-pair (the #78 deadlock: a WHOOP that's connected
    /// can't show its blue pairing LEDs). Stop auto-reconnect, drop the live link, and clear the targeting +
    /// restoration references that point at this strap so NOOP lets go for good — until the user deliberately
    /// reconnects (which clears `intentionalDisconnect` again via connect()).
    public func forgetDevice(_ peripheralId: String?) {
        let target = peripheralId.flatMap { UUID(uuidString: $0) }
        let isCurrent = target == nil || peripheral?.identifier == target
        intentionalDisconnect = true            // defuses the disconnect→3s-reconnect loop's guard
        cancelScanFallback()
        readoptingTo = nil                       // abandon any in-flight #52 pin handoff
        // Clear the targeted-connect pin + the iOS state-restoration peripheral if they point at this strap,
        // so connect()/restoration can't re-target it.
        if target == nil || preferredPeripheralUUID == target { setPreferredPeripheral(nil) }
        if target == nil || restoredPeripheral?.identifier == target { restoredPeripheral = nil }
        // Forgetting clears `peripheral` before CoreBluetooth later emits didDisconnect. Invalidate now so
        // the stale delegate guard cannot leave an ACK continuation waiting for its full timeout.
        if target == nil
            || admittedHistoricalBackfill?.peripheralID == target
            || pendingHistoricalAck?.admission.peripheralID == target {
            invalidateHistoricalBackfill(reason: "device was forgotten")
        }
        // Drop the live BLE link so the strap is free to enter pairing mode.
        if isCurrent, let p = peripheral {
            central.cancelPeripheralConnection(p)
            peripheral = nil
            resetCharacteristics()
            state.markDisconnected()
            state.bonded = false
            state.encryptedBond = false
            state.pairingHint = nil
            bondRefusalStreak = 0
        }
        // #747/#750 invariant: releasing a strap fully resets the give-up + pause (like disconnect()) so
        // a paused state can never outlive the strap it belonged to and wedge a later re-add.
        bondGiveUp.reset()
        autoReconnectPausedForBondLoop = false
        bondLoopPausedAt = nil
        central.stopScan()
        log("Device removed — released the strap: stopped auto-reconnect, dropped the link, cleared targeting. Put it in pairing mode (blue LEDs) to re-pair if you want it back. (#78)")
    }

    /// Switch which strap we'll connect to next: drop the current strap and clear the **sticky** bond
    /// state so a newly-picked model bonds fresh. `bonded` deliberately survives a disconnect (it means
    /// "this strap is paired"), but that left a user with BOTH a WHOOP 4 and a 5/MG unable to switch —
    /// `bonded` stayed true from the first strap, which hid the strap picker and kept the scan pointed at
    /// the old family's service. Call this when the user changes the strap selection.
    public func prepareForModelSwitch() {
        disconnect()
        state.markDisconnected()
        state.bonded = false
        state.encryptedBond = false
    }

    /// Idle the engine before presenting an Add-a-WHOOP scan — but ONLY when we're not already
    /// connected to a strap of this same family. Opening the scan must NOT tear down a live, bonded
    /// same-family connection: a WHOOP 5/MG that just bonded refuses the encrypted re-bond on the
    /// reconnect ("Encryption/Authentication is insufficient") and loops forever (#74). A genuine
    /// family switch (e.g. a connected 4.0 while scanning for a 5/MG, or nothing connected) still
    /// idles via `prepareForModelSwitch()` so the scan starts clean. `connect()` reuses the live
    /// same-family peripheral on its "Already connected — refreshing" path.
    public func prepareForPresentScan(model: WhoopModel) {
        if state.connected, selectedModel.deviceFamily == model.deviceFamily {
            log("Add-a-WHOOP scan: keeping the live \(selectedModel.displayName) connection (#74) — presenting nearby straps without dropping it")
            return
        }
        prepareForModelSwitch()
    }

    // MARK: Bond-loop salvage probe (#78 hole-4)

    /// Minimum time since the pause tripped (or since the last probe) before another salvage probe may
    /// fire. 10 minutes: long enough that a still-held strap sees a handful of bounded attempts per day,
    /// short enough that a strap the user freed reconnects on the next natural app open.
    nonisolated static let bondLoopSalvageFloorSeconds: TimeInterval = 10 * 60

    /// Pure gate for the one-shot bond-loop salvage probe: probe ONLY while the pause is latched, with no
    /// live link, no user teardown in force, and at least `bondLoopSalvageFloorSeconds` since the pause
    /// tripped (or since the previous probe re-stamped it). nil seconds = no trip timestamp = never probe.
    /// Pure so the never-hammer contract is pinned by unit tests without a CoreBluetooth seam.
    nonisolated static func shouldSalvageProbe(pausedForBondLoop: Bool,
                                               connected: Bool,
                                               intentionalDisconnect: Bool,
                                               secondsSincePauseTripped: TimeInterval?) -> Bool {
        guard pausedForBondLoop, !connected, !intentionalDisconnect else { return false }
        guard let s = secondsSincePauseTripped else { return false }
        return s >= bondLoopSalvageFloorSeconds
    }

    /// #78 hole-1: classify a "the strap refused the encrypted bond" error by its ATT CODE first,
    /// locale-proof. Foundation LOCALIZES CoreBluetooth error strings, so the old
    /// `localizedDescription.contains("encryption"/"authentication")` check silently never matched on a
    /// non-English device - no pairing hint, no give-up, no #52 pin handoff: exactly the futile reconnect
    /// loop #78 describes, still live for the (large) localized user base. Android was always immune (it
    /// matches GATT status ints 5/15). The English string match is kept as a FALLBACK only, never
    /// replaced: some CoreBluetooth paths surface plain NSErrors outside the CBATTError domain, and the
    /// code check must be additive so English-device detection can't regress. Pure + nonisolated so a
    /// unit test pins both routes without a CoreBluetooth seam.
    nonisolated static func isInsufficientAuthError(_ error: Error) -> Bool {
        if let att = error as? CBATTError,
           att.code == .insufficientEncryption || att.code == .insufficientAuthentication {
            return true
        }
        let text = error.localizedDescription.lowercased()
        return text.contains("encryption") || text.contains("authentication")
    }

    /// #78 hole-4: ONE bounded salvage attempt while the bond-loop pause is latched, fired on
    /// app-foreground (see `installForegroundSalvageProbe`). This is what makes the give-up provably
    /// unable to strand a strap the user has since freed: a genuine bond on the probe fully resets the
    /// pause via the normal didWriteValueFor path, while a still-refusing strap costs one attempt per
    /// foreground per 10-minute floor and NEVER re-enters the hammer loop (the give-up stays latched, no
    /// second epitaph, the paused disconnect path schedules nothing). Re-stamps `bondLoopPausedAt` so
    /// back-to-back foregrounds can't chain probes.
    func salvageProbeIfBondLoopPaused(now: Date = Date()) {
        let since = bondLoopPausedAt.map { now.timeIntervalSince($0) }
        guard BLEManager.shouldSalvageProbe(pausedForBondLoop: autoReconnectPausedForBondLoop,
                                            connected: state.connected,
                                            intentionalDisconnect: intentionalDisconnect,
                                            secondsSincePauseTripped: since) else { return }
        bondLoopPausedAt = now   // re-floor: max one probe per foreground AND per 10-min window
        log("Bond-loop pause: one salvage probe (the strap may have been freed since the give-up) - the give-up stays latched")
        connectFromSystem()
    }

    /// Observe the app-foreground notification and run the salvage probe. Installed once per manager from
    /// init; self-contained here so the probe needs no per-target scene wiring. iOS and macOS only (the
    /// watch never builds this file).
    private func installForegroundSalvageProbe() {
        #if os(iOS) || os(macOS)
        #if os(iOS)
        let name = UIApplication.didBecomeActiveNotification
        #else
        let name = NSApplication.didBecomeActiveNotification
        #endif
        foregroundSalvageObserver = NotificationCenter.default.addObserver(
            forName: name, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.salvageProbeIfBondLoopPaused() }
        }
        #endif
    }

    // MARK: Multi-WHOOP (additive — inert on the single-WHOOP path)

    /// Pin connections to ONE specific strap by its CBPeripheral.identifier.uuidString. The app sets
    /// this to the active device's persisted `peripheralId` when it has one; pass nil to clear it
    /// (back to "connect to the first WHOOP discovered" — the single-WHOOP default). An unparseable
    /// string clears the pin rather than wedging the scan. Only `didDiscover` reads it; setting it
    /// does NOT start/stop/redirect an in-flight connection on its own.
    public func setPreferredPeripheral(_ uuidString: String?) {
        let resolved = uuidString.flatMap { UUID(uuidString: $0) }   // nil for unparseable → clears the pin
        // A genuinely NEW pin starts the #52 refusal streak clean — the old streak belonged to the strap we
        // were pinned to before, not this one. Re-applying the SAME pin (the common no-op when the active
        // device doesn't change) deliberately preserves an in-progress count. A pin change to anything other
        // than the in-flight handoff target also abandons that handoff (the user/registry re-targeted).
        if resolved != preferredPeripheralUUID {
            pinnedBondRefusals = 0
            if resolved != readoptingTo { readoptingTo = nil }
        }
        preferredPeripheralUUID = resolved
    }

    /// True when `p` is the strap we're pinned to — or when no pin is set (the single-WHOOP default, so
    /// any WHOOP is acceptable and the legacy first-found behaviour is preserved byte-for-byte). The
    /// attach/reconnect paths consult this so they can never adopt the WRONG already-connected strap on a
    /// multi-WHOOP setup (the registry said one strap, the radio stayed on another — multi-WHOOP switch bug).
    private func isPreferredPeripheral(_ p: CBPeripheral) -> Bool {
        guard let preferred = preferredPeripheralUUID else { return true }
        return p.identifier == preferred
    }

    /// #52: a strap reached a GENUINE encrypted bond. Remember its identifier as the live working strap
    /// (the candidate the registry pin should follow if a stale pin keeps refusing), and clear the
    /// pin-refusal streak — any healthy bond proves the current path is fine, so a later transient
    /// "insufficient" starts counting from zero rather than inheriting old suspicion. If this bond is the
    /// strap we're mid-handoff onto (#52 re-adoption), CONFIRM it to SourceCoordinator now: republish its
    /// identity on `connectedPeripheralUUID` while `encryptedBond` is true, the one emission of that seam
    /// that proves a genuine bond — which is exactly how SourceCoordinator tells a vetted re-adoption from
    /// the ordinary pre-bond `didConnect` publish (where `encryptedBond` is still false).
    private func noteGenuineBond(of p: CBPeripheral) {
        lastBondedPeripheralUUID = p.identifier
        pinnedBondRefusals = 0
        if readoptingTo == p.identifier {
            readoptingTo = nil
            log("Multi-WHOOP (#52): working strap bonded — confirming re-adoption to the registry.")
            // nil first so the publisher's removeDuplicates() can't swallow the value when this strap was
            // already the last-connected uuid (the nil emission is ignored downstream — the uuid guard).
            connectedPeripheralUUID = nil
            connectedPeripheralUUID = p.identifier.uuidString
        }
    }

    /// #52: the pinned strap (`stalePin`) has refused the encrypted bond `pinBondRefusalLimit` times in a
    /// row while a DIFFERENT strap (`working`) bonds fine — the registry pin is stale and is making
    /// connect() abandon the strap that actually works. Hand the pin off to the working strap: re-point our
    /// own pin so connect()/didDiscover stop dropping the working strap, then reconnect onto it. Once it
    /// re-bonds, `noteGenuineBond` republishes its identity to SourceCoordinator (with `encryptedBond` true)
    /// so the registry re-adopts it. The normal first-connect/identity path (encryptedBond false at
    /// didConnect) is untouched, so this never fires on the correct-pin or single-strap path.
    private func readoptWorkingStrap(_ working: UUID, awayFrom stalePin: UUID) {
        log("Multi-WHOOP (#52): pinned strap refused the bond \(pinnedBondRefusals)× but another strap is bonded — handing the pin off to the working strap.")
        preferredPeripheralUUID = working
        pinnedBondRefusals = 0
        readoptingTo = working
        // The stale pin made us drop the working strap; reconnect so the now-correct pin lands on it. If
        // it's somehow still the held+bonded peripheral, confirm the re-adoption straight away instead.
        if let p = peripheral, p.identifier == working, p.state == .connected, state.encryptedBond {
            noteGenuineBond(of: p)
        } else if !intentionalDisconnect {
            connect(model: selectedModel)
        }
    }

    /// Re-point which device id live WHOOP samples store under, when the active WHOOP changes (a
    /// WHOOP↔WHOOP switch via the registry). Only the `SourceCoordinator` calls this, and only when a
    /// DIFFERENT registered WHOOP becomes active — the single-WHOOP path leaves the seeded "my-whoop" id
    /// in place (bootstrapStore set it; this is never called), so that path is byte-for-byte unchanged.
    /// Sets the manager's `deviceId` and re-points the live Collector/Backfiller for the next admitted
    /// session. An already-decoding historical chunk keeps its frozen source identity and cannot be
    /// re-attributed by this mutation. Additive: nothing on the single-WHOOP path invokes it.
    public func setActiveDeviceId(_ id: String) {
        guard !id.isEmpty else { return }
        let changed = id != deviceId
        deviceId = id
        collector?.deviceId = id
        backfiller?.deviceId = id
        if changed {
            historicalSourceEpoch &+= 1
        }
    }

    /// Add-a-WHOOP wizard: scan the selected family's WHOOP service and surface every nearby strap in
    /// `discoveredWhoops` WITHOUT auto-connecting. Turns on the `isPresentingScan` flag that diverts
    /// `didDiscover` to collect-not-connect, and uses duplicate-allowing scanning so RSSI refreshes.
    /// The wizard MUST call `stopWhoopScan()` before any normal connect resumes — this mode owns the
    /// central while active. No-op-to-the-connect-path: it never touches `peripheral`/bond state.
    public func scanForWhoops() {
        guard central.state == .poweredOn else {
            log("Add-a-WHOOP scan: Bluetooth not powered on (state=\(central.state.rawValue))")
            return
        }
        cancelScanFallback()            // no family-rotation timer should fire during a present-scan
        isPresentingScan = true
        discoveredWhoops = []           // fresh list each time the wizard opens the scan
        central.stopScan()
        // Allow duplicates so the wizard's RSSI/signal readout updates as straps move.
        central.scanForPeripherals(
            withServices: [selectedModel.scanService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        log("Add-a-WHOOP scan: presenting nearby \(selectedModel.displayName) straps")
    }

    /// End the Add-a-WHOOP present-scan: stop scanning and clear `isPresentingScan` so `didDiscover`
    /// returns to its normal auto-connect behaviour. Safe to call when not presenting (idempotent).
    public func stopWhoopScan() {
        guard isPresentingScan else { return }
        isPresentingScan = false
        central.stopScan()
        log("Add-a-WHOOP scan: stopped")
    }

    /// Apply the raw-outbox retention policy (24h synced window / 50MB unsynced cap).
    /// Called when the app enters the background; no-op without a concrete store.
    public func pruneRaw() {
        Task { @MainActor in await collector?.prune() }
    }

    /// Light storage summary for the UI (decoded rows, raw batches, raw bytes). nil without a store.
    public func storageStats() async -> (decodedRows: Int, rawBatches: Int, rawBytes: Int)? {
        await collector?.storageStats()
    }

    /// Capture raw accelerometer (type-43 IMU) frames on demand for a bounded window, then stop.
    /// Persists raw even when the global research toggle is off (that's the point: on-demand, not
    /// 24/7). The Collector's window auto-expires at its deadline so a dropped stop can't leak raw.
    public func captureRawAccel(seconds: TimeInterval = 30) {
        guard !rawCaptureInFlight else {
            log("Raw-accel capture: already in flight — ignoring")
            return
        }
        rawCaptureInFlight = true
        let secs = RawCaptureWindow.clamp(seconds)
        collector?.beginRawCapture(seconds: secs)
        send(.startRawData, payload: [0x01])
        send(.toggleIMUMode, payload: [0x01])
        log("Raw-accel capture: started for \(secs)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + secs) { [weak self] in
            guard let self else { return }
            // Only stop the raw stream if the 24/7 research toggle is OFF.  When it's ON, the
            // continuous stream must keep running — we just flush/upload the bounded window we
            // captured without halting the wider session.
            if !UserDefaults.standard.bool(forKey: "enableRawCapture") {
                self.send(.stopRawData, payload: [0x01])
            }
            self.rawCaptureInFlight = false
            Task { @MainActor in
                await self.collector?.endRawCapture()
            }
            self.log("Raw-accel capture: stopped + flushed")
        }
    }

    /// Send a command to the WHOOP strap.
    /// - Parameters:
    ///   - command: The command to send.
    ///   - payload: Command payload bytes (default `[0x00]`).
    ///   - writeType: BLE write type; defaults to `.withoutResponse` so all existing call
    ///     sites are unaffected. Pass `.withResponse` for acked commands (e.g. historicalDataResult).
    public func send(_ command: WhoopCommand, payload: [UInt8] = [0x00],
                     writeType: CBCharacteristicWriteType = .withoutResponse,
                     responseLabel: String? = nil) {
        // #314 parity: CoreBluetooth already covers both Android defects here — this `p.state == .connected`
        // guard makes a write a no-op once the radio powers off (no DeadObjectException to crash on), and
        // centralManagerDidUpdateState publishes state.connected = false on .poweredOff, so the iOS/macOS UI
        // can't show a stale-connected link. The Android fix re-creates both behaviours; no Swift change needed.
        guard state.connected, let p = peripheral, p.state == .connected, let ch = cmdCharacteristic else {
            let reason = state.connected ? "command characteristic unavailable" : "not connected"
            log("send(\(command.label)) ignored — \(reason)")
            return
        }
        // WHOOP 5.0/MG uses puffin (CRC16) command framing, not the WHOOP4 frame. The realtime-HR toggle
        // is hardware-confirmed (issue #17 — a 5/MG owner saw live HR over a public build), which proves
        // the strap does act on puffin-framed commands. We now also send haptics (buzz) and the
        // firmware-alarm family on that same proven transport. Everything else stays dropped.
        // WHOOP 4.0 is unaffected.
        if selectedModel.deviceFamily == .whoop5 {
            guard whoop5SecureReady else {
                log("send(\(command.label)) refused — WHOOP 5/MG secure session is not ready; standard 0x2A37 HR remains available")
                return
            }
            // Allowlist: live (toggle HR, buzz), the firmware-alarm family (set/get/run/disable —
            // same command numbers as WHOOP4 over puffin framing; the 5/MG REVISION_4/REVISION_2
            // bodies are built at the call sites and pad4 covers their 20-/2-byte bodies), the two
            // historical-offload commands, and the clock pair. SEND_HISTORICAL_DATA triggers the
            // offload; HISTORICAL_DATA_RESULT acks each HISTORY_END to walk the trim cursor.
            // SET_CLOCK/GET_CLOCK are MANDATORY before history: an un-clocked WHOOP 5 doesn't save
            // sensor data to flash at all ("RTC timestamp … is invalid; not saving data to flash"),
            // so offloads complete with zero body frames — hardware-validated, same 8-byte WHOOP4
            // payload over puffin framing. (#78 fork)
            guard command == .toggleRealtimeHR || command == .runHapticsPattern
                || command == .setAlarmTime || command == .getAlarmTime
                || command == .runAlarm || command == .disableAlarm
                // REBOOT_STRAP (29) over puffin: opcode shared with 4.0, framing is the puffin form built
                // below. NOT hardware-confirmed on 5/MG — rebootStrap() logs the COMMAND_RESPONSE so a strap
                // log confirms whether the frame is accepted. User-initiated + confirmation-gated only.
                || command == .rebootStrap
                || command == .sendHistoricalData || command == .historicalDataResult
                || command == .setClock || command == .getClock
                // SET_CONFIG (the R22 deep-stream unlock) is allowed ONLY while the deep-data
                // experiment is opted in — it writes a persistent feature flag to the strap, so it
                // must never fire on a default install. It's still reversible (just changes which
                // data the strap emits) and is what the official app sends. Driven only by
                // enableWhoop5DeepData(). (#174)
                || (command == .setConfig && PuffinExperiment.deepDataEnabled)
                // SET_DEVICE_CONFIG (the Broadcast-HR flag) is allowed ONLY while that opt-in is on —
                // it writes one persistent device-config value so the strap advertises standard HR.
                // Reversible; driven only by setBroadcastHr(_:). (#181)
                || (command == .setDeviceConfig && PuffinExperiment.broadcastHrEnabled) else {
                log("send(\(command.label)) skipped — no WHOOP 5/MG framing for this command yet")
                return
            }
            // WHOOP 5/MG haptics differ from WHOOP 4.0 on BOTH the opcode AND the payload (#48, decoded
            // from the working "maverick" app's binary). Opcode: 0x13, not RUN_HAPTICS_PATTERN=79 (a real-MG
            // capture showed the strap rejecting 79 with COMMAND_RESPONSE result=0x03). Payload: the maverick
            // haptic body [0x01, effects(8), loopControl(u16 LE), overallLoop] — here the "notify" preset
            // (effects 47,152), NOT the 4.0 [patternId, loops, …]. puffinCommandFrame pads the inner to a
            // 4-byte boundary, which this 12-byte payload needs. WHOOP 4.0 is untouched (79 + its own frame).
            let isHaptics = command == .runHapticsPattern
            let puffinCmd: UInt8 = isHaptics ? 0x13 : command.rawValue
            let requestedLoops = payload.count > 1 ? Int(payload[1]) : 1
            let puffinPayload: [UInt8] = isHaptics
                ? MaverickHaptics.notificationBuzz(loops: requestedLoops)
                : payload
            seq = seq &+ 1
            let requestSequence = seq
            let frame = puffinCommandFrame(cmd: puffinCmd, seq: requestSequence, payload: puffinPayload)
            if command == .setConfig, let responseLabel, let sessionID = currentWhoop5SecureSessionID {
                if whoop5R22Attempt?.sessionID != sessionID { whoop5R22Attempt = Whoop5R22Attempt(sessionID: sessionID) }
                whoop5R22Attempt?.track(flag: responseLabel, requestSequence: requestSequence)
            }
            if isHaptics { pendingWhoop5HapticResponses.insert(requestSequence) }
            writeValue(Data(frame), to: ch, on: p, type: writeType,
                       confirmedPurpose: confirmedWritePurpose(for: command),
                       command: puffinCmd,
                       requestSequence: requestSequence)
            let cmdNote = isHaptics ? " cmd=0x13" : ""
            if command == .historicalDataResult {
                historicalAckLogCounter += 1
                if historicalAckLogCounter == 1 || historicalAckLogCounter.isMultiple(of: 25) {
                    log("→ \(command.label) ack #\(historicalAckLogCounter) payload=\(hex(puffinPayload)) (puffin)")
                }
                return
            }
            log("→ \(command.label) payload=\(hex(puffinPayload)) (puffin\(cmdNote))")
            return
        }
        seq = seq &+ 1
        let frame = command.frame(seq: seq, payload: payload)
        writeValue(Data(frame), to: ch, on: p, type: writeType,
                   confirmedPurpose: confirmedWritePurpose(for: command),
                   command: command.rawValue,
                   requestSequence: seq)
        log("→ \(command.label) payload=\(hex(payload))")
    }

    /// Point the Collector's live decode at the selected family. For a 5/MG, also install an identity
    /// clock ref: live puffin REALTIME_DATA timestamps are already real-unix seconds, so device==wall
    /// makes toWall a no-op (the same idiom the Backfiller uses for 5/MG history). For a WHOOP 4.0 the
    /// collector takes the manager's GET_CLOCK correlation (nil until it lands — the normal 4.0 flow);
    /// this also evicts a stale identity ref a prior 5/MG session installed when the user switches
    /// straps, which would otherwise mis-stamp WHOOP4 device-epoch frames as wall-clock. Idempotent;
    /// called from connect() AND after the async store bootstrap builds the collector, so the
    /// configuration lands regardless of which finishes first.
    private func configureCollectorFamily() {
        collector?.family = selectedModel.deviceFamily
        if selectedModel.deviceFamily == .whoop5 {
            let now = Int(Date().timeIntervalSince1970)
            collector?.clockRef = ClockRef(device: now, wall: now)
        } else {
            collector?.clockRef = clockRef   // the WHOOP4 correlation, nil until GET_CLOCK lands
        }
    }

    /// Refresh the battery reading on demand. Source is FAMILY-SPECIFIC (#77): on a WHOOP 4.0 the
    /// standard 0x2A19 characteristic is a STUB that reports a constant 100 — the real charge only
    /// comes from the proprietary GET_BATTERY_LEVEL command (COMMAND_RESPONSE, u16/10). Reading both
    /// flashed 100% before the true value corrected it (and a stub notification could revert a real
    /// 94% back to 100%). So WHOOP 4 uses ONLY the command; WHOOP 5/MG uses ONLY 0x2A19.
    public func refreshBattery() {
        guard state.connected, let p = peripheral, p.state == .connected else {
            log("refreshBattery ignored — not connected")
            return
        }

        if selectedModel.deviceFamily == .whoop4 {
            send(.getBatteryLevel, payload: [0x00])
            return
        }

        if let batteryCharacteristic {
            if batteryCharacteristic.properties.contains(.read) {
                p.readValue(for: batteryCharacteristic)
                log("Reading standard Battery Level")
            } else {
                log("Battery Level read unavailable; waiting for notifications")
            }
        } else {
            log("Battery Level characteristic unavailable")
        }
    }

    /// True only while the immutable admission still names the current physical BLE connection.
    private func isCurrentHistoricalBackfill(_ admission: HistoricalBackfillAdmission) -> Bool {
        guard admittedHistoricalBackfill == admission,
              connectGeneration == admission.connectGeneration,
              historicalMaterializationStoreGeneration == admission.storeGeneration,
              state.connected,
              let current = peripheral,
              current.identifier == admission.peripheralID,
              current.state == .connected else {
            return false
        }
        if selectedModel.deviceFamily == .whoop5 {
            guard let secureID = admission.secureSessionID,
                  secureID == currentWhoop5SecureSessionID,
                  whoop5SecureSession.authorizesProprietaryCommand(sessionID: secureID) else { return false }
        }
        return true
    }

    /// Resolve the compact Backfiller owner through BLEManager's full admission, including store and
    /// historical-session generations. The compact value can never resurrect an older store lineage.
    private func isCurrentWhoop5HistoricalAdmission(
        _ owner: Whoop5HistoricalSessionAdmission
    ) -> Bool {
        guard let admission = admittedHistoricalBackfill,
              let secureID = admission.secureSessionID,
              secureID.peripheralID == owner.peripheralID,
              secureID.connectGeneration == owner.connectGeneration,
              secureID.attemptEpoch == owner.attemptEpoch else { return false }
        return isCurrentHistoricalBackfill(admission)
    }

    /// Complete a pending safe-trim ACK exactly once. A disconnect, session replacement, timeout, or
    /// failed CoreBluetooth write resolves false, leaving the durable receipt replayable next session.
    private func completePendingHistoricalAck(_ confirmed: Bool, reason: String? = nil) {
        guard let pending = pendingHistoricalAck else { return }
        pendingHistoricalAck = nil
        // Do not discard the queued write here. If CoreBluetooth emits its callback after a timeout,
        // disconnect, or session replacement, that old callback must consume this exact retired token.
        // Removing it would let the callback confirm the next session's same-UUID write.
        historicalAckTimeout?.cancel()
        historicalAckTimeout = nil
        if let reason {
            log("Backfill: historical ACK trim=\(pending.trim) not confirmed — \(reason)")
        }
        pending.continuation.resume(returning: confirmed)
    }

    /// Retire the local permission to safely trim history before any teardown or replacement. Durable
    /// receipts remain replayable; only their ability to ACK over this BLE session is revoked.
    private func invalidateHistoricalBackfill(reason: String) {
        completePendingHistoricalAck(false, reason: reason)
        admittedHistoricalBackfill = nil
    }

    private var currentWhoop5SecureSessionID: Whoop5SecureSessionID? {
        guard selectedModel.deviceFamily == .whoop5,
              let id = whoop5SecureSession.id,
              id.peripheralID == peripheral?.identifier,
              id.connectGeneration == connectGeneration else { return nil }
        return id
    }

    private var whoop5SecureReady: Bool {
        guard let id = currentWhoop5SecureSessionID else { return false }
        return whoop5SecureSession.authorizesProprietaryCommand(sessionID: id)
    }

    private func armWhoop5SecureStageDeadline(for sessionID: Whoop5SecureSessionID) {
        whoop5SecureStageTimeout?.cancel()
        let deadlineID = UUID()
        whoop5SecureStageDeadlineID = deadlineID
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, Self.shouldFireWhoop5SecureDeadline(
                expectedSessionID: sessionID,
                currentSessionID: self.currentWhoop5SecureSessionID,
                expectedDeadlineID: deadlineID,
                currentDeadlineID: self.whoop5SecureStageDeadlineID,
                secureReady: self.whoop5SecureReady) else { return }
            self.failWhoop5SecureSession(sessionID, reason: "secure handshake stage timed out")
        }
        whoop5SecureStageTimeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.whoop5SecureStageTimeoutSeconds,
            execute: timeout)
    }

    /// One revocation path for every current-attempt handshake failure. Issued callback owners remain
    /// retired until their delayed callback or the matching physical disconnect consumes them.
    private func failWhoop5SecureSession(
        _ sessionID: Whoop5SecureSessionID,
        reason: String,
        reconnect: Bool = true
    ) {
        guard currentWhoop5SecureSessionID == sessionID else { return }
        whoop5SecureSession.fail(sessionID: sessionID)
        whoop5SecureStageTimeout?.cancel()
        whoop5SecureStageTimeout = nil
        whoop5SecureStageDeadlineID = nil
        whoop5NotifyRearmOffPending.removeAll()
        queuedWhoop5ConfirmedWrites.removeAll()
        invalidateHistoricalBackfill(reason: reason)
        whoop5R22Attempt = nil
        pendingWhoop5HapticResponses.removeAll()
        didBond = false
        connectHandshakeDone = false
        whoop5SessionStarted = false
        whoop5RealtimeArmed = false
        state.bonded = false
        state.encryptedBond = false
        state.syncChunksThisSession = 0
        historicalProgress.begin()
        state.historicalSyncSessionState = .failed
        state.lastSyncError = "Secure WHOOP session failed: \(reason). Reconnecting the strap."
        log("WHOOP 5/MG: \(reason); revoking generation \(connectGeneration)")
        if reconnect, let peripheral = self.peripheral, peripheral.state == .connected {
            central.cancelPeripheralConnection(peripheral)
        }
    }

    /// Clear every authorization-bearing flag before observers can see a replacement connection.
    private func admitConnectionGeneration(_ peripheral: CBPeripheral) {
        invalidateHistoricalBackfill(reason: "a newer BLE connection was admitted")
        let retiredGeneration = connectGeneration
        confirmedCommandWrites.removeAll {
            $0.peripheralID == peripheral.identifier && $0.connectGeneration == retiredGeneration
        }
        connectGeneration &+= 1
        historicalSourceEpoch &+= 1
        didBond = false
        connectHandshakeDone = false
        whoop5SessionStarted = false
        whoop5RealtimeArmed = false
        cmdNotifyConfirmedActive = false
        connectSettledSignaled = false
        state.bonded = false
        state.encryptedBond = false
        state.syncChunksThisSession = 0
        historicalProgress.begin()
        lastOffloadFrameAt = nil
        loggedWhoop5OffloadDeepPacket = false
        loggedWhoop5TrailingDeepPacket = false
        whoop5R22Attempt = nil
        pendingWhoop5HapticResponses.removeAll()
        queuedWhoop5ConfirmedWrites.removeAll()
        whoop5SecureStageTimeout?.cancel()
        whoop5SecureStageTimeout = nil
        whoop5SecureStageDeadlineID = nil
        whoop5NotifyRearmOffPending.removeAll()
        whoop5FrozenCommandCharacteristic = nil
        whoop5FrozenNotifyCharacteristics.removeAll()
        activeWhoop5ConfirmedWriteID = nil
        whoop5ConfirmedWriteTimeout?.cancel()
        whoop5ConfirmedWriteTimeout = nil
        if selectedModel.deviceFamily == .whoop5 {
            _ = whoop5SecureSession.acceptConnection(
                peripheralID: peripheral.identifier,
                connectGeneration: connectGeneration)
        } else {
            whoop5SecureSession.disconnect()
        }
    }

    nonisolated static func confirmedWritePurpose(
        command: WhoopCommand,
        isHistoricalAck: Bool
    ) -> ConfirmedWritePurpose {
        isHistoricalAck && command == .historicalDataResult ? .historicalAck : .genericCommand
    }

    nonisolated static func handshakeConfirmedWritePurpose(for family: DeviceFamily) -> ConfirmedWritePurpose {
        family == .whoop5 ? .clientHello : .bondHandshake
    }

    enum Whoop5ConnectedRefreshAction: Equatable, Sendable {
        case continueDiscovery
        case coalesceAttempt
        case refreshLiveOnly
        case reconnect
    }

    nonisolated static func whoop5ConnectedRefreshAction(
        for state: Whoop5SecureSessionState
    ) -> Whoop5ConnectedRefreshAction {
        switch state {
        case .standardOnly: .continueDiscovery
        case .clientHelloPending, .protectedNotificationsPending, .protocolProofPending: .coalesceAttempt
        case .secureReady: .refreshLiveOnly
        case .failed, .disconnected: .reconnect
        }
    }

    enum Whoop5InitialNotificationAction: Equatable, Sendable {
        case requestOffBeforeOn
        case requestOn
    }

    nonisolated static func whoop5InitialNotificationAction(
        isAlreadyNotifying: Bool
    ) -> Whoop5InitialNotificationAction {
        isAlreadyNotifying ? .requestOffBeforeOn : .requestOn
    }

    nonisolated static func shouldRevokeFrozenCharacteristic(
        hasFrozenInstance: Bool,
        isSameInstance: Bool
    ) -> Bool {
        hasFrozenInstance && !isSameInstance
    }

    nonisolated static func shouldFireWhoop5SecureDeadline(
        expectedSessionID: Whoop5SecureSessionID,
        currentSessionID: Whoop5SecureSessionID?,
        expectedDeadlineID: UUID,
        currentDeadlineID: UUID?,
        secureReady: Bool
    ) -> Bool {
        expectedSessionID == currentSessionID
            && expectedDeadlineID == currentDeadlineID
            && !secureReady
    }

    private func confirmedWritePurpose(for command: WhoopCommand) -> ConfirmedWritePurpose {
        Self.confirmedWritePurpose(command: command, isHistoricalAck: pendingHistoricalAck != nil)
    }

    /// One canonical CoreBluetooth write seam. WHOOP 5 callback ownership is registered only when the
    /// serial lane selects the operation for issue; a queued operation owns no CoreBluetooth callback.
    private func writeValue(
        _ data: Data,
        to characteristic: CBCharacteristic,
        on peripheral: CBPeripheral,
        type writeType: CBCharacteristicWriteType,
        confirmedPurpose: ConfirmedWritePurpose,
        command: UInt8 = 0,
        requestSequence: UInt8 = 0
    ) {
        if writeType == .withResponse {
            let owner = makeConfirmedCommandWrite(
                purpose: confirmedPurpose,
                peripheral: peripheral,
                characteristic: characteristic,
                command: command,
                requestSequence: requestSequence)
            if selectedModel.deviceFamily == .whoop5, characteristic.uuid == Self.whoop5CmdWriteChar {
                queuedWhoop5ConfirmedWrites.append(QueuedWhoop5ConfirmedWrite(
                    owner: owner,
                    data: data,
                    peripheral: peripheral,
                    characteristic: characteristic))
                issueNextWhoop5ConfirmedWriteIfPossible()
                return
            }
            confirmedCommandWrites.append(owner)
        }
        peripheral.writeValue(data, for: characteristic, type: writeType)
    }

    private func characteristicIdentity(for characteristic: CBCharacteristic) -> UUID {
        let key = ObjectIdentifier(characteristic)
        if let existing = characteristicIdentities[key] { return existing }
        let identity = UUID()
        characteristicIdentities[key] = identity
        return identity
    }

    /// Register complete operation ownership before a write can trigger its delegate callback.
    private func makeConfirmedCommandWrite(
        purpose: ConfirmedWritePurpose,
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        command: UInt8,
        requestSequence: UInt8
    ) -> ConfirmedCommandWrite {
        let historicalAck: HistoricalAckWriteIdentity?
        if purpose == .historicalAck,
           let pending = pendingHistoricalAck,
           pending.admission.peripheralID == peripheral.identifier,
           pending.characteristicUUID == characteristic.uuid,
           pending.admission.connectGeneration == connectGeneration {
            historicalAck = HistoricalAckWriteIdentity(
                admission: pending.admission,
                trim: pending.trim)
        } else {
            historicalAck = nil
        }
        return ConfirmedCommandWrite(
            id: UUID(),
            peripheralID: peripheral.identifier,
            characteristicUUID: characteristic.uuid,
            characteristicIdentity: characteristicIdentity(for: characteristic),
            connectGeneration: connectGeneration,
            secureAttemptEpoch: currentWhoop5SecureSessionID?.attemptEpoch,
            purpose: purpose,
            command: command,
            requestSequence: requestSequence,
            historicalAck: historicalAck)
    }

    private func issueNextWhoop5ConfirmedWriteIfPossible() {
        guard activeWhoop5ConfirmedWriteID == nil,
              let next = queuedWhoop5ConfirmedWrites.first else { return }
        guard let sessionID = currentWhoop5SecureSessionID,
              next.owner.peripheralID == sessionID.peripheralID,
              next.owner.connectGeneration == sessionID.connectGeneration,
              next.owner.secureAttemptEpoch == sessionID.attemptEpoch,
              next.characteristic === cmdCharacteristic else {
            queuedWhoop5ConfirmedWrites.removeFirst()
            issueNextWhoop5ConfirmedWriteIfPossible()
            return
        }
        activeWhoop5ConfirmedWriteID = next.owner.id
        queuedWhoop5ConfirmedWrites.removeFirst()
        confirmedCommandWrites.append(next.owner)
        next.peripheral.writeValue(next.data, for: next.characteristic, type: .withResponse)
        let operationID = next.owner.id
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.activeWhoop5ConfirmedWriteID == operationID else { return }
            let timedOutOwner = self.confirmedCommandWrites.first { $0.id == operationID }
            self.activeWhoop5ConfirmedWriteID = nil
            self.queuedWhoop5ConfirmedWrites.removeAll()
            if let timedOutOwner, timedOutOwner.command == 0x13 {
                self.pendingWhoop5HapticResponses.remove(timedOutOwner.requestSequence)
            }
            if let currentID = self.currentWhoop5SecureSessionID {
                self.failWhoop5SecureSession(currentID, reason: "confirmed write timed out")
            } else {
                self.invalidateHistoricalBackfill(reason: "WHOOP 5 confirmed write timed out")
                self.state.lastSyncError = "Secure session write timed out. Reconnecting the strap."
                if let peripheral = self.peripheral { self.central.cancelPeripheralConnection(peripheral) }
            }
        }
        whoop5ConfirmedWriteTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.whoop5ConfirmedWriteTimeout, execute: timeout)
    }

    /// CoreBluetooth can surface a delayed disconnect for a different peripheral while a newer link is
    /// already healthy. Do not let that callback tear down the current connection. A reused peripheral
    /// object is also ignored when CoreBluetooth reports it as connected again.
    nonisolated static func shouldApplyDisconnectEvent(
        eventPeripheralID: UUID,
        activePeripheralID: UUID?,
        activePeripheralIsConnected: Bool
    ) -> Bool {
        eventPeripheralID == activePeripheralID && !activePeripheralIsConnected
    }

    /// Non-disconnect CoreBluetooth callbacks are admitted only from the current live peripheral. A late
    /// callback from another strap must never decode into, bond, or ACK through the active strap's session.
    nonisolated static func shouldAcceptPeripheralCallback(
        eventPeripheralID: UUID,
        activePeripheralID: UUID?,
        activePeripheralIsConnected: Bool
    ) -> Bool {
        eventPeripheralID == activePeripheralID && activePeripheralIsConnected
    }

    private func isCurrentPeripheralCallback(_ candidate: CBPeripheral) -> Bool {
        Self.shouldAcceptPeripheralCallback(
            eventPeripheralID: candidate.identifier,
            activePeripheralID: peripheral?.identifier,
            activePeripheralIsConnected: peripheral?.state == .connected
        )
    }

    /// A reused `CBPeripheral` can report a callback from an earlier discovery pass. UUID equality is not
    /// enough in that case: only the characteristic object retained for the active session may mutate state.
    private func isCurrentCharacteristicCallback(_ candidate: CBCharacteristic) -> Bool {
        switch candidate.uuid {
        case Self.cmdWriteChar, Self.whoop5CmdWriteChar:
            return candidate === cmdCharacteristic
        case Self.cmdNotifyChar:
            return candidate === cmdNotifyCharacteristic
        case Self.eventNotifyChar:
            return candidate === eventNotifyCharacteristic
        case Self.dataNotifyChar:
            return candidate === dataNotifyCharacteristic
        case Self.heartRateChar:
            return candidate === heartRateCharacteristic
        case Self.batteryChar:
            return candidate === batteryCharacteristic
        default:
            return whoop5NotifyCharacteristics.contains { $0 === candidate }
        }
    }

    /// Characteristic discovery can also arrive late on a reused peripheral. Accept it only when the
    /// service object is still part of the active discovery result, so an old pass cannot replace the
    /// current session's characteristic identities.
    private func isCurrentServiceCallback(_ candidate: CBService, on peripheral: CBPeripheral) -> Bool {
        peripheral.services?.contains { $0 === candidate } == true
    }

    /// Confirmed-write callbacks do not include a CoreBluetooth connection generation. The queued write
    /// does, so reject a delayed callback from a prior connection even when iOS reuses the peripheral UUID.
    nonisolated static func shouldAcceptConfirmedWriteCallback(
        eventPeripheralID: UUID,
        eventCharacteristicUUID: CBUUID,
        activePeripheralID: UUID?,
        activePeripheralIsConnected: Bool,
        activeConnectGeneration: Int,
        queuedPeripheralID: UUID,
        queuedCharacteristicUUID: CBUUID,
        queuedConnectGeneration: Int
    ) -> Bool {
        shouldAcceptPeripheralCallback(
            eventPeripheralID: eventPeripheralID,
            activePeripheralID: activePeripheralID,
            activePeripheralIsConnected: activePeripheralIsConnected)
            && eventPeripheralID == queuedPeripheralID
            && eventCharacteristicUUID == queuedCharacteristicUUID
            && activeConnectGeneration == queuedConnectGeneration
    }

    /// Ack one HISTORY_END chunk so the strap may trim it. The durable scope, physical peripheral, and
    /// connect generation must still match the original admission. A successful `writeValue` call is not
    /// treated as an ACK: only `didWriteValueFor(..., error: nil)` confirms it.
    ///
    /// High-freq-sync ack form (matches re/sync_openwhoop.py, which pulled 762 type-47 records):
    /// HISTORICAL_DATA_RESULT(23) payload = `[0x01] + end_data`, where end_data is the verbatim
    /// 8 bytes of the HISTORY_END metadata.data[10:18] (trim u32 at [10:14] + next u32 at [14:18]).
    /// The `trim` argument (= end_data first u32) is already persisted as the strap_trim cursor by
    /// the Backfiller; it is passed here only for logging.
    func ackHistoricalChunk(
        scope: HistoricalCursorScope,
        trim: UInt32,
        endData: [UInt8]
    ) async -> Bool {
        guard let admission = admittedHistoricalBackfill,
              admission.scope == scope,
              isCurrentHistoricalBackfill(admission),
              let characteristic = cmdCharacteristic else {
            log("Backfill: refused historical ACK for stale or unadmitted scope \(scope.key), trim=\(trim)")
            return false
        }
        guard pendingHistoricalAck == nil else {
            log("Backfill: refused overlapping historical ACK for trim=\(trim)")
            return false
        }

        return await withCheckedContinuation { continuation in
            pendingHistoricalAck = PendingHistoricalAck(
                admission: admission,
                trim: trim,
                characteristicUUID: characteristic.uuid,
                continuation: continuation)
            let timeout = DispatchWorkItem { [weak self] in
                guard let self,
                      let pending = self.pendingHistoricalAck,
                      pending.admission == admission,
                      pending.trim == trim else { return }
                self.completePendingHistoricalAck(false, reason: "timed out waiting for CoreBluetooth confirmation")
            }
            historicalAckTimeout = timeout
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.historicalAckConfirmationTimeout,
                execute: timeout)
            send(.historicalDataResult, payload: [0x01] + endData, writeType: .withResponse)
        }
    }

    // MARK: Backfill helpers

    /// Start a historical-offload session: tell the store machine to begin, flip the routing
    /// flag, kick the strap with sendHistoricalData, and arm the idle timeout.
    @discardableResult
    private func beginBackfill(requiring requestOwnership: HistoricalSyncRequestOwnership) -> Bool {
        // Never offload before the connect handshake has run: a racing foreground/restore trigger
        // firing SEND_HISTORICAL ahead of hello/SET_CLOCK was part of the storm that stopped serving.
        guard connectHandshakeDone else {
            log("Backfill: deferred — connect handshake not done yet")
            return false
        }
        if selectedModel.deviceFamily == .whoop5, !whoop5SecureReady {
            log("Backfill: deferred — current WHOOP 5/MG secure proof is not ready")
            return false
        }
        guard requestOwnership.storeGeneration == historicalMaterializationStoreGeneration else {
            log("Backfill: deferred — history request belongs to a replaced store generation")
            return false
        }
        if selectedModel.deviceFamily == .whoop5 {
            guard let secureID = requestOwnership.secureSessionID,
                  secureID == currentWhoop5SecureSessionID,
                  whoop5SecureSession.authorizesProprietaryCommand(sessionID: secureID) else {
                log("Backfill: deferred — history request belongs to a replaced secure session")
                return false
            }
        }
        if let historicalRadioDeadline {
            let remaining = historicalRadioDeadline.remaining(at: ProcessInfo.processInfo.systemUptime)
            guard BackfillContinuation.hasMinimumUsefulRemainingRadioBudget(remaining) else {
                log("Backfill: continuation stopped — only \(Int(remaining.rounded(.down)))s of the radio budget remains; at least \(Int(BackfillContinuation.defaultMinimumUsefulRemainingRadioSeconds))s is required before another history command.")
                return false
            }
        }
        guard let backfiller else {
            // Store not built yet (bootstrapStore failed or hasn't run). Do NOT force live HR — the
            // type-47 backfill is the metric source. RE-ATTEMPT the bootstrap here so a transient
            // first-open failure self-heals: on iOS the data-protected store is unreadable while the
            // phone is locked, so a background-reconnect bootstrap can fail and, with no retry, stay
            // dead forever (#222). Each periodic tick now retries; the first one that runs after the
            // device is unlocked rebuilds the store and backfill proceeds. bootstrapStore() guards on
            // `collector == nil`, so this is a no-op once the store is up.
            log("Backfill: store not ready — re-attempting bootstrap, will retry next tick")
            Task { @MainActor in await self.bootstrapStore() }
            return false
        }
        guard let store = dataStore else {
            log("Backfill: registry store not ready — deferring historical admission")
            return false
        }
        guard let admittedPeripheral = peripheral,
              let admittedPeripheralUUID = connectedPeripheralUUID,
              admittedPeripheral.state == .connected,
              admittedPeripheral.identifier.uuidString == admittedPeripheralUUID else {
            log("Backfill: no current physical peripheral identity — deferring historical admission")
            return false
        }
        let admittedScope: HistoricalCursorScope
        do {
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            // SourceCoordinator eventually observes this same seam. Admission cannot wait for that
            // asynchronous publisher: bind the exact connected peripheral first, then resolve scope.
            try registry.setPeripheralId(deviceId, peripheralId: admittedPeripheral.identifier.uuidString)
            admittedScope = try registry.historicalCursorScope(for: deviceId)
        } catch {
            log("Backfill: failed to resolve durable cursor scope — deferring historical admission: \(error)")
            return false
        }
        // Capture the family at begin() (not init): selectedModel is reliably set by connect() before any
        // backfill starts, whereas bootstrapStore() can build the Backfiller before the family is known.
        // #42/#364: consecutiveAutoContinues > 0 means this offload is re-kicked after an EARLIER session in
        // the same burst banked rows — tell the backfiller so its no-cursor END reads as "caught up", not
        // "no banked history / charge to 100%". A fresh offload (count 0) keeps the honest guidance.
        let admittedSource = HistoricalReceiptWatermark.SourceIdentity(
            deviceId: admittedScope.deviceId,
            lineage: admittedScope.lineage,
            epoch: Int64(admittedScope.cursorEpoch),
            trimScope: admittedScope.trimScope)
        // Replacing an admission intentionally invalidates any suspended completion from the prior
        // session. It can remain committed, but it cannot ACK the new physical strap.
        invalidateHistoricalBackfill(reason: "historical session was replaced")
        historicalSessionGeneration &+= 1
        let secureID = requestOwnership.secureSessionID
        admittedHistoricalBackfill = HistoricalBackfillAdmission(
            scope: admittedScope,
            peripheralID: admittedPeripheral.identifier,
            connectGeneration: connectGeneration,
            secureSessionID: secureID,
            storeGeneration: historicalMaterializationStoreGeneration,
            sessionGeneration: historicalSessionGeneration)
        let whoop5Admission = secureID.map {
            Whoop5HistoricalSessionAdmission(
                peripheralID: $0.peripheralID,
                connectGeneration: $0.connectGeneration,
                attemptEpoch: $0.attemptEpoch)
        }
        guard backfiller.begin(
            family: selectedModel.deviceFamily,
            continuedAfterRows: historicalBurstPasses.productivePasses > 0,
            sourceIdentity: admittedSource,
            historicalCursorScope: admittedScope,
            whoop5Admission: whoop5Admission) else {
            invalidateHistoricalBackfill(reason: "secure-session ownership disappeared before history begin")
            return false
        }
        if historicalRadioDeadline == nil {
            historicalRadioDeadline = HistoricalRadioDeadline(
                startedAt: ProcessInfo.processInfo.systemUptime,
                budgetSeconds: BackfillContinuation.defaultMaxContinuousRadioSeconds
            )
        }
        historicalBurstPasses.startPass()
        historicalSessionInsertedSensorReceipt = false
        backfilling = true
        state.backfilling = true
        state.historicalSyncSessionState = .syncing
        historicalProgress.begin()
        state.syncChunksThisSession = 0
        state.rejectedFramesThisSession = 0
        state.rejectedFramesUnarchived = 0
        state.decodedChunksThisSession = 0
        state.consoleChunksThisSession = 0
        state.deepPacketsThisSession = 0
        loggedWhoop5OffloadDeepPacket = false
        loggedWhoop5TrailingDeepPacket = false
        historicalAckLogCounter = 0
        // Payload MUST be [0x00], NOT empty: verified on-device that this strap serves type-47 only with
        // [0x00] (empty → 0 frames on a clean stable link with ~2k records pending); the Mac ground-truth
        // offload (re/sync_openwhoop.py, re/diagnose_biometrics.py) uses [0x00] too. Plain offload — the
        // strap streams HISTORY_START → type-47 records → HISTORY_END (acked) … → HISTORY_COMPLETE.
        send(.sendHistoricalData, payload: [0x00], writeType: .withResponse)
        armBackfillTimeout()
        log("Backfill: session started — historical offload requested")
        return true
    }

    /// Feed a frame to the Backfiller preserving exact arrival order. Frames are appended
    /// synchronously (delegate order) and drained sequentially in small slices, so START /
    /// data / END chunk assembly is never reordered while the UI still gets time to paint.
    private func routeBackfillFrame(_ frame: [UInt8]) {
        let whoop5Admission: Whoop5HistoricalSessionAdmission?
        if selectedModel.deviceFamily == .whoop5 {
            guard let admission = admittedHistoricalBackfill,
                  isCurrentHistoricalBackfill(admission),
                  let secureID = admission.secureSessionID else {
                log("Backfill: ignored WHOOP 5 frame without current secure-session ownership")
                return
            }
            whoop5Admission = Whoop5HistoricalSessionAdmission(
                peripheralID: secureID.peripheralID,
                connectGeneration: secureID.connectGeneration,
                attemptEpoch: secureID.attemptEpoch)
        } else {
            whoop5Admission = nil
        }
        backfillFrameQueue.append(AdmittedBackfillFrame(bytes: frame, whoop5Admission: whoop5Admission))
        guard !backfillDraining else { return }
        backfillDraining = true
        Task { @MainActor in await drainBackfillFrames() }
    }

    private func drainBackfillFrames() async {
        while !backfillFrameQueue.isEmpty {
            let count = min(Self.backfillDrainBatchSize, backfillFrameQueue.count)
            let batch = Array(backfillFrameQueue.prefix(count))
            backfillFrameQueue.removeFirst(count)

            for admittedFrame in batch {
                if let admission = admittedFrame.whoop5Admission {
                    await backfiller?.ingest(admittedFrame.bytes, admittedBy: admission)
                } else {
                    await backfiller?.ingest(admittedFrame.bytes)
                }
                afterBackfillIngest()
                if !backfilling {
                    backfillFrameQueue.removeAll(keepingCapacity: true)
                    break
                }
            }

            if !backfillFrameQueue.isEmpty {
                await Task.yield()
            }
        }
        backfillDraining = false
    }

    /// Called after every Backfiller.ingest completes. If the Backfiller has consumed all
    /// historical data (isBackfilling drops to false), exit the backfill session cleanly.
    private func afterBackfillIngest() {
        guard backfilling, backfiller?.isBackfilling == false else { return }
        exitBackfilling(reason: "HISTORY_COMPLETE")
    }

    private func handleBackfillFailure(_ failure: BackfillFailure) {
        guard backfilling else { return }
        backfilling = false
        state.backfilling = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        invalidateHistoricalBackfill(reason: "historical backfill failed")
        state.historicalSyncSessionState = .failed
        historicalEmptyBackoff.record(freshProgress: false)
        historicalRadioDeadline = nil
        historicalBurstPasses.reset()
        startBackfillTimer()
        switch failure {
        case .acknowledgment:
            state.lastSyncError = "Live HR is connected, but history could not be confirmed. Tap Sync Now to retry; reconnect if it repeats."
        case .integrity:
            state.lastSyncError = "Live HR is connected, but a history packet failed verification. NOOP kept the strap data for a safe retry."
        case .fingerprint, .commit, .rejectedArchive:
            state.lastSyncError = "Live HR is connected, but history could not be saved. Tap Sync Now to retry."
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "sync.lastWriteStalledAt")
        log("Backfill: session failed — \(failure)")
    }

    /// True when a frame is part of the historical offload (HISTORICAL_DATA=47, EVENT=48,
    /// METADATA=49 / puffin METADATA=56, CONSOLE_LOGS=50) rather than the live stream (REALTIME_DATA=40,
    /// REALTIME_RAW_DATA=43). The live type-43 raw flood streams continuously and unprompted on
    /// this firmware, so the backfill idle-watchdog must NOT be re-armed by it — only by genuine
    /// offload progress — otherwise the session can neither complete nor time out.
    static func isOffloadFrame(_ frame: [UInt8], family: DeviceFamily) -> Bool {
        // The type byte sits at the inner-record start: frame[4] on WHOOP 4.0, frame[8] on WHOOP 5/MG
        // (the puffin envelope is 4 bytes longer). Reading frame[4] for a puffin frame misclassifies
        // EVERY offload frame as live-flood and routes nothing to the Backfiller.
        let typeIndex = family == .whoop5 ? 8 : 4
        guard frame.count > typeIndex else { return false }
        switch frame[typeIndex] {
        case 47, 48, 49, 50, 56: return true   // HISTORICAL_DATA / EVENT / METADATA / CONSOLE_LOGS
        default: return false              // 40 REALTIME_DATA, 43 REALTIME_RAW_DATA (live flood)
        }
    }

    /// Re-arm the idle watchdog. Called on every offload frame during backfill so the timer resets
    /// as long as the strap keeps sending HISTORY; if the strap goes silent the timer fires and we
    /// exit the session (the durable strap_trim cursor means the next session resumes where we left
    /// off). Timeout is generous (60 s, not 20 s): the unstoppable ~2/s type-43 raw flood eats BLE
    /// airtime, so genuine offload frames can arrive in bursts with multi-second lulls between chunks
    /// — a short watchdog cut sessions short mid-drain. Longer = more records drained per session.
    static let backfillIdleTimeoutSeconds = 60
    private func armBackfillTimeout() {
        backfillTimeout?.cancel()
        let sessionGeneration = historicalSessionGeneration
        let timeoutSeconds = historicalRadioDeadline?.sessionTimeout(
            at: ProcessInfo.processInfo.systemUptime,
            idleTimeout: TimeInterval(Self.backfillIdleTimeoutSeconds)
        ) ?? TimeInterval(Self.backfillIdleTimeoutSeconds)
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.backfilling,
                  self.historicalSessionGeneration == sessionGeneration else { return }
            self.backfiller?.timeoutFired()
            self.exitBackfilling(reason: timeoutSeconds <= 0 ? "deadline" : "timeout")
        }
        backfillTimeout = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int((timeoutSeconds * 1_000).rounded(.up))),
            execute: item
        )
    }

    /// Tear down the backfill session. Does NOT auto-start live HR: the periodic type-47 backfill
    /// is the primary metric source now, mirroring how WHOOP syncs. Live HR is opt-in only (the
    /// manual "Start HR" button in LiveView). Between backfills the Collector sees only the live
    /// type-43 flood, which extractStreams ignores — the data comes from the next periodic offload.
    private func exitBackfilling(reason: String) {
        guard backfilling else { return }
        backfilling = false
        state.backfilling = false
        if let visible = historicalProgress.flush(now: Date().timeIntervalSince1970) {
            state.syncChunksThisSession = visible
        }
        // #174: a backfill just ended. Start (or extend) the deep-packet cooldown from this instant so
        // any type-0x2F records the strap flushes in the seconds after the session aren't miscounted as
        // the live R22 stream — they're the offload's tail.
        lastOffloadFrameAt = Date()
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        log("Backfill: session ended — reason=\(reason)")
        // Inactivity reminder (#419): read-only hook on the natural offload completion (no cadence
        // change). Only on a true HISTORY_COMPLETE — a timeout/disconnect didn't bring a fresh window.
        if reason == "HISTORY_COMPLETE" { maybeBuzzInactivity() }
        // Success-side summary (#150 forensics): we logged failures (decoded-to-0) but never successes,
        // so a strap log couldn't tell a banking strap from a broken one. Emit the per-session persistence
        // tally whenever anything actually landed — the win-rate signal a log previously lacked.
        if let bf = backfiller,
           let summary = Backfiller.sessionSummaryLine(
               rows: bf.sessionRowsPersisted,
               motion: bf.sessionMotionRows,
               skinTemp: bf.sessionSkinTempRows,
               nights: bf.sessionNights,
               mappedRawRecords: bf.sessionMappedRawRecords) {
            log(summary)
            // #67: WHERE the rows landed + WHY (the clock ref that decoded them). A reset-RTC strap banks
            // last night into the past; this line makes the misdating self-evident in the strap log instead
            // of leaving "persisted N rows across 1 night(s)" looking like a clean sync.
            if let diag = Backfiller.sessionClockDiagLine(nightKeys: bf.sessionNightKeys,
                                                          device: bf.sessionClockDevice,
                                                          wall: bf.sessionClockWall,
                                                          usedIdentityRef: bf.sessionUsedIdentityRef) {
                log(diag)
            }
        }
        // Connection test mode: the offload OUTCOME the readout's lastOffloadResult id binds. Gated
        // zero-cost (the .connection bool is read before any string is built). Diagnostic only - it reads
        // the same per-session tallies the existing summary above does, changing no offload behaviour. A
        // timeout/idle-cap exit is a STALL; a HISTORY_COMPLETE with rows is a clean complete; with none it
        // is an empty (console-only) cycle.
        if TestCentre.active(.connection), let bf = backfiller {
            let rows = bf.sessionRowsPersisted
            let result: String
            if reason == "timeout" {
                result = "stalled (idle timeout, rows=\(rows) so far)"
            } else if reason == "HISTORY_COMPLETE" {
                result = rows > 0
                    ? "complete rows=\(rows) nights=\(bf.sessionNights)"
                    : "empty (console only, no sensor records)"
            } else {
                result = "\(reason) rows=\(rows)"
            }
            state.append(log: "offload result=\(result)", domain: .connection)
        }
        // #547 RE-POLLUTION: this session's ingest gate dropped bad-clock records, so the strap has a
        // wandering clock and may have banked similar garbage on an OLDER build whose gate was weaker. Arm
        // a heal re-run so the next analyze tick purges any such pollution — not gated behind the one-shot
        // done flag. Pure UserDefaults set (no engine handle here); IntelligenceEngine honours it next tick.
        let sessionRowsPersisted = backfiller?.sessionRowsPersisted ?? 0
        let freshProgressThisSession = historicalSessionInsertedSensorReceipt
            || (backfiller?.sessionMappedRawRecords ?? 0) > 0
        historicalBurstPasses.finishPass(freshSourceProgress: freshProgressThisSession)
        historicalEmptyBackoff.record(freshProgress: freshProgressThisSession)
        // Re-anchor the already-running periodic timer to the adaptive 15 -> 30 -> 60 minute floor.
        startBackfillTimer()
        let sessionDroppedImplausible = backfiller?.sessionDroppedImplausible ?? 0
        if sessionDroppedImplausible > 0 {
            IntelligenceEngine.requestTimestampReheal()
        }
        let progress = backfillBurstPublication.record(
            rowsPersisted: sessionRowsPersisted,
            requiresTimestampHeal: sessionDroppedImplausible > 0,
            latestFrontierUnix: backfiller?.sessionDurableMaxTs)
        if let progress {
            state.publishHistoricalSyncProgress(progress)
        }
        // #364 auto-continue spin-detector: did THIS session move the strap's trim cursor? Compare the
        // Backfiller's current high-water trim against where it stood when the previous session ended.
        // A frozen cursor (console-only / strap refusing to trim) ⇒ don't re-kick (it would spin forever).
        let currentTrim = backfiller?.lastAckedTrim
        let trimAdvanced = currentTrim != nil && currentTrim != lastSessionEndTrim
        lastSessionEndTrim = currentTrim
        // #324/#928: a strap whose newest banked record is dated in the FUTURE (RTC relatched ahead) is
        // future-dated regardless of HOW this offload ended — a deep future-dated backlog TIMES OUT as
        // readily as it completes (the reporter's #324 session ended on timeout, not HISTORY_COMPLETE).
        // Compute the banner once so BOTH outcomes name the real cause instead of "strap went quiet".
        let wallNowForBanner = Int(Date().timeIntervalSince1970)
        let futureClockBanner = BLEManager.futureDatedStrapBanner(
            strapNewestTs: strapNewestTs, wallNowUnix: wallNowForBanner)
        if futureClockBanner != nil {
            let aheadH = ((strapNewestTs ?? 0) - wallNowForBanner) / 3600
            log("Backfill: the strap's newest banked record is \(aheadH)h AHEAD of the wall clock (#324/#928) - clock set in the future; showing the future-clock banner and importing nothing from this range.")
        }
        // Honest sync outcome for a cloud-free user (mirrors Android exitBackfilling, ed6a31d):
        // HISTORY_COMPLETE stamps lastSyncedAt + clears any error; the idle-watchdog timeout surfaces
        // a non-silent error. A disconnect mid-sync bypasses this path (didDisconnectPeripheral resets
        // the flags directly) — that's not a sync failure, and the next connect re-offloads.
        if reason == "HISTORY_COMPLETE" {
            state.lastSyncedAt = Date().timeIntervalSince1970
            if let frontier = backfiller?.sessionDurableMaxTs {
                state.noteHistoricalDataFrontier(TimeInterval(frontier))
            }
            // #77 / #91: a sync that COMPLETED but discarded records must not read as a clean
            // "History synced" — the wording distinguishes bytes saved on this Mac from bytes the
            // full archive could not preserve, so "saved" is never claimed falsely.
            let archived = state.rejectedFramesThisSession
            let unarchived = state.rejectedFramesUnarchived
            // Classify this completed offload (pure, unit-tested in EmptyBankingClassifierTests).
            let mappedRawRecords = backfiller?.sessionMappedRawRecords ?? 0
            let banking = BLEManager.classifyCompletedOffload(
                decodedChunks: state.decodedChunksThisSession,
                archivedFrames: archived,
                unarchivedFrames: unarchived,
                consoleChunks: state.consoleChunksThisSession,
                rowsPersisted: (backfiller?.sessionRowsPersisted ?? 0) + mappedRawRecords)
            let bankedSensorRecords = banking.bankedSensorRecords
            // #42: the empty tail of an auto-continue burst (consecutiveAutoContinues > 0) isn't a "banked
            // nothing" sync — an EARLIER session in the same burst handed over real rows and this pass just
            // confirms we're caught up. Don't surface the "charge to 100%" framing, and don't count it toward
            // the sustained-empty streak (the productive session already cleared it).
            let productiveBurstTail = historicalBurstPasses.productivePasses > 0
            let bankedNothing = banking.bankedNothing && !productiveBurstTail
            let sustainedEmpty = productiveBurstTail ? false : emptySyncTracker.recordCompletedSync(
                bankedSensorRecords: bankedSensorRecords, consoleOnly: banking.bankedNothing)
            // #57 debug: write-health for the export. Distinguish "rows actually landed" from "an offload
            // STALLED on a persist failure" — the latter (usually a restore without a restart) is otherwise
            // invisible in a report that just shows "0 synced".
            let du = UserDefaults.standard
            if (backfiller?.sessionRowsPersisted ?? 0) + mappedRawRecords > 0 {
                du.set(Date().timeIntervalSince1970, forKey: "sync.lastWriteOkAt")
            }
            if backfiller?.persistStalled == true { du.set(Date().timeIntervalSince1970, forKey: "sync.lastWriteStalledAt") }
            if unarchived > 0 {
                state.lastSyncError = "Synced, but \(archived + unarchived) record(s) couldn't be decoded (unrecognised strap firmware layout), and the on-device archive is full - the \(unarchived) newest weren't preserved. Please share a strap log so the layout can be mapped."
            } else if archived > 0 {
                state.lastSyncError = "Synced, but \(archived) record(s) couldn't be decoded (unrecognised strap firmware layout). The raw bytes were saved on this Mac - please share a strap log so the layout can be mapped."
            } else if bankedNothing {
                // #77 / #214 family: the offload COMPLETED but the strap handed over no sensor records
                // at all — either console/diagnostic output across many chunks, OR a near-empty
                // metadata-only completion (zero rows persisted) — i.e. it isn't banking history to
                // flash (its RTC has lost sync). Only escalate to the actionable banner once emptiness
                // is SUSTAINED (#126): a single empty cycle on an otherwise-banking strap stays silent.
                let detail = state.consoleChunksThisSession >= 3
                    ? "console-only across \(state.consoleChunksThisSession) chunks"
                    : "metadata-only, 0 sensor rows persisted"
                log("Backfill: completed but the strap banked no sensor history (\(detail)); consecutive empty syncs = \(emptySyncTracker.consecutiveEmptySyncs).")
                state.lastSyncError = sustainedEmpty
                    ? "Synced, but your strap had no stored history to hand over - only its diagnostic output. This usually means its clock has lost sync, so it isn't saving data to flash. Fully charge it to 100%, then reconnect, and it should start banking again."
                    : nil
            } else if let futureBanner = futureClockBanner {
                // #324/#928: the strap banked records but its newest is dated implausibly in the FUTURE
                // (RTC relatched ahead). #773 drops the future-dated samples so nothing is misfiled, but
                // the "banked something" path above would otherwise report a clean sync and leave the
                // user with no data and no reason. Name the real cause + the strap-side remedy.
                state.lastSyncError = futureBanner
            } else {
                state.lastSyncError = nil
            }
            // #580: a 5/MG that reaches a real HISTORY_COMPLETE with banked sensor records proves its
            // history offload IS working — clear the experimental note + empty streak so the home state
            // stops saying "history sync experimental".
            if selectedModel.deviceFamily == .whoop5, bankedSensorRecords {
                whoop5EmptyOffload.reset()
                state.historySyncExperimental = false
            }
            UserDefaults.standard.set(state.lastSyncedAt, forKey: "lastSyncedAt")
            state.historicalSyncSessionState = .completed
            // NOTE: the auto-continue streak is NOT reset here. A HISTORY_COMPLETE is no longer assumed to
            // mean "caught up" (#25): a strap whose firmware segments a deep offload into many small
            // HISTORY_COMPLETE slices would otherwise reset the streak on every slice and never engage the
            // bounded per-connection cap. The streak is cleared only once shouldAutoContinue proves we're actually
            // caught up — inside maybeAutoContinueBackfill's else path, fired below for BOTH exit reasons.
        } else if reason == "timeout" {
            // #580: distinguish a genuine WHOOP-4 "strap went quiet mid-sync" from a WHOOP 5/MG whose
            // firmware acks SEND_HISTORICAL_DATA but never emits a single type-0x2F offload frame. The
            // 5/MG case isn't a failure — live HR is streaming fine over 0x2A37, the history offload is
            // just experimental/empty on that firmware. "Banked" = this offload made ANY offload progress
            // (chunks acked, rows persisted, or deep packets seen); an empty 5/MG offload has none.
            let bankedThisOffload = historicalProgress.acknowledged > 0
                || (backfiller?.sessionRowsPersisted ?? 0) > 0
                || (backfiller?.sessionMappedRawRecords ?? 0) > 0
                || state.deepPacketsThisSession > 0
            if selectedModel.deviceFamily == .whoop5 {
                let crossed = whoop5EmptyOffload.recordOffload(bankedRecords: bankedThisOffload)
                if whoop5EmptyOffload.historyEmpty {
                    // Honest home state (#580): NOT a sync error — connected + live HR, history experimental.
                    state.historySyncExperimental = true
                    state.lastSyncError = nil
                    state.historicalSyncSessionState = .ready
                    if crossed {
                        log("Backfill: WHOOP 5/MG offload empty \(whoop5EmptyOffload.consecutiveEmpty)× — history sync is experimental on 5.0; surfacing 'connected, history experimental' (not a sync error) and backing off the bounce loop.")
                    }
                } else {
                    // Either the first empty cycle (could be the strap waking flash — stay quiet, don't
                    // cry failure) OR a banking offload that just cleared the streak (recovery — drop the
                    // experimental note). Both want a clean, error-free state.
                    state.historySyncExperimental = false
                    state.lastSyncError = nil
                    state.historicalSyncSessionState = bankedThisOffload ? .ready : .failed
                }
            } else {
                // #324/#928: a future-dated strap TIMES OUT on its deep future-dated backlog — that's not
                // "the strap went quiet", it's the clock being set ahead. Prefer the honest future-clock
                // banner so the reporter's timeout case (the common one) names the real cause + remedy.
                state.lastSyncError = futureClockBanner
                    ?? "Sync interrupted - the strap went quiet. It will retry on the next sync."
                state.historicalSyncSessionState = .failed
            }
        }
        checkStrapLiveness()         // safety-net: strap ahead of us AND our frontier frozen ⇒ stuck?
        // #364 / #25: a session that ended on the 60s IDLE cap OR on a true HISTORY_COMPLETE while still
        // connected, with more backlog to fetch and the trim still advancing, immediately re-kicks another
        // offload instead of tearing down to wait the 15-min floor — so a deep oldest-first backlog drains
        // in back-to-back ~60s passes rather than one-per-15-min. #25: fire on HISTORY_COMPLETE too — some
        // straps segment a deep overnight offload into many small HISTORY_COMPLETE slices and would
        // otherwise stall between slices until the periodic floor. The pure shouldAutoContinue guards make
        // this safe: a genuinely caught-up strap (newest within behindGapSeconds of the frontier and 0 rows)
        // returns false and stops; that else path is also where the consecutive streak is cleared. Bounded
        // by the consecutive-cap and the spin-detector inside the pure predicate either way.
        if reason == "timeout" || reason == "deadline" || reason == "HISTORY_COMPLETE" {
            maybeAutoContinueBackfill(
                trimAdvanced: trimAdvanced,
                freshSourceProgress: freshProgressThisSession,
                acknowledgedTrim: currentTrim,
                acknowledgedFingerprint: backfiller?.sessionLastAckedFingerprint,
                cursorScope: backfiller?.historicalCursorScope
            )
        } else {
            publishBackfillBurstIfNeeded()
        }
    }

    /// Emit a data-availability edge only after the full burst stops. `lastSyncedAt` remains reserved for
    /// formal `HISTORY_COMPLETE`, so an idle-timeout with durable rows refreshes the dashboard without
    /// lying that the strap finished syncing.
    private func recordHistoricalCommit(_ context: HistoricalCommitContext) {
        backfillBurstPublication.record(receipt: context.receipt)
        if context.receipt.decodedRows.total > 0 {
            // `onHistoricalCommitContext` fires only for a newly inserted receipt. Therefore a new
            // duplicate-only sensor receipt advances this source, while an exact receipt replay never
            // reaches this branch and console-only metadata has zero decoded rows.
            historicalSessionInsertedSensorReceipt = true
        }

        // A productive commit may resume after didDisconnectPeripheral already finalized and cleared the
        // burst. Finalize again at the receipt boundary so durable work cannot strand behind a dead drain.
        if !backfilling {
            publishBackfillBurstIfNeeded()
        }
    }

    /// Resume bounded deferred V20/V21 work after bootstrap and after an ACK-confirmed insert. One task
    /// drains at most four jobs per pass. Wake-ups received during that pass coalesce into one follow-up
    /// pass, and a full productive batch keeps draining older durable backlog. An all-retryable batch
    /// stops until a later external wake. Materialization never blocks the BLE notification, SQLite
    /// commit, or ACK path.
    private var currentHistoricalMaterializationOwnership: HistoricalMaterializationOwnership {
        HistoricalMaterializationOwnership(
            storeGeneration: historicalMaterializationStoreGeneration,
            workerGeneration: historicalMaterializationWorkerGeneration
        )
    }

    private func ownsHistoricalMaterialization(
        store: WhoopStore,
        ownership: HistoricalMaterializationOwnership
    ) -> Bool {
        !restoreInProgress
            && dataStore === store
            && currentHistoricalMaterializationOwnership == ownership
    }

    private func wakeHistoricalMaterializationAfterAcknowledgment(
        receipt: HistoricalDataCommitReceipt,
        outcome: HistoricalCommitOutcome,
        store: WhoopStore
    ) async {
        let ownership = currentHistoricalMaterializationOwnership
        guard ownsHistoricalMaterialization(store: store, ownership: ownership) else { return }
        let dueCheck = historicalMaterializationDueCheck
        let due = await dueCheck(store, receipt.receiptId)
        guard ownsHistoricalMaterialization(store: store, ownership: ownership),
              HistoricalMaterializationWakeState.shouldWakeAfterAcknowledgment(
                receipt: receipt,
                outcome: outcome,
                due: due
              ) else { return }
        scheduleHistoricalMaterialization(on: store, requiring: ownership)
    }

    /// Explicit UI recovery entry point after a quarantined job has been reset. This wakes the same
    /// coalescing scheduler used by bootstrap and ACK callbacks; it does not create a second pipeline.
    func wakeHistoricalMaterializationForRecovery() {
        guard let store = dataStore else { return }
        scheduleHistoricalMaterialization(
            on: store,
            requiring: currentHistoricalMaterializationOwnership
        )
    }

    private func scheduleHistoricalMaterialization(
        on store: WhoopStore,
        requiring ownership: HistoricalMaterializationOwnership? = nil
    ) {
        let admittedOwnership = ownership ?? currentHistoricalMaterializationOwnership
        guard ownsHistoricalMaterialization(store: store, ownership: admittedOwnership) else { return }
        historicalMaterializationRetryTask?.cancel()
        historicalMaterializationRetryTask = nil
        guard historicalMaterializationWake.request() else { return }
        startHistoricalMaterializationPass(
            on: store,
            storeGeneration: admittedOwnership.storeGeneration
        )
    }

    private func startHistoricalMaterializationPass(
        on store: WhoopStore,
        storeGeneration: Int
    ) {
        guard !restoreInProgress,
              dataStore === store,
              historicalMaterializationStoreGeneration == storeGeneration else {
            historicalMaterializationWake.cancel()
            return
        }
        // A completion and a new wake can cross while their MainActor jobs are queued. The wake state
        // already owns the follow-up; never trap or replace the task that currently owns this slot.
        if historicalMaterializationTask != nil {
            guard historicalMaterializationTaskOwnership != nil else {
                historicalMaterializationWake.cancel()
                return
            }
            return
        }
        historicalMaterializationWorkerGeneration &+= 1
        let workerGeneration = historicalMaterializationWorkerGeneration
        let ownership = HistoricalMaterializationOwnership(
            storeGeneration: storeGeneration,
            workerGeneration: workerGeneration
        )
        let run = historicalMaterializationRun
        historicalMaterializationTaskOwnership = ownership
        historicalMaterializationTask = Task.detached(priority: .utility) { [weak self, weak store] in
            var requestDrainFollowUp = false
            defer {
                Task { @MainActor [weak self, weak store, requestDrainFollowUp] in
                    guard let self, let store,
                          self.ownsHistoricalMaterialization(
                            store: store,
                            ownership: ownership
                          ),
                          self.historicalMaterializationTaskOwnership == ownership else { return }
                    self.historicalMaterializationTask = nil
                    self.historicalMaterializationTaskOwnership = nil
                    if requestDrainFollowUp {
                        _ = self.historicalMaterializationWake.request()
                    }
                    if self.historicalMaterializationWake.finish() {
                        self.startHistoricalMaterializationPass(
                            on: store,
                            storeGeneration: ownership.storeGeneration
                        )
                    }
                }
            }
            guard !Task.isCancelled, let store else { return }
            guard await MainActor.run(body: { [weak self] in
                self?.ownsHistoricalMaterialization(store: store, ownership: ownership) == true
            }) else { return }
            do {
                let result = try await run(store)
                guard !Task.isCancelled else { return }
                requestDrainFollowUp = HistoricalMaterializationWakeState.shouldRequestDrainFollowUp(
                    hasMoreDueWork: result.hasMoreDueWork,
                    completed: result.completed,
                    quarantined: result.quarantined
                )
                let fallbackNextAttemptAt: Int?
                if result.nextAttemptAt == nil {
                    fallbackNextAttemptAt = try? await store.nextHistoricalMaterializationAttemptAt()
                } else {
                    fallbackNextAttemptAt = nil
                }
                if let nextAttemptAt = HistoricalMaterializationWakeState.nextRetryAttempt(
                    resultAttemptAt: result.nextAttemptAt,
                    storeAttemptAt: fallbackNextAttemptAt
                ) {
                    await MainActor.run { [weak self, weak store] in
                        guard let self, let store,
                              self.ownsHistoricalMaterialization(
                                store: store,
                                ownership: ownership
                              ) else { return }
                        let delay = max(0, nextAttemptAt - Int(Date().timeIntervalSince1970))
                        self.historicalMaterializationRetryTask?.cancel()
                        self.historicalMaterializationRetryTask = Task { @MainActor [weak self, weak store] in
                            try? await Task.sleep(for: .seconds(delay))
                            guard !Task.isCancelled, let self, let store,
                                  self.ownsHistoricalMaterialization(
                                    store: store,
                                    ownership: ownership
                                  ) else { return }
                            self.scheduleHistoricalMaterialization(
                                on: store,
                                requiring: ownership
                            )
                        }
                    }
                }
                guard result.claimed > 0 else { return }
                await MainActor.run { [weak self] in
                    self?.log(
                        "Backfill: deferred mapped-raw materialization claimed \(result.claimed), "
                        + "completed \(result.completed), retryable \(result.retryable), "
                        + "quarantined \(result.quarantined)."
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.log("Backfill: deferred mapped-raw materialization paused: \(error)")
                }
            }
        }
    }

    private func publishBackfillBurstIfNeeded() {
        guard let finalization = backfillBurstPublication.consumeFinalization() else { return }
        state.finalizeHistoricalSyncBurst(
            at: Date().timeIntervalSince1970,
            watermark: finalization.watermark)
        if let watermark = finalization.watermark {
            let scopes = watermark.coordinates.map {
                "\($0.databaseInstanceId)/\($0.sourceIdentity.deviceId)#\($0.sourceIdentity.lineage)#\($0.sourceIdentity.epoch)/\($0.sourceIdentity.trimScope) through \($0.throughGeneration)"
            }.joined(separator: ", ")
            log("Backfill: durable history is ready for source scopes [\(scopes)]; scheduling one dashboard refresh.")
        } else {
            log("Backfill: durable history is ready after the sync burst; scheduling one dashboard refresh.")
        }
    }

    /// #364 / #25: evaluate (and, if warranted, fire) an immediate back-to-back backfill after a 60s
    /// idle-cap exit OR a HISTORY_COMPLETE. The "more backlog remains" test needs our persisted data
    /// receipt-backed frontier (normalized or mapped raw), which only the Collector can read, so this hops
    /// onto a Task exactly like
    /// `checkStrapLiveness`. The decision itself is the pure `BackfillContinuation.shouldAutoContinue` so it
    /// stays unit-testable; this method only gathers the inputs, bumps the counter (or clears it on the
    /// caught-up else path — see #25), and re-kicks via the SAME gated requestSync path (so it still
    /// respects connected/bonded and can't double-start). The `.autoContinue` trigger ⇒
    /// the BackfillPolicy 15-min floor is bypassed for this expedited continuation (the cap is the guard).
    /// `trimAdvanced` is the spin-detector signal computed in exitBackfilling (did this session move the
    /// trim cursor vs the previous one) — passed in because exitBackfilling has already advanced
    /// `lastSessionEndTrim` past the comparison point by the time this Task runs.
    private func maybeAutoContinueBackfill(
        trimAdvanced: Bool,
        freshSourceProgress: Bool,
        acknowledgedTrim: UInt32?,
        acknowledgedFingerprint: String?,
        cursorScope: HistoricalCursorScope?
    ) {
        // Cheap pre-checks first (no Task if we already know we won't continue): still connected, under
        // the cap, and the trim moved. The frontier read only happens when those already hold.
        guard state.connected, state.bonded else {
            historicalRadioDeadline = nil
            historicalBurstPasses.reset()
            publishBackfillBurstIfNeeded()
            return
        }
        let newest = strapNewestTs
        let totalPasses = historicalBurstPasses.totalPasses
        let workerConnectGeneration = connectGeneration
        let workerSessionGeneration = historicalSessionGeneration
        Task { @MainActor in
            guard !Task.isCancelled,
                  connectGeneration == workerConnectGeneration,
                  historicalSessionGeneration == workerSessionGeneration,
                  state.connected, state.bonded else { return }
            let scopedFrontier: HistoricalSourceFrontier?
            if let cursorScope, let store = dataStore {
                if let databaseInstanceId = try? await store.databaseInstanceId(),
                   let durable = try? await store.latestHistoricalDurableFrontier(
                    databaseInstanceId: databaseInstanceId,
                    scope: cursorScope
                   ) {
                    scopedFrontier = HistoricalSourceFrontier(
                        scope: HistoricalReceiptWatermark.Scope(
                            databaseInstanceId: databaseInstanceId,
                            sourceIdentity: HistoricalReceiptWatermark.SourceIdentity(
                                deviceId: cursorScope.deviceId,
                                lineage: cursorScope.lineage,
                                epoch: Int64(cursorScope.cursorEpoch),
                                trimScope: cursorScope.trimScope
                            )
                        ),
                        normalizedMaxTs: durable.normalizedMaxTs,
                        mappedRawMaxTs: durable.mappedRawMaxTs
                    )
                } else {
                    scopedFrontier = nil
                }
            } else {
                scopedFrontier = nil
            }
            guard !Task.isCancelled,
                  connectGeneration == workerConnectGeneration,
                  historicalSessionGeneration == workerSessionGeneration else { return }
            let frontier = scopedFrontier?.maxTs
            let signature = acknowledgedTrim.flatMap { trim in
                acknowledgedFingerprint.flatMap { fingerprint in
                    scopedFrontier.flatMap { scoped in
                        scoped.maxTs.map {
                        HistoricalPassSignature(
                            scope: scoped.scope,
                            trim: trim,
                            fingerprint: fingerprint,
                            durableFrontierTs: $0
                        )
                        }
                    }
                }
            }
            let signatureRepeated = signature != nil && signature == lastHistoricalPassSignature
            if let signature { lastHistoricalPassSignature = signature }
            let remainingRadioSeconds = historicalRadioDeadline?.remaining(
                at: ProcessInfo.processInfo.systemUptime
            ) ?? 0
            let wallNow = Int(Date().timeIntervalSince1970)   // #928: real wall clock, at decision time
            let stillConnected = state.connected && state.bonded
            guard BackfillContinuation.shouldAutoContinue(
                stillConnected: stillConnected,
                strapNewestTs: newest,
                ourFrontierTs: frontier,
                wallNowUnix: wallNow,
                rowsPersistedThisSession: freshSourceProgress ? 1 : 0,
                lastTrimAdvanced: trimAdvanced,
                passSignatureRepeated: signatureRepeated,
                continuousRadioSeconds: BackfillContinuation.defaultMaxContinuousRadioSeconds
                    - remainingRadioSeconds,
                totalPasses: totalPasses) else {
                // #1012: name the stop honestly when the future-clock gate is what ended the chain —
                // without this line the log just goes quiet after one pass and a strap-log export can't
                // tell "caught up" from "future-dated range refused". Fires ONLY when 2b would otherwise
                // have continued (still connected, rows banked, trim advanced, under the cap), so a
                // frozen-trim / cap / disconnect stop is never misattributed to the clock.
                if stillConnected, freshSourceProgress, trimAdvanced,
                   totalPasses < BackfillContinuation.defaultMaxTotalPasses,
                   BackfillContinuation.isFutureDatedNewest(newest, wallNowUnix: wallNow) {
                    let aheadH = ((newest ?? wallNow) - wallNow) / 3600
                    log("Backfill: not auto-continuing (#1012) - the strap-reported newest banked record reads \(aheadH)h AHEAD of the wall clock, so the range is future-dated and the strap clock is likely wrong (#928). Stopping after one pass instead of chasing future-dated ranges; the periodic sync keeps draining across connects.")
                }
                // No re-kick. THIS is the real "we're done draining" signal (#25): clear the auto-continue
                // streak so the NEXT deep backlog (e.g. after the app's been off again) gets a fresh budget
                // of re-kicks. Reset here — NOT unconditionally on every HISTORY_COMPLETE — so a strap that
                // slices one offload into many completions can't keep resetting the cap and spin forever.
                // EXCEPTION: if we stopped because the per-connection CAP is hit, leave the streak at/over
                // the cap so it STAYS engaged for the rest of this connection (the 15-min floor takes over);
                // zeroing it here would immediately re-arm the cap and let a runaway strap spin again.
                if totalPasses < BackfillContinuation.defaultMaxTotalPasses {
                    historicalBurstPasses.reset()
                }
                historicalRadioDeadline = nil
                self.publishBackfillBurstIfNeeded()
                return
            }
            // Guard against a race: a real backfill may already have re-started (periodic/connect) in the
            // gap before this Task ran. requestSync's own gate (!backfilling) handles that, but skip the
            // log/counter churn if so.
            guard !backfilling else { return }
            let remainingBeforeStart = historicalRadioDeadline?.remaining(
                at: ProcessInfo.processInfo.systemUptime
            ) ?? 0
            guard BackfillContinuation.hasMinimumUsefulRemainingRadioBudget(
                remainingBeforeStart
            ) else {
                historicalRadioDeadline = nil
                historicalBurstPasses.reset()
                publishBackfillBurstIfNeeded()
                return
            }
            log("Backfill: auto-continuing (#364/#451) — the trim advanced and the strap is still handing over real records (frontier \(frontier.map(String.init) ?? "?"), strap-reported newest \(newest.map(String.init) ?? "?")); starting pass \(totalPasses + 1)/\(BackfillContinuation.defaultMaxTotalPasses) without waiting the 15-min floor.")
            // .autoContinue bypasses the BackfillPolicy floor (the whole point — don't wait 15 min);
            // requestSync still re-checks connected/bonded/not-backfilling before kicking, and the
            // consecutive-cap above is the runaway guard.
            requestSync(.autoContinue)
            if !backfilling {
                // The continuation could not start (for example, the store is briefly unavailable).
                // The raw rows from the just-ended session are still durable and must not wait for a
                // future clean completion before becoming visible.
                publishBackfillBurstIfNeeded()
                historicalRadioDeadline = nil
                historicalBurstPasses.reset()
            }
        }
    }

    /// On-device archive for HISTORICAL_DATA record frames that failed decode (#77 / #91).
    private let rejectedHistoryArchive = RawHistoryArchive()

    /// Durably archive undecodable record frames (append-only JSONL, fsynced) BEFORE the Backfiller
    /// acks the trim — the user's only remaining copy of an unmapped firmware's records once the
    /// strap frees them, and the corpus a later layout mapping re-ingests. Updates the session
    /// counters that drive the honest sync status. Returns false ONLY on a genuine write failure,
    /// which makes the Backfiller hold the cursor/ack so the strap re-sends the chunk (no data loss
    /// either way). Frames carry sensor payloads, not identifiers — no serials/MACs are archived.
    private func archiveRejectedFrames(_ frames: [[UInt8]], trim: UInt32, family: DeviceFamily) -> Bool {
        switch rejectedHistoryArchive.archive(frames, trim: trim, family: family) {
        case .written(let count):
            state.rejectedFramesThisSession += count
            return true
        case .capReached(let count):
            // Cap reached: succeed WITHOUT writing (wedging the offload over a full archive would be
            // worse; ample sample bytes exist by now), counted separately so the sync status never
            // claims "saved" for bytes that were not.
            state.rejectedFramesUnarchived += count
            log("Backfill: rejected-frame archive is FULL — \(count) frame(s) NOT preserved (acking anyway so the offload can finish)")
            return true
        case .failed:
            log("Backfill: rejected-frame archive FAILED — holding ack so the strap re-sends")
            return false
        }
    }

    /// After an offload, judge liveness: stuck = strap reports records newer than our frontier AND our
    /// frontier (max persisted HR ts) hasn't advanced for the detector window. Off-wrist / caught up
    /// (strap not ahead) is NOT stuck. On stuck: attempt recovery (defensive EXIT + SET_CLOCK) and raise
    /// the surface. Best-effort; reads the frontier via the Collector (which owns the concrete store).
    private func checkStrapLiveness() {
        let strapNewest = strapNewestTs
        Task { @MainActor in
            let frontier = await collector?.latestHRSampleTs()
            let front: Int? = frontier ?? nil
            let now = Date().timeIntervalSince1970
            let stuck = stuckDetector.observe(strapNewestTs: strapNewest,
                                              ourFrontierTs: front,
                                              now: now)
            state.strapNeedsReboot = stuck
            if stuck {
                log("Watchdog: behind + frontier frozen — recovery (exit high-freq + SET_CLOCK)")
                send(.exitHighFreqSync, payload: [0x00])
                sendSetClockBothForms()
            }
        }
    }

    /// Pure decision: should the periodic timer kick off another historical offload? Only when
    /// connected + bonded and NOT already mid-backfill. Extracted so the gate is unit-testable
    /// without a CoreBluetooth seam. Note this intentionally does NOT consult `backfillStarted`
    /// (that flag guards the once-per-connect INITIAL kick); the periodic re-trigger is separate.
    static func shouldRunPeriodicBackfill(connected: Bool, bonded: Bool, backfilling: Bool) -> Bool {
        connected && bonded && !backfilling
    }

    /// Pure classification of a COMPLETED (HISTORY_COMPLETE) offload, extracted from exitBackfilling so
    /// it's unit-testable without a CoreBluetooth seam (EmptyBankingClassifierTests).
    /// - `bankedSensorRecords`: the strap handed over real sensor records — decoded, or
    ///   undecodable-but-archived (either way its clock is banking to flash).
    /// - `bankedNothing` (#77/#120/#214): the offload completed but banked NO sensor records at all,
    ///   in EITHER shape — console-only across ≥3 diagnostic chunks, OR a near-empty metadata-only
    ///   completion (zero rows persisted) with fewer than 3 console frames. The #214 broadening is the
    ///   `rowsPersisted == 0` arm: before it, a metadata-only completion slipped through silently. The
    ///   sustained-streak gate (EmptySyncTracker) still decides whether the banner fires.
    nonisolated static func classifyCompletedOffload(decodedChunks: Int, archivedFrames: Int,
                                                     unarchivedFrames: Int, consoleChunks: Int,
                                                     rowsPersisted: Int)
        -> (bankedSensorRecords: Bool, bankedNothing: Bool) {
        let bankedSensorRecords = decodedChunks > 0 || archivedFrames > 0 || unarchivedFrames > 0
        let bankedNothing = !bankedSensorRecords && (consoleChunks >= 3 || rowsPersisted == 0)
        return (bankedSensorRecords, bankedNothing)
    }

    /// #324/#928: the post-sync banner for a strap whose clock is set in the FUTURE. Unlike the
    /// "clock lost / not banking" case (`bankedNothing`), this strap DOES bank records every pass — but
    /// its RTC relatched to a future base, so every banked timestamp reads ahead of the wall clock and
    /// NOOP won't import them (importing would misfile the night days or years ahead). The existing
    /// clock-lost banner is gated on empty syncs and never fires here, so this failure mode was silent
    /// (#324). Returns the user-facing string when the strap-reported newest record is future-dated
    /// beyond the 48 h skew allowance (`BackfillContinuation.isFutureDatedNewest`), else nil. Pure and
    /// deterministic — one detection is decisive (nothing legitimate banks 48 h ahead), so no streak
    /// gate is needed. Mirrors Android `futureDatedStrapBanner`.
    nonisolated static func futureDatedStrapBanner(strapNewestTs: Int?, wallNowUnix: Int) -> String? {
        guard BackfillContinuation.isFutureDatedNewest(strapNewestTs, wallNowUnix: wallNowUnix) else { return nil }
        return "Synced, but your strap's clock is set in the future - its banked history is dated ahead of "
            + "today, so NOOP can't trust those timestamps and didn't import them (importing them would "
            + "misfile your data days or years ahead). Fully charge the strap to 100% and power-cycle it so "
            + "its clock re-syncs, then reconnect."
    }

    /// Start (or restart) the periodic backfill timer. Each tick re-runs the type-47 historical
    /// offload while connected+bonded and not already backfilling — the primary metric sync.
    // MARK: - Keep-alive (always-ping + liveness watchdog)

    /// Enable live HR and remember we want it re-armed by keep-alive.
    /// Some WHOOP firmware acknowledges TOGGLE_REALTIME_HR but only emits usable live samples once
    /// the R10/R11 realtime stream is also on. Keep that stream scoped to the Live tab and stop it
    /// on disappear so it does not permanently compete with historical offload.
    public func startRealtime() {
        screenWantsRealtime = true
        state.liveFeedActive = true   // drives the menu-bar Start/Stop label off the real intent
        // The user explicitly (re-)asked for the full stream by opening Live / tapping Start HR — give the
        // heavy R10/R11 burst another chance even if a prior marginal-radio fallback had tripped. If the
        // radio still can't take it, the detector will simply trip again. (#80) This is screen-only intent;
        // the continuous-capture path does NOT reset the fallback (it's a passive background want).
        marginalRadio.reset()
        standardHRFallback = false
        state.standardHRMode = nil
        enableLiveNotifications(reason: "start realtime")
        send(.sendR10R11Realtime, payload: [0x01])   // the heavy burst rides alongside the toggle on Live
        reconcileRealtime()                          // arms TOGGLE_REALTIME_HR(1) on the off→on edge
        realtimeArmedAt = Date()       // start the arm→drop stopwatch for the marginal-radio detector
    }
    /// Stop the Live-tab realtime streams. The lightweight 0x2A37 HR keeps recording if firmware emits it.
    /// The TOGGLE only actually disarms if the continuous-capture preference no longer wants it either —
    /// the reconciler sends it on the on→off edge of the combined want, so a Live screen closing while
    /// continuous capture is on keeps the dense stream flowing.
    public func stopRealtime() {
        screenWantsRealtime = false
        state.liveFeedActive = false   // flip the menu-bar toggle back to "Start live feed"
        // Always stop the heavy R10/R11 burst when the Live screen leaves — it's the battery-hungry part
        // and is only ever wanted while a live screen is up. The lightweight TOGGLE/0x2A37 R-R stream is
        // what continuous capture keeps; the reconciler decides whether to disarm that.
        send(.sendR10R11Realtime, payload: [0x00])
        reconcileRealtime()
    }

    /// The "Continuous HRV capture" preference flipped: hold the realtime stream open with no Live screen
    /// visible (true) or release it (false), then reconcile. Driven from the app model. Mirrors the
    /// Android `setKeepStreamForData`. #927: also called with the UNCHANGED preference when "overnight
    /// only" flips, purely to re-run the reconciler with the fresh window gate.
    public func setKeepRealtimeForData(_ keep: Bool) {
        keepRealtimeForData = keep
        reconcileRealtime()
    }

    /// #477 (Settings): battery-% at/below which the offload cadence stretches while discharging (0 = off).
    /// Recompute the absolute next-attempt deadline now. A live sync in flight is never interrupted.
    public func setLowBatteryOffloadThrottle(_ thresholdPct: Int) {
        lowBatteryOffloadPct = thresholdPct
        startBackfillTimer()
    }

    /// #477 (Settings): pause the background continuous-HRV stream when the strap is low. Keyed on the
    /// STRAP's battery like the offload lever — pass the same threshold; engages at/below it (0 = off).
    /// Reconciles now.
    public func setPauseCaptureOnPowerSave(_ enabled: Bool, thresholdPct: Int) {
        pauseCaptureBatteryPct = enabled ? thresholdPct : 0
        reconcileRealtime()
    }


    /// #477: the connected STRAP's (battery-%, isCharging) — WHOOP, and the same for Oura/Fitbit. Power
    /// saving keys off the strap, not the phone, because the levers reduce how much the STRAP transmits
    /// (fewer offloads, no continuous stream) and so extend the strap's life when it wasn't charged in
    /// time. Unknown (disconnected / not yet read) → (100, false), so it fails SAFE (never throttles
    /// without a real low reading; a disconnected strap has nothing to throttle anyway).
    private func batteryPctAndCharging() -> (pct: Int, charging: Bool) {
        (state.batteryPct.map { Int($0.rounded()) } ?? 100, state.charging == true)
    }

    /// Whether the current strap/settings snapshot selects the 45-minute periodic floor.
    private func periodicPowerSavingActive() -> Bool {
        guard lowBatteryOffloadPct > 0 else { return false }
        let (pct, charging) = batteryPctAndCharging()
        return BLEManager.lowPowerThrottleActive(
            batteryPct: pct, charging: charging, thresholdPct: lowBatteryOffloadPct)
    }

    /// LiveState calls this only when battery percentage or charging state actually changes. Recomputing
    /// against the persisted last-attempt time makes both threshold crossings take effect immediately.
    private func installPowerStateScheduling() {
        state.onSyncPowerStateChange = { [weak self] in
            self?.startBackfillTimer()
        }
    }

    /// #927: the continuous-capture side of the realtime want, window-gated. True while the "Continuous
    /// HRV capture" preference wants the stream held open AND, when "overnight only" is on, the local
    /// wall clock sits inside the nightly window (the reused quiet-hours window, 22:00 → 07:00 by
    /// default). RE-DERIVED at every arm site (reconcile / keep-alive tick / post-bond arm) instead of
    /// precomputed, so a reconnect outside the window can never arm the flood from a stale value.
    /// Mirrors the Android `continuousCaptureWantsNow`.
    private func continuousCaptureWantsNow(now: Date = Date()) -> Bool {
        guard keepRealtimeForData else { return false }
        // #477: while the STRAP's battery is low (≤ threshold, discharging), release the held-open
        // background stream — via the shared lowPowerThrottleActive gate. A Live screen still arms it via
        // screenWantsRealtime (checked separately in reconcileRealtime). The keep-alive re-derives this,
        // so it re-arms automatically once the strap is charged.
        if pauseCaptureBatteryPct > 0 {
            let (pct, charging) = batteryPctAndCharging()
            if BLEManager.lowPowerThrottleActive(batteryPct: pct, charging: charging,
                                                 thresholdPct: pauseCaptureBatteryPct) {
                return false
            }
        }
        let comps = Calendar.current.dateComponents([.hour, .minute], from: now)
        let minuteOfDay = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        let d = UserDefaults.standard
        return ContinuousHrvSchedule.streamWanted(
            continuousHrv: true,
            overnightOnly: PuffinExperiment.continuousHrvOvernightOnlyEnabled,
            minuteOfDay: minuteOfDay,
            startMin: d.object(forKey: ContinuousHrvSchedule.quietStartKey) as? Int ?? ContinuousHrvSchedule.defaultStartMinutes,
            endMin: d.object(forKey: ContinuousHrvSchedule.quietEndKey) as? Int ?? ContinuousHrvSchedule.defaultEndMinutes)
    }

    /// Single reconciler for the realtime-HR TOGGLE. The stream should be armed while EITHER a screen
    /// wants it (`screenWantsRealtime`) OR the continuous-capture preference wants it
    /// (`keepRealtimeForData`, window-gated by #927 overnight-only via `continuousCaptureWantsNow()`).
    /// We arm (TOGGLE_REALTIME_HR 1) / disarm (TOGGLE_REALTIME_HR 0) ONLY on the
    /// false↔true edge of that derived want — so a Live screen closing while the preference still wants
    /// it does NOT disarm, and turning the preference off with no screen open DOES disarm. The toggle only
    /// reaches the strap once it's a WHOOP4 (custom channels open immediately) or a bonded 5/MG (puffin
    /// framing); otherwise the want is remembered and the post-bond branch arms it. Mirrors the Android
    /// `reconcileRealtime`.
    private func reconcileRealtime() {
        let want = screenWantsRealtime || continuousCaptureWantsNow()
        wantsRealtime = want   // keep-alive + post-bond arm-on-connect read this derived value
        guard want != realtimeArmed else { return }                      // no edge — nothing to send
        guard selectedModel.deviceFamily == .whoop4 || whoop5SecureReady else { return }
        realtimeArmed = want
        send(.toggleRealtimeHR, payload: [want ? 0x01 : 0x00])
    }

    /// EXPERIMENTAL R22 telemetry (#174): give the user (and us) live proof of what the strap is doing.
    /// (1) Every `COMMAND_RESPONSE` (type 0x24) to a `SET_CONFIG` (0x78) is the strap ACKing one
    ///     `enable_r22_*` flag — hardware-confirmed in sebastianwoo's capture. 15 ACKs = full acceptance.
    /// (2) A type-0x2F record arriving OUTSIDE our own history offload is NOT a separate live stream.
    ///     #494 showed these are historical-offload data: they appear when a SECOND BLE client pulls
    ///     the strap's history (`SendHistoricalData`) — the burst scales with the disconnect/backlog
    ///     time, not wall-clock — and the SET_CONFIG `enable_r22_*` sequence (accepted 15/15) starts no
    ///     separate stream. type-0x2F is only ever the historical offload (confirmed across #344's v20/v21
    ///     captures too). We still surface these as a diagnostic, but as what they are — another client's
    ///     backlog reaching us over the shared notify channel — not a live R22 "unlock".
    /// Frame layout (5/MG puffin envelope): packet_type @ byte 8, the responded-to cmd @ byte 10.
    ///
    /// #174 cooldown: when our own offload ENDS, the strap can keep flushing a few trailing type-0x2F
    /// records AFTER `backfilling` has already flipped false. So we stamp `lastOffloadFrameAt` on every
    /// offload frame (and at HISTORY_COMPLETE) and skip a non-offload 0x2F within
    /// `deepPacketLiveCooldownSeconds` of it. The flag-ACK counting (1) is unchanged.
    private func noteWhoop5R22Telemetry(_ frame: [UInt8], duringOffload: Bool) {
        // R22 deep-data is a WHOOP 5/MG concept only. On a WHOOP 4 a type-0x2F frame is something else
        // entirely, so counting it as a "deep packet" gave 4.0 owners a bogus deep-data counter (#346).
        guard selectedModel.deviceFamily == .whoop5 else { return }
        guard frame.count > 10 else { return }
        if frame[8] == 0x2F {
            if duringOffload {
                // Trailing-history reference point: a 0x2F arriving during the offload is banked
                // history (handled by the Backfiller). Remember when it landed so the cooldown below
                // can discount the few that dribble in just after the session ends.
                lastOffloadFrameAt = Date()
                if !loggedWhoop5OffloadDeepPacket {
                    loggedWhoop5OffloadDeepPacket = true
                    log("Deep-data: validated type-0x2F records arrived during NOOP's current history offload; this is history, not a separate live stream.")
                }
                return
            }
            // Cooldown guard: a 0x2F within deepPacketLiveCooldownSeconds of our own last offload
            // frame/HISTORY_COMPLETE is a trailing historical record from that session.
            if let last = lastOffloadFrameAt,
               Date().timeIntervalSince(last) < BLEManager.deepPacketLiveCooldownSeconds {
                if !loggedWhoop5TrailingDeepPacket {
                    loggedWhoop5TrailingDeepPacket = true
                    log("Deep-data: validated type-0x2F records arrived as trailing history after NOOP's offload; this is not a separate live stream.")
                }
                return
            }
            // A 0x2F outside our offload is historical-offload data, not a live R22 stream (#494) —
            // typically another BLE client pulling the strap's backlog over the shared notify channel.
            // Surface it as a diagnostic, but don't claim a live-stream "unlock".
            state.deepPacketsThisSession += 1
            if state.deepPacketsThisSession == 1 {
                log("Deep-data: validated type-0x2F records arrived through another client's history pull; this is not a separate live R22 stream (#494).")
            } else if state.deepPacketsThisSession.isMultiple(of: 50) {
                log("Deep-data: \(state.deepPacketsThisSession) type-0x2F historical-offload frames seen outside our session.")
            }
        }
    }

    /// EXPERIMENTAL (#174): write the official app's `enable_r22_*` SET_CONFIG sequence to a bonded
    /// WHOOP 5/MG, to switch on the deep biometric (type-0x2F "R22") streams the strap withholds from a
    /// fresh third-party connection. The exact 15-flag sequence + values are documented by judes.club
    /// and Asherlc/dofek and built byte-for-byte by `Whoop5Config` (golden-frame unit-tested).
    ///
    /// Safety: only ever runs when the deep-data experiment is explicitly opted in AND the strap is a
    /// bonded, worn 5/MG. The R22 stream is on-wrist gated, so an off-wrist strap is refused with a hint.
    /// Each flag is one `.setConfig` write WITH RESPONSE, spaced ~80 ms (the official app pauses between
    /// writes). Reversible — it only changes which data the strap emits. After it runs, the user should
    /// wear + sync and share their strap log so we can confirm the deeper records start flowing.
    public func enableWhoop5DeepData() {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Deep-data: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        guard PuffinExperiment.deepDataEnabled else {
            log("Deep-data: the deep-data experiment is off — enable it in Settings → Experimental first."); return
        }
        guard state.connected, whoop5SecureReady, let sessionID = currentWhoop5SecureSessionID else {
            // The R22 SET_CONFIG writes go over the encrypted command channel, so the live-HR-only
            // shortcut (`bonded` true, `encryptedBond` false on a 5/MG still owned by the official app,
            // #69/#266) can't carry them. Require the genuine bond, or the writes silently fail (#269).
            log("Deep-data: needs the full encrypted bond, not the live-HR-only link. Close the official WHOOP app, put the strap in pairing mode, and bond it to NOOP first — ignored."); return
        }
        guard state.worn else {
            log("Deep-data: the R22 stream is on-wrist only — put the strap ON, then try again."); return
        }
        state.r22FlagsAccepted = 0
        whoop5R22Attempt = Whoop5R22Attempt(sessionID: sessionID)
        let frames = Whoop5Config.enableR22Sequence
        log("Deep-data: sending the \(frames.count)-flag enable_r22 sequence (experimental, reversible)…")
        for (i, flag) in frames.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * i)) { [weak self] in
                guard let self,
                      self.currentWhoop5SecureSessionID == sessionID,
                      self.whoop5SecureReady else { return }
                self.send(.setConfig,
                          payload: [0x01] + Whoop5Config.payloadBody(name: flag.name, value: flag.value),
                          writeType: .withResponse,
                          responseLabel: flag.name)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80 * frames.count + 200)) { [weak self] in
            self?.log("Deep-data: sequence sent. Keep the strap on, let it sync, then share your strap log — we're looking for new deep records (type-0x2F) to start arriving. (#174)")
        }
    }

    /// EXPERIMENTAL (#181): make a bonded WHOOP 5/MG advertise its heart rate as a standard BLE HR
    /// sensor (0x180D + the live HR in its manufacturer data) by writing the device-config flag
    /// `whoop_live_hr_in_adv_ind_pkt` = "1" (on) / "0" (off) via SET_DEVICE_CONFIG (0x77). With it on, a
    /// Garmin (Edge/watch), Zwift or gym HR client can pair to the WHOOP directly during a workout.
    /// Validated on real hardware (paired on a Garmin Edge 840). Opt-in, reversible; unlike R22 it is NOT
    /// on-wrist gated. Re-applied on each 5/MG connection. iOS/Android only (macOS can't bond a 5/MG).
    public func setBroadcastHr(_ on: Bool) {
        guard selectedModel.deviceFamily == .whoop5 else {
            log("Broadcast HR: needs a WHOOP 5.0/MG strap selected — ignored."); return
        }
        guard state.connected, whoop5SecureReady else {
            log("Broadcast HR: current WHOOP 5/MG secure session is not ready — ignored."); return
        }
        let value: UInt8 = on ? 0x31 : 0x30   // ASCII '1' / '0'
        send(.setDeviceConfig,
             payload: [0x01] + Whoop5Config.deviceConfigBody(name: "whoop_live_hr_in_adv_ind_pkt", value: value),
             writeType: .withResponse)
        log("Broadcast HR: wrote whoop_live_hr_in_adv_ind_pkt=\(on ? "1" : "0")")
    }

    /// Read the strap's current BLE advertising name (WHOOP 4.0 / Harvard). The reply lands as a
    /// GET_ADVERTISING_NAME COMMAND_RESPONSE and FrameRouter publishes it to `LiveState.advertisingName`.
    /// Also sent automatically in the connect handshake; this is the manual refresh the Settings card
    /// fires after a rename. No-op on a 5/MG (the Harvard name command isn't part of its framing).
    public func requestAdvertisingName() {
        guard selectedModel.deviceFamily == .whoop4 else {
            log("Strap name: WHOOP 4.0 only — ignored on a 5/MG."); return
        }
        guard state.connected else { log("Strap name: not connected — ignored."); return }
        send(.getAdvertisingNameHarvard, payload: [0x00])
    }

    /// Rename the strap's BLE advertising name (WHOOP 4.0 / Harvard) via SET_ADVERTISING_NAME (cmd 77).
    /// Writes `[0x00,0x00] + UTF-8 name + [0x00]` (see `WhoopCommand.advertisingNamePayload`) over the
    /// confirmed command channel; the strap reboots to apply, so the new name appears on the next connect
    /// (the connect handshake re-reads it). The result ack is surfaced via `LiveState.renameStatus`.
    /// WHOOP 4.0 only — a 5/MG uses puffin framing and a different device-config path. Reversible.
    public func renameStrap(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard selectedModel.deviceFamily == .whoop4 else {
            state.renameStatus = "Renaming is WHOOP 4.0 only."
            log("Strap rename: WHOOP 4.0 only — ignored on a 5/MG."); return
        }
        guard state.connected, state.bonded else {
            state.renameStatus = "Connect and pair your strap first."
            log("Strap rename: connect + bond first — ignored."); return
        }
        guard !name.isEmpty else {
            state.renameStatus = "Enter a name first."; return
        }
        state.renameStatus = "Renaming…"
        send(.setAdvertisingNameHarvard,
             payload: WhoopCommand.advertisingNamePayload(name),
             writeType: .withResponse)
        log("Strap rename: wrote advertising name=\(name.debugDescription)")
        // Re-read shortly after so the card reflects the change if the strap applies it without dropping
        // the link; if it reboots instead, the connect handshake re-reads the name on reconnect anyway.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(2)) { [weak self] in
            self?.requestAdvertisingName()
        }
        // Timeout so the card can't hang on "Renaming…" forever. Some WHOOP 4.0 firmware never returns the
        // SET_ADVERTISING_NAME COMMAND_RESPONSE that clears this status (it just reboots, or swallows the
        // command) — the reporter on #428 sat on a permanent "Renaming…". If nothing has updated the status
        // by now, surface an honest fallback instead of an endless spinner. A real ack or the reconnect
        // re-read overwrites this the moment it arrives.
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(8)) { [weak self] in
            guard let self, self.state.renameStatus == "Renaming…" else { return }
            self.state.renameStatus = "Rename sent - reconnect your strap to confirm the new name."
            self.log("Strap rename: no ack within 8s — firmware may apply it on reboot/reconnect.")
        }
    }

    // MARK: Reboot (user-initiated, confirmation-gated) — see docs/PROTOCOL.md "Destructive commands"

    /// Monotonic timestamp of the last user-requested reboot, or nil. Set when `rebootStrap()` sends the
    /// command; consumed by `didDisconnectPeripheral` (to log how long the link stayed up = the strap acting
    /// on the reboot) and by the connect handshake (to log the reconnect round-trip). Cleared on reconnect
    /// or by the no-disconnect timeout. The whole point is a self-contained strap-log trail for a reboot,
    /// so a "restart did nothing" report — especially on the unverified 5/MG framing — is triageable.
    private var rebootRequestedAt: DispatchTime?
    private var rebootTimeoutWork: DispatchWorkItem?
    private var rebootSettleWork: DispatchWorkItem?

    /// Clear all reboot-in-flight state: the pending timestamp, both timers, and the `rebootInProgress`
    /// flag that drives the Devices "Reconnecting…" pill. Called from every terminal path (reconnect,
    /// no-disconnect, settle backstop) so the pill can never wedge.
    private func clearRebootState() {
        rebootRequestedAt = nil
        rebootTimeoutWork?.cancel(); rebootTimeoutWork = nil
        rebootSettleWork?.cancel(); rebootSettleWork = nil
        if state.rebootInProgress { state.rebootInProgress = false }
    }

    /// Restart the connected strap (REBOOT_STRAP / opcode 29, empty body). Non-destructive: the strap keeps
    /// its stored data and re-advertises after boot, but the BLE link drops and NOOP auto-reconnects. Gated
    /// to a connected + bonded strap; user-initiated and confirmation-gated at the call site (DevicesView).
    ///
    /// Emits a full debug trail to the strap log so a reboot is diagnosable end to end:
    ///   `reboot: request …`  — family / firmware / link state at send time
    ///   `reboot: sent …`     — opcode, framing (harvard-crc8 vs puffin-crc16), payload, seq
    ///   `reboot: strap acked result=0x…` — the COMMAND_RESPONSE (FrameRouter), the accept/reject signal
    ///                                        that caught 5/MG haptics rejection (result=0x03)
    ///   `reboot: link dropped …` — didDisconnectPeripheral, proves the strap acted
    ///   `reboot: no disconnect within …` — strap ignored it (esp. an unverified 5/MG frame)
    ///   `reboot: reconnected …` — the connect handshake, round-trip complete
    public func rebootStrap() {
        // Production Restart: opcode 29 REBOOT_STRAP, empty body per the official app's builder
        // (rh0.C45476d0). Confirmed on WHOOP 5.0 (#227); ignored on 4.0 (#235 — see rebootProbe).
        sendRebootFrame(command: .rebootStrap, payload: [], probe: nil)
    }

    /// Send one candidate reboot frame from the WHOOP 4.0 reboot probe (Test Centre → Connection).
    /// WHOOP 4.0 only — a 5.0 already reboots on the production frame (#227), so there is nothing to
    /// probe there. Reuses the full reboot watchdog/trail, so the strap log shows whether THIS candidate
    /// dropped the link (`reboot: link dropped …` = it worked) or was ignored (`reboot: no disconnect
    /// within 12s …`). Confirmation-gated at the call site (DevicesView). See `RebootProbeVariant`.
    public func rebootProbe(_ variant: RebootProbeVariant) {
        guard selectedModel.deviceFamily == .whoop4 else {
            log("reboot: probe is WHOOP 4.0 only — ignored (family=\(selectedModel.deviceFamily))")
            return
        }
        sendRebootFrame(command: variant.command, payload: variant.payload, probe: variant)
    }

    /// Shared reboot send + debug trail + watchdog, used by both the production `rebootStrap()` and the
    /// 4.0 `rebootProbe(_:)`. `probe == nil` is the normal restart; a non-nil variant is a probe attempt
    /// (its `logTag` is stamped first so the strap log correlates the attempt with what the strap did).
    private func sendRebootFrame(command: WhoopCommand, payload: [UInt8], probe: RebootProbeVariant?) {
        let family = selectedModel.deviceFamily
        guard state.connected, state.bonded, let p = peripheral, p.state == .connected else {
            log("reboot: connect + bond first — ignored (connected=\(state.connected) bonded=\(state.bonded))")
            return
        }
        guard family != .whoop5 || whoop5SecureReady else {
            log("reboot: WHOOP 5/MG secure session is not ready — ignored")
            return
        }
        // Supersede any still-pending reboot (cancels its timers + resets the flag) so a repeat tap can't
        // leave a stale watchdog/settle timer that fires during this new reboot's window.
        clearRebootState()
        // The logged opcode is always the command's on-wire value — never a separate field that could
        // disagree with the bytes actually sent.
        let opcode = Int(command.rawValue)
        let framing = family == .whoop5 ? "puffin-crc16 (verified on 5.0 fw 50.40.1.0)" : "harvard-crc8 (UNVERIFIED on 4.0)"
        let fw = state.strapFirmware ?? "unknown"
        let payloadDesc = payload.isEmpty ? "empty" : payload.map { String(format: "%02x", $0) }.joined()
        if let probe { log("reboot: PROBE \(probe.logTag) — trying an unconfirmed WHOOP 4.0 reboot frame (#235)") }
        log("reboot: request family=\(family) fw=\(fw) connected=true bonded=true")
        log("reboot: sent opcode=\(opcode) framing=\(framing) payload=\(payloadDesc) writeType=withResponse")
        // .withResponse so the write itself is acknowledged at the ATT layer before the strap drops the link.
        send(command, payload: payload, writeType: .withResponse)
        rebootRequestedAt = .now()
        // Drive the Devices "Reconnecting…" pill: true from here until the strap reconnects (or a terminal
        // path clears it). The pill only shows it once the link actually drops (it gates on !connected).
        state.rebootInProgress = true
        // No-disconnect watchdog: if the link is still up after 12 s the strap didn't act on the command —
        // the key signal that a 5/MG puffin reboot frame was silently rejected. A real reboot drops within
        // ~1-2 s when idle; a strap mid-offload finishes the transfer first (observed ~9 s on 5.0
        // fw 50.40.1.0), so 12 s is the cutoff, not the expected latency. Cancelled by
        // didDisconnectPeripheral when the reboot takes.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.rebootRequestedAt != nil, self.state.connected else { return }
            self.log("reboot: no disconnect within 12s — strap may have ignored the command"
                     + (self.selectedModel.deviceFamily == .whoop5 ? " (5/MG reboot is verified on 5.0 fw 50.40.1.0; if your firmware differs, please share this log on #166)" : " (the WHOOP 4.0 reboot frame is NOT confirmed yet — please share this log on #235)"))
            self.clearRebootState()
        }
        rebootTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(12), execute: work)
        // Absolute settle backstop: if the reboot never resolves (link dropped but the strap never comes
        // back), clear the pill after 60 s so it can't wedge on "Reconnecting…". A normal reboot+reconnect
        // completes well inside this and clears it earlier via noteRebootReconnectIfNeeded.
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.state.rebootInProgress else { return }
            self.log("reboot: not settled within 60s — clearing the reconnecting state")
            self.clearRebootState()
        }
        rebootSettleWork = settle
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(60), execute: settle)
    }

    /// Closes the reboot trail: when the connect handshake completes and a reboot was in flight, log the
    /// full round-trip (send → reboot → reconnect) and clear the pending state. No-op otherwise.
    private func noteRebootReconnectIfNeeded() {
        guard let t = rebootRequestedAt else { return }
        let s = Double(DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1_000_000_000
        log(String(format: "reboot: reconnected %.1fs after send — round trip complete", s))
        clearRebootState()   // clears the "Reconnecting…" pill → back to "Active · Live"
    }

    private func startKeepAlive() {
        keepAliveTimer?.cancel()
        let s = BLEManager.keepAliveIntervalSeconds
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .seconds(s), repeating: .seconds(s))
        t.setEventHandler { [weak self] in self?.keepAliveFire() }
        t.resume()
        keepAliveTimer = t
    }

    private func keepAliveFire() {
        guard state.connected, didBond else { return }
        enableLiveNotifications(reason: "keepalive")
        // Liveness watchdog: if NOTHING has arrived for a while, the stream/link stalled.
        // Bounce the connection — the auto-rescan on disconnect re-bonds and resumes streaming.
        // #580: a known history-empty 5/MG (firmware serves no offload) gets a far longer fuse. The
        // standard 0x2A37 HR profile keeps the link genuinely alive, but its packets can lull for >120s
        // when the strap is off-wrist / resting, and an empty offload leaves the data channel quiet — so
        // the old 120s rule disconnected/rescanned a perfectly healthy link every ~2 min (the thrash this
        // fixes). A WHOOP 4 (real "not recording" path) keeps the tight 120s fuse unchanged.
        let bounceFuse: TimeInterval =
            (selectedModel.deviceFamily == .whoop5 && whoop5EmptyOffload.historyEmpty) ? 600 : 120
        if Date().timeIntervalSince(lastDataAt) > bounceFuse {
            log("No data for >\(Int(bounceFuse))s — bouncing link to resume streaming")
            invalidateHistoricalBackfill(reason: "the liveness watchdog is reconnecting the link")
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            return
        }
        guard !backfilling else { return }            // never poke the strap mid-offload
        // #927: continuous capture can be overnight-only, which makes the want TIME-dependent; nothing
        // else re-evaluates it while the app just sits connected, so the keep-alive tick re-derives it.
        // A window-close tick DISARMS (stop the heavy R10/R11 burst, then the reconciler sends TOGGLE 0
        // on the true→false edge; the same stop shape as stopRealtime). A window-open tick re-arms on
        // the false→true edge. Ticks with no transition cost one predicate evaluation. This runs BEFORE
        // the WHOOP4-only guard below so a 5/MG stream also disarms/re-arms on the window edges (send()
        // routes the 5/MG toggle and drops the WHOOP4-framed R10/R11 stop for it).
        let captureWantNow = screenWantsRealtime || continuousCaptureWantsNow()
        if wantsRealtime != captureWantNow, keepRealtimeForData, !screenWantsRealtime {
            if captureWantNow {
                log("Continuous HRV: overnight window opened; arming the realtime stream (#927)")
            } else {
                send(.sendR10R11Realtime, payload: [0x00])   // stop the heavy burst, like stopRealtime
                log("Continuous HRV: overnight window closed; realtime stream disarmed until tonight (#927)")
            }
        }
        reconcileRealtime()   // recomputes wantsRealtime from the fresh predicate; toggles only on an edge
        // The command pings below are WHOOP4-framed; a 5/MG link drops them at the send() guard, so
        // skip them for 5/MG (it keeps the experimental strap log clean — re-subscribe + the 120s
        // bounce above are what keep a 5/MG link healthy).
        guard selectedModel.deviceFamily == .whoop4 else { return }
        // Never re-arm the heavy R10/R11 burst once the marginal-radio fallback has tripped (#80) — that
        // would just re-trigger the drop the keep-alive is meant to prevent. 0x2A37 keeps the HR flowing.
        if wantsRealtime && !standardHRFallback {
            realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the re-arm
            send(.sendR10R11Realtime, payload: [0x01])
            send(.toggleRealtimeHR, payload: [0x01])
        }   // re-arm so it can't lapse
        keepAliveTick += 1
        if keepAliveTick % 2 == 0 { send(.getBatteryLevel, payload: []) }  // ~every 60s
    }

    private func startBackfillTimer(minimumDelaySeconds: TimeInterval = 0) {
        guard state.connected, state.bonded, !restoreInProgress else {
            backfillTimer?.cancel()
            backfillTimer = nil
            backfillTimerDeadlineAt = nil
            return
        }

        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        let powerSaving = periodicPowerSavingActive()
        // A due timer normally fires immediately. If its attempt just failed a transient gate, the caller
        // supplies a small retry floor so an overdue absolute deadline cannot form a zero-delay loop.
        let delay = BackfillPolicy.periodicDelaySeconds(
            now: now,
            lastBackfillAt: last,
            powerSaving: powerSaving,
            emptyStreak: historicalEmptyBackoff.consecutiveEmpty,
            minimumDelaySeconds: minimumDelaySeconds)
        let deadline = now + delay
        if backfillTimer != nil,
           let existing = backfillTimerDeadlineAt,
           abs(existing - deadline) < 0.001 {
            return
        }

        backfillTimer?.cancel()
        let delayMilliseconds = Int((delay * 1_000).rounded(.up))
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + .milliseconds(delayMilliseconds))
        t.setEventHandler { [weak self] in
            self?.backfillTimerDeadlineAt = nil
            self?.triggerPeriodicBackfill()
        }
        t.resume()
        backfillTimer = t
        backfillTimerDeadlineAt = deadline
    }

    /// The single gated entry point for every historical-offload kick. Applies the connection/state
    /// gate AND the BackfillPolicy rate-limiter for the trigger. On a go: records the attempt time
    /// (persisted) and starts the offload.
    @discardableResult
    func requestSync(_ trigger: BackfillTrigger) -> Bool {
        guard !restoreInProgress else { return false }
        let requestOwnership = HistoricalSyncRequestOwnership(
            secureSessionID: selectedModel.deviceFamily == .whoop5 ? currentWhoop5SecureSessionID : nil,
            storeGeneration: historicalMaterializationStoreGeneration)
        if selectedModel.deviceFamily == .whoop5 {
            guard let secureID = requestOwnership.secureSessionID,
                  whoop5SecureSession.authorizesProprietaryCommand(sessionID: secureID) else {
                log("Backfill: (trigger) refused before admission — current WHOOP 5/MG secure proof is not ready")
                return false
            }
        }
        guard BLEManager.shouldRunPeriodicBackfill(
            connected: state.connected, bonded: state.bonded, backfilling: backfilling) else { return false }
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.object(forKey: BLEManager.backfillLastAtKey) as? Double
        // #160: a future-dated-clock strap's recurring automatic offloads (#928/#1012) are near-useless
        // AND each ~60s session blocks the WHOOP4 realtime-HR keep-alive re-arm (guard !backfilling), so
        // live HR lapses. Feed the already-tracked future-dated signal into BackfillPolicy, which SKIPS
        // the .strap/.periodic triggers entirely for such a strap (the .connect pass still re-checks it).
        let clockUntrusted = BackfillContinuation.isFutureDatedNewest(strapNewestTs, wallNowUnix: Int(now))
        let (batteryPct, charging) = batteryPctAndCharging()
        let powerSaving = BLEManager.lowPowerThrottleActive(
            batteryPct: batteryPct, charging: charging, thresholdPct: lowBatteryOffloadPct)
        guard BackfillPolicy.shouldRun(trigger: trigger, now: now, lastBackfillAt: last,
                                       emptyStreak: historicalEmptyBackoff.consecutiveEmpty,
                                       clockUntrusted: clockUntrusted,
                                       powerSaving: powerSaving) else {
            log("Backfill: \(trigger) skipped (rate-limited; last \(last.map { Int(now - $0) } ?? -1)s ago)")
            return false
        }
        if beginBackfill(requiring: requestOwnership) {
            UserDefaults.standard.set(now, forKey: BLEManager.backfillLastAtKey)
            // Every successful trigger moves the next periodic deadline, including manual/strap/connect
            // attempts. This avoids leaving an older timer armed only to wake and fail the same floor.
            startBackfillTimer()
            return true
        }
        return false
    }

    func quiesceStoreForRestore() async throws {
        restoreInProgress = true
        historicalMaterializationStoreGeneration &+= 1
        backfillTimeout?.cancel()
        backfillTimeout = nil
        uploadTimer?.cancel()
        uploadTimer = nil
        backfillTimer?.cancel()
        backfillTimer = nil
        historicalMaterializationWake.cancel()
        historicalMaterializationRetryTask?.cancel()
        historicalMaterializationRetryTask = nil
        historicalMaterializationWorkerGeneration &+= 1
        historicalMaterializationTask?.cancel()
        await historicalMaterializationTask?.value
        historicalMaterializationTask = nil
        historicalMaterializationTaskOwnership = nil
        await collector?.flushStandardHR()
        collector = nil
        backfiller = nil
        if let dataStore { try await dataStore.close() }
        dataStore = nil
    }

    func setHistoricalMaterializationStoreForTesting(
        _ store: WhoopStore,
        restoreInProgress: Bool = false
    ) {
        self.restoreInProgress = restoreInProgress
        historicalMaterializationStoreGeneration &+= 1
        dataStore = store
    }

    func setHistoricalMaterializationSeamsForTesting(
        dueCheck: @escaping @Sendable (WhoopStore, String) async -> Bool,
        run: @escaping @Sendable (WhoopStore) async throws -> HistoricalMaterializationRunSummary
    ) {
        historicalMaterializationDueCheck = dueCheck
        historicalMaterializationRun = run
    }

    func wakeHistoricalMaterializationAfterAcknowledgmentForTesting(
        receipt: HistoricalDataCommitReceipt,
        outcome: HistoricalCommitOutcome,
        store: WhoopStore
    ) async {
        await wakeHistoricalMaterializationAfterAcknowledgment(
            receipt: receipt,
            outcome: outcome,
            store: store
        )
    }

    func reopenStoreAfterRestore() async throws {
        restoreInProgress = false
        await bootstrapStore()
        guard collector != nil, dataStore != nil else {
            throw NSError(domain: "NOOP.Restore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The Bluetooth database could not be reopened."])
        }
        if state.connected { startBackfillTimer() }
    }

    /// Periodic-timer callback: routes through the rate-limited requestSync entry point.
    private func triggerPeriodicBackfill() {
        if !requestSync(.periodic) {
            startBackfillTimer(minimumDelaySeconds: BLEManager.backfillRetryDelaySeconds)
        }
    }

    /// User-tappable "Sync now" (#364): kick a historical offload IMMEDIATELY, bypassing the 15-min
    /// periodic floor. Routes through the SAME gated `requestSync` as every other trigger with the
    /// `.manual` tier — so it always passes the BackfillPolicy floor but still honours the
    /// connected+bonded+not-already-backfilling gate (a no-op, honestly, when there's no strap or a
    /// sync is already running). The caller (Health screen) only enables the control while connected, so
    /// a tap is meaningful; this guard is the belt-and-braces. Mirrors the Android `WhoopBleClient.syncNow`.
    public func syncNow() {
        guard state.connected, state.bonded else {
            log("Sync now: no strap connected — ignored.")
            return
        }
        if backfilling {
            log("Sync now: a sync is already in progress.")
            return
        }
        log("Sync now: manual sync requested by user.")
        requestSync(.manual)
    }

    // MARK: Helpers
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    private func log(_ s: String) {
        state.append(log: "[\(timestamp())] \(s)")
    }
    private func timestamp() -> String {
        BLEManager.logTimeFormatter.string(from: Date())
    }

    /// Emit one Connection & Sync test-mode bond-state line, gated zero-cost behind TestCentre.active(.connection).
    /// The gate (one UserDefaults bool) is read BEFORE the tagged string is appended, so this is a no-op when
    /// the mode is off. Diagnostic only - it never changes the bond path; it just records the transition.
    private func emitConnectionBondState(_ detail: String) {
        guard TestCentre.active(.connection) else { return }
        state.append(log: "bondState \(detail)", domain: .connection)
    }
    private func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func preparePeripheral(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        resetCharacteristics()
    }

    private func discoverPrimaryServices(on p: CBPeripheral) {
        p.discoverServices([
            selectedModel.scanService, BLEManager.heartRateService, BLEManager.batteryService,
        ])
    }

    private func resetCharacteristics() {
        cmdCharacteristic = nil
        cmdNotifyCharacteristic = nil
        eventNotifyCharacteristic = nil
        dataNotifyCharacteristic = nil
        heartRateCharacteristic = nil
        batteryCharacteristic = nil
        whoop5NotifyCharacteristics.removeAll()
        whoop5FrozenCommandCharacteristic = nil
        whoop5FrozenNotifyCharacteristics.removeAll()
        whoop5NotifyRearmOffPending.removeAll()
    }

    /// Start a service-filtered scan for `model`, re-framing the inbound stream for its family (so a
    /// fallback rotation decodes the strap it actually finds, not the family we started from). When
    /// `allowFallback` is true, schedule a one-shot rotation to the other WHOOP family after
    /// `scanFallbackDelaySeconds` of no discovery — recovers reconnect when the persisted preference is
    /// stale after an update/restore. Discovery/connect cancels the pending rotation. (PR#195)
    private func startScan(for model: WhoopModel, allowFallback: Bool) {
        cancelScanFallback()
        selectedModel = model
        reassembler = Reassembler(family: model.deviceFamily)
        router.family = model.deviceFamily
        configureCollectorFamily()
        central.stopScan()
        log("Scanning for \(model.displayName)…")
        // The normal production scan stays pinned to the selected connectable family. A Connection
        // Test Centre capture can additionally SEE the v9.1 diagnostic-only service families, but the
        // decision gate in `didDiscover` below rejects them before any GATT discovery or command path.
        let includesUnsupportedFamilies = TestCentre.active(.connection)
        diagnosticScanIncludesUnsupportedFamilies = includesUnsupportedFamilies
        let services = [model.scanService] + (includesUnsupportedFamilies
            ? WhoopGattServiceFamily.unsupportedServiceUUIDStrings.map { CBUUID(string: $0) } : [])
        if services.count > 1 {
            log("Connection diagnostics: scanning unsupported WHOOP service metadata only")
        }
        central.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        guard allowFallback else { return }
        let fallback = model.fallbackScanModel
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.central.isScanning, !self.state.connected else { return }
            self.log("No \(model.displayName) found yet — trying \(fallback.displayName)")
            self.startScan(for: fallback, allowFallback: true)
        }
        scanFallbackWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BLEManager.scanFallbackDelaySeconds,
            execute: work
        )
    }

    private func cancelScanFallback() {
        scanFallbackWorkItem?.cancel()
        scanFallbackWorkItem = nil
    }

    private func enableLiveNotifications(reason: String) {
        guard let p = peripheral, p.state == .connected else { return }
        let chars = [
            cmdNotifyCharacteristic,
            eventNotifyCharacteristic,
            dataNotifyCharacteristic,
            heartRateCharacteristic,
            batteryCharacteristic,
        ].compactMap { $0 }
        for c in chars where !c.isNotifying {
            requestNotify(c, on: p, reason: reason)
        }
        // #490: a 5/MG's 0x2A19 battery READ is refused pre-bond (it fires in didDiscoverCharacteristicsFor,
        // before the link is encrypted) and is never retried, so `batteryPct` stays nil from connect — and
        // the 5/MG sends NO unsolicited battery notification (so the notify subscription above never fills
        // it on its own). Re-issue the read here: every caller is post-bond (CLIENT_HELLO-ack, post-bond,
        // keep-alive), so the link is encrypted and the read succeeds; the keep-alive caller also RE-polls
        // it (~every 30 s) so the reading stays current as the strap drains and BatteryEstimator gets its
        // discharge samples on any screen. This is the iOS parity for Android's post-handshake read +
        // ~60 s keep-alive poll (WhoopBleClient BATTERY_ON_CONNECT_DELAY_MS / refreshBattery). 4.0 is
        // EXCLUDED — its 0x2A19 is a stub constant 100 (real value = GET_BATTERY_LEVEL; re-reading the stub
        // would revert the true reading, #77). The 600 s same-% throttle in LiveState guards the estimator.
        if let b = batteryCharacteristic, b.properties.contains(.read),
           selectedModel.deviceFamily != .whoop4 {
            p.readValue(for: b)
        }
    }

    private func requestNotify(_ c: CBCharacteristic, on p: CBPeripheral, reason: String) {
        guard c.properties.contains(.notify) || c.properties.contains(.indicate) else {
            log("Notify unavailable \(c.uuid) (\(reason))")
            return
        }
        if c.isNotifying {
            log("Notify already active \(c.uuid) (\(reason))")
            return
        }
        p.setNotifyValue(true, for: c)
        log("Notify requested \(c.uuid) (\(reason))")
    }

    // MARK: Alarm API (M6 — additive; does NOT touch connect/offload/sync flows)

    /// Arm the strap's firmware alarm for `date` (UTC).
    ///
    /// WHOOP 4.0 sequence: SET_CLOCK first to ensure the strap RTC is UTC-correct, then the
    /// rev-1 SET_ALARM_TIME. WHOOP 5/MG sends the REVISION_4 body alone — the strap maintains
    /// its RTC (set during the connect handshake / history sync) and the official app's alarm
    /// path doesn't re-set it (wire observation; mirrors Android WhoopBleClient.armStrapAlarm).
    /// Either way the strap will buzz at `date` even if the app is backgrounded or force-quit
    /// (event STRAP_DRIVEN_ALARM_EXECUTED=57). This is the only alarm path: the strap fires at
    /// the fixed time — NOOP has no light-sleep early-wake layer.
    ///
    /// EXPERIMENTAL / UNCONFIRMED on 5/MG (same posture as the Android client): the byte-identical
    /// Android rev-4 frame has been ACKed by a real 5/MG when arming, but a strap-driven wake fire
    /// has NOT been captured on our side (no STRAP_DRIVEN_ALARM_EXECUTED event observed yet) — do
    /// not present the 5/MG alarm as guaranteed until one is.
    enum AlarmCommandResult: Equatable, Sendable {
        case sentAwaitingReadback
        case queuedForReconnect
        case experimentalDisabled
    }

    @discardableResult
    func armStrapAlarm(at date: Date) -> AlarmCommandResult {
        // Log the wake time in the user's LOCAL zone. `Date` prints in UTC by default, so an alarm
        // for (say) 07:00 in New York logged as "11:00:00 +0000" reads like a timezone bug — but it
        // isn't: SET_ALARM_TIME carries the absolute instant of the chosen local time, and the strap
        // fires at that instant regardless of how its UTC RTC is labelled.
        let localFmt = DateFormatter()
        localFmt.dateFormat = "EEE HH:mm zzz"
        if selectedModel.deviceFamily == .whoop5 {
            // The 5/MG firmware alarm is unconfirmed (arming ACKs, but the wake actually FIRING is not
            // verified), so only arm it when the user has opted into Experimental — matching the Android
            // client, which refuses to arm it otherwise. Without this a normal 5/MG user is silently
            // armed onto an alarm that may never fire.
            guard PuffinExperiment.isEnabled else {
                log("Alarm: 5/MG firmware alarm needs the Experimental toggle (unconfirmed) — not armed")
                return .experimentalDisabled
            }
            guard whoop5SecureReady else {
                log("Alarm: 5/MG secure session is not ready — not armed")
                return .queuedForReconnect
            }
            // 5/MG SET_ALARM_TIME is REVISION_4: [04][id][u32 sec][u16 subsec][12-byte 47/152
            // pattern, overallLoop 7, 30 s]. No SET_CLOCK preamble (see doc comment above).
            let wakeMs = Int64((date.timeIntervalSince1970 * 1000).rounded())
            send(.setAlarmTime, payload: AlarmPayload.setAlarmRev4(wakeEpochMs: wakeMs))
            recordAlarmArm(sentEpoch: Int(wakeMs / 1000))
            // #34: don't claim "armed" when the strap isn't connected (the send was dropped) — the arm
            // re-fires on the next connect.
            log(connectedPeripheralUUID != nil
                ? "Alarm: armed 5/MG rev4 for \(localFmt.string(from: date)) — your local wake time"
                : "Alarm: queued 5/MG rev4 for \(localFmt.string(from: date)) — strap not connected; will send on next connect")
            return connectedPeripheralUUID == nil ? .queuedForReconnect : .sentAwaitingReadback
        }
        // Clamp rather than trap: an out-of-range alarm date (pre-1970 / post-2106) must not crash.
        let epochSec = UInt32(clamping: Int64(date.timeIntervalSince1970))
        sendSetClockBothForms()
        send(.setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: epochSec))
        recordAlarmArm(sentEpoch: Int(epochSec))
        // #34: only claim "armed" when the strap is connected (the send actually went out); otherwise it's
        // queued and re-sent on the next connect.
        if connectedPeripheralUUID != nil {
            log("Alarm: armed for \(localFmt.string(from: date)) — your local wake time (sent as UTC epoch \(epochSec))")
        } else {
            log("Alarm: queued for \(localFmt.string(from: date)) — strap not connected; will send on next connect")
        }
        // Arm READBACK (#401 close-out): ask the strap what it now has armed (GET_ALARM_TIME, cmd 67) so
        // the strap log carries armed + strap-reports + fired as one decidable sequence in any future
        // "didn't buzz" report. WHOOP 4.0 ONLY: cmd 67 is allowlisted for 5/MG but its puffin readback
        // semantics are unverified, and this lands unacknowledged in the arm burst (trivial airtime).
        // Log-only: FrameRouter parses the cmd-67 COMMAND_RESPONSE defensively and NEVER gates behaviour
        // on it (the 4.0 response layout is undocumented; unparseable replies log raw hex).
        send(.getAlarmTime, payload: [0x01])
        return connectedPeripheralUUID == nil ? .queuedForReconnect : .sentAwaitingReadback
    }

    /// #34: persist the last alarm arm for the debug export's Alarm block (sent epoch + when + whether the
    /// strap was connected when we sent it), so a "didn't buzz" report shows sent-vs-strap-reports at a glance.
    private func recordAlarmArm(sentEpoch: Int) {
        let d = UserDefaults.standard
        d.set(sentEpoch, forKey: "alarm.lastArmSentEpoch")
        d.set(Date().timeIntervalSince1970, forKey: "alarm.lastArmAt")
        d.set(connectedPeripheralUUID != nil, forKey: "alarm.lastArmConnected")
        // A missing live sample is meaningful diagnostics too; don't let an older arm's HR masquerade
        // as the HR at this arm event.
        if let heartRate = state.heartRate {
            d.set(heartRate, forKey: "alarm.lastArmHeartRate")
        } else {
            d.removeObject(forKey: "alarm.lastArmHeartRate")
        }
        // #34: the strap-clock skew (its own RTC minus wall, seconds) AT THE MOMENT we armed. A wrong RTC
        // is a top cause of the firmware alarm never firing, and knowing the clock state at arm — not just
        // now — tells whether the arm even had a chance (skew ~0 but the strap still rejects ⇒ a corrupted
        // alarm register, not a clock problem).
        d.set(strapClockNow - Int(Date().timeIntervalSince1970), forKey: "alarm.lastArmClockSkew")
    }

    /// Disarm the currently-armed firmware alarm.
    func disableStrapAlarm() {
        // #34: clear the "strap keeps rejecting the alarm" streak/warning — it's about an ACTIVE arm being
        // refused, and there's nothing armed to refuse once disarmed.
        UserDefaults.standard.set(0, forKey: "alarm.rejectStreak")
        if selectedModel.deviceFamily == .whoop5 {
            guard whoop5SecureReady else {
                log("Alarm: 5/MG secure session is not ready — not disarmed")
                return
            }
            // 5/MG DISABLE_ALARM is REVISION_2 [0x02, 0xFF]; the rev-1 [0x01] form below is WHOOP4.
            send(.disableAlarm, payload: AlarmPayload.disableRev2())
            log("Alarm: disarmed (5/MG rev2)")
            return
        }
        send(.disableAlarm, payload: [0x01])
        log("Alarm: disarmed")
    }

    /// Request the currently-armed alarm time from the strap (response arrives on cmd-notify char).
    /// Parsing the reply is optional/bonus — the raw bytes will appear in the BLE log.
    func getStrapAlarm() {
        if selectedModel.deviceFamily == .whoop5, !whoop5SecureReady {
            log("Alarm: 5/MG secure session is not ready — request refused")
            return
        }
        send(.getAlarmTime, payload: [0x01])
        log("Alarm: requested current alarm time")
    }

    /// One-shot user buzz (#921): the on-device-confirmed "vibrate the strap now" sequence.
    ///
    /// WHOOP 4 uses RUN_HAPTICS_PATTERN (cmd 79) with patternId=2, 3 loops plus RUN_ALARM (cmd 68).
    /// WHOOP 5/MG sends only the Maverick notify haptic (cmd 0x13); it never appends RUN_ALARM.
    /// A bare RUN_HAPTICS_PATTERN write is exactly what a WHOOP 4.0 was reported ignoring on the
    /// Siri-shortcut path (#921), so every user-facing one-shot buzz (the Live "Buzz strap" button,
    /// the Buzz Strap App Intent) routes through here instead of composing its own write.
    ///
    /// Writes are ACKNOWLEDGED (.withResponse): a backgrounded shortcut on a busy link can
    /// silently drop an unacknowledged write, which is how #921 logged "Run Haptics" with no
    /// vibration. On a 5/MG, send() remaps cmd 79 to the Maverick 0x13 notify buzz.
    ///
    /// Alternative waveform form (12-byte):
    ///   [wfe1=47, wfe2=152, 0,0,0,0,0,0, loop u16=0, overall_loop=7, dur=30]
    /// is a note for future refinement; the preset id=2 form is simpler and confirmed to buzz on-device.
    ///
    /// Haptic firing cannot be verified in the simulator (no strap motor). Test on-device only.
    @discardableResult
    func buzzStrapOnce() -> AlarmCommandResult {
        guard connectedPeripheralUUID != nil else {
            log("Buzz: not sent — strap is not connected")
            return .queuedForReconnect
        }
        if selectedModel.deviceFamily == .whoop5, !whoop5SecureReady {
            log("Buzz: not sent — WHOOP 5/MG secure session is not ready")
            return .queuedForReconnect
        }
        send(.runHapticsPattern, payload: [2, 3, 0, 0, 0], writeType: .withResponse)  // patternId=2, 3 loops (5/MG: send() remaps to the maverick notify buzz)
        if selectedModel.deviceFamily == .whoop5 {
            log("Buzz: Maverick 0x13 haptic queued; ATT, protocol acceptance, and physical confirmation are separate facts")
            return .sentAwaitingReadback
        }
        send(.runAlarm, payload: [0x01], writeType: .withResponse)
        log("Buzz: one-shot fired (patternId=2 loops=3 + runAlarm, acked)")
        return .sentAwaitingReadback
    }

    /// Haptic Clock (#460): buzz the current wall-clock time out on the strap so the user can read it
    /// off their wrist without a screen. The pure, unit-tested `HapticClock` encoder turns now into an
    /// ordered pulse list (long = a "ten", short = a "unit", in HH-tens / HH-units / MM-tens / MM-units
    /// order); we then schedule each pulse with `DispatchQueue.main.asyncAfter`, firing the EXISTING
    /// maverick notification buzz (`runHapticsPattern`, remapped to the cmd-0x13 notify body in `send`)
    /// at each pulse's start. Only the SCHEDULE is new — the buzz itself is the hardware-confirmed one.
    ///
    /// `is24h` controls 12- vs 24-hour reading; a Settings toggle should supply it (default 12h — see
    /// `concerns`). Public so a Settings button can trigger it. Long-press / double-tap strap input is
    /// hardware-dependent and not wired (no tap event is parsed yet — see `hardwareUnverifiable`).
    ///
    /// Each WHOOP notification buzz is a fixed-length motor pulse, so we can't vary the on-time per
    /// pulse from the app; instead we map a LONG pulse to two stacked buzzes and a SHORT pulse to one,
    /// which the wrist feels as "longer vs shorter". Pulse-feel timing can only be confirmed on a real
    /// strap motor — best-effort here (see `hardwareUnverifiable`).
    public func buzzTimeNow(is24h: Bool = false, at date: Date = Date()) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: date)
        let pulses = HapticClock.pulses(hour: comps.hour ?? 0, minute: comps.minute ?? 0, is24h: is24h)
        guard !pulses.isEmpty else {
            log("Haptic Clock: nothing to buzz (00:00 in 24h form).")
            return
        }
        log("Haptic Clock: buzzing \(pulses.count) pulses for the current time (\(is24h ? "24h" : "12h")).")
        // Walk the encoder's pulse list, converting each (durationMs,gapMs) into a scheduled buzz.
        // A long pulse is felt as a heavier buzz (2 stacked loops); a short pulse as a light one (1).
        var offsetMs = 0
        for pulse in pulses {
            let loops = pulse.isLong ? 2 : 1
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(offsetMs)) { [weak self] in
                // patternId/loops payload — send() remaps this to the 5/MG maverick notify buzz; on a
                // WHOOP 4.0 it's the native runHapticsPattern. Same call the inactivity nudge uses.
                self?.send(.runHapticsPattern, payload: [2, UInt8(clamping: loops), 0, 0, 0])
            }
            offsetMs += pulse.durationMs + pulse.gapMs
        }
    }

    /// Inactivity reminder (#419): on each natural offload completion, run the shipped, unit-tested
    /// `SedentaryDetector` over the freshly-arrived gravity window and buzz the wrist if the user has
    /// been seated too long. NO offload-timer change — a read-only hook on an event that already
    /// happens, so the nudge lags the stillness by the offload cadence (~7-15 min). Best-effort.
    ///
    /// All gating + de-dup lives in the engine: we only supply honest inputs (recent gravity, the live
    /// `state.worn` flag, the prefs→`SedentaryConfig`/`SedentaryState`) and persist the engine's
    /// `nextState`. The engine acts only when this offload advanced the newest gravity ts (a replayed /
    /// no-new-rows sync can't re-buzz), only for a bout whose end is still current, only through its
    /// mayBuzz gate (master / quiet hours / worn / active-hours-by-bout-end-time), and either re-nudges a
    /// continuing bout on the user's cadence or alerts a distinct new bout separated by movement.
    ///
    /// Mirrors the async pattern of checkStrapLiveness: the gravity read only the Collector can do (it
    /// owns the concrete store) hops onto a @MainActor Task, then the gated buzz + state save run back on
    /// the main actor. Haptic firing can't be verified in the simulator — test on-device.
    private func maybeBuzzInactivity() {
        guard InactivityPrefs.isEnabled() else { return }   // cheap pre-check before any DB read
        Task { @MainActor in
            let nowSec = Int(Date().timeIntervalSince1970)
            let from = nowSec - BLEManager.inactivityLookbackSeconds
            let gravity = await collector?.recentGravity(from: from, to: nowSec) ?? []
            guard !gravity.isEmpty else { return }
            // Sleep & Rest test mode (Group E): bank the live gravity window for the readout's coverage
            // figure. Gated on the zero-cost active() Bool, so this is a no-op when the mode is off.
            if TestCentre.active(.sleep) { state.recordSleepLiveGravity(gravity) }

            let decision = SedentaryDetector.evaluate(
                gravity, state: InactivityPrefs.loadState(),
                config: InactivityPrefs.loadConfig(),
                worn: state.worn, nowSec: nowSec,
                tzOffsetSec: InactivityPrefs.tzOffsetSec(nowSec))
            // The engine always advances lastProcessedGravityTs when a window arrived, so persist the
            // de-dup state every run — a replayed window then can't re-buzz across a relaunch.
            InactivityPrefs.saveState(decision.nextState)

            if decision.shouldBuzz {
                send(.runHapticsPattern, payload: [2, UInt8(clamping: decision.buzzLoops), 0, 0, 0])
                let mins = Int((decision.bout?.durationS ?? 0) / 60)
                log("Inactivity: nudged after a \(mins)-min sedentary stretch.")
                AppModel.postInactivity(minutes: mins)   // #577 — local notification (iOS-only, self-gated on notif.masterEnabled)
            }
        }
    }

    /// Parse a standard BLE Heart Rate Measurement (0x2A37) via the pure StandardHeartRate parser.
    private func parseStandardHR(_ data: [UInt8]) {
        guard let m = StandardHeartRate.parse(data) else {
            log("HR notify parse failed: \(hex(data))")
            return
        }
        let now = Date()
        if lastStandardHRLogAt.map({ now.timeIntervalSince($0) >= 30 }) ?? true {
            lastStandardHRLogAt = now
            let plausibility = (30...220).contains(m.hr) ? "" : " ignored"
            log("HR notify: \(m.hr) bpm\(plausibility), rr=\(m.rr.count)")
        }
        // R-R: the standard profile is the RELIABLE source (the custom REALTIME_DATA stream
        // usually reports rr_count=0), so always surface intervals when present. setRRIntervals also
        // feeds the Live console's rolling rrRecent buffer.
        if !m.rr.isEmpty { state.setRRIntervals(m.rr) }
        // HR: the standard 0x2A37 profile is the RELIABLE source (BLE-standard, ~1Hz). Let it
        // drive the value whenever it's physiologically plausible; reject 0/garbage (off-wrist).
        // AppModel medians these into a stable display value. live perf: only publish on a real
        // change so a steady resting HR doesn't re-render the whole Live console every second.
        if m.hr >= 30 && m.hr <= 220 {
            state.streamingLiveHR = true
            if state.heartRate != m.hr { state.heartRate = m.hr }
        }
        // Record it continuously — independent of the realtime stream or the open screen.
        collector?.ingestStandardHR(hr: m.hr, rr: m.rr, at: Int(Date().timeIntervalSince1970))
    }
}

// MARK: - CBCentralManagerDelegate
extension BLEManager: @preconcurrency CBCentralManagerDelegate {
    /// What `centralManagerDidUpdateState` should do about an `.unauthorized` central state, decided
    /// from the TCC grant (`CBManager.authorization`) rather than the transient central state alone.
    /// Pure and stateless so the #391 discrimination is pinnable by a unit test without CoreBluetooth
    /// plumbing. Design from digitalerdude's #407; test seam per tigercraft4's #407 review.
    enum UnauthorizedAction: Equatable {
        /// The grant itself reads denied/restricted — a genuine denial; latch the #280/#295 banner now.
        case showRegrantBanner
        /// The grant reads granted (or undecided): the macOS cold-start settling window (#391), or a
        /// first-run prompt still on screen. Wait — but under a settle deadline (see
        /// `armUnauthorizedSettleDeadline`), because a WEDGED grant (#429: an unsigned build's stale
        /// TCC row) presents exactly the same way and never settles.
        case waitForSettle
    }

    static func unauthorizedAction(_ authorization: CBManagerAuthorization) -> UnauthorizedAction {
        switch authorization {
        case .denied, .restricted: return .showRegrantBanner
        default: return .waitForSettle
        }
    }

    /// How long an apparently-transient `.unauthorized` may sit unresolved before it is treated as a
    /// wedged grant (#429) and the re-grant banner shows anyway. The #391 reporter's cold-start settle
    /// took ~40 s (unauthorized 14:51:44 → poweredOn 14:52:25), so 120 s clears the observed case with
    /// a wide margin while still surfacing the wedged case in a bounded time instead of never.
    static let unauthorizedSettleSeconds = 120

    /// The #280/#295 "re-grant Bluetooth" banner, verbatim. One home so the immediate genuine-denial
    /// path and the #391 settle-deadline escalation can never drift apart.
    private func showBluetoothRegrantBanner() {
        // #295: an unsigned/ad-hoc build's code identity changes on every release, so a Bluetooth
        // toggle that already reads "on" from a PRIOR build's grant may not carry over — the
        // message needs to tell the user to re-toggle it, not just check that it's on.
        #if os(macOS)
        state.lastSyncError = "NOOP isn't allowed to use Bluetooth. Open System Settings → Privacy & Security → Bluetooth — if NOOP is already listed there, toggle it off and back on (a new NOOP build needs a fresh grant), then quit and reopen NOOP."
        #else
        state.lastSyncError = "NOOP isn't allowed to use Bluetooth. Open iPhone Settings → NOOP → Bluetooth — if it's already on, toggle it off and back on, then quit and reopen NOOP."
        #endif
        log("Bluetooth permission not granted (unauthorized) — cannot scan or connect")
        radioStateErrorShown = true
    }

    /// #391 escalation: the transient-looking `.unauthorized` gets `unauthorizedSettleSeconds` to
    /// resolve (every real settle produces another state callback, which cancels this). If it fires,
    /// the state is STILL unauthorized with a granted TCC read — the wedged-grant shape (#429), where
    /// staying silent would strand the user with no explanation at all — so show the re-grant banner,
    /// whose off/on-toggle instruction is exactly the wedged case's fix.
    private func armUnauthorizedSettleDeadline() {
        unauthorizedSettleWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.unauthorizedSettleWork = nil
            guard self.central?.state == .unauthorized else { return }
            self.log("Central still unauthorized \(BLEManager.unauthorizedSettleSeconds)s after a granted TCC read — not cold-start settling (#391); treating as a wedged grant (#429) and showing the re-grant banner")
            self.showBluetoothRegrantBanner()
        }
        unauthorizedSettleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(BLEManager.unauthorizedSettleSeconds), execute: work)
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("Central state: \(central.state.rawValue) (5 = poweredOn)")
        #if DEBUG
        if CommandLine.arguments.contains("--demo-bluetooth-off") {
            state.bluetoothUnavailableMessage = "Bluetooth is off. Turn it on in Settings to connect a device."
            return
        }
        #endif
        // #391: ANY state update means the cold-start settling window moved on — a pending
        // unauthorized-settle escalation is obsolete whether the new state is good news (poweredOn)
        // or its own banner-worthy case (poweredOff handles itself below).
        unauthorizedSettleWork?.cancel()
        unauthorizedSettleWork = nil
        guard central.state == .poweredOn else {
            invalidateHistoricalBackfill(reason: "Bluetooth is no longer powered on")
            switch central.state {
            case .poweredOff:
                state.bluetoothUnavailableMessage = "Bluetooth is off. Turn it on in Settings to connect a device."
            case .unauthorized:
                state.bluetoothUnavailableMessage = "Bluetooth access is denied. Allow NOOP in Settings › Privacy & Security › Bluetooth."
            case .unsupported:
                state.bluetoothUnavailableMessage = "Bluetooth isn't supported on this device."
            default:
                state.bluetoothUnavailableMessage = "Bluetooth is unavailable right now. Try again in a moment."
            }
            // #280: a non-poweredOn radio state used to be a SILENT return — the strap log showed only
            // "Central state: 3" and the UI just read "not connected", so a user whose Mac had denied NOOP
            // Bluetooth (.unauthorized == raw 3) had nothing explaining why no strap was ever found. This is
            // the #280 case: an unsigned universal rebuild (8.4.0) gets a new code identity, so the earlier
            // macOS Bluetooth TCC grant no longer applied and CoreBluetooth reported .unauthorized before
            // any scan/connect. Surface the actionable states via lastSyncError (shown in Live + Today);
            // leave .unknown/.resetting alone — they're transient and the next state update resolves them.
            // Android already surfaces all three (WhoopBleClient: no-LE / off / permission), so this brings
            // iOS+macOS up to that parity rather than adding a new behaviour.
            switch central.state {
            case .unauthorized:
                // #391 (design from digitalerdude's #407): CoreBluetooth on macOS can transiently report
                // `.unauthorized` during the cold-start settling window (before the central finishes
                // connecting to bluetoothd) even when the TCC grant is fine — the state then advances to
                // .poweredOff/.poweredOn on the next callback and the strap connects. The `authorization`
                // property reads the TCC grant DIRECTLY, independent of that transient state, so it can tell
                // a genuine denial (#280/#295) from the settling case — latching the re-grant banner on ANY
                // `.unauthorized` pushed users to toggle Bluetooth off/on to clear a false message. The
                // settle path is NOT unbounded silence: a wedged grant (#429) presents identically and never
                // settles, so it runs under `armUnauthorizedSettleDeadline`'s one-shot escalation.
                // The CLASS property (`CBCentralManager.authorization`), not the `central.authorization`
                // instance property — that one is deprecated on iOS (13.0 → 13.1); both read the same grant.
                switch Self.unauthorizedAction(CBCentralManager.authorization) {
                case .showRegrantBanner:
                    showBluetoothRegrantBanner()
                case .waitForSettle:
                    log("Central reported unauthorized but the Bluetooth grant reads OK — transient cold-start settling (#391); re-grant banner deferred \(Self.unauthorizedSettleSeconds)s")
                    armUnauthorizedSettleDeadline()
                }
            case .poweredOff:
                state.lastSyncError = "Bluetooth is off. Turn it on to connect to your strap."
                log("Bluetooth is off — cannot scan or connect")
                radioStateErrorShown = true
            case .unsupported:
                state.lastSyncError = "This device can't use Bluetooth Low Energy."
                log("Bluetooth LE unsupported on this device")
                radioStateErrorShown = true
            default:
                break
            }
            return
        }
        state.bluetoothUnavailableMessage = nil
        // #280: radio is back — clear a stale radio-state banner (only one WE set), so a "Bluetooth is off"
        // message doesn't outlive the radio coming on. A genuine sync error is left untouched.
        if radioStateErrorShown {
            state.lastSyncError = nil
            radioStateErrorShown = false
        }
        // Bootstrap the async store once on first poweredOn (idempotent if already set).
        Task { @MainActor in await bootstrapStore() }
        if let p = restoredPeripheral {
            log("poweredOn with restored peripheral — reconnecting \(p.identifier)")
            if p.state != .connected {
                central.connect(p, options: nil)
            } else {
                discoverPrimaryServices(on: p)
            }
        } else {
            // #78 hole-2: poweredOn is SYSTEM-initiated (every Bluetooth toggle / bluetoothd restart
            // lands here), so it must not reset a latched bond-loop give-up - it gets ONE bounded
            // attempt with the give-up intact (Android onBluetoothRadioOn parity), not a fresh hammer.
            connectFromSystem()
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any],
                               rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? "unknown"
        // Multi-WHOOP present-scan (Add-a-WHOOP wizard): collect the strap, do NOT auto-connect, and
        // return before touching the connect flow. Only reachable when the wizard explicitly turned on
        // `isPresentingScan` via scanForWhoops(); on the default path (false) this branch is skipped
        // entirely and the auto-connect code below runs exactly as before.
        if isPresentingScan {
            let uuid = peripheral.identifier.uuidString
            if let i = discoveredWhoops.firstIndex(where: { $0.uuid == uuid }) {
                discoveredWhoops[i] = (uuid: uuid, name: name, rssi: RSSI.intValue)   // refresh RSSI
            } else {
                discoveredWhoops.append((uuid: uuid, name: name, rssi: RSSI.intValue))
            }
            return
        }
        // A diagnostic-wide scan may report service families that we intentionally do not support.
        // Decide before pinning, stopping the scan, preparing the peripheral, or opening GATT: those
        // families are metadata-only until their framing is proven on owned hardware.
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?
            .map(\.uuidString) ?? []
        // A normal selected-family scan may safely keep CoreBluetooth's empty-advertisement exception:
        // the scan filter itself proves the selected service. A diagnostic-wide scan cannot make that
        // proof because it also targets unsupported services, so never open GATT for an unidentified hit.
        guard !diagnosticScanIncludesUnsupportedFamilies || !advertisedServices.isEmpty else {
            log("Discovered \(name) during diagnostic-wide WHOOP scan without advertised services; ignoring unknown family")
            return
        }
        let scanDecision = whoopGattScanDecision(
            // `DeviceFamily` intentionally keeps its raw UUID detail inside WhoopProtocol; the
            // app's selected CBUUID is the production scan contract and normalizes identically.
            selectedServiceUUIDString: selectedModel.scanService.uuidString,
            advertisedServiceUUIDStrings: advertisedServices
        )
        guard scanDecision.shouldConnect else {
            if let unsupported = scanDecision.unsupportedFamily {
                log(unsupported.diagnosticUnsupportedMessage)
            } else {
                log("Discovered \(name) — selected WHOOP service is not connectable; ignoring")
            }
            return
        }
        // Multi-WHOOP preferred-peripheral filter: when the app has pinned a specific strap, ignore any
        // OTHER discovered WHOOP and keep scanning. When `preferredPeripheralUUID == nil` (the single-
        // WHOOP default) this guard is skipped and the original "connect to the first discovered" path
        // below is byte-for-byte unchanged.
        if let preferred = preferredPeripheralUUID, peripheral.identifier != preferred {
            log("Discovered \(name) (\(peripheral.identifier)) — not the preferred strap; ignoring")
            return
        }
        cancelScanFallback()
        // Persist the family that actually advertised so the next scan starts on the right service —
        // this is what makes a one-time rotation stick after a stale-preference reconnect. (PR#195)
        UserDefaults.standard.set(selectedModel.rawValue, forKey: "selectedWhoopModel")
        log("Discovered \(name) (rssi \(RSSI)) — connecting")
        central.stopScan()
        preparePeripheral(peripheral)
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        cancelScanFallback()
        failedConnectAttempts = 0   // a successful connect clears the reconnect backoff (#414)
        restoredPeripheral = nil
        preparePeripheral(peripheral)
        // This is the one accepted-generation seam. It clears every old handshake/session/progress owner
        // before the connected UUID is published, so observers can never combine a new link with stale proof.
        admitConnectionGeneration(peripheral)
        // Multi-WHOOP: publish the strap's stable BLE identity so the app can persist it onto the active
        // registry device (it observes this and calls registry.setPeripheralId). Additive observation
        // only — BLEManager stays decoupled from the store and the connect flow below is unchanged.
        connectedPeripheralUUID = peripheral.identifier.uuidString
        state.markConnected()
        state.lastSyncError = nil
        // A connect succeeded → clear the stale-bond re-pair guide UNLESS we are in a known bond-loop
        // (#617). In that loop the strap "connects" every ~3 s before timing out again, so clearing here
        // wiped the guide on EVERY cycle: it flashed for ~1 s and vanished, so the user could never read it
        // (#711). While tripped, keep the guide up and instead clear it once THIS connection proves healthy,
        // i.e. it survives past the loop's quick-timeout window (below), or on a clean teardown
        // (disconnect() resets the detector and clears the guide too).
        resetClockRecoveryForConnection()
        // Data Range markers belong to the physical connection that returned them. Never let a stale
        // previous-generation marker become this generation's approximate clock fallback.
        strapNewestTs = nil
        if postBondLoop.tripped {
            let gen = connectGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + postBondLoop.quickTimeoutWindow + 1) { [weak self] in
                // Clear only if the SAME continuous connection is still up. A reconnect (loop cycle) bumps
                // connectGeneration, so a transient cycle-connect can't satisfy this even though the
                // CBPeripheral object is reused. Without the generation, the timer could fire during a later
                // cycle's brief connect and wrongly wipe the guide, back to flashing.
                guard let self, self.state.connected, self.connectGeneration == gen else { return }
                self.postBondLoop.reset()        // survived the window → the bond-loop is resolved
                self.state.reconnectGuide = nil
            }
        } else {
            state.reconnectGuide = nil
        }
        lastDataAt = Date()
        log("Connected — discovering services")
        // Connection test mode: report the connect latency + the uptime-start marker the readout reads.
        // Gated zero-cost: the .connection bool is read before any string is built, so this is a no-op
        // when the mode is off. Behaviour-neutral diagnostics only - the connect flow above is unchanged.
        if TestCentre.active(.connection) {
            let nowUnix = Int(Date().timeIntervalSince1970)
            let latencyMs = connectAttemptStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) }
            state.append(log: "connect up gen=\(connectGeneration) "
                + "latencyMs=\(latencyMs.map(String.init) ?? "?") uptimeStart=\(nowUnix)", domain: .connection)
        }
        discoverPrimaryServices(on: peripheral)
    }

    /// Connection test mode: a STABLE, integer-token reason for a BLE error, for parity with Android's
    /// integer GATT status (which emits `status<N>`) and a tighter export surface than a localized,
    /// locale-dependent free-text string. We emit the `CBError`/`CBATTError` raw enum value (an Int), so
    /// the token is locale-independent and carries no free text. A nil error reads "unknown"; an error
    /// from neither CoreBluetooth domain reads "code?" (no localizedDescription, which could carry text).
    private func connErrorToken(_ error: Error?) -> String {
        guard let error else { return "unknown" }
        if let cb = error as? CBError { return "cbError\(cb.code.rawValue)" }
        if let att = error as? CBATTError { return "cbAttError\(att.code.rawValue)" }
        return "code?"
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        guard Self.shouldApplyDisconnectEvent(
            eventPeripheralID: peripheral.identifier,
            activePeripheralID: self.peripheral?.identifier,
            activePeripheralIsConnected: self.peripheral?.state == .connected
        ) else {
            log("Ignored stale disconnect callback for \(peripheral.identifier)")
            return
        }
        let retiredGeneration = connectGeneration
        confirmedCommandWrites.removeAll {
            $0.peripheralID == peripheral.identifier && $0.connectGeneration == retiredGeneration
        }
        invalidateHistoricalBackfill(reason: "connection ended before write confirmation")
        Task { @MainActor in await collector?.flush() }
        // Reboot trail: if a user reboot is in flight, this drop is the strap acting on it. Log how long
        // the link stayed up (a real reboot drops within ~1-2 s) and cancel the no-disconnect watchdog. The
        // reconnect time is logged separately once the handshake completes. `rebootRequestedAt` stays set so
        // the handshake can compute the round-trip; it's cleared there (or by the watchdog).
        if let t = rebootRequestedAt {
            let ms = Int(Double(DispatchTime.now().uptimeNanoseconds &- t.uptimeNanoseconds) / 1_000_000)
            rebootTimeoutWork?.cancel(); rebootTimeoutWork = nil
            // #275: a dropped LINK only proves a reboot on WHOOP 5.0 (verified fw). On WHOOP 4.0 the frame
            // is unconfirmed — opcode 29/payload01 was observed to drop the BLE link WITHOUT power-cycling
            // the strap (the sensor stayed on) — so don't claim a reboot; report the drop honestly. Twin of
            // Kotlin handleDisconnect.
            if selectedModel.deviceFamily == .whoop5 {
                log("reboot: link dropped \(ms)ms after send — reboot took effect; awaiting reconnect")
            } else {
                log("reboot: link dropped \(ms)ms after send — but a WHOOP 4.0 reboot isn't confirmed; a dropped link alone isn't proof (a real reboot also switches the sensor light off). Awaiting reconnect")
            }
        }
        // #80 marginal-radio detection: judge this drop BEFORE the state resets below clobber the
        // arm timestamp. A drop that is unintentional, error-bearing, and lands shortly after we armed
        // the R10/R11 burst is the marginal-radio tell. Feed the detector; if it trips, the NEXT connect
        // skips the heavy arm (the flag is intentionally NOT reset on disconnect so it survives rescan).
        let timedOut = !intentionalDisconnect && error != nil
        let sinceArm = realtimeArmedAt.map { Date().timeIntervalSince($0) }
        if marginalRadio.connectionEnded(wasArmed: realtimeArmedAt != nil,
                                         secondsSinceArm: sinceArm,
                                         timedOut: timedOut) {
            standardHRFallback = true
            log("Marginal radio (#80): \(marginalRadio.consecutiveArmTimeouts) arm-then-timeout cycles — next connect uses standard-HR mode (0x2A37 only)")
        }
        // #617 bond-loop detection: same pre-reset read. The bond-loop tell is a CONNECTION TIMEOUT that
        // lands within seconds of a genuine bond — bond → drop → rescan → bond → drop, forever. We require
        // the OS to classify the drop as a connection timeout (`CBError.connectionTimeout`), not merely any
        // error, so a one-off radio blip or a different failure doesn't get mistaken for the loop. Once it
        // trips, surface the EXISTING re-pair guide (the same forget-and-re-pair steps the #74/firmware-reset
        // path shows) rather than letting the link loop silently and drain the battery.
        let connTimedOut: Bool = (error as? CBError)?.code == .connectionTimeout
        let sinceBond = bondedAt.map { Date().timeIntervalSince($0) }
        if postBondLoop.connectionEnded(wasBonded: bondedAt != nil,
                                        secondsSinceBond: sinceBond,
                                        timedOut: connTimedOut && !intentionalDisconnect) {
            log("Bond-loop (#617): \(postBondLoop.consecutiveBondTimeouts) bond-then-timeout cycles — surfacing the re-pair guide and pausing auto-reconnect")
            // #844 — the loop is bond → drop → 3s rescan → bond → drop, forever, draining the battery.
            // Surfacing the guide alone left the involuntary-drop rescan (below) running. Pause auto-reconnect
            // too: the disconnect rescan and didFailToConnect both already skip while this is set, and a user
            // Connect (connect()) or a genuine bond re-arms it. We do NOT touch the bond/parse path — the bond
            // is real; the stale OS pairing is the problem, which the guide tells the user how to clear.
            autoReconnectPausedForBondLoop = true
            bondLoopPausedAt = Date()   // the #78 hole-4 salvage probe covers this pause too (one bounded cycle)
            if TestCentre.active(.connection) {
                state.append(log: "reconnect paused=bondLoop (#617: \(postBondLoop.consecutiveBondTimeouts) bond-then-timeout cycles)", domain: .connection)
            }
            if state.reconnectGuide == nil {
                state.reconnectGuide = """
                Your strap keeps connecting and then dropping a second later. This is almost always a stale Bluetooth pairing - usually after a WHOOP firmware update, or the official WHOOP app holding the strap. NOOP works fine once it's re-paired:

                1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
                2. Open System Settings → Bluetooth and Forget your WHOOP if it's listed.
                3. Tap the strap repeatedly until its LEDs flash blue (pairing mode).
                4. Come back here and reconnect.
                """
            }
        }
        bondedAt = nil   // cleared after the bond-loop detector above read it (#617)
        state.markDisconnected()
        whoop5SecureSession.disconnect()
        whoop5R22Attempt = nil
        pendingWhoop5HapticResponses.removeAll()
        queuedWhoop5ConfirmedWrites.removeAll()
        activeWhoop5ConfirmedWriteID = nil
        whoop5ConfirmedWriteTimeout?.cancel()
        whoop5ConfirmedWriteTimeout = nil
        whoop5SecureStageTimeout?.cancel()
        whoop5SecureStageTimeout = nil
        whoop5SecureStageDeadlineID = nil
        whoop5NotifyRearmOffPending.removeAll()
        state.encryptedBond = false   // cleared with didBond; next session must re-prove the bond (#69)
        state.charging = nil          // a stale charging flag must not outlive the link
        state.strapFirmware = nil     // a stale firmware version must not outlive the link
        state.clearBiometrics()       // and a stale HR / R-R must not outlive the link either
        state.liveFeedActive = false  // a drop while Live is open must not leave a stale "Stop live feed"
        didBond = false
        whoop5RealtimeArmed = false
        // The strap forgets the realtime-HR toggle across a disconnect; the post-bond branch re-arms it
        // from `wantsRealtime`. Clear only the "what we last sent" flag — `screenWantsRealtime` /
        // `keepRealtimeForData` (and thus `wantsRealtime`) are intent and must survive a reconnect so the
        // stream comes back automatically.
        realtimeArmed = false
        whoop5SessionStarted = false
        resetClockRecoveryForConnection()
        strapNewestTs = nil
        connectHandshakeDone = false
        cmdNotifyConfirmedActive = false   // #34: a fresh connection needs its own notify-confirm + settle
        connectSettledSignaled = false
        realtimeArmedAt = nil   // cleared after the marginal-radio detector above read it (#80)
        // Reset backfill state so the next connect starts a fresh offload (incl. the syncing pill —
        // a dropped link mid-offload must not leave "Syncing strap history…" stuck on, #77).
        backfillStarted = false
        let disconnectedDuringBackfill = backfilling
        let disconnectMadeFreshProgress = historicalSessionInsertedSensorReceipt
            || (backfiller?.sessionMappedRawRecords ?? 0) > 0
        // #364: burst accounting + spin-detector are per-connection.
        historicalBurstPasses.reset()
        historicalSessionInsertedSensorReceipt = false
        lastSessionEndTrim = nil
        lastHistoricalPassSignature = nil
        historicalRadioDeadline = nil
        // A disconnect terminates the current burst. `exitBackfilling` never ran for an in-flight offload,
        // so first capture THIS session's committed rows before publishing the one deferred refresh edge.
        if disconnectedDuringBackfill {
            let rowsPersisted = backfiller?.sessionRowsPersisted ?? 0
            let droppedImplausible = backfiller?.sessionDroppedImplausible ?? 0
            if droppedImplausible > 0 { IntelligenceEngine.requestTimestampReheal() }
            let progress = backfillBurstPublication.record(
                rowsPersisted: rowsPersisted + (backfiller?.sessionMappedRawRecords ?? 0),
                requiresTimestampHeal: droppedImplausible > 0,
                latestFrontierUnix: backfiller?.sessionDurableMaxTs)
            if let progress {
                state.publishHistoricalSyncProgress(progress)
            }
        }
        historicalEmptyBackoff.recordDisconnect(
            inFlight: disconnectedDuringBackfill,
            freshProgress: disconnectMadeFreshProgress
        )
        // If earlier slices in this burst were durable, publish now rather than requiring a later clean
        // HISTORY_COMPLETE to score/show them.
        publishBackfillBurstIfNeeded()
        backfilling = false
        state.backfilling = false
        state.syncChunksThisSession = 0
        historicalProgress.begin()
        // A mid-sync disconnect bypasses exitBackfilling, so clear the reject counters here too —
        // otherwise a stale non-zero count survives until the next beginBackfill. (#77/#91)
        state.rejectedFramesThisSession = 0
        state.rejectedFramesUnarchived = 0
        state.decodedChunksThisSession = 0
        state.consoleChunksThisSession = 0
        state.r22FlagsAccepted = 0
        state.deepPacketsThisSession = 0
        lastOffloadFrameAt = nil   // #174: don't carry a stale cooldown reference into the next session
        loggedWhoop5OffloadDeepPacket = false
        loggedWhoop5TrailingDeepPacket = false
        // #580: a fresh connection earns a fresh empty-offload streak — a strap that was history-empty last
        // session might bank this time (or vice-versa). Clear the experimental note too; the next offload
        // re-derives it. (The honest flag is per-link, like the syncing pill / reject counters above.)
        whoop5EmptyOffload.reset()
        state.historySyncExperimental = false
        backfillTimeout?.cancel()
        backfillTimeout = nil
        backfillFrameQueue.removeAll()
        backfillDraining = false
        uploadTimer?.cancel()
        uploadTimer = nil
        backfillTimer?.cancel()
        backfillTimer = nil
        keepAliveTimer?.cancel()
        keepAliveTimer = nil
        resetCharacteristics()
        puffinRecorder.flush()   // persist any buffered puffin capture frames before reconnect
        puffinEventLog.close()   // release the event-log handle so the file is safe to export
        puffinDeepBufferLog.close()   // same for the high-rate deep-buffer log (#423)
        Task { @MainActor in await collector?.flushStandardHR() }   // persist any buffered 0x2A37 HR
        if autoReconnectPausedForBondLoop {
            // #747: the bond keeps being refused, so auto-reconnect is paused: we stop hammering a strap that
            // can't bond (the epitaph + paused hint were already surfaced when the give-up tripped). The user
            // re-arms it by tapping Connect. We do NOT schedule a rescan here.
            log("Disconnected\(error.map { ": \($0.localizedDescription)" } ?? ""); auto-reconnect paused (strap keeps refusing to pair; tap Connect once it's free)")
            if TestCentre.active(.connection) {
                state.append(log: "connect down (uptime ends)", domain: .connection)
                state.append(log: "reconnect paused=bondLoop (strap refusing bond)", domain: .connection)
            }
        } else if !intentionalDisconnect {
            log("Disconnected\(error.map { " — \($0.localizedDescription)" } ?? ""); rescanning in 3s")
            // Connection test mode: count + describe the involuntary reconnect churn, and mark the link
            // down for the uptime readout. Gated zero-cost (the .connection bool is read before any string
            // is built). Diagnostic only - the rescan above is unchanged. The count increments only on an
            // INVOLUNTARY drop, mirroring an actual reconnect cycle.
            connReconnectCount += 1
            if TestCentre.active(.connection) {
                let reason = (error as? CBError)?.code == .connectionTimeout
                    ? "connectionTimeout" : connErrorToken(error)
                state.append(log: "connect down (uptime ends)", domain: .connection)
                state.append(log: "reconnect n=\(connReconnectCount) reason=\(reason)", domain: .connection)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                // #78 hole-3: a timer in flight when the give-up trips must not fire an extra attempt
                // (and, via connectFromSystem, can never reset the pause the way the old connect() did).
                guard let self, !self.intentionalDisconnect, !self.autoReconnectPausedForBondLoop else { return }
                self.connectFromSystem()
            }
        } else {
            log("Disconnected (intentional)")
            // A user-initiated teardown ends the churn count for the run and marks the link down so the
            // uptime readout reads "not connected" rather than a stale uptime. Gated zero-cost.
            connReconnectCount = 0
            if TestCentre.active(.connection) {
                state.append(log: "connect down (intentional)", domain: .connection)
            }
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral,
                               error: Error?) {
        log("Failed to connect\(error.map { " — \($0.localizedDescription)" } ?? "")")
        // The strap wiped its bond (a firmware update, or the official WHOOP app re-bonding it). macOS keeps
        // re-presenting the now-stale pairing key, so every reconnect loops on this same error with no
        // recovery and no user guidance. Surface an actionable re-pair guide instead of failing silently —
        // NOOP itself works fine on the new firmware once the stale bond is cleared. (5/MG firmware reset, 2026-06)
        // Connection test mode: a failed connect is part of the reconnect churn the tester is chasing.
        // Gated zero-cost; diagnostic only - the backoff/guide logic below is unchanged.
        if TestCentre.active(.connection) {
            let reason: String
            if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
                reason = "peerRemovedPairing"   // stable token (strap re-bonded elsewhere or firmware reset)
            } else {
                reason = connErrorToken(error)
            }
            state.append(log: "reconnect n=\(connReconnectCount) failedConnect reason=\(reason)", domain: .connection)
        }
        if let cbErr = error as? CBError, cbErr.code == .peerRemovedPairingInformation {
            state.reconnectGuide = """
            Your strap's Bluetooth pairing was reset - usually by a WHOOP firmware update, or the official WHOOP app reconnecting. NOOP works fine on the new firmware; you just need to re-pair:

            1. Quit the official WHOOP app (or turn off Bluetooth on that phone).
            2. Open System Settings → Bluetooth and Forget “WHOOP MG” if it's listed.
            3. Tap the strap repeatedly until its LEDs flash blue (pairing mode).
            4. Come back here and reconnect.
            """
            return
        }
        // Any other connect failure (e.g. a weak-signal encrypted-handshake timeout on a 5/MG at the
        // edge of range — #414). The disconnect path reschedules a rescan, but didFailToConnect never
        // did, so the loop died here until a manual reconnect. Reschedule with a capped exponential
        // backoff (3, 6, 12, 24, 48, 60s…) so a strap that's genuinely out of range doesn't hammer BLE.
        // #747: don't reschedule while the bond-loop pause is active; the user must free the strap first.
        guard !intentionalDisconnect, !autoReconnectPausedForBondLoop else { return }
        failedConnectAttempts += 1
        let delay = min(60.0, 3.0 * pow(2.0, Double(failedConnectAttempts - 1)))
        log("Reconnecting in \(Int(delay))s (attempt \(failedConnectAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            // #78 hole-3: a backoff timer in flight when the give-up trips must not fire an extra
            // attempt (and connectFromSystem never resets the pause the way the old connect() did).
            guard let self, !self.intentionalDisconnect, !self.autoReconnectPausedForBondLoop else { return }
            self.connectFromSystem()
        }
    }

    /// State restoration entry point (M3 background collection).
    /// Stores the restored peripheral and — if already connected — immediately
    /// re-discovers services so `cmdCharacteristic` is re-acquired and
    /// notifications are re-routed without user interaction.
    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let p = peripherals.first else {
            log("Restore: no peripherals in state dict")
            return
        }
        self.peripheral = p
        self.restoredPeripheral = p
        p.delegate = self
        resetCharacteristics()
        // Re-derive the inbound-decode family from the persisted model. connect()/startScan() set the
        // reassembler + router family, but NEITHER runs on the restore path — so without this a restored
        // WHOOP 5/MG would decode its puffin notify frames with the default .whoop4 framing (different
        // length offset + constant), producing corrupt/empty data for the whole unattended session until
        // the user manually taps connect.
        selectedModel = .persisted
        reassembler = Reassembler(family: selectedModel.deviceFamily)
        router.family = selectedModel.deviceFamily
        configureCollectorFamily()
        // CoreBluetooth restoration proves only that the OS remembers a peripheral. It does not prove
        // this process owns a current encrypted protocol session. Both connected and disconnected restore
        // shapes therefore start with every authorization flag cleared.
        state.bonded = false
        state.encryptedBond = false
        didBond = false
        connectHandshakeDone = false
        whoop5SessionStarted = false
        // A restored connection is a fresh physical link for the bounded GET_CLOCK retry state. The
        // process usually has no clockRef after restore, but treating this as a fresh generation also
        // prevents a stale Data Range marker/retry counter from a pre-suspension connection leaking in.
        resetClockRecoveryForConnection()
        strapNewestTs = nil
        // Ensure the store is ready before restored BLE data arrives (idempotent; no-op if already built).
        Task { @MainActor in await bootstrapStore() }
        if p.state == .connected {
            admitConnectionGeneration(p)
            connectedPeripheralUUID = p.identifier.uuidString
            state.markConnected()
            log("Restored CONNECTED peripheral \(p.identifier) — unverified; re-discovering secure session")
            discoverPrimaryServices(on: p)
        } else {
            invalidateHistoricalBackfill(reason: "restored peripheral is disconnected and unverified")
            whoop5SecureSession.disconnect()
            state.markDisconnected()
            log("Restored DISCONNECTED peripheral \(p.identifier) — unverified; reconnect on poweredOn")
            if central.state == .poweredOn { central.connect(p, options: nil) }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BLEManager: @preconcurrency CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrentPeripheralCallback(peripheral) else {
            log("Ignored stale service-discovery callback for \(peripheral.identifier)")
            return
        }
        if let error {
            log("Service discovery failed: \(error.localizedDescription)")
            return
        }
        guard let services = peripheral.services else { return }
        log("Services discovered: \(services.map { $0.uuid.uuidString }.joined(separator: ", "))")
        for s in services {
            switch s.uuid {
            case BLEManager.customService:
                peripheral.discoverCharacteristics(
                    [BLEManager.cmdWriteChar, BLEManager.cmdNotifyChar,
                     BLEManager.eventNotifyChar, BLEManager.dataNotifyChar], for: s)
            case BLEManager.heartRateService:
                peripheral.discoverCharacteristics([BLEManager.heartRateChar], for: s)
            case BLEManager.batteryService:
                peripheral.discoverCharacteristics([BLEManager.batteryChar], for: s)
            case BLEManager.whoop5Service:
                // EXPERIMENTAL WHOOP 5.0/MG path: discover the puffin command + notify characteristics
                // so we can send CLIENT_HELLO and receive frames. Live HR/battery still arrive over the
                // standard 0x2A37/0x2A19 profiles (discovered alongside this); this custom path is
                // unverified on MG hardware.
                if whoop5SecureSession.state == .standardOnly {
                    log("WHOOP 5/MG detected — discovering puffin characteristics (experimental).")
                    peripheral.discoverCharacteristics(
                        [BLEManager.whoop5CmdWriteChar] + BLEManager.whoop5NotifyChars, for: s)
                } else {
                    log("WHOOP 5/MG: skipped duplicate puffin discovery for secure state \(whoop5SecureSession.state.rawValue)")
                }
            default: break
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        guard isCurrentPeripheralCallback(peripheral),
              isCurrentServiceCallback(service, on: peripheral) else {
            log("Ignored stale characteristic-discovery callback for \(peripheral.identifier)")
            return
        }
        if let error {
            log("Characteristic discovery failed for \(service.uuid): \(error.localizedDescription)")
            return
        }
        guard let chars = service.characteristics else { return }
        for c in chars {
            switch c.uuid {
            case BLEManager.cmdWriteChar:
                cmdCharacteristic = c
                // THE BONDING TRICK: one confirmed write triggers just-works bonding.
                // GET_BATTERY_LEVEL is benign and what the Mac prototype uses.
                seq = seq &+ 1
                let bondFrame = WhoopCommand.getBatteryLevel.frame(seq: seq, payload: [0x00])
                log("Bonding: confirmed write GET_BATTERY_LEVEL to 61080002")
                writeValue(Data(bondFrame), to: c, on: peripheral, type: .withResponse,
                           confirmedPurpose: Self.handshakeConfirmedWritePurpose(for: .whoop4))
            case BLEManager.whoop5CmdWriteChar:
                if Self.shouldRevokeFrozenCharacteristic(
                    hasFrozenInstance: whoop5FrozenCommandCharacteristic != nil,
                    isSameInstance: whoop5FrozenCommandCharacteristic === c),
                   let sessionID = currentWhoop5SecureSessionID {
                    failWhoop5SecureSession(sessionID, reason: "command characteristic instance changed")
                    return
                }
                cmdCharacteristic = c
                _ = characteristicIdentity(for: c)
            case BLEManager.cmdNotifyChar,
                 BLEManager.eventNotifyChar,
                 BLEManager.dataNotifyChar,
                 BLEManager.heartRateChar,
                 BLEManager.batteryChar:
                switch c.uuid {
                case BLEManager.cmdNotifyChar: cmdNotifyCharacteristic = c
                case BLEManager.eventNotifyChar: eventNotifyCharacteristic = c
                case BLEManager.dataNotifyChar: dataNotifyCharacteristic = c
                case BLEManager.heartRateChar: heartRateCharacteristic = c
                case BLEManager.batteryChar:
                    batteryCharacteristic = c
                    if c.properties.contains(.read) {
                        peripheral.readValue(for: c)
                    }
                default: break
                }
                requestNotify(c, on: peripheral, reason: "discovery")
            default:
                // WHOOP 5.0/MG puffin notify characteristics (fd4b0003/0004/0005/0007). Retain them but DO
                // NOT subscribe yet — on an unauthenticated link the strap rejects them with "Authentication
                // is insufficient", which (per a 5/MG owner's verified flow, issue #17) also wedges the bond.
                // didWriteValueFor subscribes them once the CLIENT_HELLO .withResponse write confirms.
                if BLEManager.whoop5NotifyChars.contains(c.uuid) {
                    let key = c.uuid.uuidString.lowercased()
                    if Self.shouldRevokeFrozenCharacteristic(
                        hasFrozenInstance: whoop5FrozenNotifyCharacteristics[key] != nil,
                        isSameInstance: whoop5FrozenNotifyCharacteristics[key] === c),
                       let sessionID = currentWhoop5SecureSessionID {
                        failWhoop5SecureSession(sessionID, reason: "protected characteristic \(key) instance changed")
                        return
                    }
                    if let index = whoop5NotifyCharacteristics.firstIndex(where: { $0.uuid == c.uuid }) {
                        // A duplicate discovery can replace CoreBluetooth's characteristic object. Keep
                        // the current instance so a callback for the retired object cannot prove this one.
                        if whoop5NotifyCharacteristics[index] !== c {
                            whoop5NotifyCharacteristics[index] = c
                        }
                    } else {
                        whoop5NotifyCharacteristics.append(c)
                    }
                    _ = characteristicIdentity(for: c)
                }
            }
        }
        // One fd4b discovery callback represents the complete requested set. Retain every characteristic
        // first, then let the current attempt coalesce the one allowed CLIENT_HELLO write.
        if service.uuid == BLEManager.whoop5Service,
           let sessionID = currentWhoop5SecureSessionID,
           let commandCharacteristic = cmdCharacteristic {
            let required = Set(Self.whoop5NotifyChars.map { $0.uuidString.lowercased() })
            let discovered = Set(whoop5NotifyCharacteristics.map { $0.uuid.uuidString.lowercased() })
            let shouldSendHello = whoop5SecureSession.collectProtectedCharacteristics(
                commandCharacteristicFound: commandCharacteristic.uuid == Self.whoop5CmdWriteChar,
                requiredNotificationIDs: required,
                discoveryComplete: discovered == required,
                sessionID: sessionID)
            if shouldSendHello, let hello = selectedModel.deviceFamily.clientHello {
                whoop5FrozenCommandCharacteristic = commandCharacteristic
                whoop5FrozenNotifyCharacteristics = Dictionary(
                    uniqueKeysWithValues: whoop5NotifyCharacteristics.map {
                        ($0.uuid.uuidString.lowercased(), $0)
                    })
                armWhoop5SecureStageDeadline(for: sessionID)
                log("WHOOP 5/MG: fd4b set collected; writing one CLIENT_HELLO with response")
                state.pairingHint = nil
                writeValue(
                    Data(hello),
                    to: commandCharacteristic,
                    on: peripheral,
                    type: .withResponse,
                    confirmedPurpose: .clientHello,
                    command: 0,
                    requestSequence: 0)
            }
        }
    }

    /// Route each confirmed-write completion through its registered owner.
    public func peripheral(_ peripheral: CBPeripheral,
                           didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        // Consume the matching `.withResponse` write before validating the active link. A callback from
        // an old peripheral or characteristic still retires its exact queued token, so it cannot swallow
        // a later write from the current connection.
        let callbackCharacteristicIdentity = characteristicIdentity(for: characteristic)
        let tokenIndex = confirmedCommandWrites.firstIndex(where: {
            $0.peripheralID == peripheral.identifier
                && $0.characteristicUUID == characteristic.uuid
                && $0.characteristicIdentity == callbackCharacteristicIdentity
        })
        if tokenIndex == nil {
            let message = "Unexpected confirmed-write callback without an owner for the active BLE connection."
            log("Protocol error: \(message) peripheral=\(peripheral.identifier) characteristic=\(characteristic.uuid)")
            if isCurrentPeripheralCallback(peripheral), self.peripheral?.state == .connected {
                state.historicalSyncSessionState = .failed
                state.lastSyncError = connectHandshakeDone
                    ? "History sync failed because a BLE write callback had no registered owner. Reconnect the strap."
                    : "Secure handshake failed because its BLE write callback had no registered owner. Reconnect the strap."
            }
            return
        }
        let confirmedWrite = confirmedCommandWrites.remove(at: tokenIndex!)
        let isWhoop5CommandWrite = characteristic.uuid == Self.whoop5CmdWriteChar
        let wasActiveWhoop5Operation = !isWhoop5CommandWrite
            || activeWhoop5ConfirmedWriteID == confirmedWrite.id
        if isWhoop5CommandWrite, wasActiveWhoop5Operation {
            activeWhoop5ConfirmedWriteID = nil
            whoop5ConfirmedWriteTimeout?.cancel()
            whoop5ConfirmedWriteTimeout = nil
        }
        let acceptsGeneration = Self.shouldAcceptConfirmedWriteCallback(
                eventPeripheralID: peripheral.identifier,
                eventCharacteristicUUID: characteristic.uuid,
                activePeripheralID: self.peripheral?.identifier,
                activePeripheralIsConnected: self.peripheral?.state == .connected,
                activeConnectGeneration: connectGeneration,
                queuedPeripheralID: confirmedWrite.peripheralID,
                queuedCharacteristicUUID: confirmedWrite.characteristicUUID,
                queuedConnectGeneration: confirmedWrite.connectGeneration)
        let acceptsSecureAttempt = confirmedWrite.secureAttemptEpoch == nil
            || confirmedWrite.secureAttemptEpoch == currentWhoop5SecureSessionID?.attemptEpoch
        if !acceptsGeneration || !acceptsSecureAttempt || !wasActiveWhoop5Operation
            || !isCurrentPeripheralCallback(peripheral) || !isCurrentCharacteristicCallback(characteristic) {
            log("Ignored stale confirmed-write callback from BLE generation \(confirmedWrite.connectGeneration)")
            return
        }
        if isWhoop5CommandWrite { issueNextWhoop5ConfirmedWriteIfPossible() }
        if confirmedWrite.purpose == .historicalAck, let historicalAck = confirmedWrite.historicalAck {
            if let pending = pendingHistoricalAck,
               pending.characteristicUUID == characteristic.uuid,
               pending.admission.peripheralID == peripheral.identifier,
               pending.admission == historicalAck.admission,
               pending.trim == historicalAck.trim {
                let stillCurrent = isCurrentHistoricalBackfill(pending.admission)
                let acknowledged = error == nil && stillCurrent
                completePendingHistoricalAck(
                    acknowledged,
                    reason: error.map { "CoreBluetooth write failed: \($0.localizedDescription)" }
                        ?? (stillCurrent ? nil : "admission is no longer current"))
                // The exact counter remains local for liveness; publish no more than 4 Hz so a
                // high-throughput backlog does not invalidate the whole Devices screen per ACK.
                if acknowledged,
                   let visible = historicalProgress.acknowledge(now: Date().timeIntervalSince1970) {
                    state.syncChunksThisSession = visible
                }
            } else {
                log("Backfill: ignored delayed historical ACK callback after its session ended or changed")
            }
            return
        }
        guard confirmedWrite.purpose != .historicalAck else {
            log("Protocol error: historical ACK token had no historical admission identity")
            state.historicalSyncSessionState = .failed
            state.lastSyncError = "History sync failed because its BLE acknowledgment lost session ownership. Reconnect the strap."
            return
        }
        if confirmedWrite.purpose == .protocolProof {
            guard let sessionID = currentWhoop5SecureSessionID else { return }
            let accepted = whoop5SecureSession.confirmProtocolProofWrite(
                sessionID: sessionID,
                succeeded: error == nil)
            log(error == nil
                ? "WHOOP 5/MG GET_HELLO proof: ATT confirmed"
                : "WHOOP 5/MG GET_HELLO proof: ATT failed")
            if let error {
                failWhoop5SecureSession(sessionID, reason: "GET_HELLO ATT failed: \(error.localizedDescription)")
            } else if accepted, whoop5SecureReady {
                completeWhoop5SecureReady(sessionID: sessionID)
            }
            return
        }
        if confirmedWrite.purpose == .genericCommand {
            if let error {
                if confirmedWrite.command == 0x13 {
                    pendingWhoop5HapticResponses.remove(confirmedWrite.requestSequence)
                }
                if confirmedWrite.command == WhoopCommand.setConfig.rawValue,
                   var attempt = whoop5R22Attempt {
                    attempt.discard(requestSequence: confirmedWrite.requestSequence)
                    whoop5R22Attempt = attempt
                }
                log("Confirmed command write failed: \(error.localizedDescription)")
            } else {
                if confirmedWrite.command == 0x13 {
                    log("Buzz: ATT confirmed for request sequence \(confirmedWrite.requestSequence); protocol and physical confirmation still pending")
                } else {
                    log("Confirmed command write acknowledged")
                }
            }
            return
        }
        let expectedFamily: DeviceFamily = confirmedWrite.purpose == .clientHello ? .whoop5 : .whoop4
        guard selectedModel.deviceFamily == expectedFamily else {
            log("Protocol error: confirmed \(confirmedWrite.purpose) callback does not match selected family \(selectedModel.deviceFamily)")
            state.historicalSyncSessionState = .failed
            state.lastSyncError = "Secure handshake failed because the BLE callback did not match the connected device family. Reconnect the strap."
            return
        }
        if let error = error {
            let failedWhoop5SessionID = confirmedWrite.purpose == .clientHello
                ? currentWhoop5SecureSessionID : nil
            if let sessionID = failedWhoop5SessionID {
                _ = whoop5SecureSession.confirmClientHello(sessionID: sessionID, succeeded: false)
            }
            state.historicalSyncSessionState = .failed
            state.lastSyncError = "Secure handshake failed: \(error.localizedDescription)"
            log("Confirmed write failed: \(error.localizedDescription)")
            // #78 hole-1: classify by ATT code first (locale-proof), English string fallback second.
            // This one change repairs the pairing hint (streak>=2), the #747 give-up (5) AND the #52
            // stale-pin handoff below for non-English devices, which all key off this same flag.
            let insufficient = BLEManager.isInsufficientAuthError(error)
            // Connection test mode: surface the failed-encrypt / "held by another central" hint as an
            // upfront tagged line (the strap is still bonded to the official WHOOP app or a stale OS
            // pairing, so the just-works bond is refused). Gated zero-cost; diagnostic only.
            if TestCentre.active(.connection) {
                state.append(log: insufficient
                    ? "otherCentral bondWrite refused=insufficient (strap likely held by the WHOOP app or a stale pairing; cannot start a fresh encrypted bond)"
                    : "otherCentral bondWrite failed=\(connErrorToken(error))", domain: .connection)
            }
            // WHOOP 5/MG first connect: CoreBluetooth won't start a fresh just-works bond against a strap
            // still bonded to the official WHOOP app, so the CLIENT_HELLO .withResponse write fails with
            // "Encryption/Authentication is insufficient" and the link never authenticates. Surface
            // actionable pairing-mode guidance instead of failing silently (issue #17).
            if selectedModel.deviceFamily == .whoop5, !didBond, insufficient {
                bondRefusalStreak += 1
                // #78: surface the pairing-mode guidance once refusals are PERSISTENT — the strap is
                // genuinely refusing the encrypted bond (held by the official WHOOP app, or iOS holds a
                // stale/half pairing it can't re-encrypt, e.g. after a "Restored CONNECTED peripheral").
                // A SINGLE refusal right after a known-good bond (#74) is a transient reconnect race, so we
                // stay quiet on streak 1; from streak 2 we tell the user how to make the strap pairable.
                // (Earlier 5.2.3 logic keyed this off lastBondedPeripheralUUID and wrongly hid the guidance
                // for users whose strap had bonded in a PRIOR session but won't now — exactly #78.)
                if bondGiveUp.gaveUp {
                    // #78 hole-4: a refusal during a paused-state salvage probe must not stomp the paused
                    // hint back to the pairing hint (or flap the banner per probe). The streak keeps
                    // counting silently; recordRefusal() below stays false (latched), so no epitaph spam.
                    log("WHOOP 5/MG: bond still refused during a paused-state probe (streak \(bondRefusalStreak)) - the give-up stays latched")
                } else if bondRefusalStreak >= 2 {
                    state.pairingHint = "NOOP can see your strap but it's refusing to pair - it's likely still bonded to the official WHOOP app, or your phone is holding an old pairing. To fix it: (1) fully close the WHOOP app, (2) on a 5.0/MG, tap the band repeatedly until the LEDs flash blue (pairing mode), (3) if your strap is listed under iPhone Settings → Bluetooth, tap it and choose Forget This Device, then reconnect in NOOP."
                    log("WHOOP 5/MG: bond refused \(bondRefusalStreak)× with no successful bond — the strap is refusing the encrypted link (WHOOP app holds it, or a stale iOS pairing). Surfacing pairing-mode + forget-device guidance (#78).")
                } else {
                    log("WHOOP 5/MG: bond write refused (insufficient) — retrying once; will surface pairing-mode guidance if it persists (#78).")
                }
                // #747 / #750: feed the same refusal into the give-up tracker. Once it crosses the higher
                // threshold (the pairing hint has had several cycles to be acted on), pause auto-reconnect so
                // we stop hammering a strap that can't bond, write the one-line epitaph (opaque id only, no
                // PII), and surface the honest paused hint. A genuine bond or a manual reconnect re-arms it.
                if bondGiveUp.recordRefusal() {
                    autoReconnectPausedForBondLoop = true
                    bondLoopPausedAt = Date()   // starts the #78 hole-4 salvage-probe floor
                    let opaque = BondRefusalGiveUp.opaqueId(fromLocalUUID: peripheral.identifier.uuidString)
                    log(BondRefusalGiveUp.epitaphLine(refusals: bondGiveUp.refusals, opaqueId: opaque))
                    state.pairingHint = BondRefusalGiveUp.pausedHint()
                    if TestCentre.active(.connection) {
                        state.append(log: "bond gaveUp refusals=\(bondGiveUp.refusals) id=\(opaque) (auto-reconnect paused)", domain: .connection)
                    }
                }
            }
            // Multi-WHOOP stale-pin recovery (#52). When a stale registry pin points at a strap that keeps
            // refusing the encrypted bond ("Encryption/Authentication is insufficient") but a DIFFERENT
            // strap has bonded fine this run, connect() otherwise drops the working strap and loops forever
            // on the dead pin — encryptedBond never turns true (which also kills buzz/haptics that gate on
            // it). Count consecutive refusals on the PINNED peripheral; after `pinBondRefusalLimit`, hand
            // the pin off to the live-bonding strap so the registry re-adopts it (handoff republishes the
            // working uuid on the connectedPeripheralUUID seam SourceCoordinator already observes).
            if insufficient, !didBond,
               let pinned = preferredPeripheralUUID, peripheral.identifier == pinned {
                pinnedBondRefusals += 1
                if pinnedBondRefusals >= pinBondRefusalLimit,
                   let working = lastBondedPeripheralUUID, working != pinned {
                    readoptWorkingStrap(working, awayFrom: pinned)
                }
            }
            if let sessionID = failedWhoop5SessionID {
                failWhoop5SecureSession(sessionID, reason: "CLIENT_HELLO ATT failed: \(error.localizedDescription)")
            }
            return
        }

        // EXPERIMENTAL WHOOP 5.0/MG (issue #17): the CLIENT_HELLO is now a .withResponse write, so this
        // fires once the strap acks it — after just-works bonding if the link needed authenticating.
        // Treat that as the link being established: mark bonded (which clears the "Finishing the secure
        // pairing handshake…" status) and re-subscribe the puffin notify chars + standard HR/battery,
        // which the strap refused before the link was encrypted. Do NOT run the WHOOP4 command handshake
        // below — a 5/MG strap rejects WHOOP4-framed commands (the send() guard drops them anyway).
        if selectedModel.deviceFamily == .whoop5 {
            guard let sessionID = currentWhoop5SecureSessionID,
                  whoop5SecureSession.confirmClientHello(sessionID: sessionID, succeeded: true) else {
                log("WHOOP 5/MG: ignored CLIENT_HELLO callback outside the current pending attempt")
                return
            }
            state.pairingHint = nil
            bondRefusalStreak = 0
            bondGiveUp.reset()
            autoReconnectPausedForBondLoop = false
            bondLoopPausedAt = nil
            log("WHOOP 5/MG: CLIENT_HELLO ATT confirmed — requesting protected notifications")
            armWhoop5SecureStageDeadline(for: sessionID)
            for c in whoop5FrozenNotifyCharacteristics.values {
                let key = c.uuid.uuidString.lowercased()
                switch Self.whoop5InitialNotificationAction(isAlreadyNotifying: c.isNotifying) {
                case .requestOffBeforeOn:
                    whoop5NotifyRearmOffPending.insert(key)
                    peripheral.setNotifyValue(false, for: c)
                    log("WHOOP 5/MG: re-proving restored protected notification \(key) off then on")
                case .requestOn:
                    requestNotify(c, on: peripheral, reason: "post-hello puffin")
                }
            }
            enableLiveNotifications(reason: "post-bond 5/MG")   // standard HR/battery that failed pre-bond
            return
        }

        if !didBond {
            didBond = true
            state.bonded = true
            state.encryptedBond = true   // WHOOP 4 confirmed-write bond is always genuine — #69
            state.historicalSyncSessionState = .ready
            bondedAt = Date()            // #617: start the bond→drop stopwatch for the bond-loop detector
            noteGenuineBond(of: peripheral)   // #52: this strap bonds fine; clears any pin-refusal streak
            emitConnectionBondState("encryptedBond family=whoop4 (confirmed write acked)")
            log("BONDED (confirmed write acknowledged) — custom channels should now flow")
        }
        // Run the connect handshake EXACTLY ONCE per connection. Purpose-owned callbacks prevent later
        // command and history ACK writes from entering this branch. Keep the guard as defense in depth.
        guard !connectHandshakeDone else { return }
        connectHandshakeDone = true
        noteRebootReconnectIfNeeded()
        backfillStarted = true

        // WHOOP-faithful connect lifecycle: hello → set RTC,
        // then offload. Hello is NOT strictly required to serve — verified on this strap via the Mac
        // ground-truth test: plain SEND_HISTORICAL_DATA serves type-47 with no hello and no high-freq-sync
        // (PHASE A = 50 records; PHASE B high-freq = 0). We still exchange hello to mirror WHOOP exactly.
        send(.getHelloHarvard)
        send(.getAdvertisingNameHarvard)
        // One-shot firmware-version read for the Devices card. These are read-only commands (not
        // firmware-load opcodes); send the one this family answers and let the other be ignored. The
        // reply decodes to fw_harvard (4.0) / fw_version (5/MG) and FrameRouter posts it to LiveState.
        switch selectedModel.deviceFamily {
        case .whoop4: send(.reportVersionInfo)
        case .whoop5: send(.getHello)
        }
        sendSetClockBothForms()
        requestClockCorrelationIfNeeded()
        send(.sendR10R11Realtime, payload: [0x00])   // stop the type-43 realtime flood (BLE airtime/battery)
        send(.getDataRange)                          // refresh the strap's stored range for the watchdog
        // Plain offload (no high-freq-sync), rate-limited (first connect always runs; reconnect-flaps are
        // throttled by BackfillPolicy). Deferred ~1.5s so SET_CLOCK/GET_DATA_RANGE round-trip first and
        // SEND_HISTORICAL runs on a settled link, like the paced Mac prototype. beginBackfill is itself
        // gated on connectHandshakeDone so a racing foreground/restore trigger can't fire it early.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.requestSync(.connect) }
        startBackfillTimer()   // re-offload the type-47 store every backfillIntervalSeconds
        startKeepAlive()       // always-ping: re-arm realtime, poll battery, watchdog the link
        enableLiveNotifications(reason: "post-bond")   // includes 0x2A37 standard HR — the fallback path
        // #927: RE-DERIVE the want at arm time (same reasoning as the 5/MG branch above): a reconnect
        // outside the overnight window must not arm the flood from a stale precomputed `wantsRealtime`
        // (up to a keep-alive tick stale); the keep-alive would then hold it armed for another 30 s.
        let realtimeWantNow = screenWantsRealtime || continuousCaptureWantsNow()
        wantsRealtime = realtimeWantNow
        if realtimeWantNow {
            if standardHRFallback {
                // #80: this radio repeatedly dropped the link the instant we armed the R10/R11 burst.
                // Skip the heavy stream entirely; live HR rides the already-subscribed low-bandwidth
                // 0x2A37 standard profile (subscribed by enableLiveNotifications above). SAFE either way:
                // if 0x2A37 emits the user gets live HR on a radio that otherwise died; if it doesn't, at
                // least the arm→die loop stops.
                log("Realtime HR: standard-HR mode (low bandwidth) — skipping R10/R11 arm (#80)")
                state.standardHRMode = "Standard HR mode (low bandwidth) - your Bluetooth radio couldn't sustain the full stream; live heart rate via the standard profile."
            } else {
                log("Realtime HR: arming after bond")
                realtimeArmed = true   // keep reconcileRealtime()'s edge tracking in sync with the arm
                send(.sendR10R11Realtime, payload: [0x01])
                send(.toggleRealtimeHR, payload: [0x01])
                realtimeArmedAt = Date()   // start the arm→drop stopwatch for the marginal-radio detector
            }
        }
        // #34: the handshake body above (hello, SET_CLOCK, notify-resubscribe requests) has now been
        // fully ISSUED — check whether the cmd-notify characteristic has also CONFIRMED (the other half
        // may already have landed, e.g. from the discovery-phase subscribe, or may still be in flight and
        // land via didUpdateNotificationStateFor below).
        maybeSignalConnectSettled()
    }

    /// #34: bump `state.connectSettled` once, per connection, the first moment BOTH `connectHandshakeDone`
    /// (hello + SET_CLOCK sent) AND `cmdNotifyConfirmedActive` (cmd-notify characteristic confirmed
    /// subscribed) are true — whichever lands second. Called from the tail of the WHOOP4 handshake and
    /// from `didUpdateNotificationStateFor` on a cmd-notify confirmation; a no-op until both are true, and
    /// latched by `connectSettledSignaled` so it can't double-bump on a second call. This is the signal
    /// the alarm re-arm (AppModel's `live.$connectSettled` sink) waits on instead of raw `bonded`, so
    /// SET_ALARM_TIME/GET_ALARM_TIME go out on a link whose reply channel is confirmed live (#34).
    private func maybeSignalConnectSettled() {
        guard connectHandshakeDone, cmdNotifyConfirmedActive, !connectSettledSignaled else { return }
        connectSettledSignaled = true
        state.connectSettled &+= 1
        log("Connect settled: handshake done + cmd-notify confirmed — alarm re-arm (if due) can fire now")
    }

    private func handleWhoop5CommandResponse(_ parsed: ParsedFrame, frame: [UInt8]) {
        guard parsed.typeName == "COMMAND_RESPONSE",
              frame.count > 10,
              let sessionID = currentWhoop5SecureSessionID,
              let requestSequenceValue = parsed.responseRequestSequence,
              let resultValue = parsed.responseResult,
              let requestSequence = UInt8(exactly: requestSequenceValue),
              let result = UInt8(exactly: resultValue) else { return }
        let command = frame[10]
        let integrityValid = parsed.envelopeOK
            && parsed.headerCRCOK == true
            && parsed.payloadCRCOK == true

        let secureStateBeforeResponse = whoop5SecureSession.state
        if whoop5SecureSession.acceptProtocolProofResponse(
            command: command,
            requestSequence: requestSequence,
            result: result,
            integrityValid: integrityValid,
            sessionID: sessionID) {
            log("WHOOP 5/MG GET_HELLO proof: protocol accepted for current session")
            completeWhoop5SecureReady(sessionID: sessionID)
            return
        }
        if secureStateBeforeResponse == .protocolProofPending,
           whoop5SecureSession.state == .failed {
            failWhoop5SecureSession(sessionID, reason: "GET_HELLO protocol proof was rejected")
            return
        }

        if command == WhoopCommand.setConfig.rawValue, var attempt = whoop5R22Attempt {
            let outcome = attempt.acceptResponse(
                command: command,
                requestSequence: requestSequence,
                result: result,
                integrityValid: integrityValid,
                sessionID: sessionID)
            whoop5R22Attempt = attempt
            state.r22FlagsAccepted = attempt.acceptedFlags.count
            switch outcome {
            case let .accepted(flag):
                log("Deep-data: SET_CONFIG seq=\(requestSequence) accepted (\(attempt.acceptedFlags.count)/\(Whoop5Config.enableR22Sequence.count))")
                log("Deep-data: accepted R22 flag \(flag)")
            case let .rejected(flag, rejectionResult):
                log("Deep-data: SET_CONFIG seq=\(requestSequence) flag=\(flag) rejected result=\(rejectionResult)")
            case .ignored:
                break
            }
        }

        if command == 0x13, pendingWhoop5HapticResponses.contains(requestSequence) {
            guard integrityValid else {
                log("Buzz: protocol response failed CRC/envelope validation for request sequence \(requestSequence)")
                return
            }
            pendingWhoop5HapticResponses.remove(requestSequence)
            if result == 1 {
                log("Buzz: protocol accepted request sequence \(requestSequence); physical motor confirmation is still device-observed proof")
            } else {
                log("Buzz: protocol rejected request sequence \(requestSequence) result=\(result); no physical confirmation")
            }
        }
    }

    private func completeWhoop5SecureReady(sessionID: Whoop5SecureSessionID) {
        guard currentWhoop5SecureSessionID == sessionID,
              whoop5SecureSession.authorizesProprietaryCommand(sessionID: sessionID),
              !whoop5SessionStarted else { return }
        whoop5SecureStageTimeout?.cancel()
        whoop5SecureStageTimeout = nil
        whoop5SecureStageDeadlineID = nil
        whoop5NotifyRearmOffPending.removeAll()
        whoop5SessionStarted = true
        connectHandshakeDone = true
        didBond = true
        state.bonded = true
        state.encryptedBond = true
        state.historicalSyncSessionState = .ready
        state.standardHRMode = nil
        bondedAt = Date()
        state.pairingHint = nil
        bondRefusalStreak = 0
        bondGiveUp.reset()
        autoReconnectPausedForBondLoop = false
        bondLoopPausedAt = nil
        if let peripheral { noteGenuineBond(of: peripheral) }
        emitConnectionBondState("encryptedBond family=whoop5 (GET_HELLO protocol proof accepted)")
        noteRebootReconnectIfNeeded()

        let realtimeWantNow = screenWantsRealtime || continuousCaptureWantsNow()
        wantsRealtime = realtimeWantNow
        if realtimeWantNow && !whoop5RealtimeArmed {
            whoop5RealtimeArmed = true
            realtimeArmed = true
            send(.toggleRealtimeHR, payload: [0x01])
        }
        startKeepAlive()
        if PuffinExperiment.broadcastHrEnabled { setBroadcastHr(true) }
        send(.setClock, payload: BLEManager.setClockPayload())
        send(.getClock, payload: [])
        log("WHOOP 5/MG: secureReady — proprietary commands and history admitted")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.currentWhoop5SecureSessionID == sessionID, self.whoop5SecureReady else { return }
            self.requestSync(.connect)
        }
        startBackfillTimer()
        if !connectSettledSignaled {
            connectSettledSignaled = true
            state.connectSettled &+= 1
        }
    }

    /// SET_CLOCK(10) payload — the 8-byte form `[seconds u32 LE][subseconds u32 LE]`, subseconds in
    /// 1/32768 s (0 is fine). The payload LENGTH is firmware-specific and LOAD-BEARING: newer WHOOP 4
    /// firmware latches this form, but fw 41.17.x ignores it outright — no COMMAND_RESPONSE, RTC
    /// unchanged — and latches only the legacy 9-byte form below. A strap that misses the set keeps an
    /// invalid RTC and stops banking sensor data to flash entirely, which surfaces as endless
    /// console-only syncs and no sleep/recovery (#120). Send WHOOP 4 through sendSetClockBothForms()
    /// so either firmware latches.
    static func setClockPayload(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0]
    }

    /// SET_CLOCK(10) payload — the legacy 9-byte form `[seconds u32 LE][5 zero]` required by WHOOP 4
    /// fw 41.17.x, which ignores the 8-byte form. On a strap whose RTC was stuck in the past, days of
    /// 8-byte sends drew no response; the 9-byte form was ack'd (COMMAND_RESPONSE cmd 10), the clock
    /// latched and ticked, and the strap resumed banking history to flash (#120). On newer firmware
    /// this form is ack'd but NOT latched, so sending it after the 8-byte form is a no-op there — both
    /// forms carry the same seconds, so whichever one latches sets the same time.
    static func setClockPayloadLegacy(now: UInt32 = UInt32(Date().timeIntervalSince1970)) -> [UInt8] {
        [UInt8(now & 0xFF), UInt8((now >> 8) & 0xFF),
         UInt8((now >> 16) & 0xFF), UInt8((now >> 24) & 0xFF),
         0, 0, 0, 0, 0]
    }

    /// Send SET_CLOCK in every payload form the WHOOP 4 firmware family is known to accept (8-byte for
    /// newer firmware, 9-byte for 41.17.x — each a no-op on the other). Both carry the same `now`, so
    /// double-latching is harmless. WHOOP 5/MG keeps its single hardware-validated 8-byte send (its
    /// connect path calls setClockPayload() directly; the 9-byte form is unverified on that family), so
    /// the legacy form is gated to WHOOP 4. (#120)
    func sendSetClockBothForms() {
        let now = UInt32(Date().timeIntervalSince1970)
        send(.setClock, payload: BLEManager.setClockPayload(now: now))
        if selectedModel.deviceFamily == .whoop4 {
            send(.setClock, payload: BLEManager.setClockPayloadLegacy(now: now))
        }
    }

    /// Start one precise GET_CLOCK request for this connection when the current reference is absent or
    /// only approximate. WHOOP 5/MG deliberately stays out: its firmware does not serve GET_CLOCK and
    /// its realtime/historical frames already carry real Unix time.
    private func requestClockCorrelationIfNeeded() {
        guard selectedModel.deviceFamily == .whoop4,
              !hasPreciseClockCorrelation,
              !clockRequested
        else { return }

        clockRequested = true
        // GET_CLOCK's payload length is firmware-specific: newer firmware answers the empty form while
        // 41.17.x answers [0x00]. Sending both retains the established, hardware-tested command path.
        send(.getClock, payload: [])
        send(.getClock, payload: [0x00])
        armClockRecoveryTimeout(for: connectGeneration)
    }

    private var hasPreciseClockCorrelation: Bool {
        clockRef != nil && !clockRefIsApproximate
    }

    private func resetClockRecoveryForConnection() {
        clockRecoveryTimeout?.cancel()
        clockRecoveryTimeout = nil
        clockRecovery.reset()
        clockRequested = false
        // A fallback is only a same-connection best effort based on that link's Data Range marker.
        // Never decode the next generation with this approximate reference while waiting for its own
        // GET_CLOCK response; a precise reference retains the existing cross-reconnect behavior.
        if clockRefIsApproximate {
            clockRef = nil
            clockRefIsApproximate = false
            collector?.clockRef = nil
            backfiller?.clockRef = nil
        }
    }

    private func armClockRecoveryTimeout(for generation: Int) {
        clockRecoveryTimeout?.cancel()
        let timeout = DispatchWorkItem { [weak self] in
            guard let self,
                  self.connectGeneration == generation,
                  self.state.connected,
                  self.selectedModel.deviceFamily == .whoop4,
                  !self.hasPreciseClockCorrelation
            else { return }
            self.clockRecoveryTimeout = nil
            self.applyClockRecoveryAction(for: generation)
        }
        clockRecoveryTimeout = timeout
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.clockRecoveryTimeoutSeconds,
            execute: timeout
        )
    }

    /// A GET_CLOCK deadline or newly-arrived Data Range marker advances the bounded planner exactly once.
    /// Its retry budget is per `connectGeneration`; late work from an old connection is ignored.
    private func applyClockRecoveryAction(for generation: Int) {
        guard connectGeneration == generation,
              state.connected,
              selectedModel.deviceFamily == .whoop4
        else { return }

        switch clockRecovery.nextAction(
            hasPreciseCorrelation: hasPreciseClockCorrelation,
            newestBankedUnix: strapNewestTs,
            wallUnix: Int(Date().timeIntervalSince1970)
        ) {
        case .retryGetClock(let attempt, let maximum):
            log("Clock: no precise correlation; retrying GET_CLOCK \(attempt)/\(maximum)")
            send(.getClock, payload: [])
            send(.getClock, payload: [0x00])
            armClockRecoveryTimeout(for: generation)

        case .installDataRangeFallback(let deviceUnix, let wallUnix):
            let approximate = ClockRef(device: deviceUnix, wall: wallUnix)
            clockRef = approximate
            clockRefIsApproximate = true
            collector?.clockRef = approximate
            backfiller?.clockRef = approximate
            log("Clock: GET_CLOCK unresponsive; installed one approximate Data Range correlation")

        case .none:
            break
        }
    }

    /// If the fourth GET_CLOCK deadline happened before GET_DATA_RANGE replied, install the one permitted
    /// fallback as soon as that current-generation marker arrives. Before the retry budget is exhausted,
    /// the range answer never accelerates retries.
    private func applyClockFallbackIfReady() {
        guard !hasPreciseClockCorrelation,
              clockRecovery.retryCount >= clockRecovery.maximumRetries
        else { return }
        applyClockRecoveryAction(for: connectGeneration)
    }

    /// Newest plausible-unix marker in a GET_DATA_RANGE COMMAND_RESPONSE = the strap's newest stored
    /// record. Mirrors re/diagnose_biometrics.py: scan u32 LE words in the response body (data starts at
    /// frame[7], after [type,seq,cmd]), keep those in the unix range, return the max. nil if none.
    static func dataRangeNewestUnix(from frame: [UInt8],
                                    wallNowUnix: Int = Int(Date().timeIntervalSince1970)) -> Int? {
        // #286 follow-up: delegate to the pure, twin-tested WhoopProtocol.DataRange (byte-identical to the
        // Kotlin com.noop.protocol.DataRange) so this parity-critical read — it gates auto-sync via
        // isFutureDatedNewest → BackfillPolicy — is CI-pinned on BOTH platforms, not the Kotlin side only.
        DataRange.newestUnix(from: frame, wallNowUnix: wallNowUnix,
                             futureSkewSeconds: BackfillContinuation.defaultFutureSkewSeconds)
    }

    /// The OLDEST plausible record timestamp in a GET_DATA_RANGE frame — the start of the strap's stored
    /// history. Same scan as `dataRangeNewestUnix` but keeps the minimum, so one connect can report the
    /// full banked SPAN (oldest…newest). For the recurring "last night didn't sync" reports (#364) that
    /// span is the backlog DEPTH at a glance: a strap that banked weeks of un-synced history has a wide
    /// span and simply needs time to drain oldest-first, vs. a narrow span that should clear quickly.
    // #286 follow-up: delegate to the pure, twin-tested WhoopProtocol.DataRange (byte-identical Swift/Kotlin).
    static func dataRangeOldestUnix(from frame: [UInt8]) -> Int? {
        DataRange.oldestUnix(from: frame)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard isCurrentPeripheralCallback(peripheral),
              isCurrentCharacteristicCallback(characteristic) else {
            log("Ignored stale notification callback for \(peripheral.identifier)")
            return
        }
        if let error {
            log("Notify update failed for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        guard let data = characteristic.value else { return }
        let bytes = [UInt8](data)
        lastDataAt = Date()   // feed the liveness watchdog on every notification

        switch characteristic.uuid {
        case BLEManager.heartRateChar:
            parseStandardHR(bytes)
            if selectedModel.deviceFamily == .whoop5, !whoop5SecureReady {
                state.standardHRMode = "Live HR only - secure WHOOP session is still being established."
                log("WHOOP 5/MG: standard HR is live while the proprietary secure session remains unverified.")
            }
        case BLEManager.batteryChar:
            // 0x2A19 = percent — 5/MG ONLY. The WHOOP 4.0's 0x2A19 is a stub constant 100 (real value =
            // GET_BATTERY_LEVEL response, u16/10) and it's subscribed, so an unsolicited stub
            // notification was reverting the true reading back to 100% (#77).
            if selectedModel.deviceFamily != .whoop4, let pct = bytes.first {
                state.setBattery(Double(pct))
            }
        case BLEManager.dataNotifyChar,
             BLEManager.cmdNotifyChar,
             BLEManager.eventNotifyChar:
            // Reassemble (no-op for already-complete frames) then route each complete frame.
            for frame in reassembler.feed(bytes) {
                if backfilling, BLEManager.isOffloadFrame(frame, family: .whoop4) {
                    // Historical replay is bulk sync traffic, not live UI traffic. Feed it only to
                    // the Backfiller; parsing every record through FrameRouter updates SwiftUI for
                    // no user-visible benefit and can make the app feel hung during long offloads.
                    armBackfillTimeout()
                    routeBackfillFrame(frame)
                    // …but a REAL-TIME physical gesture (double-tap / wrist) must still fire even mid-
                    // offload (#69). Gated on ts≈now so replayed historical EVENTs (old ts) are ignored.
                    router.dispatchLiveGestureIfFresh(frame: frame, now: strapClockNow)
                    continue
                }
                // #47: decode this live WHOOP4 frame ONCE here and thread the result to every consumer
                // (router / clock-correlation / collector) instead of each re-parsing it — steady-state
                // drops 2→1 parse per frame, pre-clock 3→1. This is the WHOOP4 custom-notify case (5/MG has
                // its own case), so parse with `.whoop4` explicitly — the same family this loop already uses
                // for isOffloadFrame, and byte-identical to all three original parses (router.family /
                // collector.family / the no-family clock parse all resolve to .whoop4 here; a DEBUG assert in
                // the router + collector re-checks the invariant).
                let parsed = parseFrame(frame, family: .whoop4)
                router.handle(parsed: parsed, frame: frame)       // live/UI path
                if frame.count > 6, frame[6] == WhoopCommand.getDataRange.rawValue {
                    // #451: the decoded "newest" can latch a stale/wrong-epoch field (claypilat saw 2024 when
                    // the real newest was 2026). To tell a genuinely-stale strap apart from a frame-alignment
                    // bug in dataRangeNewestUnix WITHOUT guessing, dump the raw GET_DATA_RANGE response bytes
                    // (logged unconditionally on a data-range reply, even if decode returns nil) so the field
                    // offsets are inspectable straight from a normal strap-log export. Short frame.
                    let hex = frame.map { String(format: "%02x", $0) }.joined()
                    log("Get Data Range raw frame (#451 — for offset analysis): \(hex)")
                    if let newest = BLEManager.dataRangeNewestUnix(from: frame) {
                        strapNewestTs = newest                    // feeds the liveness watchdog
                        // If GET_CLOCK has already exhausted its bounded retry budget, this current-link
                        // banked marker is the sole safe fallback source. Until then it must not alter the
                        // retry cadence or replace a precise correlation.
                        applyClockFallbackIfReady()
                        // #928: flag an implausibly FUTURE "newest" (strap clock set ahead) right where it
                        // lands, so a Test Centre export shows WHY auto-continue refused to trust the range.
                        let wallNowForSkew = Int(Date().timeIntervalSince1970)
                        if newest > wallNowForSkew + BackfillContinuation.defaultFutureSkewSeconds {
                            log("Strap newest banked record reads \((newest - wallNowForSkew) / 3600)h AHEAD of the wall clock (implausible; strap clock set in the future, #928). Auto-continue will not trust this range.")
                        }
                        // #547 SESSION-RELATIVE gate: publish the strap's banked-record window to the
                        // Backfiller so the historical ingest gate can reject a record dated months outside
                        // THIS strap's own [oldest, newest] (wandering-clock pollution that clears the
                        // absolute 2023-11 floor). The newest marker alone gives an upper bound; the oldest
                        // (set below when present) closes the lower bound. The gate ignores a half/malformed
                        // window, so setting newest before oldest is decoded is safe.
                        backfiller?.sessionNewestUnix = newest
                        // Observability for the "last night didn't sync" reports (#364): print the NEWEST
                        // record the strap actually holds. With the persisted-N line this lets one connect tell
                        // a banked-but-not-yet-reached backlog (newest == last night, cursor still grinding)
                        // apart from a genuinely un-banked night (newest is older) — no more guessing.
                        let d = ISO8601DateFormatter()
                        d.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
                        log("Strap newest banked record: \(d.string(from: Date(timeIntervalSince1970: TimeInterval(newest)))) (from data range)")
                        // Also surface the OLDEST banked record so one connect shows the full backlog SPAN — the
                        // depth a deep oldest-first drain has to cover before recent nights land (#364).
                        let oldest = BLEManager.dataRangeOldestUnix(from: frame)
                        if let oldest, oldest < newest {
                            backfiller?.sessionOldestUnix = oldest   // #547: closes the session-relative window
                            let spanDays = (newest - oldest) / 86_400
                            log("Strap banked history span: \(d.string(from: Date(timeIntervalSince1970: TimeInterval(oldest)))) → newest (~\(spanDays) day\(spanDays == 1 ? "" : "s") of backlog, drained oldest-first)")
                        }
                        // UNIVERSAL clock-drift snapshot (RTC cluster #531/#767/#804/#812): bank the strap's
                        // [oldest, newest] window onto LiveState UNCONDITIONALLY (observability, not gated) so the
                        // export assembler can ride a universal clock-drift line on EVERY Test Centre export, not
                        // only when Connection mode is on. Additive; the decode above is unchanged.
                        state.setStrapRange(newestUnix: newest, oldestUnix: (oldest.map { $0 < newest } ?? false) ? oldest : nil)
                        // Connection test mode: promote the CLOCK-DRIFT picture from the buried raw frames to one
                        // upfront tagged line - the strap-reported [oldest, newest] window vs wall clock with a
                        // FUTURE-DATE flag (#767 / #754 cluster). Gated zero-cost; pure formatter, no behaviour
                        // change (the offload/watchdog logic above already ran on the same decoded values).
                        if TestCentre.active(.connection) {
                            let line = ConnectionTrace.clockDriftLine(
                                oldestUnix: (oldest.map { $0 < newest } ?? false) ? oldest : nil,
                                newestUnix: newest,
                                wallNowUnix: Int(Date().timeIntervalSince1970))
                            state.append(log: line, domain: .connection)
                        }
                    }
                }
                // Clock correlation runs in both live and backfill modes. Once established it
                // unblocks both the Collector (live path) and the Backfiller (chunk decoding).
                if !hasPreciseClockCorrelation {
                    // #47: reuse the single decode above (byte-identical for WHOOP4) instead of re-parsing.
                    if let ref = ClockCorrelation.clockRef(from: parsed, wall: Int(Date().timeIntervalSince1970)) {
                        clockRef = ref
                        clockRefIsApproximate = false
                        clockRecoveryTimeout?.cancel()
                        clockRecoveryTimeout = nil
                        collector?.clockRef = ref                  // unblocks buffered persistence
                        backfiller?.clockRef = ref                 // unblocks historical chunk decode
                        // State for the UI is written at the same proven correlation seam. The log remains
                        // export evidence; it is no longer a state store that screens have to re-parse.
                        state.noteClockCorrelation(deviceUnix: ref.device)
                        log("Clock correlated: device=\(ref.device) wall=\(ref.wall)")
                        // Conditional SET_CLOCK (mirrors WHOOP): only when the strap RTC has drifted /
                        // is frozen — not blindly every connect. Offload doesn't depend on this (it uses
                        // clockRef for decoding); SET_CLOCK only keeps FUTURE logging timestamps sane.
                        if ClockPolicy.shouldSetClock(deviceClock: ref.device, wallNow: ref.wall) {
                            log("Clock drift detected — issuing SET_CLOCK")
                            sendSetClockBothForms()
                        }
                    }
                }
                if !backfilling {
                    // Live path: synchronous ingest preserves delegate arrival order. #47: thread the
                    // single parse so the collector's flush doesn't re-decode the batch.
                    collector?.ingest(frame: frame, parsed: parsed)
                }
            }
        default:
            // EXPERIMENTAL WHOOP 5.0/MG puffin notify chars (fd4b0003/0004/0005/0007): reassemble with
            // the family-aware reassembler and route through the family-aware FrameRouter so the UI
            // reflects arriving frames. The historical offload uses the WHOOP4 backfill machinery
            // (family-aware), and live puffin frames are now persisted too — see below. (Clock: the
            // Collector runs an identity ref for 5/MG via configureCollectorFamily, since live puffin
            // timestamps are already real-unix seconds.) Live HR/battery still also come from the
            // standard 0x2A37 / 0x2A19 profiles handled above.
            if BLEManager.whoop5NotifyChars.contains(characteristic.uuid) {
                for frame in reassembler.feed(bytes) {
                    let parsed = parseFrame(frame, family: .whoop5)
                    handleWhoop5CommandResponse(parsed, frame: frame)
                    let isOffload = backfilling && BLEManager.isOffloadFrame(frame, family: .whoop5)
                    noteWhoop5R22Telemetry(frame, duringOffload: isOffload)   // #174 deep-data telemetry
                    // Durable EVENT-frame log for deep-data research (#103) — BEFORE the offload
                    // branch, so it sees both live events and their history replays (either path
                    // may be the only one that delivers a given record). Single byte compare when
                    // the frame is not an EVENT; no-op unless the capture toggle is on.
                    puffinEventLog.appendIfEvent(frame: frame, char: characteristic.uuid)
                    // Durable log of the big high-rate R22 deep buffers (type-0x2F ≥ 1 KB) for #423
                    // reverse-engineering — its own file the bulk-capture eviction never churns.
                    // BEFORE the offload branch so it catches the burst; no-op unless capture is on.
                    puffinDeepBufferLog.appendIfDeepBuffer(frame: frame, char: characteristic.uuid, isOffload: isOffload)
                    if isOffload {
                        // Same policy as WHOOP4: historical offload frames are bulk sync traffic.
                        // Keep them out of the live UI parser during backfill and let Backfiller
                        // preserve/order/process them in the sliced drain.
                        armBackfillTimeout()
                        routeBackfillFrame(frame)
                        // A real-time double-tap / wrist gesture still fires during a 5/MG offload (which
                        // runs for minutes, #69); the ts≈now gate rejects replayed historical EVENTs.
                        router.dispatchLiveGestureIfFresh(frame: frame, now: strapClockNow)
                        continue
                    }
                    router.handle(parsed: parsed, frame: frame)
                    // NOTE: we deliberately do NOT ingest live 5/MG REALTIME_DATA into the Collector
                    // here. For a 5/MG the standard 0x2A37 Heart-Rate profile is already the RELIABLE,
                    // continuously-persisted live source (see didUpdateValueFor 0x2A37 → ingestStandardHR);
                    // decoding HR a second time off the puffin stream stored a duplicate row per heartbeat
                    // at a slightly different second (strap-unix vs Mac-receive), inflating the sample
                    // store. 0x2A37 stays the single authoritative live HR/RR source for 5/MG.
                    // Capture for protocol mapping (no-op unless the Settings toggle is on). PR #20.
                    puffinRecorder.capture(frame: frame, char: characteristic.uuid)
                }
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard isCurrentPeripheralCallback(peripheral),
              isCurrentCharacteristicCallback(characteristic) else {
            log("Ignored stale notification-state callback for \(peripheral.identifier)")
            return
        }
        if BLEManager.whoop5NotifyChars.contains(characteristic.uuid),
           let sessionID = currentWhoop5SecureSessionID {
            let key = characteristic.uuid.uuidString.lowercased()
            if whoop5NotifyRearmOffPending.contains(key) {
                guard error == nil, !characteristic.isNotifying else {
                    failWhoop5SecureSession(sessionID, reason: "restored protected notification \(key) did not confirm off")
                    return
                }
                whoop5NotifyRearmOffPending.remove(key)
                log("WHOOP 5/MG: restored protected notification \(key) confirmed off; requesting fresh on")
                requestNotify(characteristic, on: peripheral, reason: "secure rearm")
                return
            }
            guard error == nil, characteristic.isNotifying else {
                failWhoop5SecureSession(sessionID, reason: "protected notification \(key) failed to confirm on")
                return
            }
            let allRequiredConfirmed = whoop5SecureSession.confirmProtectedNotification(
                key,
                enabled: true,
                sessionID: sessionID)
            if allRequiredConfirmed,
               let commandCharacteristic = whoop5FrozenCommandCharacteristic {
                seq = seq &+ 1
                let proofSequence = seq
                if whoop5SecureSession.beginProtocolProof(sequence: proofSequence, sessionID: sessionID) {
                    armWhoop5SecureStageDeadline(for: sessionID)
                    let frame = puffinCommandFrame(
                        cmd: WhoopCommand.getHello.rawValue,
                        seq: proofSequence,
                        payload: [0x00])
                    log("WHOOP 5/MG: protected notifications confirmed; sending owned GET_HELLO proof seq=\(proofSequence)")
                    writeValue(
                        Data(frame),
                        to: commandCharacteristic,
                        on: peripheral,
                        type: .withResponse,
                        confirmedPurpose: .protocolProof,
                        command: WhoopCommand.getHello.rawValue,
                        requestSequence: proofSequence)
                }
            }
        }
        if let error = error {
            log("Notify enable failed for \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            log("Notify \(characteristic.isNotifying ? "active" : "off") \(characteristic.uuid)")
            // #34: the cmd-notify channel carries GET_ALARM_TIME's (and every other COMMAND_RESPONSE's)
            // reply. Once IT confirms subscribed, check whether the handshake side of connectSettled is
            // also done — this is the "notify confirmed" half arriving AFTER the handshake body, the
            // ordering a v8.6.2 strap log showed actually happens.
            if characteristic === cmdNotifyCharacteristic, characteristic.isNotifying {
                cmdNotifyConfirmedActive = true
                maybeSignalConnectSettled()
            }
        }
    }
}
