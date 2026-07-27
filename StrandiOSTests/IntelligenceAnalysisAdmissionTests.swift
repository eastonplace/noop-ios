import XCTest
@testable import NOOP

@MainActor
final class IntelligenceAnalysisAdmissionTests: XCTestCase {
    func testNonForcedTickIsRejectedWhileAnotherPassRuns() async {
        let admission = IntelligenceAnalysisAdmission()
        let firstAcquired = await admission.acquire(force: true)
        let disposableAcquired = await admission.acquire(force: false)

        XCTAssertTrue(firstAcquired)
        XCTAssertFalse(disposableAcquired)
        XCTAssertTrue(admission.isRunning)
        XCTAssertEqual(admission.waitingForcedCallers, 0)
        admission.release()
    }

    func testForcedRequestWaitsThenAcquiresInsteadOfBeingCollapsed() async throws {
        let admission = IntelligenceAnalysisAdmission()
        let firstAcquired = await admission.acquire(force: true)
        XCTAssertTrue(firstAcquired)

        let waiter = Task { @MainActor in
            await admission.acquire(force: true)
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(admission.waitingForcedCallers, 1)
        XCTAssertTrue(admission.isRunning)

        admission.release()
        let waiterAcquired = await waiter.value
        XCTAssertTrue(waiterAcquired)
        XCTAssertTrue(admission.isRunning)
        XCTAssertEqual(admission.waitingForcedCallers, 0)
        admission.release()
    }

    func testCancelledForcedWaiterDoesNotStealOwnership() async throws {
        let admission = IntelligenceAnalysisAdmission()
        let firstAcquired = await admission.acquire(force: true)
        XCTAssertTrue(firstAcquired)

        let waiter = Task { @MainActor in
            await admission.acquire(force: true)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(admission.waitingForcedCallers, 1)
        waiter.cancel()

        let waiterAcquired = await waiter.value
        XCTAssertFalse(waiterAcquired)
        XCTAssertEqual(admission.waitingForcedCallers, 0)
        XCTAssertTrue(admission.isRunning, "the original owner still holds the pipeline")
        admission.release()
    }
}
