import Foundation
import Testing
@testable import NoopPhase34Core

private let outboxDay = try! CivilDay(key: "2026-08-03")

@Test func outboxIdentityIsPerProjectionGenerationAndDestination() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let widget = try ExternalPublicationOutboxItem(
        contextId: "ctx", deviceId: "device", snapshotGeneration: 12,
        analysisGeneration: 7, changedDays: [outboxDay], destination: .widget, createdAt: now
    )
    let watch = try ExternalPublicationOutboxItem(
        contextId: "ctx", deviceId: "device", snapshotGeneration: 12,
        analysisGeneration: 7, changedDays: [outboxDay], destination: .watch, createdAt: now
    )
    #expect(widget.idempotencyKey != watch.idempotencyKey)
}

@Test func latestStateIdentityUsesSnapshotGeneration() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let first = try ExternalPublicationOutboxItem(
        contextId: "ctx", deviceId: "device", snapshotGeneration: 12,
        analysisGeneration: 7, changedDays: [outboxDay], destination: .widget, createdAt: now
    )
    let replayFromAnotherAnalysis = try ExternalPublicationOutboxItem(
        contextId: "ctx", deviceId: "device", snapshotGeneration: 12,
        analysisGeneration: 8, changedDays: [outboxDay], destination: .widget, createdAt: now
    )
    #expect(first.idempotencyKey == replayFromAnotherAnalysis.idempotencyKey)
}

@Test func healthKitIdentityUsesAnalysisGenerationAndRetainsChangedDays() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let first = try ExternalPublicationOutboxItem(
        contextId: "ctx", deviceId: "device", snapshotGeneration: 12,
        analysisGeneration: 7, changedDays: [outboxDay], destination: .healthKit, createdAt: now
    )
    let second = try ExternalPublicationOutboxItem(
        contextId: "ctx", deviceId: "device", snapshotGeneration: 12,
        analysisGeneration: 8, changedDays: [outboxDay], destination: .healthKit, createdAt: now
    )
    #expect(first.idempotencyKey != second.idempotencyKey)
    #expect(first.changedDays == [outboxDay])
}

@Test func outboxRetriesDurably() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var item = try ExternalPublicationOutboxItem(
        contextId: "ctx", deviceId: "device", snapshotGeneration: 12,
        analysisGeneration: 7, changedDays: [outboxDay], destination: .healthKit, createdAt: now
    )
    try ExternalPublicationReducer.apply(
        .acquire(owner: "worker", expiresAt: now.addingTimeInterval(60)), to: &item, now: now
    )
    try ExternalPublicationReducer.apply(.begin(owner: "worker"), to: &item, now: now)
    try ExternalPublicationReducer.apply(
        .failed(owner: "worker", code: "temporarily_unavailable", retryable: true),
        to: &item,
        now: now
    )
    #expect(item.state == ExternalPublicationState.retryable)
    #expect(item.nextAttemptAt! > now)
}

@Test func pendingLatestStateItemCanBeSuperseded() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var item = try ExternalPublicationOutboxItem(
        contextId: "ctx", deviceId: "device", snapshotGeneration: 12,
        analysisGeneration: 7, changedDays: [outboxDay], destination: .widget, createdAt: now
    )
    try ExternalPublicationReducer.apply(.supersede, to: &item, now: now)
    #expect(item.state == .superseded)
    #expect(item.isTerminal)
}

@Test func healthKitCannotBeSuperseded() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var item = try ExternalPublicationOutboxItem(
        contextId: "ctx", deviceId: "device", snapshotGeneration: 12,
        analysisGeneration: 7, changedDays: [outboxDay], destination: .healthKit, createdAt: now
    )
    #expect(throws: ExternalPublicationError.invalidTransition) {
        try ExternalPublicationReducer.apply(.supersede, to: &item, now: now)
    }
}

@Test func inFlightExternalPublicationLeaseCanBeRenewed() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    var item = try ExternalPublicationOutboxItem(
        contextId: "ctx",
        deviceId: "device",
        snapshotGeneration: 4,
        analysisGeneration: 3,
        changedDays: [outboxDay],
        destination: .healthKit,
        createdAt: now
    )
    try ExternalPublicationReducer.apply(
        .acquire(owner: "worker", expiresAt: now.addingTimeInterval(30)),
        to: &item,
        now: now
    )
    try ExternalPublicationReducer.apply(.begin(owner: "worker"), to: &item, now: now)
    let renewedExpiry = now.addingTimeInterval(120)
    try ExternalPublicationReducer.apply(
        .renew(owner: "worker", expiresAt: renewedExpiry),
        to: &item,
        now: now.addingTimeInterval(10)
    )
    #expect(item.state == ExternalPublicationState.inFlight)
    #expect(item.lease?.expiresAt == renewedExpiry)
}
