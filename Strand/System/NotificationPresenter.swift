import Foundation
import UserNotifications
import StrandAnalytics

/// Routine advice is silent in the relevant screen. Independent alarm/session categories
/// keep their established foreground sound contract.
@MainActor
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    private override init() { super.init() }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let request = notification.request
        guard request.identifier.hasPrefix(NotificationCoordinator.namespace) else {
            completionHandler([.banner, .sound, .list]); return
        }
        // Listing keeps foreground updates unobtrusive even on normal destination screens,
        // where the root may not have registered an exact record identity.
        completionHandler([.list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void) {
        let payload = response.notification.request.content.userInfo
        let owned = response.notification.request.identifier.hasPrefix(NotificationCoordinator.namespace)
        let action = response.actionIdentifier
        let version = payload["noopNotificationVersion"] as? Int
        let routeJSON = payload["noopNotificationDestination"] as? String
        let source = payload["noopNotificationSourceContext"] as? String
        let occurrence = payload["noopNotificationOccurrence"] as? String
        let groupRaw = payload["noopNotificationGroup"] as? String
        let repeating = payload["noopNotificationRepeating"] as? Bool == true
        // The delegate handoff is complete; only Sendable values cross to the main actor.
        completionHandler()
        guard owned else { return }
        Task { @MainActor in
            if action == "noop.notification.turnOff", let groupRaw, let group = NotificationGroup(rawValue: groupRaw) {
                NotificationPreferences.shared.setMode(.off, for: group)
                await NotificationCoordinator.shared.reconcileSchedules()
            } else if action == UNNotificationDefaultActionIdentifier {
                var routedJSON = routeJSON
                if repeating, let groupRaw {
                    let destination: NotificationDestination?
                    switch NotificationGroup(rawValue: groupRaw) {
                    case .windDown: destination = .sleepPlan(logicalDay: NotificationFactBuilder.dayKey(Date()))
                    case .weeklyReview:
                        let calendar = Calendar.current
                        let start = NotificationSchedulePlanner.previousCompleteWeekStart(now: Date(), calendar: calendar)
                        destination = .weeklyReview(weekStart: NotificationFactBuilder.dayKey(start))
                    default: destination = nil
                    }
                    if let destination, let data = try? JSONEncoder().encode(destination) {
                        routedJSON = String(decoding: data, as: UTF8.self)
                    }
                }
                var routePayload: [AnyHashable: Any] = [:]
                routePayload["noopNotificationVersion"] = version
                routePayload["noopNotificationDestination"] = routedJSON
                routePayload["noopNotificationSourceContext"] = source
                NavRouter.receiveNotificationResponse(userInfo: routePayload)
            }
            if let occurrence, let store = await AppModel.shared?.repo.notificationDecisionStore() {
                try? await store.acknowledgeNotification(occurrenceID: occurrence, now: Date())
            }
        }
    }
}
