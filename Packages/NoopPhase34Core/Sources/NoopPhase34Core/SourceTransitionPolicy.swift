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

/// Identifies whether a source mutation changes the Repository projection that
/// owns Today, Widget, Live Activity, and exact historical publication.
public enum SourceTransitionScope: String, Codable, Equatable, Sendable {
    case targetOnly
    case activeProjection
}

/// A durable snapshot of every source namespace contributing to the active
/// Repository projection before a lifecycle mutation starts.
public struct ActiveProjectionContributorSet: Codable, Equatable, Sendable {
    public let deviceIds: Set<String>

    public init(deviceIds: Set<String>) {
        self.deviceIds = Self.normalized(deviceIds)
    }

    public init(
        activeLiveDeviceId: String?,
        canonicalContributorIds: Set<String>
    ) {
        var deviceIds = Self.normalized(canonicalContributorIds)
        if let activeLiveDeviceId {
            let normalizedActiveId = activeLiveDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalizedActiveId.isEmpty {
                deviceIds.insert(normalizedActiveId)
            }
        }
        self.deviceIds = deviceIds
    }

    public func contains(_ deviceId: String) -> Bool {
        let normalizedDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        return !normalizedDeviceId.isEmpty && deviceIds.contains(normalizedDeviceId)
    }

    public func scope(affecting deviceId: String) -> SourceTransitionScope {
        contains(deviceId) ? .activeProjection : .targetOnly
    }

    private enum CodingKeys: String, CodingKey {
        case deviceIds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceIds = Self.normalized(
            try container.decode(Set<String>.self, forKey: .deviceIds)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(deviceIds.sorted(), forKey: .deviceIds)
    }

    private static func normalized(_ deviceIds: Set<String>) -> Set<String> {
        Set(deviceIds.compactMap { deviceId in
            let trimmed = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        })
    }
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
        ActiveProjectionContributorSet(
            activeLiveDeviceId: activeLiveDeviceId,
            canonicalContributorIds: canonicalContributorIds
        ).contains(targetDeviceId)
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
