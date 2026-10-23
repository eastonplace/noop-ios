import XCTest
@testable import NOOP

@MainActor
final class HealthKitQueryCancellationTests: XCTestCase {
    func testCancellationStopsQueryWithoutWaitingForHealthKitCallback() async throws {
        var callback: (@Sendable (Result<Int, Error>) -> Void)?
        var stopCount = 0
        let started = expectation(description: "query started")
        let cancelled = expectation(description: "query cancelled without callback")
        let task = Task { @MainActor in
            defer { cancelled.fulfill() }
            return try await HealthKitCancellableQuery.run(start: { completion in
                callback = completion
                started.fulfill()
            }, stop: { stopCount += 1 })
        }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(stopCount, 1)
        // Unblock even a broken implementation so a failure does not strand the test task.
        callback?(.success(42))
        do {
            _ = try await task.value
            XCTFail("Cancelled query must throw")
        } catch is CancellationError {
            XCTAssertEqual(stopCount, 1)
        }
        // HealthKit can still deliver a callback after stop. It must not resume twice.
        callback?(.success(42))
        await Task.yield()
        XCTAssertEqual(stopCount, 1)
    }

    func testSuccessfulOneShotQueryStopsBeforeReturning() async throws {
        var stopCount = 0
        let result = try await HealthKitCancellableQuery.run(start: { completion in
            completion(.success(42))
        }, stop: { stopCount += 1 })
        XCTAssertEqual(result, 42)
        XCTAssertEqual(stopCount, 1)
    }

    func testAlreadyCancelledTaskDoesNotStartQuery() async {
        var startCount = 0
        var stopCount = 0
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await HealthKitCancellableQuery.run(start: { completion in
                startCount += 1
                completion(.success(42))
            }, stop: { stopCount += 1 })
        }
        do {
            _ = try await task.value
            XCTFail("Already-cancelled task must throw")
        } catch is CancellationError {
            XCTAssertEqual(startCount, 0)
            XCTAssertEqual(stopCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
