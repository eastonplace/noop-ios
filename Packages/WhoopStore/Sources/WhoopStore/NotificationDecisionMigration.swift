import GRDB

public enum NotificationDecisionMigration {
    /// v60 is reserved for the independently reviewed recovery repair.
    public static let identifier = "v61-notification-decisions"
    public static func register(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration(identifier) { db in
            try db.execute(sql: """
                CREATE TABLE notificationDecision (
                    occurrenceID TEXT PRIMARY KEY NOT NULL,
                    attentionKey TEXT UNIQUE NOT NULL,
                    ruleID TEXT NOT NULL, sourceContext TEXT NOT NULL, evidenceRevision TEXT NOT NULL,
                    logicalDay TEXT NOT NULL, requestIdentifier TEXT NOT NULL,
                    isProactive INTEGER NOT NULL, expiresAt REAL NOT NULL,
                    state TEXT NOT NULL, chargedAt REAL, updatedAt REAL NOT NULL,
                    attempts INTEGER NOT NULL DEFAULT 0, reason TEXT
                )
                """)
            try db.execute(sql: "CREATE INDEX notificationDecision_budget ON notificationDecision(isProactive, chargedAt, logicalDay)")
            try db.execute(sql: """
                CREATE TABLE notificationEvaluation (
                    occurrenceID TEXT PRIMARY KEY NOT NULL, ruleID TEXT NOT NULL,
                    evidenceRevision TEXT NOT NULL, disposition TEXT NOT NULL,
                    reason TEXT NOT NULL, dryRun INTEGER NOT NULL, evaluatedAt REAL NOT NULL
                )
                """)
            try db.execute(sql: "CREATE INDEX notificationEvaluation_retention ON notificationEvaluation(evaluatedAt)")
            // Compact durable identity tombstones outlive diagnostic decision retention.
            try db.execute(sql: """
                CREATE TABLE notificationIdentity (
                    occurrenceID TEXT PRIMARY KEY NOT NULL,
                    attentionKey TEXT UNIQUE NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE TABLE notificationEpisode (
                    deviceID TEXT NOT NULL, family TEXT NOT NULL,
                    episodeID TEXT NOT NULL, isActive INTEGER NOT NULL, updatedAt REAL NOT NULL,
                    PRIMARY KEY(deviceID, family)
                )
                """)
        }
    }
}
