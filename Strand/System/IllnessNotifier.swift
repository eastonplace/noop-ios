import Foundation
import UserNotifications

/// The existing in-app illness banner remains live. New phone health-pattern notices
/// require reviewed recovery repair and current qualified inputs; main has neither.
enum IllnessNotifier {
    static func requestAuthorization() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
    }
    static func post(_ message: String) {
        // Deliberately no notification submission and no persisted day/episode consumption.
        // The caller already updates its in-app banner independently.
    }
}
