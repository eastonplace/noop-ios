import Foundation

/// A deterministic evaluation. The durable store must repeat budget/identity checks inside its claim transaction.
public enum NotificationPolicy {
    public static let dailyLimit = 2
    public static let rollingSevenDayLimit = 10
    public static let minimumGap: TimeInterval = 180 * 60
    public static let reminderSeparation: TimeInterval = 30 * 60

    public static func evaluate(candidates: [NotificationCandidate], preferences: NotificationPreferencesSnapshot,
                                context: NotificationContext, history: [NotificationHistoryEntry], now: Date) -> NotificationEvaluation {
        var decisions: [NotificationDecision] = []
        var acceptedAttention = Set<String>()
        var workingHistory = history
        // Compute collision preference independently of sorting: conditional comparator overrides can
        // form cycles across three unrelated candidates and violate Swift's strict ordering contract.
        let preferredWorkoutAttention = Set(candidates.filter {
            $0.group == .workoutSummary && rejection($0, preferences: preferences, context: context, history: history, now: now) == nil
        }.map(\.attentionKey))
        let ordered = candidates.sorted { a, b in
            let aReminder = a.lane == .explicitReminder, bReminder = b.lane == .explicitReminder
            if aReminder != bReminder { return aReminder }
            if a.scheduledAt != b.scheduledAt { return (a.scheduledAt ?? .distantFuture) < (b.scheduledAt ?? .distantFuture) }
            if a.expiresAt != b.expiresAt { return a.expiresAt < b.expiresAt }
            if a.priority != b.priority { return a.priority > b.priority }
            if a.ruleID != b.ruleID { return a.ruleID < b.ruleID }
            if a.occurrenceID != b.occurrenceID { return a.occurrenceID < b.occurrenceID }
            return a.evidenceRevision < b.evidenceRevision
        }
        for candidate in ordered {
            if candidate.group == .strainTarget && preferredWorkoutAttention.contains(candidate.attentionKey) {
                decisions.append(.init(candidate: candidate, disposition: .suppress, reason: .coalesced)); continue
            }
            if acceptedAttention.contains(candidate.attentionKey) {
                decisions.append(.init(candidate: candidate, disposition: .suppress, reason: .coalesced)); continue
            }
            let reason = rejection(candidate, preferences: preferences, context: context, history: workingHistory, now: now)
            if let reason {
                decisions.append(.init(candidate: candidate, disposition: .suppress, reason: reason)); continue
            }
            acceptedAttention.insert(candidate.attentionKey)
            let visibleNow = context.visibleDestinations.contains(candidate.destination) && (candidate.scheduledAt == nil || candidate.scheduledAt! <= now)
            if preferences.mode(for: candidate.group) == .inApp || visibleNow {
                decisions.append(.init(candidate: candidate, disposition: .inApp,
                                       reason: visibleNow ? .alreadySeen : .eligible))
            } else {
                decisions.append(.init(candidate: candidate, disposition: .notify, reason: .eligible))
                workingHistory.append(.init(occurrenceID: candidate.occurrenceID, attentionKey: candidate.attentionKey,
                                            logicalDay: candidate.logicalDay, chargedAt: now, isProactive: candidate.lane == .proactive))
            }
        }
        return .init(decisions: decisions)
    }

    private static func rejection(_ c: NotificationCandidate, preferences p: NotificationPreferencesSnapshot,
                                  context: NotificationContext, history: [NotificationHistoryEntry], now: Date) -> NotificationReason? {
        if p.mode(for: c.group) == .off { return .categoryOff }
        let q = c.quality
        if !q.hasRequiredInputs || c.ruleID.isEmpty || c.evidenceRevision.isEmpty || c.subjectID.isEmpty || c.occurrenceID.isEmpty || c.attentionKey.isEmpty || c.sourceContext.isEmpty || c.logicalDay.isEmpty { return .missingInput }
        if !q.hasFiniteValues || !c.observedAt.timeIntervalSince1970.isFinite || !c.generatedAt.timeIntervalSince1970.isFinite || !c.expiresAt.timeIntervalSince1970.isFinite || !c.freshnessLimit.isFinite || c.freshnessLimit < 0 || (c.scheduledAt.map { !$0.timeIntervalSince1970.isFinite } ?? false) { return .invalidValue }
        if !q.sourceAccepted || c.sourceContext != context.sourceContext { return .sourceChanged }
        if !q.modelAccepted { return .modelMismatch }
        if !q.isFinal { return .notFinal }
        if !q.coverageAccepted { return .insufficientCoverage }
        if c.requiresRecoveryQualification && !q.recoveryQualified { return .dependencyUnqualified }
        if q.isHistoricalReplay || (c.lane == .proactive && c.logicalDay != context.logicalDay) { return .historicalReplay }
        if c.expiresAt <= now { return .expired }
        if c.observedAt > now || c.generatedAt > now { return .futureObservation }
        if now.timeIntervalSince(c.observedAt) > c.freshnessLimit { return .staleMetric }
        if history.contains(where: { $0.occurrenceID == c.occurrenceID || $0.attentionKey == c.attentionKey }) { return .alreadyScheduled }
        // Cards never consume OS attention budgets and remain usable with notification permission denied.
        if p.mode(for: c.group) == .inApp || (context.visibleDestinations.contains(c.destination) && (c.scheduledAt == nil || c.scheduledAt! <= now)) { return nil }
        if !context.permissionGranted { return .permissionDenied }
        if c.lane == .proactive {
            if !p.proactiveEnabled { return .proactiveDisabled }
            if context.activeWorkout { return .activeWorkout }
            if context.sleeping { return .sleepInProgress }
            if isQuiet(now, preferences: p, timeZoneIdentifier: context.timeZoneIdentifier) { return .quietHours }
            if context.explicitReminderDates.contains(where: { abs($0.timeIntervalSince(now)) < reminderSeparation }) { return .reminderNearby }
            let proactive = history.filter { $0.isProactive }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: context.timeZoneIdentifier) ?? .current
            if proactive.filter({ calendar.isDate($0.chargedAt, inSameDayAs: now) }).count >= dailyLimit || proactive.filter({ $0.chargedAt > now.addingTimeInterval(-7 * 86400) }).count >= rollingSevenDayLimit { return .budgetFull }
            if proactive.contains(where: { now.timeIntervalSince($0.chargedAt) < minimumGap }) { return .minimumGap }
        }
        return nil
    }
    private static func isQuiet(_ now: Date, preferences: NotificationPreferencesSnapshot, timeZoneIdentifier: String) -> Bool {
        guard preferences.quietHoursEnabled else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let minute = calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
        let start = min(1439, max(0, preferences.quietStartMinutes))
        let end = min(1439, max(0, preferences.quietEndMinutes))
        if start == end { return true }
        return start < end ? minute >= start && minute < end : minute >= start || minute < end
    }
}
