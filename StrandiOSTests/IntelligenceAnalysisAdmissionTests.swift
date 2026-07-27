import XCTest
@testable import NOOP

@MainActor
final class IntelligenceAnalysisAdmissionTests: XCTestCase {
    func testNonForcedTickIsRejectedWhileAnotherPassRuns() async {
        let admission = IntelligenceAnalysisAdmission()
        XCTAssertTrue(await admission.acquire(force: true))
        XCTAssertFalse(await admission.acquire(force: false))
        XCTAssertTrue(admission.isRunning)
        XCTAssertEqual(admission.waitingForcedCallers, 0)
        admission.release()
    }

    func testForcedRequestWaitsThenAcquiresInsteadOfBeingCollapsed() async throws {
        let admission = IntelligenceAnalysisAdmission()
        XCTAssertTrue(await admission.acquire(force: true))

        let waiter = Task { @MainActor in
            await admission.acquire(force: true)
        }
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(admission.waitingForcedCallers, 1)
        XCTAssertTrue(admission.isRunning)

        admission.release()
        XCTAssertTrue(await waiter.value)
        XCTAssertTrue(admission.isRunning)
        XCTAssertEqual(admission.waitingForcedCallers, 0)
        admission.release()
    }

    func testCancelledForcedWaiterDoesNotStealOwnership() async throws {
        let admission = IntelligenceAnalysisAdmission()
        XCTAssertTrue(await admission.acquire(force: true))

        let waiter = Task { @MainActor in
            await admission.acquire(force: true)
        }
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(admission.waitingForcedCallers, 1)
        waiter.cancel()

        XCTAssertFalse(await waiter.value)
        XCTAssertEqual(admission.waitingForcedCallers, 0)
        XCTAssertTrue(admission.isRunning, "the original owner still holds the pipeline")
        admission.release()
    }
}
