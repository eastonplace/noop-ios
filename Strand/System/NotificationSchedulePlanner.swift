import Foundation
import StrandAnalytics

struct NotificationWorkoutPlan: Equatable {
    let id: String
    let plannedAt: Date
    let completedSessionID: String?
    let hasExplicitTime: Bool
    var revision: Int = 0
}

/// Resolves one-shot wall-clock times. The OS cannot re-run eligibility at delivery;
/// all scheduled copy is generic and current completion is reconciled on execution.
enum NotificationSchedulePlanner {
    static func previousCompleteWeekStart(now: Date, calendar: Calendar = .current) -> Date {
        let day = calendar.startOfDay(for: now)
        let daysSinceMonday = (calendar.component(.weekday, from: day) + 5) % 7
        return calendar.date(byAdding: .day, value: -daysSinceMonday - 7, to: day) ?? day
    }
    static func resolve(day: Date, minute: Int, calendar: Calendar = .current) -> Date? {
        guard (0..<1440).contains(minute) else { return nil }
        let start = calendar.startOfDay(for: day)
        var matching = calendar.dateComponents([.year, .month, .day], from: start)
        matching.hour = minute / 60; matching.minute = minute % 60
        return calendar.nextDate(after: start.addingTimeInterval(-1), matching: matching,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }
    static func shouldScheduleWorkout(hasExplicitTime: Bool, completedSessionID: String?) -> Bool {
        hasExplicitTime && completedSessionID == nil
    }
    static func candidate(group: NotificationGroup, id: String, scheduledAt: Date, source: String,
                          destination: NotificationDestination, now: Date, revision: Int = 0, recurring: Bool = false,
                          actionAt: Date? = nil) -> NotificationCandidate {
        let timing = recurring ? "recurring" : String(Int(scheduledAt.timeIntervalSince1970))
        let occurrence = "\(group.rawValue):\(source.utf8.count):\(source):\(id):\(timing):r\(revision)"
        let copy: (String, String)
        switch group {
        case .windDown: copy = ("Time to wind down", "Your chosen sleep-plan reminder is due.")
        case .workoutPlan: copy = ("Your planned workout", "Review your saved workout plan.")
        case .journalCheckIn: copy = ("Journal check-in", "Your chosen check-in is due. Open your journal when it suits you.")
        default: copy = ("Your weekly review", "Take a moment to review your week in Noop.")
        }
        let expiry: Date
        if recurring { expiry = .distantFuture }
        else if group == .workoutPlan {
            // WT021/024/027/030 expire relative to the chosen workout start,
            // not the earlier reminder time produced by the selected lead.
            expiry = (actionAt ?? scheduledAt).addingTimeInterval(120 * 60)
        } else if group == .journalCheckIn { expiry = scheduledAt.addingTimeInterval(120 * 60) }
        else { expiry = scheduledAt.addingTimeInterval(86400) }
        return .init(ruleID: group.rawValue + ".scheduled", group: group, subjectID: id,
            occurrenceID: occurrence, attentionKey: occurrence, evidenceRevision: occurrence,
            sourceContext: source, logicalDay: NotificationFactBuilder.dayKey(scheduledAt),
            observedAt: now, generatedAt: now, expiresAt: expiry,
            lane: .explicitReminder, destination: destination, genericTitle: copy.0,
            genericBody: copy.1, scheduledAt: scheduledAt)
    }
}
