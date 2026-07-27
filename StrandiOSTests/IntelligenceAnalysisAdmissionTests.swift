import XCTest
@testable import NOOP

@MainActor
final class IntelligenceAnalysisAdmissionTests: XCTestCase {
    private final class Recorder {
        var requests: [IntelligenceAnalysisRequest] = []
        let firstPassDelayNanoseconds: UInt64

        init(firstPassDelayNanoseconds: UInt64 = 80_000_000) {
            self.firstPassDelayNanoseconds = firstPassDelayNanoseconds
        }

        func execute(_ request: IntelligenceAnalysisRequest) async {
            requests.append(request)
            if requests.count == 1, firstPassDelayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: firstPassDelayNanoseconds)
            }
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
        XCTFail("Timed out waiting for analysis coordinator state")
    }

    func testNonForcedTickIsDroppedWhileAnotherPassRuns() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let recorder = Recorder()
        let execute: IntelligenceAnalysisCoordinator.Execute = { request in
            await recorder.execute(request)
        }
        let first = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 60, force: true, refreshRepository: true)
        let disposable = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: false, refreshRepository: true)

        let owner = Task { @MainActor in
            await coordinator.submit(first, execute: execute)
        }
        try await waitUntil { coordinator.isRunning }
        await coordinator.submit(disposable, execute: execute)
        await owner.value

        XCTAssertEqual(recorder.requests, [first])
        XCTAssertEqual(coordinator.completedPasses, 1)
    }

    func testForcedCurrentDayRequestWaitsAndRunsItsExactWindow() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let recorder = Recorder()
        let execute: IntelligenceAnalysisCoordinator.Execute = { request in
            await recorder.execute(request)
        }
        let history = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 120, force: true, refreshRepository: true)
        let today = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)

        let historyTask = Task { @MainActor in
            await coordinator.submit(history, execute: execute)
        }
        try await waitUntil { coordinator.isRunning }
        let todayTask = Task { @MainActor in
            await coordinator.submit(today, execute: execute)
        }
        try await waitUntil { coordinator.waitingForcedCallers == 1 }

        await historyTask.value
        await todayTask.value

        XCTAssertEqual(recorder.requests, [history, today])
        XCTAssertEqual(coordinator.completedPasses, 2)
        XCTAssertEqual(coordinator.waitingForcedCallers, 0)
    }

    func testCurrentDayFastLaneRunsBeforeNextQueuedHistoryChunk() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let recorder = Recorder()
        let execute: IntelligenceAnalysisCoordinator.Execute = { request in
            await recorder.execute(request)
        }
        let activeHistory = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 60, force: true, refreshRepository: true)
        let laterHistory = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 120, force: true, refreshRepository: true)
        let today = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)

        let activeTask = Task { @MainActor in
            await coordinator.submit(activeHistory, execute: execute)
        }
        try await waitUntil { coordinator.isRunning }
        let laterTask = Task { @MainActor in
            await coordinator.submit(laterHistory, execute: execute)
        }
        let todayTask = Task { @MainActor in
            await coordinator.submit(today, execute: execute)
        }
        try await waitUntil { coordinator.pendingBatchCount == 2 }

        await activeTask.value
        await laterTask.value
        await todayTask.value

        XCTAssertEqual(recorder.requests, [activeHistory, today, laterHistory])
    }

    func testOverlappingCompatiblePendingRequestsCoalesceOnce() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let recorder = Recorder()
        let execute: IntelligenceAnalysisCoordinator.Execute = { request in
            await recorder.execute(request)
        }
        let blocker = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 300, force: true, refreshRepository: true)
        let first = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 20, force: true, refreshRepository: false)
        let second = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 35, force: true, refreshRepository: false)
        let expectedMerged = IntelligenceAnalysisRequest(
            maxDays: 45, startOffset: 20, force: true, refreshRepository: false)

        let blockerTask = Task { @MainActor in
            await coordinator.submit(blocker, execute: execute)
        }
        try await waitUntil { coordinator.isRunning }
        let firstTask = Task { @MainActor in
            await coordinator.submit(first, execute: execute)
        }
        let secondTask = Task { @MainActor in
            await coordinator.submit(second, execute: execute)
        }
        try await waitUntil {
            coordinator.pendingBatchCount == 1 && coordinator.waitingForcedCallers == 2
        }

        await blockerTask.value
        await firstTask.value
        await secondTask.value

        XCTAssertEqual(recorder.requests, [blocker, expectedMerged])
        XCTAssertEqual(coordinator.completedPasses, 2)
    }

    func testDifferentPublicationSemanticsDoNotCoalesce() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let recorder = Recorder()
        let execute: IntelligenceAnalysisCoordinator.Execute = { request in
            await recorder.execute(request)
        }
        let blocker = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 300, force: true, refreshRepository: true)
        let noRefresh = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)
        let refresh = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: true)

        let blockerTask = Task { @MainActor in
            await coordinator.submit(blocker, execute: execute)
        }
        try await waitUntil { coordinator.isRunning }
        let noRefreshTask = Task { @MainActor in
            await coordinator.submit(noRefresh, execute: execute)
        }
        let refreshTask = Task { @MainActor in
            await coordinator.submit(refresh, execute: execute)
        }
        try await waitUntil { coordinator.pendingBatchCount == 2 }

        await blockerTask.value
        await noRefreshTask.value
        await refreshTask.value

        XCTAssertEqual(recorder.requests, [blocker, noRefresh, refresh])
    }

    func testRequestBoundsPreventOverflow() {
        let request = IntelligenceAnalysisRequest(
            maxDays: Int.max,
            startOffset: Int.min,
            force: true,
            refreshRepository: false)

        XCTAssertEqual(request.startOffset, 0)
        XCTAssertEqual(request.maxDays, IntelligenceAnalysisRequest.maximumWindowDays)
        XCTAssertEqual(request.endOffsetExclusive, IntelligenceAnalysisRequest.maximumWindowDays)
    }
}
