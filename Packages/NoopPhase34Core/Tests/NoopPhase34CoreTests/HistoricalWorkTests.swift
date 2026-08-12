import Foundation
import Testing
@testable import NoopPhase34Core

private func scope() throws -> HistoricalAnalysisScope {
    try HistoricalAnalysisScope(
        databaseInstanceId: "db",
        sourceId: "my-whoop",
        deviceId: "my-whoop",
        deviceLineageId: "strap-a",
        cursorEpoch: 1,
        trimScope: "historical"
    )
}

@Test func workFollowsVerifiedPublicationOrder() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day = try CivilDay(key: "2026-08-03")
    var work = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 4,
        lastReceiptGeneration: 5,
        affectedDays: [day],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    try HistoricalAnalysisWorkReducer.apply(.acquireLease(owner: "worker", expiresAt: now.addingTimeInterval(60)), to: &work, now: now)
    try HistoricalAnalysisWorkReducer.apply(.beginAnalysis(owner: "worker"), to: &work, now: now)
    try HistoricalAnalysisWorkReducer.apply(
        .analysisSucceeded(owner: "worker", throughReceiptGeneration: 5, analysisGeneration: 2, analyzedDays: [day]),
        to: &work,
        now: now
    )
    try HistoricalAnalysisWorkReducer.apply(
        .verificationSucceeded(owner: "worker", throughReceiptGeneration: 5, analysisGeneration: 2, snapshotGeneration: 1),
        to: &work,
        now: now
    )
    try HistoricalAnalysisWorkReducer.apply(.repositoryPublished(owner: "worker"), to: &work, now: now)
    try HistoricalAnalysisWorkReducer.apply(
        .outboxCommitted(owner: "worker", destinations: [.widget, .watch]),
        to: &work,
        now: now
    )
    #expect(work.state == .complete)
    #expect(work.lease == nil)
    #expect(work.pendingDestinations == [.widget, .watch])
}

@Test func retryClearsLeaseAndBacksOff() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var work = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 1,
        lastReceiptGeneration: 1,
        affectedDays: [],
        kind: .fullHistoryRepair(reason: "timestamp_heal"),
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    try HistoricalAnalysisWorkReducer.apply(.acquireLease(owner: "worker", expiresAt: now.addingTimeInterval(60)), to: &work, now: now)
    try HistoricalAnalysisWorkReducer.apply(.beginAnalysis(owner: "worker"), to: &work, now: now)
    try HistoricalAnalysisWorkReducer.apply(.failed(owner: "worker", code: "protected_data", retryable: true), to: &work, now: now)
    #expect(work.state == .retryable)
    #expect(work.lease == nil)
    #expect(work.nextAttemptAt! > now)
}

@Test func pendingWorkCoalescesExactDaysWithoutFillingGap() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var first = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 1,
        lastReceiptGeneration: 1,
        affectedDays: [CivilDay(key: "2026-01-01")],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    let second = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 2,
        lastReceiptGeneration: 2,
        affectedDays: [CivilDay(key: "2026-03-01")],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    try first.mergePending(second, now: now)
    #expect(first.affectedDays.count == 2)
    #expect(first.lastReceiptGeneration == 2)
}

@Test func pendingWorkDoesNotMergeAcrossRecordedTimeZones() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var first = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 1,
        lastReceiptGeneration: 1,
        affectedDays: [CivilDay(key: "2026-01-01")],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    let second = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 2,
        lastReceiptGeneration: 2,
        affectedDays: [CivilDay(key: "2026-01-01")],
        recordedTimeZoneIdentifier: "Europe/London",
        createdAt: now
    )
    #expect(throws: HistoricalWorkError.incompatibleMerge) {
        try first.mergePending(second, now: now)
    }
}

@Test func generationsAreValidatedOnlyInsideTheirOwnDomains() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day = try CivilDay(key: "2026-08-03")
    var work = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 100,
        lastReceiptGeneration: 101,
        affectedDays: [day],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    try HistoricalAnalysisWorkReducer.apply(
        .acquireLease(owner: "worker", expiresAt: now.addingTimeInterval(60)),
        to: &work, now: now
    )
    try HistoricalAnalysisWorkReducer.apply(.beginAnalysis(owner: "worker"), to: &work, now: now)
    // Analysis generation 3 is valid even though receipt generation is 101; they are unrelated counters.
    try HistoricalAnalysisWorkReducer.apply(
        .analysisSucceeded(
            owner: "worker", throughReceiptGeneration: 101, analysisGeneration: 3, analyzedDays: [day]
        ),
        to: &work, now: now
    )
    // Snapshot generation 1 is also valid and independently monotonic in its own table.
    try HistoricalAnalysisWorkReducer.apply(
        .verificationSucceeded(
            owner: "worker", throughReceiptGeneration: 101, analysisGeneration: 3, snapshotGeneration: 1
        ),
        to: &work, now: now
    )
    #expect(work.state == .snapshotCommitted)
    #expect(work.analyzedThroughReceiptGeneration == 101)
    #expect(work.analysisGeneration == 3)
    #expect(work.snapshotGeneration == 1)
}

@Test func analysisCannotClaimReceiptsBeyondItsImmutableWorkEdge() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day = try CivilDay(key: "2026-08-03")
    var work = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 10,
        lastReceiptGeneration: 11,
        affectedDays: [day],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    try HistoricalAnalysisWorkReducer.apply(
        .acquireLease(owner: "worker", expiresAt: now.addingTimeInterval(60)),
        to: &work, now: now
    )
    try HistoricalAnalysisWorkReducer.apply(.beginAnalysis(owner: "worker"), to: &work, now: now)
    #expect(throws: HistoricalWorkError.invalidTransition) {
        try HistoricalAnalysisWorkReducer.apply(
            .analysisSucceeded(
                owner: "worker",
                throughReceiptGeneration: 12,
                analysisGeneration: 1,
                analyzedDays: [day]
            ),
            to: &work,
            now: now
        )
    }
}

@Test func activeWorkLeaseCanBeRenewedWithoutChangingPipelineState() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day = try CivilDay(key: "2026-08-03")
    var work = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 1,
        lastReceiptGeneration: 1,
        affectedDays: [day],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    try HistoricalAnalysisWorkReducer.apply(
        .acquireLease(owner: "worker", expiresAt: now.addingTimeInterval(30)),
        to: &work,
        now: now
    )
    try HistoricalAnalysisWorkReducer.apply(.beginAnalysis(owner: "worker"), to: &work, now: now)
    let renewedExpiry = now.addingTimeInterval(120)
    try HistoricalAnalysisWorkReducer.apply(
        .renewLease(owner: "worker", expiresAt: renewedExpiry),
        to: &work,
        now: now.addingTimeInterval(10)
    )
    #expect(work.state == .analyzing)
    #expect(work.lease?.expiresAt == renewedExpiry)
}

@Test func exactWorkRejectsMoreThanMaximumDayCount() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let calendar = try HealthCalendar(timeZoneIdentifier: "America/New_York")
    let first = try CivilDay(key: "2025-01-01")
    let days = Set(try (0...HistoricalAnalysisWork.maximumExactDayCount).map {
        try calendar.adding(days: $0, to: first)
    })
    #expect(throws: HistoricalWorkError.invalidRange) {
        _ = try HistoricalAnalysisWork(
            scope: scope(),
            firstReceiptGeneration: 1,
            lastReceiptGeneration: 1,
            affectedDays: days,
            recordedTimeZoneIdentifier: "America/New_York",
            createdAt: now
        )
    }
}

@Test func pendingWorkRefusesMergeThatWouldExceedMaximumDayCount() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let calendar = try HealthCalendar(timeZoneIdentifier: "America/New_York")
    let firstDay = try CivilDay(key: "2025-01-01")
    let firstDays = Set(try (0..<HistoricalAnalysisWork.maximumExactDayCount).map {
        try calendar.adding(days: $0, to: firstDay)
    })
    var first = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 1,
        lastReceiptGeneration: 64,
        affectedDays: firstDays,
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    let overflowDay = try calendar.adding(days: HistoricalAnalysisWork.maximumExactDayCount, to: firstDay)
    let second = try HistoricalAnalysisWork(
        scope: scope(),
        firstReceiptGeneration: 65,
        lastReceiptGeneration: 65,
        affectedDays: [overflowDay],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    #expect(throws: HistoricalWorkError.incompatibleMerge) {
        try first.mergePending(second, now: now)
    }
}
