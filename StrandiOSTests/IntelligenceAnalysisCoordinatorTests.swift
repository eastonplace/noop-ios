import XCTest
@testable import NOOP

@MainActor
final class IntelligenceAnalysisCoordinatorTests: XCTestCase {
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
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out waiting for analysis coordinator state")
    }

    func testInvalidAndOverflowingInputsAreBounded() {
        let request = IntelligenceAnalysisRequest(
            maxDays: Int.max,
            startOffset: Int.min,
            force: true,
            refreshRepository: false)

        XCTAssertEqual(request.startOffset, 0)
        XCTAssertEqual(request.maxDays, IntelligenceAnalysisRequest.maximumWindowDays)
        XCTAssertEqual(request.endOffsetExclusive, IntelligenceAnalysisRequest.maximumWindowDays)
    }

    func testForcedCurrentDayCallerWaitsForItsExactWindow() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let gate = Gate()
        let history = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 120, force: true, refreshRepository: true)
        let today = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)
        var runs: [IntelligenceAnalysisRequest] = []

        let runner: IntelligenceAnalysisCoordinator.Execute = { request in
            runs.append(request)
            if runs.count == 1 { await gate.wait() }
        }
        let active = Task { @MainActor in
            await coordinator.submit(owner: owner, request: history, run: runner)
        }
        try await waitUntil { coordinator.isRunning(for: owner) }
        try await waitUntil { runs == [history] }
        let current = Task { @MainActor in
            await coordinator.submit(owner: owner, request: today, run: runner)
        }
        try await waitUntil { coordinator.waitingForcedCallerCount(for: owner) == 1 }

        XCTAssertEqual(runs, [history])
        gate.open()
        _ = await active.value
        _ = await current.value

        XCTAssertEqual(runs, [history, today])
    }

    func testFailedBatchDoesNotReportSuccessfulCompletion() async {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let request = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)

        let completed = await coordinator.submit(owner: owner, request: request) { _ in
            throw TestFailure.simulated
        }

        XCTAssertFalse(completed)
    }

    func testCurrentDayFastLaneRunsBeforeNextHistoricalChunk() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let gate = Gate()
        let activeHistory = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 60, force: true, refreshRepository: true)
        let laterHistory = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 120, force: true, refreshRepository: true)
        let today = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)
        var runs: [IntelligenceAnalysisRequest] = []

        let runner: IntelligenceAnalysisCoordinator.Execute = { request in
            runs.append(request)
            if runs.count == 1 { await gate.wait() }
        }
        let active = Task { @MainActor in
            await coordinator.submit(owner: owner, request: activeHistory, run: runner)
        }
        try await waitUntil { coordinator.isRunning(for: owner) }
        try await waitUntil { runs == [activeHistory] }
        let later = Task { @MainActor in
            await coordinator.submit(owner: owner, request: laterHistory, run: runner)
        }
        let current = Task { @MainActor in
            await coordinator.submit(owner: owner, request: today, run: runner)
        }
        try await waitUntil { coordinator.pendingBatchCount(for: owner) == 2 }

        gate.open()
        _ = await active.value
        _ = await later.value
        _ = await current.value

        XCTAssertEqual(runs, [activeHistory, today, laterHistory])
    }

    func testOverlappingCompatiblePendingRequestsCoalesceOnce() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let gate = Gate()
        let blocker = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 300, force: true, refreshRepository: true)
        let first = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 20, force: true, refreshRepository: false)
        let second = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 35, force: true, refreshRepository: false)
        let expected = IntelligenceAnalysisRequest(
            maxDays: 45, startOffset: 20, force: true, refreshRepository: false)
        var runs: [IntelligenceAnalysisRequest] = []

        let runner: IntelligenceAnalysisCoordinator.Execute = { request in
            runs.append(request)
            if runs.count == 1 { await gate.wait() }
        }
        let active = Task { @MainActor in
            await coordinator.submit(owner: owner, request: blocker, run: runner)
        }
        try await waitUntil { coordinator.isRunning(for: owner) }
        try await waitUntil { runs == [blocker] }
        let one = Task { @MainActor in
            await coordinator.submit(owner: owner, request: first, run: runner)
        }
        let two = Task { @MainActor in
            await coordinator.submit(owner: owner, request: second, run: runner)
        }
        try await waitUntil {
            coordinator.pendingBatchCount(for: owner) == 1
                && coordinator.waitingForcedCallerCount(for: owner) == 2
        }

        gate.open()
        _ = await active.value
        _ = await one.value
        _ = await two.value

        XCTAssertEqual(runs, [blocker, expected])
    }

    func testDifferentPublicationSemanticsDoNotCoalesce() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let gate = Gate()
        let blocker = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 300, force: true, refreshRepository: true)
        let noRefresh = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)
        let refresh = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: true)
        var runs: [IntelligenceAnalysisRequest] = []

        let runner: IntelligenceAnalysisCoordinator.Execute = { request in
            runs.append(request)
            if runs.count == 1 { await gate.wait() }
        }
        let active = Task { @MainActor in
            await coordinator.submit(owner: owner, request: blocker, run: runner)
        }
        try await waitUntil { coordinator.isRunning(for: owner) }
        try await waitUntil { runs == [blocker] }
        let one = Task { @MainActor in
            await coordinator.submit(owner: owner, request: refresh, run: runner)
        }
        let two = Task { @MainActor in
            await coordinator.submit(owner: owner, request: noRefresh, run: runner)
        }
        try await waitUntil { coordinator.pendingBatchCount(for: owner) == 2 }

        gate.open()
        _ = await active.value
        _ = await one.value
        _ = await two.value

        XCTAssertEqual(runs, [blocker, noRefresh, refresh])
    }

    func testNonForcedCadenceTickIsDroppedWhileForcedWorkRuns() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let gate = Gate()
        let forced = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: true)
        let idle = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: false, refreshRepository: true)
        var runs: [IntelligenceAnalysisRequest] = []

        let runner: IntelligenceAnalysisCoordinator.Execute = { request in
            runs.append(request)
            await gate.wait()
        }
        let active = Task { @MainActor in
            await coordinator.submit(owner: owner, request: forced, run: runner)
        }
        try await waitUntil { coordinator.isRunning(for: owner) }
        // Queue ownership is visible before the runner reaches its first suspension.
        // Wait for that runner edge so opening the gate below cannot race ahead of
        // `Gate.wait()` and strand this test indefinitely.
        try await waitUntil { runs == [forced] }
        await coordinator.submit(owner: owner, request: idle, run: runner)

        XCTAssertEqual(runs, [forced])
        XCTAssertEqual(coordinator.pendingBatchCount(for: owner), 0)
        gate.open()
        _ = await active.value
    }

    func testQueuedForcedWorkSurvivesCallerCancellation() async throws {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let gate = Gate()
        let blocker = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 90, force: true, refreshRepository: true)
        let durable = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)
        var runs: [IntelligenceAnalysisRequest] = []

        let runner: IntelligenceAnalysisCoordinator.Execute = { request in
            runs.append(request)
            if runs.count == 1 { await gate.wait() }
        }
        let active = Task { @MainActor in
            await coordinator.submit(owner: owner, request: blocker, run: runner)
        }
        try await waitUntil { coordinator.isRunning(for: owner) }
        try await waitUntil { runs == [blocker] }
        let queued = Task { @MainActor in
            await coordinator.submit(owner: owner, request: durable, run: runner)
        }
        try await waitUntil { coordinator.waitingForcedCallerCount(for: owner) == 1 }
        queued.cancel()

        gate.open()
        _ = await active.value
        _ = await queued.value

        XCTAssertEqual(runs, [blocker, durable])
    }
}
