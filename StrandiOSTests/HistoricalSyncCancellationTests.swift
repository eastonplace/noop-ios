import XCTest
@testable import NOOP

#if os(iOS)
@MainActor
final class HistoricalSyncCancellationTests: XCTestCase {
    func testExpirationBeforeFirstExecutionCannotStartHistoricalSync() async {
        var syncRequests = 0
        let operation = HistoricalSyncBackgroundTaskRegistrar.makeOperation {
            syncRequests += 1
        }
        // The MainActor is still running this test, so the operation has not begun yet.
        operation.cancel()
        await operation.value

        XCTAssertEqual(syncRequests, 0, "an expired launch must not open a new radio offload")
    }

    func testAnUnexpiredLaunchStillRunsItsOperationOnce() async {
        var syncRequests = 0
        let operation = HistoricalSyncBackgroundTaskRegistrar.makeOperation {
            syncRequests += 1
        }
        await operation.value

        XCTAssertEqual(syncRequests, 1)
    }
}
#endif
