import XCTest
@testable import NOOP

@MainActor
final class IntelligenceAnalysisDurableRetryTests: XCTestCase {
    private final class Owner {}
    private enum TestFailure: Error { case simulated }

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
