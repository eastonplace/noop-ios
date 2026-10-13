import Foundation

/// BLE-9 + CC-7: one reconnect backoff for every involuntary link loss.
///
/// Reconnect rules used to be split across two delegate callbacks: `didFailToConnect` backed off
/// exponentially, but `didDisconnect` retried a flat 3 s forever, so a strap that connected, bonded and
/// then dropped with a non-timeout error re-kicked every ~3 s with nothing to stop it. The ladder below
/// paces every retry while the app is in the foreground and resets only when a link proves healthy, not
/// merely on a successful connect.
///
/// F1: a main-queue timer does not survive app suspension (a BLE event buys a backgrounded app only
/// ~10 s), so in the background a known strap gets an OS-managed pending connect instead, bounded by a
/// consecutive-attempt cap rather than by timers (see `action(after:appActive:knownTarget:forcedDelay:)`).
public struct ReconnectPolicy: Equatable, Sendable {
    /// 3, 6, 12, 24, 48, then 60 s for every later attempt.
    public static let ladderSeconds: [TimeInterval] = [3, 6, 12, 24, 48, 60]
    /// A link that stayed up this long was healthy, whatever ended it.
    public static let healthyLinkSeconds: TimeInterval = 60
    /// Background pending connects allowed with no healthy link in between before auto-reconnect pauses
    /// until the next foreground. 10: the cause-specific give-ups (bond refusal, the 5/MG secure series)
    /// trip at 5, so they always fire first for their causes and this only catches unclassified loops.
    /// Each background attempt is paced by the OS (the strap must advertise and a link attempt must run),
    /// so ten real edge-of-range cycles span minutes, while a failure that returns instantly is held to
    /// ten wakeups instead of spinning all night. One healthy link resets it.
    public static let backgroundRetryCap = 10

    public private(set) var attempts = 0
    /// Pending connects issued in the background since the last healthy link (or foreground, or user
    /// Connect). Past `backgroundRetryCap` the next background event pauses auto-reconnect.
    public private(set) var backgroundRetries = 0

    public init() {}

    /// The delay before the next automatic reconnect attempt. Each call climbs one rung.
    public mutating func nextDelay() -> TimeInterval {
        let delay = Self.ladderSeconds[min(attempts, Self.ladderSeconds.count - 1)]
        attempts += 1
        return delay
    }

    /// A link ended. Reset the ladder and the background count when it proved healthy: it stayed up for
    /// `healthyLinkSeconds`, or the strap acknowledged a history chunk on it. A link that only connected
    /// (or bonded) and then dropped keeps climbing. Returns whether the link proved healthy, which also
    /// ends a background-cap pause.
    @discardableResult
    public mutating func linkEnded(upSeconds: TimeInterval?, acknowledgedHistory: Bool) -> Bool {
        guard acknowledgedHistory || (upSeconds.map { $0 >= Self.healthyLinkSeconds } ?? false) else {
            return false
        }
        attempts = 0
        backgroundRetries = 0
        return true
    }

    /// The user explicitly asked to connect: the next automatic retry starts from the bottom again.
    public mutating func reset() {
        attempts = 0
        backgroundRetries = 0
    }

    /// The app came to the foreground, where the ladder paces retries again: the background count
    /// starts over for the next background stretch.
    public mutating func enteredForeground() {
        backgroundRetries = 0
    }

    /// The involuntary event the manager is reacting to.
    public enum Event: Sendable {
        /// An established link ended (`didDisconnect`, not user-initiated).
        case drop
        /// A connect attempt failed before a link came up (`didFailToConnect`).
        case failedConnect
    }

    /// What the manager does after a link loss or a failed connect.
    public enum Action: Equatable, Sendable {
        /// Re-issue an OS-managed pending connect to a known strap right away. It uses no radio while the
        /// strap is absent and survives app suspension, so CoreBluetooth wakes (or relaunches) the app when
        /// the strap comes back.
        case connectNow
        /// As `connectNow`, but the WHOOP 5/MG secure handshake must not start until `for` seconds after
        /// this event: the secure-recovery delay is enforced after the reconnect instead of by a timer that
        /// a suspended app would never run.
        case connectNowHoldingHandshake(for: TimeInterval)
        /// Re-enter the connect path from a main-queue timer after `after` seconds.
        case retry(after: TimeInterval)
        /// Too many background attempts with no healthy link: stop auto-reconnecting until the app comes to
        /// the foreground or the user taps Connect.
        case pause
    }

    /// F1: the one reconnect decision for both involuntary events.
    ///
    /// - Foreground: timers run, so every retry is paced by the ladder (BLE-9's connect-and-drop churn
    ///   guard). `forcedDelay` (the WHOOP 5/MG secure-recovery delay) replaces the rung and is honoured as
    ///   given.
    /// - Background with a known strap (the pinned one, or the one that just dropped): a pending connect at
    ///   once, because a timer would never fire. A forced delay moves to the secure handshake. Attempts are
    ///   counted; past `backgroundRetryCap` the answer is `.pause`.
    /// - Background with no known strap: nothing to connect to, so only the timer is left.
    ///
    /// A forced delay of 0 (an explicit physical reset) is no delay at all.
    public mutating func action(after event: Event,
                                appActive: Bool,
                                knownTarget: Bool,
                                forcedDelay: TimeInterval?) -> Action {
        let delay = forcedDelay.flatMap { $0 > 0 ? $0 : nil }
        guard !appActive, knownTarget else {
            if let forcedDelay { return .retry(after: max(0, forcedDelay)) }
            return .retry(after: nextDelay())
        }
        backgroundRetries += 1
        if backgroundRetries > Self.backgroundRetryCap { return .pause }
        if let delay { return .connectNowHoldingHandshake(for: delay) }
        return .connectNow
    }

    /// F1: a WHOOP 5/MG secure-handshake hold is never shortened. The later of a still-running hold and
    /// a new one wins; `new == nil` (a reconnect with no delay of its own) keeps the running hold. Only
    /// the paths that end the series (user Connect, disconnect, forget, secure proof) clear it.
    public static func laterHandshakeHold(existing: Date?, new: Date?, now: Date) -> Date? {
        [existing, new].compactMap { $0 }.filter { $0 > now }.max()
    }

    /// A link with no inbound strap traffic for this long is quiet: nothing will wake a suspended app at a
    /// CLIENT_HELLO hold's deadline.
    public static let quietLinkSeconds: TimeInterval = 5

    /// F1: iOS is about to end the background time that covers a CLIENT_HELLO hold (about 30 s, shorter
    /// than the 60 s rung). On a quiet link nothing would wake the app at the deadline, so the hello goes
    /// now; while the strap is still notifying (standard HR about once a second), each notification
    /// releases the hello at the real deadline, so the hold is kept and only the background task ends.
    /// `lastInboundAt` is the strap's last notification; nil (none on this link yet) is quiet.
    public static func shouldSendHeldHandshakeOnBackgroundExpiry(lastInboundAt: Date?, now: Date) -> Bool {
        guard let lastInboundAt else { return true }
        return now.timeIntervalSince(lastInboundAt) > quietLinkSeconds
    }

    /// F1: the app is leaving the foreground with a reconnect timer armed. A suspended app's timer never
    /// fires and leaves nothing pending to wake it, so the armed retry must become a pending connect now,
    /// unless the user tore the link down, auto-reconnect is paused, there is no known strap, or the strap
    /// is already connected or connecting.
    public static func shouldHandOffArmedRetryOnBackground(timerArmed: Bool,
                                                           intentionalDisconnect: Bool,
                                                           autoReconnectPaused: Bool,
                                                           target: LinkState?) -> Bool {
        guard timerArmed, !intentionalDisconnect, !autoReconnectPaused, let target else { return false }
        switch target {
        case .connected, .connecting: return false
        case .none, .disconnected, .disconnecting: return true
        }
    }

    /// The connection state a scheduled reconnect sees when it fires.
    public enum LinkState: Sendable {
        case none
        case disconnected
        case connecting
        case connected
        case disconnecting
    }

    /// CC-7: a reconnect timer may fire only if nothing happened since it was armed. A newer connection
    /// generation (a manual Connect, a power-on reconnect, a restore) or a link that is already up or
    /// coming up means the timer is stale; re-entering the connect path then would reset per-connection
    /// framing state in the middle of a live stream.
    public static func shouldFire(scheduledGeneration: Int, currentGeneration: Int, state: LinkState) -> Bool {
        guard scheduledGeneration == currentGeneration else { return false }
        switch state {
        case .connected, .connecting: return false
        case .none, .disconnected, .disconnecting: return true
        }
    }
}
