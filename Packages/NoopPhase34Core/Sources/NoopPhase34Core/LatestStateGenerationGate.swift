import Foundation

/// Shared guard for Widget, Live Activity, and Watch latest-state stores. An already-leased old outbox item may
/// finish after a new one, so each sink must reject lower generations at its own atomic write boundary.
public enum LatestStateGenerationGate {
    public static func accepts(incoming: Int64, current: Int64?) -> Bool {
        guard incoming > 0 else { return false }
        guard let current else { return true }
        return incoming >= current
    }
}
