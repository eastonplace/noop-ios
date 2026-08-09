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
    let fixture = try selectivePublicationFixture()
    let previous = destinationCheckpoints(fixture: fixture)

    let destinations = SelectiveExternalPublicationPlan.destinations(
        snapshot: fixture.receipt,
        bundle: fixture.bundle,
        previousLatestState: previous,
        now: Date(timeIntervalSince1970: 1_700_000_010)
    )
    #expect(destinations == [.healthKit])
}

@Test func widgetSuccessDoesNotAcknowledgeFailedLiveActivity() throws {
    let fixture = try selectivePublicationFixture()
    let all = destinationCheckpoints(fixture: fixture)
    let destinations = SelectiveExternalPublicationPlan.destinations(
        snapshot: fixture.receipt,
        bundle: fixture.bundle,
        previousLatestState: [.widget: all[.widget]!],
        now: Date(timeIntervalSince1970: 1_700_000_010)
    )
    #expect(destinations == [.healthKit, .liveActivity])
}

@Test func liveActivitySuccessDoesNotAcknowledgeFailedWidget() throws {
    let fixture = try selectivePublicationFixture()
    let all = destinationCheckpoints(fixture: fixture)
    let destinations = SelectiveExternalPublicationPlan.destinations(
        snapshot: fixture.receipt,
        bundle: fixture.bundle,
        previousLatestState: [.liveActivity: all[.liveActivity]!],
        now: Date(timeIntervalSince1970: 1_700_000_010)
    )
    #expect(destinations == [.healthKit, .widget])
}

@Test func widgetOnlyIdentityChangeLeavesLiveActivityUnchanged() throws {
    let fixture = try selectivePublicationFixture(recoveryDelta: 2)
    let previousFixture = try selectivePublicationFixture(recoveryDelta: 1)
    let previous = destinationCheckpoints(fixture: previousFixture)
    let destinations = SelectiveExternalPublicationPlan.destinations(
        snapshot: fixture.receipt,
        bundle: fixture.bundle,
        previousLatestState: previous,
        now: Date(timeIntervalSince1970: 1_700_000_010)
    )
    #expect(destinations == [.healthKit, .widget])
}

@Test func sleepOnlyProjectionChangeDoesNotEnqueueLiveActivity() throws {
    let fixture = try selectivePublicationFixture(sleepScore: 81)
    let previousFixture = try selectivePublicationFixture(sleepScore: 80)
    let destinations = SelectiveExternalPublicationPlan.destinations(
        snapshot: fixture.receipt,
        bundle: fixture.bundle,
        previousLatestState: destinationCheckpoints(fixture: previousFixture),
        now: Date(timeIntervalSince1970: 1_700_000_010)
    )
    #expect(destinations == [.healthKit, .widget])
}

@Test func recoveryOrStrainProjectionChangeEnqueuesLiveActivity() throws {
    let previous = try selectivePublicationFixture(recovery: 70, strain: 40)
    for fixture in [
        try selectivePublicationFixture(recovery: 71, strain: 40),
        try selectivePublicationFixture(recovery: 70, strain: 41),
    ] {
        let destinations = SelectiveExternalPublicationPlan.destinations(
            snapshot: fixture.receipt,
            bundle: fixture.bundle,
            previousLatestState: destinationCheckpoints(fixture: previous),
            now: Date(timeIntervalSince1970: 1_700_000_010)
        )
        #expect(destinations == [.healthKit, .widget, .liveActivity])
    }
}

private actor HardeningCounter {
    private var count = 0

    func increment() { count += 1 }
    func value() -> Int { count }
}

private struct SelectivePublicationFixture {
    let day: CivilDay
    let projection: VerifiedHealthProjection
    let core: VerifiedWidgetCorePayload
    let bundle: VerifiedExternalProjectionBundle
    let receipt: SnapshotCommitReceipt
}

private func selectivePublicationFixture(
    recoveryDelta: Int? = nil,
    recovery: Double? = nil,
    strain: Double? = nil,
    sleepScore: Double? = nil
) throws -> SelectivePublicationFixture {
    let day = try CivilDay(key: "2026-08-03")
    var metrics: [HealthMetricKind: VerifiedHealthMetric] = [:]
    for (kind, value) in [
        (HealthMetricKind.recovery, recovery),
        (.strain, strain),
        (.sleepScore, sleepScore),
    ] {
        if let value {
            metrics[kind] = try VerifiedHealthMetric(
                kind: kind,
                value: value,
                metricDay: day,
                sourceId: "device-noop",
                algorithmVersion: "v50-test",
                generation: 7,
                freshness: .fresh
            )
        }
    }
    let projection = try VerifiedHealthProjection(
        contextId: "ctx",
        deviceId: "device",
        generation: 7,
        logicalDay: day,
        metrics: metrics
    )
    let core = try VerifiedWidgetCorePayload(
        contextId: "ctx",
        projectionGeneration: 7,
        logicalDay: day,
        restingHR: 52,
        sleepMinutes: 420,
        steps: 1000,
        calories: 2000,
        recoveryDelta: recoveryDelta
    )
    let bundle = try VerifiedExternalProjectionBundle(
        projection: projection,
        widgetCore: core
    )
    let receipt = try SnapshotCommitReceipt(
        throughReceiptGeneration: 9,
        analysisGeneration: 11,
        snapshotGeneration: 7,
        analyzedDays: [day],
        projection: projection
    )
    return SelectivePublicationFixture(
        day: day,
        projection: projection,
        core: core,
        bundle: bundle,
        receipt: receipt
    )
}

private func destinationCheckpoints(
    fixture: SelectivePublicationFixture
) -> [DownstreamDestination: LatestStateDeliveryCheckpoint] {
    let deliveredAt = Date(timeIntervalSince1970: 1_700_000_000)
    return [
        .widget: LatestStateDeliveryCheckpoint(
            contextId: fixture.projection.contextId,
            identity: LatestStateDeliveryIdentity.make(
                destination: .widget,
                projection: fixture.projection,
                widgetCore: fixture.core
            )!,
            logicalDay: fixture.day,
            deliveredAt: deliveredAt
        ),
        .liveActivity: LatestStateDeliveryCheckpoint(
            contextId: fixture.projection.contextId,
            identity: LatestStateDeliveryIdentity.make(
                destination: .liveActivity,
                projection: fixture.projection,
                widgetCore: fixture.core
            )!,
            logicalDay: fixture.day,
            deliveredAt: deliveredAt
        ),
    ]
}
