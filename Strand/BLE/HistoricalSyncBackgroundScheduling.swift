import Foundation
import WhoopProtocol

/// Pure scheduling decision for discretionary iOS history wakes. Caught-up, eligible WHOOP 4 links keep
/// a maintenance request without claiming an exact iOS wake cadence. Both maintenance and durable debt
/// use the existing adaptive offload floors.
enum HistoricalSyncBackgroundSchedulingPolicy {
    enum Plan: Equatable, Sendable {
        case cancel
        case schedule(after: TimeInterval)
    }

    static let minimumRetrySeconds: TimeInterval = BackfillPolicy.periodicFloorSeconds

    static func maintenanceEligible(
        family: DeviceFamily,
        clockTrusted: Bool = true,
        connectionReady: Bool,
        isCurrentPreferredPeripheral: Bool,
        intentionalDisconnect: Bool,
        autoReconnectPaused: Bool,
        restoreInProgress: Bool
    ) -> Bool {
        family == .whoop4
            && clockTrusted
            && connectionReady
            && isCurrentPreferredPeripheral
            && !intentionalDisconnect
            && !autoReconnectPaused
            && !restoreInProgress
    }

    static func plan(
        backlogRemains: Bool,
        maintenanceEligible: Bool = false,
        automaticSyncAllowed: Bool = true,
        syncActive: Bool,
        connectionReady: Bool,
        now: TimeInterval,
        lastBackfillAt: TimeInterval?,
        powerSaving: Bool,
        emptyStreak: Int
    ) -> Plan {
        guard automaticSyncAllowed, !syncActive,
              backlogRemains || (maintenanceEligible && connectionReady) else { return .cancel }
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
    let maintenanceEligible: Bool
    let automaticSyncAllowed: Bool
    let syncActive: Bool
    let connectionReady: Bool
    let now: TimeInterval
    let lastBackfillAt: TimeInterval?
    let powerSaving: Bool
    let emptyStreak: Int

    init(
        backlogRemains: Bool,
        maintenanceEligible: Bool = false,
        automaticSyncAllowed: Bool = true,
        syncActive: Bool,
        connectionReady: Bool,
        now: TimeInterval,
        lastBackfillAt: TimeInterval?,
        powerSaving: Bool,
        emptyStreak: Int
    ) {
        self.backlogRemains = backlogRemains
        self.maintenanceEligible = maintenanceEligible
        self.automaticSyncAllowed = automaticSyncAllowed
        self.syncActive = syncActive
        self.connectionReady = connectionReady
        self.now = now
        self.lastBackfillAt = lastBackfillAt
        self.powerSaving = powerSaving
        self.emptyStreak = emptyStreak
    }

    var plan: HistoricalSyncBackgroundSchedulingPolicy.Plan {
        HistoricalSyncBackgroundSchedulingPolicy.plan(
            backlogRemains: backlogRemains,
            maintenanceEligible: maintenanceEligible,
            automaticSyncAllowed: automaticSyncAllowed,
            syncActive: syncActive,
            connectionReady: connectionReady,
            now: now,
            lastBackfillAt: lastBackfillAt,
            powerSaving: powerSaving,
            emptyStreak: emptyStreak
        )
    }
}
