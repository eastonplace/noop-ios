import Foundation

public enum NotificationGroup: String, Codable, CaseIterable, Sendable {
    case morningSummary, windDown, workoutPlan, workoutSummary, strainTarget
    case chargeReminder, batteryFull, weeklyReview, journalCheckIn, healthPattern, inactivity
}
public enum NotificationDeliveryMode: String, Codable, CaseIterable, Sendable { case off, inApp, notify }
public enum NotificationLane: String, Codable, Sendable { case proactive, explicitReminder, sessionControl }
public enum NotificationDestination: Codable, Hashable, Sendable {
    case day(logicalDay: String), sleepPlan(logicalDay: String), plannedWorkout(id: String)
    case workout(id: String), device(id: String), weeklyReview(weekStart: String)
    case journal(logicalDay: String), health(logicalDay: String), settings(group: NotificationGroup?)
}
public enum NotificationDisposition: String, Codable, Sendable { case suppress, inApp, notify }
public enum NotificationReason: String, Codable, Sendable {
    case eligible, coalesced
    case categoryOff = "category_off", proactiveDisabled = "proactive_disabled"
    case missingInput = "missing_input", invalidValue = "invalid_value", staleMetric = "stale_metric"
    case sourceChanged = "source_changed", modelMismatch = "model_mismatch", notFinal = "not_final"
    case insufficientCoverage = "insufficient_coverage", dependencyUnqualified = "dependency_unqualified"
    case historicalReplay = "historical_replay", alreadySeen = "already_seen", alreadyScheduled = "already_scheduled"
    case activeWorkout = "active_workout", sleepInProgress = "sleep_in_progress"
    case sleepStateUnavailable = "sleep_state_unavailable", quietHours = "quiet_hours"
    case expired, permissionDenied = "permission_denied", budgetFull = "budget_full"
    case minimumGap = "minimum_gap", reminderNearby = "reminder_nearby", futureObservation = "future_observation"
}

public struct NotificationPreferencesSnapshot: Codable, Equatable, Sendable {
    public let modes: [NotificationGroup: NotificationDeliveryMode]
    public let quietHoursEnabled: Bool
    public let quietStartMinutes: Int
    public let quietEndMinutes: Int
    public let showHealthDetails: Bool
    public let proactiveEnabled: Bool
    public init(modes: [NotificationGroup: NotificationDeliveryMode] = [:], quietHoursEnabled: Bool = true,
                quietStartMinutes: Int = 1260, quietEndMinutes: Int = 480,
                showHealthDetails: Bool = false, proactiveEnabled: Bool = true) {
        self.modes = modes; self.quietHoursEnabled = quietHoursEnabled
        self.quietStartMinutes = quietStartMinutes; self.quietEndMinutes = quietEndMinutes
        self.showHealthDetails = showHealthDetails; self.proactiveEnabled = proactiveEnabled
    }
    public func mode(for group: NotificationGroup) -> NotificationDeliveryMode { modes[group] ?? .off }
}

public struct NotificationQuality: Codable, Equatable, Sendable {
    public let isFinal: Bool
    public let hasRequiredInputs: Bool
    public let hasFiniteValues: Bool
    public let coverageAccepted: Bool
    public let sourceAccepted: Bool
    public let modelAccepted: Bool
    public let isHistoricalReplay: Bool
    public let recoveryQualified: Bool
    public init(isFinal: Bool = true, hasRequiredInputs: Bool = true, hasFiniteValues: Bool = true,
                coverageAccepted: Bool = true, sourceAccepted: Bool = true, modelAccepted: Bool = true,
                isHistoricalReplay: Bool = false, recoveryQualified: Bool = false) {
        self.isFinal = isFinal; self.hasRequiredInputs = hasRequiredInputs; self.hasFiniteValues = hasFiniteValues
        self.coverageAccepted = coverageAccepted; self.sourceAccepted = sourceAccepted; self.modelAccepted = modelAccepted
        self.isHistoricalReplay = isHistoricalReplay; self.recoveryQualified = recoveryQualified
    }
}

public struct NotificationCandidate: Codable, Equatable, Sendable {
    public let ruleID: String
    public let ruleVersion: Int
    public let group: NotificationGroup
    public let subjectID: String
    public let occurrenceID: String
    public let attentionKey: String
    public let evidenceRevision: String
    public let sourceContext: String
    public let logicalDay: String
    public let observedAt: Date
    public let generatedAt: Date
    public let expiresAt: Date
    public let quality: NotificationQuality
    public let lane: NotificationLane
    public let priority: Int
    public let destination: NotificationDestination
    public let genericTitle: String
    public let genericBody: String
    public let detailBody: String?
    public let scheduledAt: Date?
    public let freshnessLimit: TimeInterval
    public let requiresRecoveryQualification: Bool
    public init(ruleID: String, ruleVersion: Int = 1, group: NotificationGroup, subjectID: String,
                occurrenceID: String, attentionKey: String, evidenceRevision: String, sourceContext: String,
                logicalDay: String, observedAt: Date, generatedAt: Date, expiresAt: Date,
                quality: NotificationQuality = .init(), lane: NotificationLane = .proactive, priority: Int = 0,
                destination: NotificationDestination, genericTitle: String, genericBody: String,
                detailBody: String? = nil, scheduledAt: Date? = nil, freshnessLimit: TimeInterval = 1800,
                requiresRecoveryQualification: Bool = false) {
        self.ruleID = ruleID; self.ruleVersion = ruleVersion; self.group = group; self.subjectID = subjectID
        self.occurrenceID = occurrenceID; self.attentionKey = attentionKey; self.evidenceRevision = evidenceRevision
        self.sourceContext = sourceContext; self.logicalDay = logicalDay; self.observedAt = observedAt
        self.generatedAt = generatedAt; self.expiresAt = expiresAt; self.quality = quality; self.lane = lane
        self.priority = priority; self.destination = destination; self.genericTitle = genericTitle
        self.genericBody = genericBody; self.detailBody = detailBody; self.scheduledAt = scheduledAt
        self.freshnessLimit = freshnessLimit; self.requiresRecoveryQualification = requiresRecoveryQualification
    }
}

public struct NotificationContext: Equatable, Sendable {
    public let sourceContext: String
    public let logicalDay: String
    public let timeZoneIdentifier: String
    public let permissionGranted: Bool
    public let activeWorkout: Bool
    /// nil means no qualified current observation. A historical sleep window is not live sleep state.
    public let sleeping: Bool?
    public let visibleDestinations: Set<NotificationDestination>
    public let explicitReminderDates: [Date]
    public init(sourceContext: String, logicalDay: String, timeZoneIdentifier: String = TimeZone.current.identifier,
                permissionGranted: Bool = true, activeWorkout: Bool = false, sleeping: Bool? = nil,
                visibleDestinations: Set<NotificationDestination> = [], explicitReminderDates: [Date] = []) {
        self.sourceContext = sourceContext; self.logicalDay = logicalDay; self.timeZoneIdentifier = timeZoneIdentifier
        self.permissionGranted = permissionGranted; self.activeWorkout = activeWorkout; self.sleeping = sleeping
        self.visibleDestinations = visibleDestinations; self.explicitReminderDates = explicitReminderDates
    }
}
public struct NotificationHistoryEntry: Equatable, Sendable {
    public let occurrenceID: String
    public let attentionKey: String
    public let logicalDay: String
    public let chargedAt: Date
    public let isProactive: Bool
    public init(occurrenceID: String, attentionKey: String, logicalDay: String, chargedAt: Date, isProactive: Bool = true) {
        self.occurrenceID = occurrenceID; self.attentionKey = attentionKey; self.logicalDay = logicalDay
        self.chargedAt = chargedAt; self.isProactive = isProactive
    }
}
public struct NotificationDecision: Equatable, Sendable {
    public let candidate: NotificationCandidate
    public let disposition: NotificationDisposition
    public let reason: NotificationReason
    public init(candidate: NotificationCandidate, disposition: NotificationDisposition, reason: NotificationReason) {
        self.candidate = candidate; self.disposition = disposition; self.reason = reason
    }
}
public struct NotificationEvaluation: Equatable, Sendable {
    public let decisions: [NotificationDecision]
    public var selected: [NotificationCandidate] { decisions.filter { $0.disposition == .notify }.map(\.candidate) }
    public var inApp: [NotificationCandidate] { decisions.filter { $0.disposition == .inApp }.map(\.candidate) }
    public init(decisions: [NotificationDecision]) { self.decisions = decisions }
}
