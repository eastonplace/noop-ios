import XCTest
import GRDB
@testable import WhoopStore

final class NotificationDecisionStoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func claim(_ id: String = "one", attention: String? = nil, day: String = "today", proactive: Bool = true) -> NotificationLedgerClaim {
        .init(occurrenceID: id, attentionKey: attention ?? id, ruleID: "rule", sourceContext: "canonical", evidenceRevision: "1", logicalDay: day, requestIdentifier: "noop.\(id)", isProactive: proactive, expiresAt: now.addingTimeInterval(86400), timeZoneIdentifier: "UTC")
    }
    func testMigrationAndAtomicAttentionClaim() async throws {
        let store = try await WhoopStore.inMemory()
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("notificationDecision"))
        async let a = store.claimNotification(claim("one", attention: "shared"), now: now)
        async let b = store.claimNotification(claim("two", attention: "shared"), now: now)
        let results = try await [a, b]
        XCTAssertEqual(results.filter { if case .claimed = $0 { return true }; return false }.count, 1)
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.count, 1)
    }
    func testKnownFailureReleasesBudgetAndOnlyOneRetry() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim(), now: now)
        let marked = try await store.markNotificationSubmitting(occurrenceID: "one", now: now)
        XCTAssertTrue(marked)
        try await store.markNotificationFailed(occurrenceID: "one", now: now, reason: "add_failed")
        let retry = try await store.claimNotification(claim(), now: now)
        guard case .claimed = retry else { return XCTFail("Expected one known-failure retry") }
        _ = try await store.markNotificationSubmitting(occurrenceID: "one", now: now)
        try await store.markNotificationFailed(occurrenceID: "one", now: now, reason: "add_failed")
        let exhausted = try await store.claimNotification(claim(), now: now)
        guard case .rejected = exhausted else { return XCTFail("Third add attempt must be forbidden") }
        let rows = try await store.notificationRecords()
        XCTAssertNil(rows.first?.chargedAt)
    }
    func testInterruptedSubmissionConservativelyKeepsCharge() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim(), now: now)
        _ = try await store.markNotificationSubmitting(occurrenceID: "one", now: now)
        try await store.reconcileNotifications(pending: [], delivered: [], now: now)
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.first?.state, .submissionUncertain)
        XCTAssertNotNil(rows.first?.chargedAt)
        let retry = try await store.claimNotification(claim(), now: now)
        guard case .rejected = retry else { return XCTFail("Uncertain delivery cannot resend") }
    }
    func testReservedBeforeAddCanResumeAndAcceptedNeverMeansAcknowledged() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim(), now: now)
        try await store.reconcileNotifications(pending: [], delivered: [], now: now)
        let resumed = try await store.claimNotification(claim(), now: now)
        guard case .claimed = resumed else { return XCTFail("Durable reserved state must be resumable") }
        let marked = try await store.markNotificationSubmitting(occurrenceID: "one", now: now)
        XCTAssertTrue(marked)
        try await store.reconcileNotifications(pending: ["noop.one"], delivered: [], now: now)
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.first?.state, .submitted)
    }
    func testAtomicBudgetProtectsIndependentClaims() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim("one"), now: now)
        let other = try await store.claimNotification(claim("two"), now: now)
        XCTAssertEqual(other, .rejected(reason: "minimum_gap"))
        let later = now.addingTimeInterval(10800)
        _ = try await store.claimNotification(claim("two"), now: later)
        let third = try await store.claimNotification(claim("three"), now: later.addingTimeInterval(10800))
        XCTAssertEqual(third, .rejected(reason: "budget_full"))
    }
    func testEpisodeUnknownDoesNotClearAndDevicesRemainSeparate() async throws {
        let store = try await WhoopStore.inMemory()
        let a = try await store.notificationEpisode(deviceID: "a", family: "battery", observationIsActive: true, now: now)
        let unknown = try await store.notificationEpisode(deviceID: "a", family: "battery", observationIsActive: nil, now: now)
        let b = try await store.notificationEpisode(deviceID: "b", family: "battery", observationIsActive: true, now: now)
        XCTAssertEqual(a, unknown); XCTAssertNotEqual(a, b)
        _ = try await store.notificationEpisode(deviceID: "a", family: "battery", observationIsActive: false, now: now)
        let rearmed = try await store.notificationEpisode(deviceID: "a", family: "battery", observationIsActive: true, now: now)
        XCTAssertNotEqual(a, rearmed)
    }
    func testRetentionPreservesOccurrenceAndAttentionTombstones() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim(), now: now)
        _ = try await store.markNotificationSubmitting(occurrenceID: "one", now: now)
        try await store.markNotificationSubmitted(occurrenceID: "one", now: now)
        let later = now.addingTimeInterval(31 * 86400)
        try await store.pruneNotificationDecisions(now: later)
        let rows = try await store.notificationRecords()
        XCTAssertTrue(rows.isEmpty)
        let newClaim = NotificationLedgerClaim(occurrenceID: "other", attentionKey: "one", ruleID: "rule", sourceContext: "canonical", evidenceRevision: "2", logicalDay: "later", requestIdentifier: "other", isProactive: true, expiresAt: later.addingTimeInterval(60))
        let result = try await store.claimNotification(newClaim, now: later)
        XCTAssertEqual(result, .rejected(reason: "already_scheduled"))
    }
    func testProductionV60UpgradeAddsEmptyNotificationTablesAndPreservesHealthAndLift() throws {
        let queue = try DatabaseQueue()
        let migrator = WhoopStore.makeMigrator()
        try migrator.migrate(queue, upTo: LiftStrainMigration.identifier)
        try WhoopStore.migrateSleepRecoverySchema(queue)
        try queue.write { db in
            try MigrationPreservationFixture.seedStrengthAndRawRR(db)
            try MigrationPreservationFixture.seedHealthAndLiftLog(db)
        }
        try migrator.migrate(queue, upTo: RRQualityMigration.identifier)
        let before = try queue.read { db in
            (try MigrationPreservationFixture.healthAndLiftSnapshots(db),
             try MigrationPreservationFixture.snapshot(db, sql: "SELECT * FROM rrInterval ORDER BY deviceId, ts, rrMs, seq"),
             try MigrationPreservationFixture.snapshot(db, sql: "SELECT * FROM hrSample ORDER BY deviceId, ts"))
        }
        for _ in 1...2 {
            try migrator.migrate(queue)
            try queue.read { db in
                XCTAssertEqual(try MigrationPreservationFixture.healthAndLiftSnapshots(db), before.0)
                XCTAssertEqual(try MigrationPreservationFixture.snapshot(db, sql: "SELECT * FROM rrInterval ORDER BY deviceId, ts, rrMs, seq"), before.1)
                XCTAssertEqual(try MigrationPreservationFixture.snapshot(db, sql: "SELECT * FROM hrSample ORDER BY deviceId, ts"), before.2)
                try MigrationPreservationFixture.assertNotificationTablesEmpty(db)
                let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
                let coreTail = identifiers.filter { [LiftStrainMigration.identifier, RRQualityMigration.identifier, NotificationDecisionMigration.identifier].contains($0) }
                XCTAssertEqual(coreTail, [LiftStrainMigration.identifier, RRQualityMigration.identifier, NotificationDecisionMigration.identifier])
                XCTAssertEqual(Set(identifiers).count, identifiers.count)
            }
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 62)
    }
    func testFileBackedRestartPreservesSubmittingAndEpisode() async throws {
        let path = NSTemporaryDirectory() + "notification-ledger-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let first = try await WhoopStore(path: path)
        _ = try await first.claimNotification(claim(), now: now)
        _ = try await first.markNotificationSubmitting(occurrenceID: "one", now: now)
        let episode = try await first.notificationEpisode(deviceID: "strap", family: "battery", observationIsActive: true, now: now)
        try await first.close()
        let reopened = try await WhoopStore(path: path)
        try await reopened.reconcileNotifications(pending: [], delivered: [], now: now)
        let records = try await reopened.notificationRecords()
        XCTAssertEqual(records.first?.state, .submissionUncertain)
        let sameEpisode = try await reopened.notificationEpisode(deviceID: "strap", family: "battery", observationIsActive: nil, now: now)
        XCTAssertEqual(sameEpisode, episode)
        try await reopened.close()
    }
    func testOnlyOneConcurrentSubmitGateCanInvokePlatformAdd() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim(), now: now)
        async let a = store.markNotificationSubmitting(occurrenceID: "one", now: now)
        async let b = store.markNotificationSubmitting(occurrenceID: "one", now: now)
        let gates = try await [a, b]
        XCTAssertEqual(gates.filter { $0 }.count, 1)
    }

    func testConcurrentStoreHandlesShareAtomicAttentionAndBudget() async throws {
        let path = NSTemporaryDirectory() + "notification-concurrent-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let first = try await WhoopStore(path: path)
        let second = try await WhoopStore(path: path)
        async let a = first.claimNotification(claim("a", attention: "shared"), now: now)
        async let b = second.claimNotification(claim("b", attention: "shared"), now: now)
        let claims = try await [a, b]
        XCTAssertEqual(claims.filter { if case .claimed = $0 { return true }; return false }.count, 1)
        let rows = try await second.notificationRecords()
        XCTAssertEqual(rows.count, 1)
        try await first.close()
        try await second.close()
    }
    func testRetentionKeepsFutureRecurringScheduleOwnership() async throws {
        let store = try await WhoopStore.inMemory()
        let recurring = NotificationLedgerClaim(occurrenceID: "recurring", attentionKey: "recurring", ruleID: "windDown", sourceContext: "canonical", evidenceRevision: "1", logicalDay: "today", requestIdentifier: "recurring", isProactive: false, expiresAt: now.addingTimeInterval(365 * 86400))
        _ = try await store.claimNotification(recurring, now: now)
        _ = try await store.markNotificationSubmitting(occurrenceID: "recurring", now: now)
        try await store.markNotificationSubmitted(occurrenceID: "recurring", now: now)
        try await store.pruneNotificationDecisions(now: now.addingTimeInterval(31 * 86400))
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.first?.requestIdentifier, "recurring")
    }

    func testEvaluationAuditIsBoundedAndDoesNotOverwriteSchedulingState() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim(), now: now)
        try await store.recordNotificationEvaluation(occurrenceID: "one", ruleID: "rule", evidenceRevision: "1", disposition: "notify", reason: "eligible", dryRun: true, now: now)
        try await store.recordNotificationEvaluation(occurrenceID: "one", ruleID: "rule", evidenceRevision: "2", disposition: "suppress", reason: "source_changed", dryRun: true, now: now)
        let evaluations = try await store.notificationEvaluations()
        XCTAssertEqual(evaluations.count, 1)
        XCTAssertEqual(evaluations.first?.evidenceRevision, "2")
        XCTAssertEqual(evaluations.first?.reason, "source_changed")
        XCTAssertEqual(evaluations.first?.dryRun, true)
        let ledger = try await store.notificationRecords()
        XCTAssertEqual(ledger.first?.state, .reserved)
        try await store.pruneNotificationDecisions(now: now.addingTimeInterval(31 * 86400))
        let retained = try await store.notificationEvaluations()
        XCTAssertTrue(retained.isEmpty)
    }

    func testNotificationFirstDatabaseReceivesRealRecoveryMigrationAcrossFileBackedReopens() async throws {
        let path = NSTemporaryDirectory() + "notification-first-upgrade-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let queue = try DatabaseQueue(path: path)
        try WhoopStore.makeMigrator().migrate(queue, upTo: LiftStrainMigration.identifier)
        // Reproduce the shipped notification branch: core v59 plus real v61, with
        // the real recovery v60 not yet applied. No replacement/fake recovery tables.
        var notificationFirst = DatabaseMigrator()
        NotificationDecisionMigration.register(on: &notificationFirst)
        try notificationFirst.migrate(queue)
        try WhoopStore.migrateSleepRecoverySchema(queue)
        try await queue.write { db in
            XCTAssertFalse(try db.columns(in: "rrInterval").contains { $0.name == "tsSuspect" })
            try MigrationPreservationFixture.seedStrengthAndRawRR(db)
            try MigrationPreservationFixture.seedHealthAndLiftLog(db)
            try db.execute(sql: """
                INSERT INTO notificationDecision
                    (occurrenceID,attentionKey,ruleID,sourceContext,evidenceRevision,logicalDay,requestIdentifier,
                     isProactive,expiresAt,state,chargedAt,updatedAt,attempts,reason)
                VALUES ('old-notification','old-attention','completedWorkout','canonical','rev-1','2026-07-17',
                        'noop.old-notification',1,1800086400.25,'submitting',1800000000.125,1800000001.25,1,NULL);
                INSERT INTO notificationEvaluation
                    (occurrenceID,ruleID,evidenceRevision,disposition,reason,dryRun,evaluatedAt)
                VALUES ('old-notification','completedWorkout','rev-1','notify','eligible',0,1800000000.125);
                INSERT INTO notificationIdentity (occurrenceID,attentionKey)
                VALUES ('old-notification','old-attention'),('retained-tombstone','retained-attention');
                INSERT INTO notificationEpisode (deviceID,family,episodeID,isActive,updatedAt)
                VALUES ('strap','battery','existing-episode',1,1800000000.125);
                """)
        }
        let before = try await queue.read { db in
            let rrColumns = try db.columns(in: "rrInterval").map(\.name)
            let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
            XCTAssertFalse(identifiers.contains(RRQualityMigration.identifier))
            XCTAssertTrue(identifiers.contains(NotificationDecisionMigration.identifier))
            return (try MigrationPreservationFixture.healthAndLiftSnapshots(db), rrColumns,
                    try MigrationPreservationFixture.snapshot(db, sql: MigrationPreservationFixture.rawRRSQL(columns: rrColumns)),
                    try MigrationPreservationFixture.snapshot(db, sql: "SELECT * FROM hrSample ORDER BY deviceId, ts"),
                    try MigrationPreservationFixture.notificationSnapshots(db))
        }
        try queue.close()

        var firstMigrationIDs: [String]?
        for pass in 1...2 {
            // Exercise the actual production open gate, core factory and recovery sidecar.
            let reopened = try await WhoopStore(path: path)
            let identifiers = try await reopened.registryWriter.read { db in
                XCTAssertEqual(try MigrationPreservationFixture.healthAndLiftSnapshots(db), before.0, "Open \(pass)")
                XCTAssertEqual(try MigrationPreservationFixture.snapshot(db, sql: MigrationPreservationFixture.rawRRSQL(columns: before.1)), before.2)
                XCTAssertEqual(try MigrationPreservationFixture.snapshot(db, sql: "SELECT * FROM hrSample ORDER BY deviceId, ts"), before.3)
                XCTAssertEqual(try MigrationPreservationFixture.notificationSnapshots(db), before.4)
                XCTAssertEqual(try db.primaryKey("rrInterval").columns, ["deviceId", "ts", "rrMs", "seq"])
                XCTAssertEqual(try db.columns(in: "rrInterval").map(\.name), before.1 + ["tsSuspect"])
                let annotations = try Row.fetchAll(db, sql: "SELECT tsSuspect FROM rrInterval ORDER BY deviceId, ts, rrMs, seq").map { $0["tsSuspect"] as Int? }
                XCTAssertEqual(annotations, [1, 1, 1, nil])
                let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
                let coreTail = identifiers.filter { [LiftStrainMigration.identifier, RRQualityMigration.identifier, NotificationDecisionMigration.identifier].contains($0) }
                // Applied order retains history: v60 is inserted after already-applied v61.
                XCTAssertEqual(coreTail, [LiftStrainMigration.identifier, NotificationDecisionMigration.identifier, RRQualityMigration.identifier])
                XCTAssertEqual(Set(identifiers).count, identifiers.count)
                return identifiers
            }
            try await reopened.close()
            if let firstMigrationIDs {
                XCTAssertEqual(identifiers, firstMigrationIDs, "Second production open must not reapply a migration")
            } else {
                firstMigrationIDs = identifiers
            }
        }
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 62)
    }
    func testDailyBudgetUsesChargeCalendarDayDespiteDifferentEvidenceLabels() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim("a", day: "evidence-a"), now: now)
        _ = try await store.claimNotification(claim("b", day: "evidence-b"), now: now.addingTimeInterval(10800))
        let third = try await store.claimNotification(claim("c", day: "evidence-c"), now: now.addingTimeInterval(21600))
        XCTAssertEqual(third, .rejected(reason: "budget_full"))
    }

    func testReservedRecomputationRefreshesEvidenceWithoutNewBudgetCharge() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim(), now: now)
        let revision = NotificationLedgerClaim(occurrenceID: "one", attentionKey: "one", ruleID: "rule", sourceContext: "canonical", evidenceRevision: "2", logicalDay: "today", requestIdentifier: "noop.one", isProactive: true, expiresAt: now.addingTimeInterval(600))
        let result = try await store.claimNotification(revision, now: now.addingTimeInterval(60))
        guard case let .claimed(record) = result else { return XCTFail("Expected safe reserved revision refresh") }
        XCTAssertEqual(record.evidenceRevision, "2")
        XCTAssertEqual(record.chargedAt, now)
        XCTAssertEqual(record.attempts, 0)
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.count, 1)
    }

    func testDailyBudgetResetsAtLocalCalendarMidnight() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim("a"), now: now.addingTimeInterval(-7 * 3600))
        _ = try await store.claimNotification(claim("b"), now: now.addingTimeInterval(-4 * 3600))
        let afterMidnight = NotificationLedgerClaim(occurrenceID: "c", attentionKey: "c", ruleID: "rule", sourceContext: "canonical", evidenceRevision: "1", logicalDay: "today", requestIdentifier: "noop.c", isProactive: true, expiresAt: now.addingTimeInterval(3600), timeZoneIdentifier: "America/Los_Angeles")
        let result = try await store.claimNotification(afterMidnight, now: now)
        guard case .claimed = result else { return XCTFail("Earlier UTC-day charges occurred before Los Angeles midnight") }
    }

    func testDailyUnchangedReconciliationDoesNotExtendUncertainRetention() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim(), now: now)
        _ = try await store.markNotificationSubmitting(occurrenceID: "one", now: now)
        try await store.reconcileNotifications(pending: [], delivered: [], now: now)
        for day in 1...31 {
            let today = now.addingTimeInterval(Double(day) * 86400)
            try await store.reconcileNotifications(pending: [], delivered: [], now: today)
            if day == 30 {
                let beforePrune = try await store.notificationRecords()
                XCTAssertEqual(beforePrune.first?.updatedAt, now)
                XCTAssertEqual(beforePrune.first?.chargedAt, now)
                XCTAssertEqual(beforePrune.first?.state, .submissionUncertain)
            }
            try await store.pruneNotificationDecisions(now: today)
        }
        let retained = try await store.notificationRecords()
        XCTAssertTrue(retained.isEmpty)
        let later = now.addingTimeInterval(31 * 86400)
        let replay = NotificationLedgerClaim(occurrenceID: "recomputed", attentionKey: "one", ruleID: "rule", sourceContext: "canonical", evidenceRevision: "2", logicalDay: "later", requestIdentifier: "noop.recomputed", isProactive: true, expiresAt: later.addingTimeInterval(600))
        let result = try await store.claimNotification(replay, now: later)
        XCTAssertEqual(result, .rejected(reason: "already_scheduled"))
    }
    func testDailyWithdrawalDoesNotKeepCancelledRecurringDecisionForever() async throws {
        let store = try await WhoopStore.inMemory()
        let recurring = NotificationLedgerClaim(occurrenceID: "recurring", attentionKey: "recurring", ruleID: "windDown", sourceContext: "canonical", evidenceRevision: "1", logicalDay: "today", requestIdentifier: "recurring", isProactive: false, expiresAt: .distantFuture)
        _ = try await store.claimNotification(recurring, now: now)
        _ = try await store.markNotificationSubmitting(occurrenceID: "recurring", now: now)
        try await store.markNotificationSubmitted(occurrenceID: "recurring", now: now)
        try await store.withdrawNotification(occurrenceID: "recurring", now: now)
        for day in 1...31 {
            let today = now.addingTimeInterval(Double(day) * 86400)
            try await store.reconcileNotifications(pending: [], delivered: [], now: today)
            try await store.withdrawNotification(occurrenceID: "recurring", now: today)
            if day == 30 {
                let beforePrune = try await store.notificationRecords()
                XCTAssertEqual(beforePrune.first?.updatedAt, now)
                XCTAssertEqual(beforePrune.first?.chargedAt, now)
            }
            try await store.pruneNotificationDecisions(now: today)
        }
        let retained = try await store.notificationRecords()
        XCTAssertTrue(retained.isEmpty)
        let replay = try await store.claimNotification(recurring, now: now.addingTimeInterval(31 * 86400))
        XCTAssertEqual(replay, .rejected(reason: "already_scheduled"))
    }
    func testAcknowledgedRecurringWithdrawalPrunesDetailsButPreservesConsumedIdentity() async throws {
        let store = try await WhoopStore.inMemory()
        let withdrawnAt = now.addingTimeInterval(120)
        for rule in ["windDown", "weeklyReview"] {
            let recurring = NotificationLedgerClaim(occurrenceID: rule, attentionKey: rule, ruleID: rule, sourceContext: "canonical", evidenceRevision: "1", logicalDay: "today", requestIdentifier: "noop.\(rule)", isProactive: false, expiresAt: .distantFuture)
            _ = try await store.claimNotification(recurring, now: now)
            _ = try await store.markNotificationSubmitting(occurrenceID: rule, now: now)
            try await store.markNotificationSubmitted(occurrenceID: rule, now: now)
            try await store.acknowledgeNotification(occurrenceID: rule, now: now.addingTimeInterval(60))
            try await store.withdrawNotification(occurrenceID: rule, now: withdrawnAt)
        }
        for day in 1...31 {
            let today = withdrawnAt.addingTimeInterval(Double(day) * 86400)
            for rule in ["windDown", "weeklyReview"] {
                // Repeated cancellation and a late user response must not revive ownership
                // or move the start of the diagnostic retention window.
                try await store.withdrawNotification(occurrenceID: rule, now: today)
                try await store.acknowledgeNotification(occurrenceID: rule, now: today)
            }
            try await store.pruneNotificationDecisions(now: today)
            if day == 30 {
                let retained = try await store.notificationRecords()
                XCTAssertEqual(retained.count, 2)
                XCTAssertTrue(retained.allSatisfy { $0.state == .withdrawn && $0.updatedAt == withdrawnAt && $0.chargedAt == now })
            }
        }
        let retained = try await store.notificationRecords()
        XCTAssertTrue(retained.isEmpty)
        let later = withdrawnAt.addingTimeInterval(31 * 86400)
        for rule in ["windDown", "weeklyReview"] {
            let sameOccurrence = NotificationLedgerClaim(occurrenceID: rule, attentionKey: "changed-\(rule)", ruleID: rule, sourceContext: "canonical", evidenceRevision: "2", logicalDay: "later", requestIdentifier: "noop.\(rule)", isProactive: false, expiresAt: .distantFuture)
            let sameAttention = NotificationLedgerClaim(occurrenceID: "new-\(rule)", attentionKey: rule, ruleID: rule, sourceContext: "canonical", evidenceRevision: "2", logicalDay: "later", requestIdentifier: "noop.new-\(rule)", isProactive: false, expiresAt: .distantFuture)
            let occurrenceReplay = try await store.claimNotification(sameOccurrence, now: later)
            let attentionReplay = try await store.claimNotification(sameAttention, now: later)
            XCTAssertEqual(occurrenceReplay, .rejected(reason: "already_scheduled"))
            XCTAssertEqual(attentionReplay, .rejected(reason: "already_scheduled"))
        }
    }
    func testAcknowledgedActiveRecurringOwnershipSurvivesDailyRetention() async throws {
        let path = NSTemporaryDirectory() + "notification-acknowledged-recurring-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try await WhoopStore(path: path)
        let recurring = NotificationLedgerClaim(occurrenceID: "recurring", attentionKey: "recurring", ruleID: "windDown", sourceContext: "canonical", evidenceRevision: "1", logicalDay: "today", requestIdentifier: "recurring", isProactive: false, expiresAt: .distantFuture)
        _ = try await store.claimNotification(recurring, now: now)
        _ = try await store.markNotificationSubmitting(occurrenceID: "recurring", now: now)
        try await store.markNotificationSubmitted(occurrenceID: "recurring", now: now)
        try await store.acknowledgeNotification(occurrenceID: "recurring", now: now)
        for day in 1...31 {
            let today = now.addingTimeInterval(Double(day) * 86400)
            try await store.reconcileNotifications(pending: ["recurring"], delivered: [], now: today)
            try await store.pruneNotificationDecisions(now: today)
        }
        let retained = try await store.notificationRecords()
        XCTAssertEqual(retained.count, 1)
        XCTAssertEqual(retained.first?.state, .acknowledged)
        XCTAssertEqual(retained.first?.updatedAt, now)
        try await store.close()
        let reopened = try await WhoopStore(path: path)
        let later = now.addingTimeInterval(31 * 86400)
        try await reopened.reconcileNotifications(pending: ["recurring"], delivered: [], now: later)
        try await reopened.pruneNotificationDecisions(now: later)
        let afterRestart = try await reopened.notificationRecords()
        XCTAssertEqual(afterRestart, retained)
        let replay = try await reopened.claimNotification(recurring, now: later)
        XCTAssertEqual(replay, .rejected(reason: "already_scheduled"))
        let sameAttention = NotificationLedgerClaim(occurrenceID: "recomputed", attentionKey: "recurring", ruleID: "windDown", sourceContext: "canonical", evidenceRevision: "2", logicalDay: "later", requestIdentifier: "recomputed", isProactive: false, expiresAt: .distantFuture)
        let attentionReplay = try await reopened.claimNotification(sameAttention, now: later)
        XCTAssertEqual(attentionReplay, .rejected(reason: "already_scheduled"))
        try await reopened.close()
    }

    func testProvenPreInvocationWithdrawalReleasesBudgetWithoutReleasingIdentity() async throws {
        for acquireSubmitGate in [false, true] {
            let store = try await WhoopStore.inMemory()
            _ = try await store.claimNotification(claim(), now: now)
            if acquireSubmitGate {
                let gate = try await store.markNotificationSubmitting(occurrenceID: "one", now: now)
                XCTAssertTrue(gate)
            }
            try await store.withdrawNotificationBeforeInvocation(occurrenceID: "one", now: now, acquiredSubmitGate: acquireSubmitGate)
            let rows = try await store.notificationRecords()
            XCTAssertEqual(rows.first?.state, .withdrawn)
            XCTAssertEqual(rows.first?.attempts, acquireSubmitGate ? 1 : 0)
            XCTAssertNil(rows.first?.chargedAt)
            let occurrenceReplay = try await store.claimNotification(claim(), now: now)
            let attentionReplay = try await store.claimNotification(claim("recomputed", attention: "one"), now: now)
            XCTAssertEqual(occurrenceReplay, .rejected(reason: "already_scheduled"))
            XCTAssertEqual(attentionReplay, .rejected(reason: "already_scheduled"))
            let unrelated = try await store.claimNotification(claim("unrelated"), now: now)
            guard case .claimed = unrelated else { return XCTFail("A proven absence of add must release the proactive charge") }
        }
    }

    func testPreInvocationWithdrawalWithoutOwnedSubmitGatePreservesAnotherCallersCharge() async throws {
        let path = NSTemporaryDirectory() + "notification-pre-invocation-gate-\(UUID().uuidString).sqlite"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let first = try await WhoopStore(path: path)
        let otherCaller = try await WhoopStore(path: path)
        _ = try await first.claimNotification(claim(), now: now)
        let otherGate = try await otherCaller.markNotificationSubmitting(occurrenceID: "one", now: now)
        XCTAssertTrue(otherGate)
        try await first.withdrawNotificationBeforeInvocation(occurrenceID: "one", now: now.addingTimeInterval(60))
        let submitting = try await first.notificationRecords()
        XCTAssertEqual(submitting.first?.state, .submitting)
        XCTAssertEqual(submitting.first?.chargedAt, now)
        XCTAssertEqual(submitting.first?.updatedAt, now)
        // A producer cancellation can race with that caller's submission. Without
        // owning its gate, this caller still has no proof that add was not invoked.
        let cancelledAt = now.addingTimeInterval(120)
        try await first.withdrawNotification(occurrenceID: "one", now: cancelledAt)
        try await first.withdrawNotificationBeforeInvocation(occurrenceID: "one", now: now.addingTimeInterval(180))
        let cancelled = try await first.notificationRecords()
        XCTAssertEqual(cancelled.first?.state, .withdrawn)
        XCTAssertEqual(cancelled.first?.chargedAt, now)
        XCTAssertEqual(cancelled.first?.updatedAt, cancelledAt)
        let unrelated = try await first.claimNotification(claim("unrelated"), now: now)
        XCTAssertEqual(unrelated, .rejected(reason: "minimum_gap"))
        try await first.close()
        try await otherCaller.close()
    }

    func testOwnedPreInvocationWithdrawalReleasesChargeAfterProducerCancellation() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.claimNotification(claim(), now: now)
        let gate = try await store.markNotificationSubmitting(occurrenceID: "one", now: now)
        XCTAssertTrue(gate)
        let cancelledAt = now.addingTimeInterval(60)
        try await store.withdrawNotification(occurrenceID: "one", now: cancelledAt)
        let beforeProof = try await store.notificationRecords()
        XCTAssertEqual(beforeProof.first?.chargedAt, now)
        try await store.withdrawNotificationBeforeInvocation(occurrenceID: "one", now: now.addingTimeInterval(120), acquiredSubmitGate: true)
        let afterProof = try await store.notificationRecords()
        XCTAssertEqual(afterProof.first?.state, .withdrawn)
        XCTAssertEqual(afterProof.first?.attempts, 1)
        XCTAssertEqual(afterProof.first?.updatedAt, cancelledAt)
        XCTAssertNil(afterProof.first?.chargedAt)
        let replay = try await store.claimNotification(claim(), now: now)
        XCTAssertEqual(replay, .rejected(reason: "already_scheduled"))
        let unrelated = try await store.claimNotification(claim("unrelated"), now: now)
        guard case .claimed = unrelated else { return XCTFail("The submit-gate owner proved add was never invoked") }
    }

    func testPreInvocationWithdrawalDoesNotReleaseSubmittedOrUncertainCharge() async throws {
        for submissionIsUncertain in [false, true] {
            let store = try await WhoopStore.inMemory()
            _ = try await store.claimNotification(claim(), now: now)
            _ = try await store.markNotificationSubmitting(occurrenceID: "one", now: now)
            if submissionIsUncertain {
                try await store.reconcileNotifications(pending: [], delivered: [], now: now)
            } else {
                try await store.markNotificationSubmitted(occurrenceID: "one", now: now)
            }
            try await store.withdrawNotificationBeforeInvocation(occurrenceID: "one", now: now.addingTimeInterval(60), acquiredSubmitGate: true)
            let rows = try await store.notificationRecords()
            XCTAssertEqual(rows.first?.state, submissionIsUncertain ? .submissionUncertain : .submitted)
            XCTAssertEqual(rows.first?.chargedAt, now)
            XCTAssertEqual(rows.first?.updatedAt, now)
            let replay = try await store.claimNotification(claim(), now: now)
            let unrelated = try await store.claimNotification(claim("unrelated"), now: now)
            XCTAssertEqual(replay, .rejected(reason: "already_scheduled"))
            XCTAssertEqual(unrelated, .rejected(reason: "minimum_gap"))
        }
    }

}
