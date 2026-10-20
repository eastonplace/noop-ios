import Foundation
import GRDB

public enum NotificationLedgerState: String, Codable, Sendable {
    case evaluated, suppressed, reserved, submitting, submitted
    case submissionUncertain = "submission_uncertain"
    case failed, withdrawn, acknowledged
}
public struct NotificationLedgerClaim: Equatable, Sendable {
    public let occurrenceID: String
    public let attentionKey: String
    public let ruleID: String
    public let sourceContext: String
    public let evidenceRevision: String
    public let logicalDay: String
    public let requestIdentifier: String
    public let isProactive: Bool
    public let expiresAt: Date
    public let timeZoneIdentifier: String
    public init(occurrenceID: String, attentionKey: String, ruleID: String, sourceContext: String,
                evidenceRevision: String, logicalDay: String, requestIdentifier: String,
                isProactive: Bool, expiresAt: Date, timeZoneIdentifier: String = TimeZone.current.identifier) {
        self.occurrenceID = occurrenceID; self.attentionKey = attentionKey; self.ruleID = ruleID
        self.sourceContext = sourceContext; self.evidenceRevision = evidenceRevision; self.logicalDay = logicalDay
        self.requestIdentifier = requestIdentifier; self.isProactive = isProactive; self.expiresAt = expiresAt
        self.timeZoneIdentifier = timeZoneIdentifier
    }
}
public struct NotificationLedgerRecord: Equatable, Sendable {
    public let occurrenceID: String
    public let attentionKey: String
    public let ruleID: String
    public let sourceContext: String
    public let evidenceRevision: String
    public let logicalDay: String
    public let requestIdentifier: String
    public let isProactive: Bool
    public let expiresAt: Date
    public let state: NotificationLedgerState
    public let chargedAt: Date?
    public let updatedAt: Date
    public let attempts: Int
    public let reason: String?
    fileprivate init(row: Row) {
        occurrenceID = row["occurrenceID"]; attentionKey = row["attentionKey"]; ruleID = row["ruleID"]
        sourceContext = row["sourceContext"]; evidenceRevision = row["evidenceRevision"]; logicalDay = row["logicalDay"]
        requestIdentifier = row["requestIdentifier"]; isProactive = row["isProactive"]
        expiresAt = Date(timeIntervalSince1970: row["expiresAt"])
        state = NotificationLedgerState(rawValue: row["state"]) ?? .submissionUncertain
        let charge: Double? = row["chargedAt"]
        chargedAt = charge.map { Date(timeIntervalSince1970: $0) }
        updatedAt = Date(timeIntervalSince1970: row["updatedAt"]); attempts = row["attempts"]; reason = row["reason"]
    }
}
public struct NotificationEvaluationRecord: Equatable, Sendable {
    public let occurrenceID: String
    public let ruleID: String
    public let evidenceRevision: String
    public let disposition: String
    public let reason: String
    public let dryRun: Bool
    public let evaluatedAt: Date
    fileprivate init(row: Row) {
        occurrenceID = row["occurrenceID"]; ruleID = row["ruleID"]; evidenceRevision = row["evidenceRevision"]
        disposition = row["disposition"]; reason = row["reason"]; dryRun = row["dryRun"]
        evaluatedAt = Date(timeIntervalSince1970: row["evaluatedAt"])
    }
}
public enum NotificationClaimResult: Equatable, Sendable {
    case claimed(NotificationLedgerRecord)
    case rejected(reason: String)
}

extension WhoopStore {
    /// FULL matches syncWriteDurable; IMMEDIATE additionally takes the writer lock before reads,
    /// preventing a second connection's deferred read-to-write upgrade from racing the budget check.
    private func notificationWriteDurable<T>(_ block: (Database) throws -> T) throws -> T {
        try dbWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            defer { try? db.execute(sql: "PRAGMA synchronous = NORMAL") }
            var result: T?
            try db.inTransaction(.immediate) {
                result = try block(db)
                return .commit
            }
            return result!
        }
    }
    /// Last decision per occurrence, separate from platform state; only identifiers and reason codes belong here.
    public func recordNotificationEvaluation(occurrenceID: String, ruleID: String, evidenceRevision: String,
                                             disposition: String, reason: String, dryRun: Bool, now: Date) async throws {
        try syncWrite { db in
            try db.execute(sql: """
                INSERT INTO notificationEvaluation
                (occurrenceID, ruleID, evidenceRevision, disposition, reason, dryRun, evaluatedAt)
                VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(occurrenceID) DO UPDATE SET
                    ruleID = excluded.ruleID, evidenceRevision = excluded.evidenceRevision,
                    disposition = excluded.disposition, reason = excluded.reason,
                    dryRun = excluded.dryRun, evaluatedAt = excluded.evaluatedAt
                """, arguments: [occurrenceID, ruleID, evidenceRevision, disposition, reason, dryRun, now.timeIntervalSince1970])
        }
    }
    public func notificationEvaluations() async throws -> [NotificationEvaluationRecord] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notificationEvaluation ORDER BY evaluatedAt, occurrenceID").map(NotificationEvaluationRecord.init(row:))
        }
    }
    /// GRDB's write transaction serializes occurrence, shared attention, and proactive budget together.
    public func claimNotification(_ claim: NotificationLedgerClaim, now: Date) async throws -> NotificationClaimResult {
        guard now.timeIntervalSince1970.isFinite, claim.expiresAt.timeIntervalSince1970.isFinite else {
            return .rejected(reason: "invalid_value")
        }
        guard !claim.occurrenceID.isEmpty, !claim.attentionKey.isEmpty, !claim.requestIdentifier.isEmpty else {
            return .rejected(reason: "missing_input")
        }
        guard claim.expiresAt > now else { return .rejected(reason: "expired") }
        return try notificationWriteDurable { db in
            let existing = try Row.fetchOne(db, sql: "SELECT * FROM notificationDecision WHERE occurrenceID = ?", arguments: [claim.occurrenceID]).map(NotificationLedgerRecord.init(row:))
            if let existing {
                if existing.state == .reserved,
                   existing.attentionKey == claim.attentionKey,
                   existing.sourceContext == claim.sourceContext,
                   existing.requestIdentifier == claim.requestIdentifier,
                   existing.isProactive == claim.isProactive,
                   existing.expiresAt > now {
                    // Refresh evidence without another charge or a new occurrence. Only submitting CAS invokes add.
                    try db.execute(sql: "UPDATE notificationDecision SET evidenceRevision = ?, expiresAt = ?, updatedAt = ? WHERE occurrenceID = ?",
                                   arguments: [claim.evidenceRevision, min(existing.expiresAt, claim.expiresAt).timeIntervalSince1970,
                                               now.timeIntervalSince1970, claim.occurrenceID])
                    let row = try Row.fetchOne(db, sql: "SELECT * FROM notificationDecision WHERE occurrenceID = ?", arguments: [claim.occurrenceID])!
                    return .claimed(NotificationLedgerRecord(row: row))
                }
                guard existing.state == .failed, existing.attempts < 2,
                      existing.attentionKey == claim.attentionKey,
                      existing.sourceContext == claim.sourceContext,
                      existing.requestIdentifier == claim.requestIdentifier,
                      existing.isProactive == claim.isProactive else {
                    return .rejected(reason: "already_scheduled")
                }
            } else if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notificationIdentity WHERE occurrenceID = ? OR attentionKey = ?)", arguments: [claim.occurrenceID, claim.attentionKey]) == true {
                return .rejected(reason: "already_scheduled")
            }
            let timestamp = now.timeIntervalSince1970
            if claim.isProactive {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = TimeZone(identifier: claim.timeZoneIdentifier) ?? .current
                let dayStart = calendar.startOfDay(for: now)
                let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)!
                let daily = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notificationDecision WHERE isProactive = 1 AND chargedAt >= ? AND chargedAt < ?", arguments: [dayStart.timeIntervalSince1970, dayEnd.timeIntervalSince1970]) ?? 0
                let weekly = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notificationDecision WHERE isProactive = 1 AND chargedAt > ?", arguments: [timestamp - 7 * 86400]) ?? 0
                if daily >= 2 || weekly >= 10 { return .rejected(reason: "budget_full") }
                let recent = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM notificationDecision WHERE isProactive = 1 AND chargedAt > ?)", arguments: [timestamp - 10800]) ?? false
                if recent { return .rejected(reason: "minimum_gap") }
            }
            if existing == nil {
                try db.execute(sql: "INSERT INTO notificationIdentity (occurrenceID, attentionKey) VALUES (?, ?)", arguments: [claim.occurrenceID, claim.attentionKey])
                try db.execute(sql: """
                    INSERT INTO notificationDecision
                    (occurrenceID, attentionKey, ruleID, sourceContext, evidenceRevision, logicalDay,
                     requestIdentifier, isProactive, expiresAt, state, chargedAt, updatedAt, attempts)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'reserved', ?, ?, 0)
                    """, arguments: [claim.occurrenceID, claim.attentionKey, claim.ruleID, claim.sourceContext,
                                      claim.evidenceRevision, claim.logicalDay, claim.requestIdentifier, claim.isProactive,
                                      claim.expiresAt.timeIntervalSince1970, timestamp, timestamp])
            } else {
                try db.execute(sql: """
                    UPDATE notificationDecision SET state = 'reserved', chargedAt = ?, updatedAt = ?,
                        evidenceRevision = ?, expiresAt = ?, reason = NULL WHERE occurrenceID = ?
                    """, arguments: [timestamp, timestamp, claim.evidenceRevision, claim.expiresAt.timeIntervalSince1970, claim.occurrenceID])
            }
            let row = try Row.fetchOne(db, sql: "SELECT * FROM notificationDecision WHERE occurrenceID = ?", arguments: [claim.occurrenceID])!
            return .claimed(NotificationLedgerRecord(row: row))
        }
    }

    public func notificationRecords() async throws -> [NotificationLedgerRecord] {
        try syncRead { db in
            try Row.fetchAll(db, sql: "SELECT * FROM notificationDecision ORDER BY updatedAt, occurrenceID").map(NotificationLedgerRecord.init(row:))
        }
    }
    /// Must succeed durably before invoking the platform add API. A second caller cannot also start add.
    public func markNotificationSubmitting(occurrenceID: String, now: Date) async throws -> Bool {
        try notificationWriteDurable { db in
            try db.execute(sql: """
                UPDATE notificationDecision SET state = 'submitting', attempts = attempts + 1, updatedAt = ?
                WHERE occurrenceID = ? AND state = 'reserved' AND expiresAt > ? AND attempts < 2
                """, arguments: [now.timeIntervalSince1970, occurrenceID, now.timeIntervalSince1970])
            return db.changesCount == 1
        }
    }
    /// Accepted by the OS, not evidence of presentation or human acknowledgement.
    public func markNotificationSubmitted(occurrenceID: String, now: Date) async throws {
        try notificationWriteDurable { db in
            try db.execute(sql: "UPDATE notificationDecision SET state = 'submitted', updatedAt = ?, reason = NULL WHERE occurrenceID = ? AND state IN ('submitting', 'submission_uncertain')", arguments: [now.timeIntervalSince1970, occurrenceID])
        }
    }
    /// Call only when add returned a known error. Unknown results must go through reconciliation.
    public func markNotificationFailed(occurrenceID: String, now: Date, reason: String) async throws {
        try notificationWriteDurable { db in
            try db.execute(sql: "UPDATE notificationDecision SET state = 'failed', chargedAt = NULL, updatedAt = ?, reason = ? WHERE occurrenceID = ? AND state = 'submitting'", arguments: [now.timeIntervalSince1970, reason, occurrenceID])
        }
    }
    public func withdrawNotification(occurrenceID: String, now: Date) async throws {
        try notificationWriteDurable { db in
            try db.execute(sql: """
                UPDATE notificationDecision SET state = 'withdrawn', updatedAt = ?, reason = 'withdrawn',
                    chargedAt = CASE WHEN attempts = 0 THEN NULL ELSE chargedAt END
                WHERE occurrenceID = ? AND state NOT IN ('acknowledged', 'withdrawn')
                """, arguments: [now.timeIntervalSince1970, occurrenceID])
        }
    }
    public func acknowledgeNotification(occurrenceID: String, now: Date) async throws {
        try notificationWriteDurable { db in
            try db.execute(sql: "UPDATE notificationDecision SET state = 'acknowledged', updatedAt = ?, reason = NULL WHERE occurrenceID = ? AND state IN ('submitting', 'submitted', 'submission_uncertain', 'withdrawn')", arguments: [now.timeIntervalSince1970, occurrenceID])
        }
    }
    public func reconcileNotifications(pending: Set<String>, delivered: Set<String>, now: Date) async throws {
        try notificationWriteDurable { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM notificationDecision WHERE state IN ('submitting', 'submission_uncertain')")
            for row in rows {
                let record = NotificationLedgerRecord(row: row)
                let present = pending.contains(record.requestIdentifier) || delivered.contains(record.requestIdentifier)
                let state: NotificationLedgerState = present ? .submitted : .submissionUncertain
                // Repeated absence is not new evidence and must not restart decision retention.
                guard state != record.state else { continue }
                try db.execute(sql: "UPDATE notificationDecision SET state = ?, updatedAt = ?, reason = ? WHERE occurrenceID = ?", arguments: [state.rawValue, now.timeIntervalSince1970, present ? nil : "submission_uncertain", record.occurrenceID])
            }
            // Reserved proves no add invocation; expiry releases its unused budget, but identity stays claimed.
            try db.execute(sql: "UPDATE notificationDecision SET state = 'withdrawn', chargedAt = NULL, updatedAt = ?, reason = 'expired' WHERE state = 'reserved' AND expiresAt <= ?", arguments: [now.timeIntervalSince1970, now.timeIntervalSince1970])
        }
    }
    public func pruneNotificationDecisions(now: Date, retentionDays: Int = 30) async throws {
        let cutoff = now.addingTimeInterval(-Double(max(7, retentionDays)) * 86400).timeIntervalSince1970
        try notificationWriteDurable { db in
            try db.execute(sql: "DELETE FROM notificationEvaluation WHERE evaluatedAt < ?", arguments: [cutoff])
            // Only active accepted/acknowledged schedules need ownership beyond normal retention.
            // Terminal cancellation or uncertainty keeps the compact identity, not indefinite details.
            try db.execute(sql: """
                DELETE FROM notificationDecision WHERE updatedAt < ?
                    AND state NOT IN ('reserved', 'submitting')
                    AND (expiresAt <= ? OR state NOT IN ('submitted', 'acknowledged'))
                """, arguments: [cutoff, now.timeIntervalSince1970])
        }
    }
    /// An unknown observation never clears a live device episode. A valid clear rearms the next episode.
    public func notificationEpisode(deviceID: String, family: String, observationIsActive: Bool?, now: Date) async throws -> String? {
        try notificationWriteDurable { db in
            let row = try Row.fetchOne(db, sql: "SELECT * FROM notificationEpisode WHERE deviceID = ? AND family = ?", arguments: [deviceID, family])
            let active: Bool = row?["isActive"] ?? false
            let current: String? = row?["episodeID"]
            guard let observationIsActive else { return active ? current : nil }
            if observationIsActive && active { return current }
            if !observationIsActive {
                try db.execute(sql: "UPDATE notificationEpisode SET isActive = 0, updatedAt = ? WHERE deviceID = ? AND family = ?", arguments: [now.timeIntervalSince1970, deviceID, family])
                return nil
            }
            let episode = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO notificationEpisode(deviceID, family, episodeID, isActive, updatedAt)
                VALUES (?, ?, ?, 1, ?) ON CONFLICT(deviceID, family) DO UPDATE SET
                    episodeID = excluded.episodeID, isActive = 1, updatedAt = excluded.updatedAt
                """, arguments: [deviceID, family, episode, now.timeIntervalSince1970])
            return episode
        }
    }
}
