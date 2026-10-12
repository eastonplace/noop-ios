import Foundation
import Testing
@testable import NoopPhase34Core

private final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) { lock.withLock { values.append(value) } }
    var snapshot: [String] { lock.withLock { values } }
}

private func waitUntil(
    _ description: String,
    timeout: Duration = .seconds(5),
    _ predicate: @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await predicate() { return }
        try? await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("Timed out waiting for \(description)")
}

@Test func waiterQueueHandsOffInFifoOrder() async throws {
    let queue = CancellableWaiterQueue<Int>()
    let log = LockedLog()
    var tasks: [Task<Void, any Error>] = []
    for value in 1...3 {
        tasks.append(Task {
            try await queue.wait(value)
            log.append("resumed-\(value)")
        })
        await waitUntil("waiter \(value) to enqueue") { queue.count == value }
    }

    #expect(queue.resumeNext() == 1)
    try await tasks[0].value
    #expect(queue.resumeNext() == 2)
    try await tasks[1].value
    #expect(queue.resumeNext() == 3)
    try await tasks[2].value
    #expect(queue.resumeNext() == nil)
    #expect(log.snapshot == ["resumed-1", "resumed-2", "resumed-3"])
}

@Test func cancelBeforeHandOffRemovesTheWaiterAndThrows() async {
    let queue = CancellableWaiterQueue<String>()
    let waiter = Task { try await queue.wait("cancelled") }
    await waitUntil("waiter to enqueue") { queue.count == 1 }

    waiter.cancel()
    let result = await waiter.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(queue.isEmpty)
    #expect(queue.resumeNext() == nil, "a cancelled waiter can never receive a later hand-off")
}

@Test func cancelledWaiterDoesNotBlockTheNextInLine() async throws {
    let queue = CancellableWaiterQueue<String>()
    let first = Task { try await queue.wait("first") }
    await waitUntil("first waiter to enqueue") { queue.count == 1 }
    let second = Task { try await queue.wait("second") }
    await waitUntil("second waiter to enqueue") { queue.count == 2 }

    first.cancel()
    _ = await first.result
    #expect(queue.resumeNext() == "second")
    try await second.value
}

@Test func alreadyCancelledTaskNeverEnqueues() async {
    let queue = CancellableWaiterQueue<Int>()
    let waiter = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try await queue.wait(1)
    }
    let result = await waiter.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(queue.isEmpty)
}

@Test func cancelAfterHandOffReturnsOwnershipToTheCaller() async throws {
    // The hand-off already happened, so `wait` returns normally. The caller sees the cancel afterwards
    // and must release what it was given at once.
    let queue = CancellableWaiterQueue<Int>()
    let gate = CancellableWaiterQueue<Int>()
    let waiter = Task { () -> Bool in
        try await queue.wait(1)
        // Park until the test has cancelled this task, without consuming the cancel inside `wait`.
        try? await gate.wait(0)
        return Task.isCancelled
    }
    await waitUntil("waiter to enqueue") { queue.count == 1 }
    #expect(queue.resumeNext() == 1)
    await waitUntil("owner to park") { gate.count == 1 }
    waiter.cancel()
    let observedCancelAfterOwnership = try await waiter.value
    #expect(observedCancelAfterOwnership)
    #expect(queue.isEmpty)
}

@Test func resumeAllReleasesEveryCoalescedWaiter() async throws {
    let queue = CancellableWaiterQueue<Int>()
    let first = Task { try await queue.wait(1) }
    let second = Task { try await queue.wait(2) }
    await waitUntil("both waiters to enqueue") { queue.count == 2 }
    #expect(queue.resumeAll() == 2)
    try await first.value
    try await second.value
    #expect(queue.isEmpty)
}

@MainActor
private final class HandOffState {
    var held = true
    var waiterFinished = false
}

/// Review finding (lost wake-up): the caller checks its state on its actor and then waits. When `wait` hopped
/// off that actor before joining the queue, a release scheduled on the same actor could run in the gap, find
/// the queue empty and open the lock, and the late waiter then sat in the queue forever. The waiter must be
/// queued before the caller's actor can run anything else.
@MainActor
@Test func aReleaseOnTheCallersActorCannotRunBetweenTheCheckAndTheAppend() async throws {
    for iteration in 0..<100 {
        let queue = CancellableWaiterQueue<Void>()
        let state = HandOffState()
        let waiter = Task { @MainActor in
            if state.held {
                try? await queue.wait(())
            }
            state.waiterFinished = true
        }
        let releaser = Task { @MainActor in
            state.held = false
            _ = queue.resumeNext()
        }
        await releaser.value
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !state.waiterFinished, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        let stranded = !state.waiterFinished
        #expect(!stranded, "iteration \(iteration): the release ran before the waiter joined the queue")
        if stranded { queue.resumeAll() }
        _ = await waiter.value
        #expect(queue.isEmpty)
        if stranded { return }
    }
}

private actor ParkedPublicationStore {
    var work: HistoricalAnalysisWork

    init(work: HistoricalAnalysisWork) { self.work = work }

    func lease(owner: String, now: Date, duration: TimeInterval) throws -> HistoricalAnalysisWork? {
        guard work.canAttempt(at: now) else { return nil }
        try HistoricalAnalysisWorkReducer.apply(
            .acquireLease(owner: owner, expiresAt: now.addingTimeInterval(duration)),
            to: &work,
            now: now
        )
        return work
    }

    func apply(id: UUID, event: HistoricalWorkEvent, now: Date) throws -> HistoricalAnalysisWork {
        guard work.id == id else { throw HistoricalWorkError.invalidTransition }
        try HistoricalAnalysisWorkReducer.apply(event, to: &work, now: now)
        return work
    }

    func current() -> HistoricalAnalysisWork { work }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// CC-3 / CC-2: a drain parked on a held publication lock must not stall quiesce. Before the fix the lock
/// wait ignored cancellation, so quiesce (source switch, BG-task expiry) waited for as long as the lock
/// stayed closed, which under CC-1 was forever.
@Test func quiesceReturnsPromptlyWhileADrainIsParkedOnAHeldLock() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let day = try CivilDay(key: "2026-08-03")
    let scope = try HistoricalAnalysisScope(
        databaseInstanceId: "db", sourceId: "my-whoop", deviceId: "my-whoop-cc3",
        deviceLineageId: "strap-a", cursorEpoch: 1, trimScope: "history"
    )
    let store = ParkedPublicationStore(work: try HistoricalAnalysisWork(
        scope: scope,
        firstReceiptGeneration: 1,
        lastReceiptGeneration: 1,
        affectedDays: [day],
        recordedTimeZoneIdentifier: "America/New_York",
        createdAt: now
    ))
    // Models RepositoryPublicationBarrier held by another source owner for the whole test.
    let heldLock = CancellableWaiterQueue<Void>()
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
                contextId: "ctx", deviceId: "device", generation: 2, logicalDay: day, metrics: [:]
            )
            return try SnapshotCommitReceipt(
                throughReceiptGeneration: analysis.throughReceiptGeneration,
                analysisGeneration: analysis.analysisGeneration,
                snapshotGeneration: projection.generation,
                analyzedDays: analysis.analyzedDays,
                projection: projection
            )
        },
        publishRepository: { _, _ in try await heldLock.wait(()) },
        commitOutbox: { _ in [] },
        classifyError: { _ in PipelineFailureClassification(code: "unexpected", retryable: true) },
        now: { now }
    )
    let coordinator = HistoricalPipelineCoordinator(dependencies: dependencies)
    let drain = Task { await coordinator.signal() }
    await waitUntil("drain to park on the held lock") { heldLock.count == 1 }

    let quiesced = CompletionFlag()
    let quiesce = Task {
        let epoch = try await coordinator.quiesce()
        quiesced.set()
        return epoch
    }
    await waitUntil("quiesce to return while the lock is still held") { quiesced.isSet }

    let epoch = try await quiesce.value
    let result = await drain.value
    #expect(result.completedWorkCount == 0)
    #expect(heldLock.isEmpty, "the cancelled waiter left the lock queue")
    let work = await store.current()
    #expect(work.lease == nil, "cancellation hands the durable lease back instead of waiting for expiry")
    #expect(work.state != .complete)
    try await coordinator.resume(expectedEpoch: epoch)
}
