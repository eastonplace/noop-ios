import XCTest
@testable import NOOP

@MainActor
final class IntelligenceAnalysisDurableRetryTests: XCTestCase {
    private final class Owner {}
    private enum TestFailure: Error { case simulated }

    @MainActor
    private final class Gate {
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func waitUntil(
        attempts: Int = 200,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<attempts {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Timed out waiting for durable analysis retry state")
    }

    func testForcedRetryableFailureStaysQueuedUntilItCompletes() async {
        let coordinator = IntelligenceAnalysisCoordinator(retryDelay: 0)
        let owner = Owner()
        let request = IntelligenceAnalysisRequest(
            maxDays: 21,
            startOffset: 0,
            force: true,
            refreshRepository: false)
        var attempts = 0

        let completed = await coordinator.submit(owner: owner, request: request) { _ in
            attempts += 1
            if attempts == 1 {
                throw IntelligenceAnalysisCoordinatorError.analysisDidNotComplete
            }
        }

        XCTAssertTrue(completed)
        XCTAssertEqual(attempts, 2)
        XCTAssertFalse(coordinator.isRunning(for: owner))
    }

    func testConcurrentArrivalDuringFailureSurvivesAndCoalescesIntoRetry() async throws {
        let coordinator = IntelligenceAnalysisCoordinator(retryDelay: 0)
        let owner = Owner()
        let gate = Gate()
        let first = IntelligenceAnalysisRequest(
            maxDays: 21,
            startOffset: 0,
            force: true,
            refreshRepository: false)
        let second = IntelligenceAnalysisRequest(
            maxDays: 30,
            startOffset: 10,
            force: true,
            refreshRepository: false)
        let expectedRetry = first.coalesced(with: second)
        var attempts = 0
        var runs: [IntelligenceAnalysisRequest] = []

        let runner: IntelligenceAnalysisCoordinator.Execute = { request in
            attempts += 1
            runs.append(request)
            if attempts == 1 {
                await gate.wait()
                throw IntelligenceAnalysisCoordinatorError.analysisDidNotComplete
            }
        }

        let firstTask = Task { @MainActor in
            await coordinator.submit(owner: owner, request: first, run: runner)
        }
        try await waitUntil { runs == [first] }

        let secondTask = Task { @MainActor in
            await coordinator.submit(owner: owner, request: second, run: runner)
        }
        try await waitUntil { coordinator.pendingBatchCount(for: owner) == 1 }

        gate.open()
        let firstCompleted = await firstTask.value
        let secondCompleted = await secondTask.value

        XCTAssertTrue(firstCompleted)
        XCTAssertTrue(secondCompleted)
        XCTAssertEqual(runs, [first, expectedRetry])
        XCTAssertFalse(coordinator.isRunning(for: owner))
    }

    func testNonForcedRetryableFailureRemainsDisposable() async {
        let coordinator = IntelligenceAnalysisCoordinator(retryDelay: 0)
        let owner = Owner()
        let request = IntelligenceAnalysisRequest(
            maxDays: 21,
            startOffset: 0,
            force: false,
            refreshRepository: true)
        var attempts = 0

        let completed = await coordinator.submit(owner: owner, request: request) { _ in
            attempts += 1
            throw IntelligenceAnalysisCoordinatorError.analysisDidNotComplete
        }

        XCTAssertFalse(completed)
        XCTAssertEqual(attempts, 1)
    }

    func testNonRetryableFailureDoesNotLoopEvenWhenForced() async {
        let coordinator = IntelligenceAnalysisCoordinator(retryDelay: 0)
        let owner = Owner()
        let request = IntelligenceAnalysisRequest(
            maxDays: 21,
            startOffset: 0,
            force: true,
            refreshRepository: true)
        var attempts = 0

        let completed = await coordinator.submit(owner: owner, request: request) { _ in
            attempts += 1
            throw TestFailure.simulated
        }

        XCTAssertFalse(completed)
        XCTAssertEqual(attempts, 1)
    }
}
