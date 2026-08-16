import XCTest
@testable import NoopPhase34Core

private struct AccumulatingProbeResult: Equatable, Sendable {
    let completed: Int
    let deferred: Int
}

private actor GatePassSequence {
    private var outputs: [AccumulatingProbeResult]
    private var calls = 0
    private var firstStarted = false
    private var firstStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstRelease: CheckedContinuation<Void, Never>?

    init(_ outputs: [AccumulatingProbeResult]) { self.outputs = outputs }

    func next() async -> AccumulatingProbeResult {
        calls += 1
        let output = outputs.isEmpty ? .init(completed: 0, deferred: 0) : outputs.removeFirst()
        if calls == 1 {
            firstStarted = true
            let waiters = firstStartedWaiters
            firstStartedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                firstRelease = continuation
            }
        }
        return output
    }

    func waitUntilFirstStarted() async {
        guard !firstStarted else { return }
        await withCheckedContinuation { continuation in
            firstStartedWaiters.append(continuation)
        }
    }

    func releaseFirst() {
        firstRelease?.resume()
        firstRelease = nil
    }

    func callCount() -> Int { calls }
}

private actor FenceLeaseLatch {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?

    func hold() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            release = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func releaseLease() {
        release?.resume()
        release = nil
    }
}

final class PR29Round5RootFixTests: XCTestCase {
    func testLosslessGateAccumulatesProductivePassBeforeFinalEdgeRerun() async {
        let sequence = GatePassSequence([
            .init(completed: 4, deferred: 0),
            .init(completed: 0, deferred: 1),
        ])
        let gate = LosslessDrainSignalGate<AccumulatingProbeResult>(
            combine: {
                .init(
                    completed: $0.completed + $1.completed,
                    deferred: $0.deferred + $1.deferred)
            },
            operation: { await sequence.next() }
        )

        let first = Task { await gate.signal() }
        await sequence.waitUntilFirstStarted()
        let finalEdge = Task { await gate.signal() }
        while await !gate.hasPendingDrainForTesting { await Task.yield() }
        await sequence.releaseFirst()

        let result = await first.value
        let finalEdgeResult = await finalEdge.value
        let calls = await sequence.callCount()
        XCTAssertEqual(result, .init(completed: 4, deferred: 1))
        XCTAssertEqual(finalEdgeResult, result)
        XCTAssertEqual(calls, 2)
    }

    func testExactNamespaceKeepsDerivedWritesWithCommittedSource() throws {
        let namespace = try ExactAnalysisNamespace(
            rawDeviceId: "source-A",
            additionalVerificationSourceIds: ["apple-health", "source-A"],
            historyLineage: "lineage-A",
            cursorEpoch: 3
        )
        XCTAssertEqual(namespace.rawDeviceId, "source-A")
        XCTAssertEqual(namespace.computedDeviceId, "source-A-noop")
        XCTAssertEqual(namespace.importedBaselineDeviceIds, ["source-A"])
        XCTAssertEqual(namespace.verificationSourceIds,
                       ["source-A", "source-A-noop", "apple-health"])
    }

    func testTargetScopedFenceBlocksOnlyRequestedSource() async throws {
        let fence = TargetScopedPipelineFence()
        try await fence.begin(sourceId: "source-A")
        try await fence.begin(sourceId: "source-B")

        let quiesceA = Task { await fence.quiesce(sourceId: "source-A") }
        await Task.yield()
        let sourceABlocked = await fence.isBlocked(sourceId: "source-A")
        let sourceBBlocked = await fence.isBlocked(sourceId: "source-B")
        XCTAssertTrue(sourceABlocked)
        XCTAssertFalse(sourceBBlocked)

        await fence.end(sourceId: "source-A")
        await quiesceA.value
        do {
            try await fence.begin(sourceId: "source-A")
            XCTFail("blocked source admitted new work")
        } catch TargetScopedFenceError.blocked {
            // Expected.
        }

        await fence.resume(sourceId: "source-A")
        try await fence.begin(sourceId: "source-A")
        await fence.end(sourceId: "source-A")
        await fence.end(sourceId: "source-B")
    }

    func testTargetScopedFenceWaitsForAsyncLeaseWithoutBlockingAnotherSource() async throws {
        let fence = TargetScopedPipelineFence()
        let latch = FenceLeaseLatch()
        let sourceA = Task {
            try await fence.withLease(sourceId: "source-A") {
                await latch.hold()
            }
        }

        await latch.waitUntilStarted()
        let quiesceA = Task { await fence.quiesce(sourceId: "source-A") }
        await Task.yield()
        let blockedDuringLease = await fence.isBlocked(sourceId: "source-A")
        XCTAssertTrue(blockedDuringLease)

        let sourceB = try await fence.withLease(sourceId: "source-B") { 42 }
        XCTAssertEqual(sourceB, 42)

        await latch.releaseLease()
        try await sourceA.value
        await quiesceA.value
        let blockedAfterQuiescence = await fence.isBlocked(sourceId: "source-A")
        XCTAssertTrue(blockedAfterQuiescence)

        await fence.resume(sourceId: "source-A")
        let blockedAfterResume = await fence.isBlocked(sourceId: "source-A")
        XCTAssertFalse(blockedAfterResume)
    }

    func testNestedTargetQuiesceRequiresMatchingOuterResume() async throws {
        let fence = TargetScopedPipelineFence()

        await fence.quiesce(sourceId: "source-A")
        await fence.quiesce(sourceId: "source-A")
        let blockedTwice = await fence.isBlocked(sourceId: "source-A")
        XCTAssertTrue(blockedTwice)

        await fence.resume(sourceId: "source-A")
        let blockedAfterInnerResume = await fence.isBlocked(sourceId: "source-A")
        XCTAssertTrue(blockedAfterInnerResume)
        do {
            try await fence.begin(sourceId: "source-A")
            XCTFail("inner resume reopened admission through the outer transition fence")
        } catch TargetScopedFenceError.blocked {
            // Expected.
        }

        await fence.resume(sourceId: "source-A")
        let blockedAfterOuterResume = await fence.isBlocked(sourceId: "source-A")
        XCTAssertFalse(blockedAfterOuterResume)
        try await fence.begin(sourceId: "source-A")
        await fence.end(sourceId: "source-A")
    }
}
