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

    /// CORE-01: a background pipeline pass that committed exact work must wake the external-publication
    /// outbox with no scene event; a pass that only admitted receipts, or did nothing, must not.
    func testOnlyCommittedWorkWakesTheOutbox() {
        let committed = HistoricalPipelineRuntimeResult(
            admittedReceipts: 1, completedWork: 3, deferredWork: 0, pendingWork: 0, alreadyRunning: false)
        let admittedOnly = HistoricalPipelineRuntimeResult(
            admittedReceipts: 2, completedWork: 0, deferredWork: 1, pendingWork: 2, alreadyRunning: false)
        let idle = HistoricalPipelineRuntimeResult(
            admittedReceipts: 0, completedWork: 0, deferredWork: 0, pendingWork: nil, alreadyRunning: true)

        XCTAssertTrue(committed.committedExternalPublicationWork)
        XCTAssertFalse(admittedOnly.committedExternalPublicationWork)
        XCTAssertFalse(idle.committedExternalPublicationWork)
    }
}
