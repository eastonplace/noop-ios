import Foundation
import Testing
@testable import NoopPhase34Core

private func blockedTestDay(_ key: String = "2026-08-04") throws -> CivilDay {
    try CivilDay(key: key)
}

private func blockedTestScope() throws -> HistoricalAnalysisScope {
    try HistoricalAnalysisScope(
        databaseInstanceId: "db",
        sourceId: "my-whoop",
        deviceId: "my-whoop",
        deviceLineageId: "lineage",
        cursorEpoch: 0,
        trimScope: "historical"
    )
}

@Test func blockedHistoricalWorkDoesNotConsumeRetryBudget() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var work = try HistoricalAnalysisWork(
        scope: blockedTestScope(),
        firstReceiptGeneration: 1,
        lastReceiptGeneration: 1,
        affectedDays: [blockedTestDay()],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    _ = try HistoricalAnalysisWorkReducer.apply(
        .acquireLease(owner: "owner", expiresAt: now.addingTimeInterval(60)),
        to: &work,
        now: now
    )
    _ = try HistoricalAnalysisWorkReducer.apply(
        .beginCurrentPhase(owner: "owner"),
        to: &work,
        now: now
    )
    _ = try HistoricalAnalysisWorkReducer.apply(
        .blocked(owner: "owner", code: "protected_data_unavailable"),
        to: &work,
        now: now
    )
    #expect(work.state == .blocked)
    #expect(work.resumePhase == .analysis)
    #expect(work.attemptCount == 0)
    #expect(!work.canAttempt(at: now.addingTimeInterval(86_400)))

    _ = try HistoricalAnalysisWorkReducer.apply(.resumeBlocked, to: &work, now: now.addingTimeInterval(1))
    #expect(work.state == .retryable)
    #expect(work.canAttempt(at: now.addingTimeInterval(1)))
}

@Test func blockedExternalPublicationWaitsForExplicitRearm() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    var item = try ExternalPublicationOutboxItem(
        contextId: "context",
        deviceId: "my-whoop",
        snapshotGeneration: 3,
        analysisGeneration: 2,
        changedDays: [blockedTestDay()],
        recordedTimeZoneIdentifier: "America/New_York",
        destination: .healthKit,
        createdAt: now
    )
    _ = try ExternalPublicationReducer.apply(
        .acquire(owner: "owner", expiresAt: now.addingTimeInterval(60)),
        to: &item,
        now: now
    )
    _ = try ExternalPublicationReducer.apply(.begin(owner: "owner"), to: &item, now: now)
    _ = try ExternalPublicationReducer.apply(
        .blocked(owner: "owner", code: "healthkit_authorization_required"),
        to: &item,
        now: now
    )
    #expect(item.state == .blocked)
    #expect(item.attemptCount == 0)
    #expect(!item.canAttempt(at: now.addingTimeInterval(86_400)))

    _ = try ExternalPublicationReducer.apply(.resumeBlocked, to: &item, now: now.addingTimeInterval(1))
    #expect(item.state == .retryable)
    #expect(item.canAttempt(at: now.addingTimeInterval(1)))
}
