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
    func testMigrationCoexistsWithReservedRecoveryMigrationAndPreservesData() throws {
        let db = try DatabaseQueue()
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v59-existing-fixture") { db in
            try db.execute(sql: "CREATE TABLE existingPayload(value TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO existingPayload VALUES ('keep')")
        }
        migrator.registerMigration("v60-recovery-fixture") { db in
            try db.execute(sql: "CREATE TABLE recoveryRepairFixture(revision INTEGER)")
        }
        try migrator.migrate(db)
        NotificationDecisionMigration.register(on: &migrator)
        try migrator.migrate(db)
        try migrator.migrate(db)
        try db.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM existingPayload"), "keep")
            let identifiers = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            XCTAssertTrue(identifiers.contains("v60-recovery-fixture"))
            XCTAssertEqual(identifiers.filter { $0 == "v61-notification-decisions" }.count, 1)
        }
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

    func testRecoveryMigrationCanBeInsertedBeforeAlreadyAppliedNotificationMigration() throws {
        let db = try DatabaseQueue()
        var initial = DatabaseMigrator()
        initial.registerMigration("v59-fixture") { db in try db.execute(sql: "CREATE TABLE fixture(value TEXT)") }
        NotificationDecisionMigration.register(on: &initial)
        try initial.migrate(db)
        var merged = DatabaseMigrator()
        merged.registerMigration("v59-fixture") { db in try db.execute(sql: "CREATE TABLE fixture(value TEXT)") }
        merged.registerMigration("v60-recovery-fixture") { db in try db.execute(sql: "INSERT INTO fixture VALUES ('repaired')") }
        NotificationDecisionMigration.register(on: &merged)
        try merged.migrate(db)
        try db.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT value FROM fixture"), "repaired")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations"), 3)
        }
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
    func testAcknowledgedActiveRecurringOwnershipSurvivesDailyRetention() async throws {
        let store = try await WhoopStore.inMemory()
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
        XCTAssertEqual(retained.first?.state, .acknowledged)
        XCTAssertEqual(retained.first?.updatedAt, now)
    }

}
