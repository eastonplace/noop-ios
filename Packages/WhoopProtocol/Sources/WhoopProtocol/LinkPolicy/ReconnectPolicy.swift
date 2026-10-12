import Foundation

/// BLE-9 + CC-7: one reconnect backoff for every involuntary link loss.
///
/// Reconnect rules used to be split across two delegate callbacks: `didFailToConnect` backed off
/// exponentially, but `didDisconnect` retried a flat 3 s forever, so a strap that connected, bonded and
/// then dropped with a non-timeout error re-kicked every ~3 s with nothing to stop it. The ladder below is
/// shared by both paths and resets only when a link proves healthy, not merely on a successful connect.
public struct ReconnectPolicy: Equatable, Sendable {
    /// 3, 6, 12, 24, 48, then 60 s for every later attempt.
    public static let ladderSeconds: [TimeInterval] = [3, 6, 12, 24, 48, 60]
    /// A link that stayed up this long was healthy, whatever ended it.
    public static let healthyLinkSeconds: TimeInterval = 60

    public private(set) var attempts = 0

    public init() {}

    /// The delay before the next automatic reconnect attempt. Each call climbs one rung.
    public mutating func nextDelay() -> TimeInterval {
        let delay = Self.ladderSeconds[min(attempts, Self.ladderSeconds.count - 1)]
        attempts += 1
        return delay
    }

    /// A link ended. Reset the ladder when it proved healthy: it stayed up for `healthyLinkSeconds`, or
    /// the strap acknowledged a history chunk on it. A link that only connected (or bonded) and then
    /// dropped keeps climbing.
    public mutating func linkEnded(upSeconds: TimeInterval?, acknowledgedHistory: Bool) {
        if acknowledgedHistory || (upSeconds.map { $0 >= Self.healthyLinkSeconds } ?? false) {
            attempts = 0
        }
    }

    /// The user explicitly asked to connect: the next automatic retry starts from the bottom again.
    public mutating func reset() {
        attempts = 0
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
