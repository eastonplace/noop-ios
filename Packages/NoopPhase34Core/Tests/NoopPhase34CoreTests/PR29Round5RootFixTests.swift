import XCTest
@testable import NoopPhase34Core

private struct AccumulatingProbeResult: Equatable, Sendable, DrainSignalResultAccumulating {
    let completed: Int
    let deferred: Int

    static func combineDrainResults(_ accumulated: Any, _ next: Any) -> Any {
        guard let lhs = accumulated as? Self, let rhs = next as? Self else { return next }
        return Self(completed: lhs.completed + rhs.completed,
                    deferred: lhs.deferred + rhs.deferred)
    }
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

final class PR29Round5RootFixTests: XCTestCase {
    func testLosslessGateAccumulatesProductivePassBeforeFinalEdgeRerun() async {
        let sequence = GatePassSequence([
            .init(completed: 4, deferred: 0),
            .init(completed: 0, deferred: 1),
        ])
        let gate = LosslessDrainSignalGate<AccumulatingProbeResult> {
            await sequence.next()
        }

        let first = Task { await gate.signal() }
        await sequence.waitUntilFirstStarted()
        let finalEdge = Task { await gate.signal() }
        await sequence.releaseFirst()

        let result = await first.value
        XCTAssertEqual(result, .init(completed: 4, deferred: 1))
        XCTAssertEqual(await finalEdge.value, result)
        XCTAssertEqual(await sequence.callCount(), 2)
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
        XCTAssertTrue(await fence.isBlocked(sourceId: "source-A"))
        XCTAssertFalse(await fence.isBlocked(sourceId: "source-B"))

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
}
