import Foundation

/// Persistence decision for an Oura IBI that carries ring time.
///
/// A banked overnight IBI must never be stamped at drain-arrival wall time. When the current session has
/// a ring-time → UTC anchor, persist at that real timestamp. Otherwise park the event until an anchor arrives.
/// IBI is both live and historical, so this policy deliberately says nothing about advancing a history resume
/// cursor; transports must not let a live beat skip an un-drained banked remainder.
public enum OuraIBITimestampDecision: Equatable, Sendable {
    case persist(unixSeconds: Int)
    case park(ringTimestamp: UInt32)
}

public enum OuraIBITimestampPolicy {
    public static func decision(
        ringTimestamp: UInt32,
        anchoredUnixSeconds: Int?
    ) -> OuraIBITimestampDecision {
        guard let anchoredUnixSeconds, anchoredUnixSeconds > 0 else {
            return .park(ringTimestamp: ringTimestamp)
        }
        return .persist(unixSeconds: anchoredUnixSeconds)
    }
}
