import XCTest
@testable import NOOP

final class HistoricalPipelineRuntimeResultTests: XCTestCase {
    func testCombinePreservesEveryCoalescedPassAndLatestKnownPendingCount() {
        let accumulated = HistoricalPipelineRuntimeResult(
            admittedReceipts: 2,
            completedWork: 3,
            deferredWork: 1,
            pendingWork: 8,
            alreadyRunning: false
        )
        let next = HistoricalPipelineRuntimeResult(
            admittedReceipts: 5,
            completedWork: 7,
            deferredWork: 2,
            pendingWork: nil,
            alreadyRunning: true
        )

        XCTAssertEqual(
            HistoricalPipelineRuntimeResult.combine(accumulated, next),
            HistoricalPipelineRuntimeResult(
                admittedReceipts: 7,
                completedWork: 10,
                deferredWork: 3,
                pendingWork: 8,
                alreadyRunning: true
            )
        )
    }

    func testCombineUsesTheNewestSuccessfulPendingCount() {
        let accumulated = HistoricalPipelineRuntimeResult(
            admittedReceipts: 0,
            completedWork: 0,
            deferredWork: 0,
            pendingWork: 8,
            alreadyRunning: false
        )
        let next = HistoricalPipelineRuntimeResult(
            admittedReceipts: 0,
            completedWork: 0,
            deferredWork: 0,
            pendingWork: 3,
            alreadyRunning: false
        )

        XCTAssertEqual(HistoricalPipelineRuntimeResult.combine(accumulated, next).pendingWork, 3)
    }
}
