import Foundation
import WhoopProtocol

/// Pure scheduling decision for the discretionary iOS background fallback. It never creates a tighter
/// cadence than the existing 15/45/60-minute offload policy, including when a disconnected or protected
/// store prevents the requested work from starting.
enum HistoricalSyncBackgroundSchedulingPolicy {
    enum Plan: Equatable, Sendable {
        case cancel
        case schedule(after: TimeInterval)
    }

    static let minimumRetrySeconds: TimeInterval = BackfillPolicy.periodicFloorSeconds

    static func plan(
        backlogRemains: Bool,
        syncActive: Bool,
        connectionReady: Bool,
        now: TimeInterval,
        lastBackfillAt: TimeInterval?,
        powerSaving: Bool,
        emptyStreak: Int
    ) -> Plan {
        guard backlogRemains, !syncActive else { return .cancel }
        let policyDelay = BackfillPolicy.periodicDelaySeconds(
            now: now,
            lastBackfillAt: lastBackfillAt,
            powerSaving: powerSaving,
            emptyStreak: emptyStreak
        )
        if !connectionReady {
            return .schedule(after: max(minimumRetrySeconds, policyDelay))
        }
        return .schedule(after: policyDelay)
    }
}

struct HistoricalSyncBackgroundSnapshot: Equatable, Sendable {
    let backlogRemains: Bool
    let syncActive: Bool
    let connectionReady: Bool
    let now: TimeInterval
    let lastBackfillAt: TimeInterval?
    let powerSaving: Bool
    let emptyStreak: Int

    var plan: HistoricalSyncBackgroundSchedulingPolicy.Plan {
        HistoricalSyncBackgroundSchedulingPolicy.plan(
            backlogRemains: backlogRemains,
            syncActive: syncActive,
            connectionReady: connectionReady,
            now: now,
            lastBackfillAt: lastBackfillAt,
            powerSaving: powerSaving,
            emptyStreak: emptyStreak
        )
    }
}
