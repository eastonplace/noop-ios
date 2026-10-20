import Foundation

public struct ReceiptLiftNotificationPlan: Equatable, Sendable {
    public let id: String
    public let plannedAt: Date
    public let completedSessionID: String?
    public let hasExplicitTime: Bool
    public let revision: Int
}

@MainActor
extension ReceiptLiftCoordinator {
    public var notificationRestorationComplete: Bool { store.isLoaded }
    public func setNotificationCompletionHandler(_ handler: @escaping @MainActor (Date, Date) -> Void) {
        store.notificationCompletion = handler
    }
    /// Read-only scheduling evidence; excludes private notes and never starts a session.
    public var notificationPlans: [ReceiptLiftNotificationPlan] {
        store.scheduledWorkouts.map {
            .init(id: $0.id.uuidString, plannedAt: $0.plannedAt,
                  completedSessionID: $0.completedSessionID?.uuidString,
                  hasExplicitTime: $0.notificationTimeExplicit == true, revision: $0.notificationRevision ?? 0)
        }
    }
}
