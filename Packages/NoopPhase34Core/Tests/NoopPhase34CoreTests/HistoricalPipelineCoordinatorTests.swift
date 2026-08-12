import Foundation
import Testing
@testable import NoopPhase34Core

private actor MemoryWorkStore {
    var work: HistoricalAnalysisWork?

    init(work: HistoricalAnalysisWork) { self.work = work }

    func lease(owner: String, now: Date, duration: TimeInterval) throws -> HistoricalAnalysisWork? {
        guard var work, work.canAttempt(at: now) else { return nil }
        try HistoricalAnalysisWorkReducer.apply(
            .acquireLease(owner: owner, expiresAt: now.addingTimeInterval(duration)),
            to: &work,
            now: now
        )
        self.work = work
        return work
    }

    func apply(id: UUID, event: HistoricalWorkEvent, now: Date) throws -> HistoricalAnalysisWork {
        guard var work, work.id == id else { throw HistoricalWorkError.invalidTransition }
        try HistoricalAnalysisWorkReducer.apply(event, to: &work, now: now)
        self.work = work
        return work
    }

    func current() -> HistoricalAnalysisWork? { work }
}

@Test func coordinatorPersistsFullVerifiedOrder() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day = try CivilDay(key: "2026-08-03")
    let scope = try HistoricalAnalysisScope(
        databaseInstanceId: "db",
        sourceId: "my-whoop",
        deviceId: "my-whoop",
        deviceLineageId: "strap-a",
        cursorEpoch: 1,
        trimScope: "history"
    )
    let initial = try HistoricalAnalysisWork(
        scope: scope,
        firstReceiptGeneration: 1,
        lastReceiptGeneration: 1,
        affectedDays: [day],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    )
    let store = MemoryWorkStore(work: initial)
    let dependencies = HistoricalPipelineDependencies(
        leaseNext: { owner, current, duration in try await store.lease(owner: owner, now: current, duration: duration) },
        applyEvent: { id, event, current in try await store.apply(id: id, event: event, now: current) },
        analyze: { work in
            try AnalysisMutationReceipt(
                throughReceiptGeneration: work.lastReceiptGeneration,
                analysisGeneration: 7,
                analyzedDays: work.affectedDays,
                rawFrontierTs: 1_700_000_000,
                algorithmBundleVersion: "bundle-v1"
            )
        },
        verifyAndCommitSnapshot: { _, analysis in
            let projection = try VerifiedHealthProjection(
                contextId: "ctx",
                deviceId: "device",
                generation: 2,
                logicalDay: day,
                metrics: [:]
            )
            return try SnapshotCommitReceipt(
                throughReceiptGeneration: analysis.throughReceiptGeneration,
                analysisGeneration: analysis.analysisGeneration,
                snapshotGeneration: projection.generation,
                analyzedDays: analysis.analyzedDays,
                projection: projection
            )
        },
        publishRepository: { _, _ in },
        commitOutbox: { _ in [] },
        classifyError: { _ in PipelineFailureClassification(code: "unexpected", retryable: true) },
        now: { now }
    )
    let coordinator = HistoricalPipelineCoordinator(dependencies: dependencies)
    let result = await coordinator.signal()
    #expect(result.completedWorkCount == 1)
    #expect(await store.current()?.state == .complete)
}

private actor QueueWorkStore {
    var workById: [UUID: HistoricalAnalysisWork]

    init(_ work: [HistoricalAnalysisWork]) {
        workById = Dictionary(uniqueKeysWithValues: work.map { ($0.id, $0) })
    }

    func lease(owner: String, now: Date, duration: TimeInterval) throws -> HistoricalAnalysisWork? {
        guard var next = workById.values
            .filter({ $0.canAttempt(at: now) })
            .sorted(by: { $0.firstReceiptGeneration < $1.firstReceiptGeneration })
            .first else { return nil }
        try HistoricalAnalysisWorkReducer.apply(
            .acquireLease(owner: owner, expiresAt: now.addingTimeInterval(duration)),
            to: &next,
            now: now
        )
        workById[next.id] = next
        return next
    }

    func apply(id: UUID, event: HistoricalWorkEvent, now: Date) throws -> HistoricalAnalysisWork {
        guard var work = workById[id] else { throw HistoricalWorkError.invalidTransition }
        try HistoricalAnalysisWorkReducer.apply(event, to: &work, now: now)
        workById[id] = work
        return work
    }

    func completedCount() -> Int { workById.values.filter { $0.state == .complete }.count }
}

@Test func coordinatorBatchLimitDoesNotLeaveReadyWorkIdle() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day = try CivilDay(key: "2026-08-03")
    let scope = try HistoricalAnalysisScope(
        databaseInstanceId: "db", sourceId: "my-whoop", deviceId: "my-whoop",
        deviceLineageId: "strap-a", cursorEpoch: 1, trimScope: "history"
    )
    let work = try (1...3).map { generation in
        try HistoricalAnalysisWork(
            scope: scope,
            firstReceiptGeneration: Int64(generation),
            lastReceiptGeneration: Int64(generation),
            affectedDays: [day],
            recordedTimeZoneIdentifier: "America/New_York",
            createdAt: now.addingTimeInterval(TimeInterval(generation))
        )
    }
    let store = QueueWorkStore(work)
    let dependencies = HistoricalPipelineDependencies(
        leaseNext: { owner, current, duration in
            try await store.lease(owner: owner, now: current, duration: duration)
        },
        applyEvent: { id, event, current in try await store.apply(id: id, event: event, now: current) },
        analyze: { work in
            try AnalysisMutationReceipt(
                throughReceiptGeneration: work.lastReceiptGeneration,
                analysisGeneration: work.lastReceiptGeneration + 10,
                analyzedDays: work.affectedDays,
                rawFrontierTs: nil,
                algorithmBundleVersion: "bundle-v1"
            )
        },
        verifyAndCommitSnapshot: { _, analysis in
            let projection = try VerifiedHealthProjection(
                contextId: "ctx",
                deviceId: "device",
                generation: analysis.throughReceiptGeneration,
                logicalDay: day,
                metrics: [:]
            )
            return try SnapshotCommitReceipt(
                throughReceiptGeneration: analysis.throughReceiptGeneration,
                analysisGeneration: analysis.analysisGeneration,
                snapshotGeneration: projection.generation,
                analyzedDays: analysis.analyzedDays,
                projection: projection
            )
        },
        publishRepository: { _, _ in },
        commitOutbox: { _ in [] },
        classifyError: { _ in PipelineFailureClassification(code: "unexpected", retryable: true) },
        now: { now }
    )
    let coordinator = HistoricalPipelineCoordinator(
        dependencies: dependencies,
        maximumItemsPerDrain: 1
    )
    let result = await coordinator.signal()
    #expect(result.completedWorkCount == 3)
    #expect(await store.completedCount() == 3)
}
