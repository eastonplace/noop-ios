import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

@MainActor
final class NotificationCoordinatorTests: XCTestCase {
    final class Center: NotificationCenterClient {
        var permission = true
        var requests: [String: NotificationDeliveryRequest] = [:]
        var additions = 0
        var failure: Error?
        var acceptsBeforeFailure = false
        var duringAdd: (() -> Void)?
        var duringPendingRead: (() -> Void)?
        var details: Set<String> = []
        var authorizationReads = 0
        var duringAuthorization: ((Int) -> Void)?
        func isAuthorized() async -> Bool {
            authorizationReads += 1
            duringAuthorization?(authorizationReads)
            return permission
        }
        func pendingIdentifiers() async -> Set<String> {
            duringPendingRead?()
            return Set(requests.keys)
        }
        func deliveredIdentifiers() async -> Set<String> { [] }
        func add(_ request: NotificationDeliveryRequest) async throws {
            additions += 1
            if let failure, !acceptsBeforeFailure { throw failure }
            requests[request.identifier] = request
            duringAdd?()
            if let failure { throw failure }
        }
        func identifiersContainingDetails() async -> Set<String> { details }
        func removeDelivered(_ identifiers: [String]) {}
        func remove(_ identifiers: [String], delivered: Bool) { identifiers.forEach { requests[$0] = nil } }
    }
    let now = Date(timeIntervalSince1970: 1_800_360_000)
    func candidate() -> NotificationCandidate {
        .init(ruleID: "workoutSummary", group: .workoutSummary, subjectID: "workout", occurrenceID: "workout:1", attentionKey: "workout:1", evidenceRevision: "v2", sourceContext: "device", logicalDay: "2027-01-19", observedAt: now, generatedAt: now, expiresAt: now.addingTimeInterval(3600), destination: .workout(id: "workout"), genericTitle: "Workout ready", genericBody: "Review your result.", detailBody: "Private health values")
    }
    func coordinator(store: WhoopStore, center: Center, preferences: @escaping () -> NotificationPreferencesSnapshot = { .init(modes: [.workoutSummary: .notify], quietHoursEnabled: false) }) -> NotificationCoordinator {
        NotificationCoordinator(center: center, clock: { self.now }, preferences: preferences, context: { .init(sourceContext: "device", logicalDay: "2027-01-19", sleeping: false) }, store: { store }, dryRun: { false })
    }
    func testProductionContextDoesNotInventAwakeEvidence() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let liveContext = NotificationCoordinator.productionContext(sourceContext: "device", logicalDay: "2027-01-19", activeWorkout: false)
        XCTAssertNil(liveContext.sleeping)
        let runtime = NotificationCoordinator(center: center, clock: { self.now },
            preferences: { .init(modes: [.workoutSummary: .notify], quietHoursEnabled: false) },
            context: { liveContext }, store: { store }, dryRun: { false })
        await runtime.process(candidates: [candidate()])
        XCTAssertEqual(runtime.lastEvaluation?.decisions.first?.reason, .sleepStateUnavailable)
        XCTAssertEqual(center.additions, 0)
        let rows = try await store.notificationRecords()
        XCTAssertTrue(rows.isEmpty, "Unknown sleep must not consume the coaching occurrence")
    }

    func testAcceptedSubmissionIsPrivateAndDurableAcrossRestart() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        await coordinator(store: store, center: center).process(candidates: [candidate()])
        XCTAssertEqual(center.additions, 1)
        XCTAssertEqual(center.requests.values.first?.body, "Review your result.")
        let submittedRows = try await store.notificationRecords()
        XCTAssertEqual(submittedRows.first?.state, .submitted)
        await coordinator(store: store, center: center).process(candidates: [candidate()])
        XCTAssertEqual(center.additions, 1)
    }
    func testPermissionDeniedDoesNotConsumeClaim() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center(); center.permission = false
        let runtime = coordinator(store: store, center: center)
        await runtime.process(candidates: [candidate()])
        let deniedRows = try await store.notificationRecords()
        XCTAssertTrue(deniedRows.isEmpty)
        center.permission = true
        await runtime.process(candidates: [candidate()])
        XCTAssertEqual(center.additions, 1)
    }
    func testSettingsChangeDuringAddWithdrawsAcceptedRequest() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        var enabled = true
        center.duringAdd = { enabled = false }
        let runtime = coordinator(store: store, center: center, preferences: {
            .init(modes: [.workoutSummary: enabled ? .notify : .off], quietHoursEnabled: false)
        })
        await runtime.process(candidates: [candidate()])
        XCTAssertTrue(center.requests.isEmpty)
        let withdrawnRows = try await store.notificationRecords()
        XCTAssertEqual(withdrawnRows.first?.state, .withdrawn)
    }
    func testKnownFailureHasOnlyOneRetry() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center(); center.failure = NotificationSubmissionError.knownFailure
        let runtime = coordinator(store: store, center: center)
        await runtime.process(candidates: [candidate()])
        await runtime.process(candidates: [candidate()])
        XCTAssertEqual(center.additions, 2)
    }
    func testUnknownOutcomeIsNeverBlindlyRetried() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center(); center.failure = NotificationSubmissionError.uncertain
        let runtime = coordinator(store: store, center: center)
        await runtime.process(candidates: [candidate()])
        await runtime.process(candidates: [candidate()])
        XCTAssertEqual(center.additions, 1)
        let uncertainRows = try await store.notificationRecords()
        XCTAssertEqual(uncertainRows.first?.state, .submissionUncertain)
    }
    func testAcceptedThenUncertainAddRevalidatesSourcePreferencesAndPrivacyWithoutRetry() async throws {
        for change in ["source", "preferences", "privacy", "permission"] {
            let store = try await WhoopStore.inMemory()
            let center = Center()
            center.failure = NotificationSubmissionError.uncertain
            center.acceptsBeforeFailure = true
            var source = "device"
            var enabled = true
            var details = true
            center.duringAdd = {
                switch change {
                case "source": source = "replacement"
                case "preferences": enabled = false
                case "privacy": details = false
                default: center.permission = false
                }
            }
            let runtime = NotificationCoordinator(center: center, clock: { self.now },
                preferences: { .init(modes: [.workoutSummary: enabled ? .notify : .off],
                    quietHoursEnabled: false, showHealthDetails: details) },
                context: { .init(sourceContext: source, logicalDay: "2027-01-19", sleeping: false) },
                store: { store }, dryRun: { false })
            await runtime.process(candidates: [candidate()])
            XCTAssertTrue(center.requests.isEmpty, change)
            let rows = try await store.notificationRecords()
            XCTAssertEqual(rows.first?.state, .withdrawn, change)
            XCTAssertNotNil(rows.first?.chargedAt, change)
            XCTAssertEqual(rows.first?.attempts, 1, change)
            center.failure = nil
            center.duringAdd = nil
            source = "device"; enabled = true; details = true; center.permission = true
            await runtime.process(candidates: [candidate()])
            XCTAssertEqual(center.additions, 1, "An uncertain outcome cannot regain a retry: \(change)")
        }
    }
    func testKnownCancellationAfterSubmittingMarkerReleasesUnusedBudgetWithoutReplayingIdentity() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        center.duringAuthorization = { count in if count == 3 { center.permission = false } }
        let runtime = coordinator(store: store, center: center)
        await runtime.process(candidates: [candidate()])
        XCTAssertEqual(center.additions, 0)
        let cancelled = try await store.notificationRecords()
        XCTAssertEqual(cancelled.first?.state, .withdrawn)
        XCTAssertNil(cancelled.first?.chargedAt)
        XCTAssertEqual(cancelled.first?.attempts, 1)
        center.permission = true
        center.duringAuthorization = nil
        await runtime.process(candidates: [candidate()])
        XCTAssertEqual(center.additions, 0, "Unused budget does not erase the cancelled occurrence identity")
        let other = NotificationCandidate(ruleID: "workoutSummary", group: .workoutSummary, subjectID: "other",
            occurrenceID: "other", attentionKey: "other", evidenceRevision: "v2", sourceContext: "device",
            logicalDay: "2027-01-19", observedAt: now, generatedAt: now, expiresAt: now.addingTimeInterval(3600),
            destination: .workout(id: "other"), genericTitle: "Ready", genericBody: "Review")
        await runtime.process(candidates: [other])
        XCTAssertEqual(center.additions, 1, "A notice that never invoked add must not block an unrelated useful result")
    }
    func testDefaultPrivateReconciliationPreservesGenericPendingRequest() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let runtime = coordinator(store: store, center: center)
        await runtime.process(candidates: [candidate()])
        await runtime.reconcile()
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.additions, 1)
    }
    func testSourceChangeDuringAddWithdrawsOldSource() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        var source = "device"
        center.duringAdd = { source = "different-device" }
        let runtime = NotificationCoordinator(center: center, clock: { self.now },
            preferences: { .init(modes: [.workoutSummary: .notify], quietHoursEnabled: false) },
            context: { .init(sourceContext: source, logicalDay: "2027-01-19", sleeping: false) }, store: { store }, dryRun: { false })
        await runtime.process(candidates: [candidate()])
        XCTAssertTrue(center.requests.isEmpty)
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.first?.state, .withdrawn)
    }
    func testReplacementDatabaseRemovesOnlyOwnedOrphans() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let orphan = NotificationCoordinator.requestIdentifier("old-database")
        center.requests[orphan] = .init(identifier: orphan, title: "Old", body: "Old", candidate: candidate())
        center.requests["smart-alarm-backup"] = .init(identifier: "smart-alarm-backup", title: "Alarm", body: "Alarm", candidate: candidate())
        await coordinator(store: store, center: center).reconcile()
        XCTAssertNil(center.requests[orphan])
        XCTAssertNotNil(center.requests["smart-alarm-backup"])
    }
    func testSourceChangeDuringReconciliationPreservesNewSourceRequest() async throws {
        let oldStore = try await WhoopStore.inMemory()
        let newStore = try await WhoopStore.inMemory()
        let center = Center()
        var source = "database-a:device"
        let reminder = NotificationSchedulePlanner.candidate(group: .journalCheckIn, id: "day",
            scheduledAt: now.addingTimeInterval(3600), source: "database-b:device",
            destination: .journal(logicalDay: "2027-01-19"), now: now)
        let identifier = NotificationCoordinator.requestIdentifier(reminder.occurrenceID)
        _ = try await newStore.claimNotification(.init(occurrenceID: reminder.occurrenceID,
            attentionKey: reminder.attentionKey, ruleID: reminder.ruleID, sourceContext: reminder.sourceContext,
            evidenceRevision: reminder.evidenceRevision, logicalDay: reminder.logicalDay,
            requestIdentifier: identifier, isProactive: false, expiresAt: reminder.expiresAt), now: now)
        _ = try await newStore.markNotificationSubmitting(occurrenceID: reminder.occurrenceID, now: now)
        try await newStore.markNotificationSubmitted(occurrenceID: reminder.occurrenceID, now: now)
        let runtime = NotificationCoordinator(center: center, clock: { self.now },
            preferences: { .init(modes: [.journalCheckIn: .notify]) },
            context: { .init(sourceContext: source, logicalDay: "2027-01-19", sleeping: false) },
            store: { source == "database-a:device" ? oldStore : newStore }, dryRun: { false })
        center.duringPendingRead = {
            source = "database-b:device"
            center.requests[identifier] = .init(identifier: identifier, title: reminder.genericTitle,
                body: reminder.genericBody, candidate: reminder)
        }
        await runtime.reconcile()
        XCTAssertNotNil(center.requests[identifier], "An old database pass must not remove a new source's request")
        let rows = try await newStore.notificationRecords()
        XCTAssertEqual(rows.first?.state, .submitted)
    }
    func testSourceChangeWhileOpeningReconciliationStoreAbandonsOldStore() async throws {
        let oldStore = try await WhoopStore.inMemory()
        let center = Center()
        var source = "database-a:device"
        let identifier = NotificationCoordinator.requestIdentifier("database-b:current")
        center.requests[identifier] = .init(identifier: identifier, title: "Current", body: "Current", candidate: candidate())
        let runtime = NotificationCoordinator(center: center, clock: { self.now },
            preferences: { .init(modes: [.workoutSummary: .notify]) },
            context: { .init(sourceContext: source, logicalDay: "2027-01-19", sleeping: false) },
            store: { source = "database-b:device"; return oldStore }, dryRun: { false })
        await runtime.reconcile()
        XCTAssertNotNil(center.requests[identifier])
    }
    func testReservedBeforeInvocationCanResumeOnce() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        let fact = candidate()
        _ = try await store.claimNotification(.init(occurrenceID: fact.occurrenceID, attentionKey: fact.attentionKey,
            ruleID: fact.ruleID, sourceContext: fact.sourceContext, evidenceRevision: fact.evidenceRevision,
            logicalDay: fact.logicalDay, requestIdentifier: NotificationCoordinator.requestIdentifier(fact.occurrenceID),
            isProactive: true, expiresAt: fact.expiresAt), now: now)
        await coordinator(store: store, center: center).process(candidates: [fact])
        XCTAssertEqual(center.additions, 1)
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.first?.state, .submitted)
    }
    func testPrivacyChangeWithdrawsDetailedContentButNotGenericRequests() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        var details = true
        let runtime = coordinator(store: store, center: center, preferences: {
            .init(modes: [.workoutSummary: .notify], quietHoursEnabled: false, showHealthDetails: details)
        })
        await runtime.process(candidates: [candidate()])
        let identifier = NotificationCoordinator.requestIdentifier(candidate().occurrenceID)
        center.details = [identifier]
        details = false
        await runtime.reconcile()
        XCTAssertTrue(center.requests.isEmpty)
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.first?.state, .withdrawn)
    }

    func testPermissionRaceRearmsChosenReminderWithNewScheduleRevision() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center()
        var revision = 0
        let runtime = NotificationCoordinator(center: center, clock: { self.now },
            preferences: { .init(modes: [.journalCheckIn: .notify]) },
            context: { .init(sourceContext: "device", logicalDay: "2027-01-19", sleeping: false) }, store: { store }, dryRun: { false },
            authorizationChange: { previous, current in if previous == false && current { revision += 1 } })
        func reminder() -> NotificationCandidate {
            NotificationSchedulePlanner.candidate(group: .journalCheckIn, id: "day", scheduledAt: now.addingTimeInterval(3600),
                source: "device", destination: .journal(logicalDay: "2027-01-19"), now: now, revision: revision)
        }
        center.duringAdd = { center.permission = false; center.duringAdd = nil }
        await runtime.process(candidates: [reminder()])
        XCTAssertTrue(center.requests.isEmpty)
        center.permission = true
        // Authorization transition invalidates the old saved schedule revision; the observer rebuilds it.
        await runtime.process(candidates: [reminder()])
        XCTAssertEqual(revision, 1)
        await runtime.process(candidates: [reminder()])
        XCTAssertEqual(center.additions, 2)
        XCTAssertEqual(center.requests.count, 1)
        let rows = try await store.notificationRecords()
        XCTAssertEqual(rows.filter { $0.state == .submitted }.count, 1)
    }
    func testInAppCandidateRemainsAvailableWithoutSystemPermission() async throws {
        let store = try await WhoopStore.inMemory()
        let center = Center(); center.permission = false
        let runtime = coordinator(store: store, center: center, preferences: { .init(modes: [.workoutSummary: .inApp]) })
        await runtime.process(candidates: [candidate()])
        XCTAssertEqual(runtime.inAppCandidates.map(\.occurrenceID), [candidate().occurrenceID])
        XCTAssertEqual(center.additions, 0)
        runtime.dismissInApp(occurrenceID: candidate().occurrenceID)
        XCTAssertTrue(runtime.inAppCandidates.isEmpty)
    }

}
