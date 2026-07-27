import XCTest
@testable import NOOP

@MainActor
final class IntelligenceAnalysisCallerCompletionTests: XCTestCase {
    private final class Owner {}

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
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for caller-completion state")
    }

    func testInitialSubmitterReturnsWhenItsBatchCompletesNotWhenQueueDrains() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let firstGate = Gate()
        let secondGate = Gate()
        let today = IntelligenceAnalysisRequest(
            maxDays: 21,
            startOffset: 0,
            force: true,
            refreshRepository: false)
        let laterHistory = IntelligenceAnalysisRequest(
            maxDays: 30,
            startOffset: 120,
            force: true,
            refreshRepository: true)

        var runs: [IntelligenceAnalysisRequest] = []
        var todayReturned = false
        var historyReturned = false
        let runner: IntelligenceAnalysisCoordinator.Execute = { request in
            runs.append(request)
            if runs.count == 1 {
                await firstGate.wait()
            } else if runs.count == 2 {
                await secondGate.wait()
            }
        }

        let todayTask = Task { @MainActor in
            await coordinator.submit(owner: owner, request: today, run: runner)
            todayReturned = true
        }
        try await waitUntil { runs == [today] }

        let historyTask = Task { @MainActor in
            await coordinator.submit(owner: owner, request: laterHistory, run: runner)
            historyReturned = true
        }
        try await waitUntil { coordinator.pendingBatchCount(for: owner) == 1 }

        firstGate.open()
        try await waitUntil { todayReturned && runs == [today, laterHistory] }

        XCTAssertFalse(historyReturned,
                       "later historical work is still running, but Today's caller must already be released")

        secondGate.open()
        await todayTask.value
        await historyTask.value
        XCTAssertTrue(historyReturned)
    }
}
