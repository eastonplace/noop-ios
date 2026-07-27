import XCTest
@testable import NOOP

@MainActor
final class IntelligenceAnalysisCoordinatorTests: XCTestCase {
    private final class Owner {}

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

    func testDisjointRequestsMergeIntoOneCompleteWindow() {
        let history = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 120, force: true, refreshRepository: true)
        let today = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)

        let merged = history.merged(with: today)

        XCTAssertEqual(merged.startOffset, 0)
        XCTAssertEqual(merged.maxDays, 150)
        XCTAssertTrue(merged.force)
        XCTAssertTrue(merged.refreshRepository)
    }

    func testOverlappingRequestsDoNotDoubleCountDays() {
        let first = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 20, force: true, refreshRepository: false)
        let second = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 35, force: false, refreshRepository: true)

        let merged = first.merged(with: second)

        XCTAssertEqual(merged.startOffset, 20)
        XCTAssertEqual(merged.maxDays, 45)
        XCTAssertTrue(merged.force)
        XCTAssertTrue(merged.refreshRepository)
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

    func testForcedQueuedCallerWaitsUntilItsMergedWindowActuallyRuns() async {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let gate = Gate()
        let history = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 120, force: true, refreshRepository: true)
        let today = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)

        var runs: [IntelligenceAnalysisRequest] = []
        var firstStarted = false
        var secondStarted = false
        var secondCompleted = false
        let runner: @MainActor (IntelligenceAnalysisRequest) async -> Void = { request in
            runs.append(request)
            if runs.count == 1 {
                firstStarted = true
                await gate.wait()
            }
        }

        let first = Task { @MainActor in
            await coordinator.submit(owner: owner, request: history, run: runner)
        }
        while !firstStarted { await Task.yield() }

        let second = Task { @MainActor in
            secondStarted = true
            await coordinator.submit(owner: owner, request: today, run: runner)
            secondCompleted = true
        }
        while !secondStarted { await Task.yield() }
        await Task.yield()

        XCTAssertFalse(secondCompleted, "a forced current-day caller must not return while history still owns analysis")
        XCTAssertEqual(runs, [history])

        gate.open()
        await first.value
        await second.value

        XCTAssertTrue(secondCompleted)
        XCTAssertEqual(runs, [history, today],
                       "the queued caller's exact recent window must run after the active history pass")
    }

    func testMultipleForcedArrivalsCollapseIntoOnePendingBatch() async {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let gate = Gate()
        let active = IntelligenceAnalysisRequest(
            maxDays: 30, startOffset: 120, force: true, refreshRepository: false)
        let recent = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: false)
        let middle = IntelligenceAnalysisRequest(
            maxDays: 20, startOffset: 40, force: true, refreshRepository: true)

        var runs: [IntelligenceAnalysisRequest] = []
        var activeStarted = false
        var queuedStarts = 0
        let runner: @MainActor (IntelligenceAnalysisRequest) async -> Void = { request in
            runs.append(request)
            if runs.count == 1 {
                activeStarted = true
                await gate.wait()
            }
        }

        let first = Task { @MainActor in
            await coordinator.submit(owner: owner, request: active, run: runner)
        }
        while !activeStarted { await Task.yield() }

        let second = Task { @MainActor in
            queuedStarts += 1
            await coordinator.submit(owner: owner, request: recent, run: runner)
        }
        let third = Task { @MainActor in
            queuedStarts += 1
            await coordinator.submit(owner: owner, request: middle, run: runner)
        }
        while queuedStarts < 2 { await Task.yield() }
        await Task.yield()

        gate.open()
        await first.value
        await second.value
        await third.value

        XCTAssertEqual(runs.count, 2)
        XCTAssertEqual(runs[1], recent.merged(with: middle))
        XCTAssertTrue(runs[1].refreshRepository)
    }

    func testNonForcedCadenceTickIsDroppedWhileForcedWorkRuns() async {
        let coordinator = IntelligenceAnalysisCoordinator()
        let owner = Owner()
        let gate = Gate()
        let forced = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: true, refreshRepository: true)
        let idleTick = IntelligenceAnalysisRequest(
            maxDays: 21, startOffset: 0, force: false, refreshRepository: true)

        var runs: [IntelligenceAnalysisRequest] = []
        var forcedStarted = false
        let runner: @MainActor (IntelligenceAnalysisRequest) async -> Void = { request in
            runs.append(request)
            forcedStarted = true
            await gate.wait()
        }

        let active = Task { @MainActor in
            await coordinator.submit(owner: owner, request: forced, run: runner)
        }
        while !forcedStarted { await Task.yield() }

        await coordinator.submit(owner: owner, request: idleTick, run: runner)
        XCTAssertEqual(runs, [forced])

        gate.open()
        await active.value
    }
}
