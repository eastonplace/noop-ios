import Foundation

public struct LatestStateDeliveryCheckpoint: Codable, Equatable, Sendable {
    public let contextId: String
    public let presentationIdentity: SnapshotPresentationIdentity
    public let widgetCore: VerifiedWidgetCorePayload
    public let logicalDay: CivilDay
    public let deliveredAt: Date

    public init(
        contextId: String,
        presentationIdentity: SnapshotPresentationIdentity,
        widgetCore: VerifiedWidgetCorePayload,
        logicalDay: CivilDay,
        deliveredAt: Date
    ) {
        self.contextId = contextId
        self.presentationIdentity = presentationIdentity
        self.widgetCore = widgetCore
        self.logicalDay = logicalDay
        self.deliveredAt = deliveredAt
    }
}

public enum SelectiveExternalPublicationPlan {
    public static let heartbeatInterval: TimeInterval = 60 * 60

    public static func destinations(
        snapshot: SnapshotCommitReceipt,
        bundle: VerifiedExternalProjectionBundle,
        previousLatestState: LatestStateDeliveryCheckpoint?,
        now: Date
    ) -> Set<DownstreamDestination> {
        var result: Set<DownstreamDestination> = [.healthKit]
        let projection = snapshot.projection
        guard bundle.projection == projection else { return result }

        let presentationChanged = previousLatestState?.contextId != projection.contextId
            || previousLatestState?.presentationIdentity != projection.presentationIdentity
            || previousLatestState?.widgetCore != bundle.widgetCore
            || previousLatestState?.logicalDay != projection.logicalDay
        let heartbeatDue = previousLatestState.map {
            now.timeIntervalSince($0.deliveredAt) >= heartbeatInterval
        } ?? true

        if presentationChanged || heartbeatDue {
            result.formUnion([.widget, .liveActivity])
            // Add .watch only after a watchOS target exists and reports a real sink result.
        }
        return result
    }
}

/*
Outbox integration:

- Persist one latest-state checkpoint per active context only after Widget/Live
  delivery succeeds or reports alreadyCurrent.
- `commitOutbox` loads the immutable projection bundle and this checkpoint.
- Historical-only unchanged work therefore enqueues HealthKit only.
- Auxiliary-only Widget core changes still enqueue Widget because they are part
  of the checkpoint identity.
- Do not compare analysisGeneration and snapshotGeneration numerically.
*/
