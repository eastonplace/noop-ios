import Foundation
import Testing
@testable import NoopPhase34Core

@Test func losslessDrainGateObservesFinalEdgeSignal() async {
    let counter = HardeningCounter()
    let gate = LosslessDrainSignalGate<Int> {
        await counter.increment()
        await Task.yield()
        return await counter.value()
    }

    let first = Task { await gate.signal() }
    await Task.yield()
    let second = Task { await gate.signal() }
    _ = await first.value
    _ = await second.value

    #expect(await counter.value() == 2)
}

@Test func cancelledAnalysisLeaseReturnsWithoutAttemptIncrement() throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day = try CivilDay(key: "2026-08-03")
    let scope = try HistoricalAnalysisScope(
        databaseInstanceId: "db",
        sourceId: "source",
        deviceId: "device",
        deviceLineageId: "lineage-a",
        cursorEpoch: 3,
        trimScope: "history"
    )
    var work = try HistoricalAnalysisWork(
        scope: scope,
        firstReceiptGeneration: 1,
        lastReceiptGeneration: 1,
        affectedDays: [day],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    try HistoricalAnalysisWorkReducer.apply(
        .acquireLease(owner: "owner", expiresAt: now.addingTimeInterval(60)),
        to: &work,
        now: now
    )
    try HistoricalAnalysisWorkReducer.apply(
        .cancelOwnedLease(owner: "owner"),
        to: &work,
        now: now
    )

    #expect(work.lease == nil)
    #expect(work.attemptCount == 0)
    #expect(work.state == .pending)
    #expect(work.lastErrorCode == "owner_cancelled")
}

@Test func selectivePublicationKeepsHealthKitForHistoricalOnlyChange() throws {
    let day = try CivilDay(key: "2026-08-03")
    let projection = try VerifiedHealthProjection(
        contextId: "ctx",
        deviceId: "device",
        generation: 7,
        logicalDay: day,
        metrics: [:]
    )
    let core = try VerifiedWidgetCorePayload(
        contextId: "ctx",
        projectionGeneration: 7,
        logicalDay: day,
        restingHR: 52,
        sleepMinutes: 420,
        steps: 1000,
        calories: 2000,
        recoveryDelta: nil
    )
    let bundle = try VerifiedExternalProjectionBundle(projection: projection, widgetCore: core)
    let receipt = try SnapshotCommitReceipt(
        throughReceiptGeneration: 9,
        analysisGeneration: 11,
        snapshotGeneration: 7,
        analyzedDays: [day],
        projection: projection
    )
    let previous = LatestStateDeliveryCheckpoint(
        contextId: "ctx",
        presentationIdentity: projection.presentationIdentity,
        widgetCore: core,
        logicalDay: day,
        deliveredAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let destinations = SelectiveExternalPublicationPlan.destinations(
        snapshot: receipt,
        bundle: bundle,
        previousLatestState: previous,
        now: Date(timeIntervalSince1970: 1_700_000_010)
    )
    #expect(destinations == [.healthKit])
}

private actor HardeningCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}
