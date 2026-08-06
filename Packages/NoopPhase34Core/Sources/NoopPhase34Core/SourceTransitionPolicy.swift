import Foundation

public enum LiveSourceTransportKind: Equatable, Sendable {
    case whoop
    case genericBLE
    case appleWatchHealthKit
    case none
}

public enum SourceLifecycleOperationKind: Equatable, Sendable {
    case selectExisting
    case replacePeripheral
    case archive
    case privacyDelete
}

public enum SourceTransitionPolicy {
    /// Apple Watch and WHOOP may coexist because the Watch path is HealthKit,
    /// not a competing BLE owner. A generic BLE strap remains exclusive.
    public static func shouldStopCurrentLiveOwner(
        operation: SourceLifecycleOperationKind,
        current: LiveSourceTransportKind,
        target: LiveSourceTransportKind
    ) -> Bool {
        switch operation {
        case .replacePeripheral, .archive, .privacyDelete:
            return current != .none
        case .selectExisting:
            switch (current, target) {
            case (.whoop, .appleWatchHealthKit):
                return false
            case (.appleWatchHealthKit, .whoop):
                return false
            case let (lhs, rhs):
                return lhs != rhs && lhs != .none
            }
        }
    }

    /// Nonactive isolated devices should not close the active Today/sink epoch.
    /// Canonical history contributors still affect the projection even when they
    /// are not the selected live source.
    public static func affectsActiveProjection(
        targetDeviceId: String,
        activeLiveDeviceId: String?,
        canonicalContributorIds: Set<String>
    ) -> Bool {
        targetDeviceId == activeLiveDeviceId
            || canonicalContributorIds.contains(targetDeviceId)
    }
}

/*
AppModel integration:

- Resolve current/target transport before quiescence.
- Call `stopForTransition` only when shouldStopCurrentLiveOwner is true.
- For nonactive archive/delete where affectsActiveProjection is false:
    * do target-scoped store mutation;
    * do not quiesce the global active external worker;
    * do not begin a sink epoch;
    * do not invalidate Today;
    * do not run analysis.
- Selecting Apple Watch while WHOOP is active must not call disconnect().
*/
