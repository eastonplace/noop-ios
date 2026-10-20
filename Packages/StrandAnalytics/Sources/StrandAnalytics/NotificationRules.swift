import Foundation

/// Inputs are canonical facts, never raw sensor callbacks. The adapter owns model/source qualification.
public struct NotificationRuleFact: Equatable, Sendable {
    public let group: NotificationGroup
    public let subjectID: String
    public let episodeID: String
    public let evidenceRevision: String
    public let sourceContext: String
    public let logicalDay: String
    public let observedAt: Date
    public let expiresAt: Date
    public let quality: NotificationQuality
    public let scheduledAt: Date?
    public let actionRequired: Bool
    public let relatedWorkoutID: String?
    public init(group: NotificationGroup, subjectID: String, episodeID: String, evidenceRevision: String,
                sourceContext: String, logicalDay: String, observedAt: Date, expiresAt: Date,
                quality: NotificationQuality = .init(), scheduledAt: Date? = nil,
                actionRequired: Bool = true, relatedWorkoutID: String? = nil) {
        self.group = group; self.subjectID = subjectID; self.episodeID = episodeID
        self.evidenceRevision = evidenceRevision; self.sourceContext = sourceContext; self.logicalDay = logicalDay
        self.observedAt = observedAt; self.expiresAt = expiresAt; self.quality = quality
        self.scheduledAt = scheduledAt; self.actionRequired = actionRequired; self.relatedWorkoutID = relatedWorkoutID
    }
}

public enum NotificationRules {
    public static let version = 1
    /// Length-prefixing prevents user/source identifiers containing separators from aliasing another event.
    private static func key(_ components: String...) -> String { components.map { "\($0.utf8.count):\($0)" }.joined() }
    public static func candidates(facts: [NotificationRuleFact], now: Date) -> [NotificationCandidate] {
        facts.filter(\.actionRequired).map { fact in
            let destination: NotificationDestination
            let title: String
            let body: String
            let lane: NotificationLane
            let attention: String
            var freshness: TimeInterval = 1800
            var expiry = fact.expiresAt
            var priority = 0
            switch fact.group {
            case .morningSummary:
                destination = .day(logicalDay: fact.logicalDay); title = "Your daily summary is ready"
                body = "Open Noop to review your day."; lane = .proactive
                attention = key("morning", fact.sourceContext, fact.episodeID)
                freshness = 12 * 3600; priority = 60
            case .windDown:
                destination = .sleepPlan(logicalDay: fact.logicalDay); title = "Your sleep plan"
                body = "Your chosen wind-down reminder is due."; lane = .explicitReminder
                attention = key("sleep-plan", fact.subjectID, fact.episodeID); freshness = 7 * 86400
            case .workoutPlan:
                destination = .plannedWorkout(id: fact.subjectID); title = "Your planned workout"
                body = "Review the workout you scheduled."; lane = .explicitReminder
                attention = key("workout-plan", fact.subjectID, fact.episodeID); freshness = 7 * 86400
            case .workoutSummary:
                destination = .workout(id: fact.subjectID); title = "Your workout summary is ready"
                body = "Open Noop to review your session."; lane = .proactive
                attention = key("workout", fact.sourceContext, fact.subjectID)
                freshness = 3600; expiry = min(expiry, fact.observedAt.addingTimeInterval(3600)); priority = 80
            case .strainTarget:
                destination = .day(logicalDay: fact.logicalDay); title = "Your daily activity has an update"
                body = "Open Noop to review your day."; lane = .proactive
                attention = fact.relatedWorkoutID.map { key("workout", fact.sourceContext, $0) }
                    ?? key("strain-target", fact.sourceContext, fact.logicalDay); priority = 40
            case .chargeReminder, .batteryFull:
                destination = .device(id: fact.subjectID); title = "Your device has an update"
                body = "Open Noop to check your device."; lane = .proactive
                attention = key("battery", fact.subjectID, fact.episodeID); priority = 70
            case .weeklyReview:
                destination = .weeklyReview(weekStart: fact.logicalDay); title = "Your weekly review"
                body = "Your chosen review reminder is due."; lane = .explicitReminder
                attention = key("weekly-review", fact.sourceContext, fact.episodeID); freshness = 8 * 86400
                if let scheduled = fact.scheduledAt { expiry = min(expiry, scheduled.addingTimeInterval(86400)) }
            case .journalCheckIn:
                destination = .journal(logicalDay: fact.logicalDay); title = "Your journal check-in"
                body = "Your chosen check-in reminder is due."; lane = .explicitReminder
                attention = key("journal", fact.logicalDay, fact.episodeID); freshness = 7 * 86400
            case .healthPattern:
                destination = .health(logicalDay: fact.logicalDay); title = "Your health overview has an update"
                body = "Open Noop to review the details."; lane = .proactive
                attention = key("health-pattern", fact.sourceContext, fact.subjectID, fact.episodeID)
            case .inactivity:
                destination = .day(logicalDay: fact.logicalDay); title = "A moment to check in"
                body = "Open Noop to review your day."; lane = .proactive
                attention = key("inactivity", fact.subjectID, fact.episodeID); freshness = 5 * 60
            }
            let quality = NotificationQuality(isFinal: fact.quality.isFinal,
                hasRequiredInputs: fact.quality.hasRequiredInputs && !fact.episodeID.isEmpty && !fact.evidenceRevision.isEmpty
                    && (lane != .explicitReminder || fact.scheduledAt != nil),
                hasFiniteValues: fact.quality.hasFiniteValues, coverageAccepted: fact.quality.coverageAccepted,
                sourceAccepted: fact.quality.sourceAccepted, modelAccepted: fact.quality.modelAccepted,
                isHistoricalReplay: fact.quality.isHistoricalReplay, recoveryQualified: fact.quality.recoveryQualified)
            return NotificationCandidate(ruleID: fact.group.rawValue, ruleVersion: version,
                group: fact.group, subjectID: fact.subjectID,
                occurrenceID: key(fact.group.rawValue, fact.sourceContext, fact.subjectID, fact.episodeID),
                attentionKey: attention, evidenceRevision: fact.evidenceRevision, sourceContext: fact.sourceContext,
                logicalDay: fact.logicalDay, observedAt: fact.observedAt, generatedAt: now, expiresAt: expiry,
                quality: quality, lane: lane, priority: priority, destination: destination,
                genericTitle: title, genericBody: body, scheduledAt: fact.scheduledAt, freshnessLimit: freshness,
                requiresRecoveryQualification: fact.group == .morningSummary || fact.group == .healthPattern || fact.group == .strainTarget)
        }
    }
}
