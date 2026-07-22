import XCTest
@testable import Strand

@MainActor
final class HistoricalMigrationDriverTests: XCTestCase {
    func testFourThousandDaysAnalyzeThenRefreshExactlyOnce() async {
        var offset = 0
        var done = false
        var chunks = 0
        var finalRefreshes = 0
        let outcome = await HistoricalMigrationDriver.run(
            historyDays: 4_000, chunkDays: 30,
            isCompleted: { done }, loadOffset: { offset },
            saveOffset: { offset = $0 }, markCompleted: { done = true },
            shouldPause: { false },
            analyzeChunk: { _, _ in chunks += 1 },
            finalRefresh: { finalRefreshes += 1; return true },
            interChunkDelay: .zero)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(chunks, 134)
        XCTAssertEqual(finalRefreshes, 1)
        XCTAssertTrue(done)
    }

    func testChunkFailureDoesNotAdvanceAndResumes() async {
        struct Failure: Error {}
        var offset = 0
        var done = false
        var fail = true
        var finalRefreshes = 0
        func run() async -> HistoricalMigrationDriver.Outcome {
            await HistoricalMigrationDriver.run(
                historyDays: 90, chunkDays: 30,
                isCompleted: { done }, loadOffset: { offset },
                saveOffset: { offset = $0 }, markCompleted: { done = true },
                shouldPause: { false },
                analyzeChunk: { _, current in
                    if current == 30 && fail { fail = false; throw Failure() }
                },
                finalRefresh: { finalRefreshes += 1; return true },
                interChunkDelay: .zero)
        }
        guard case .chunkFailed(let failedOffset, _) = await run() else {
            return XCTFail("Expected chunk failure")
        }
        XCTAssertEqual(failedOffset, 30)
        XCTAssertEqual(offset, 30)
        XCTAssertFalse(done)
        XCTAssertEqual(finalRefreshes, 0)
        XCTAssertEqual(await run(), .completed)
        XCTAssertTrue(done)
        XCTAssertEqual(finalRefreshes, 1)
    }

    func testPauseAfterChunkDoesNotAdvanceUnconfirmedOffset() async {
        var offset = 0
        var done = false
        var chunks = 0
        let outcome = await HistoricalMigrationDriver.run(
            historyDays: 90, chunkDays: 30,
            isCompleted: { done }, loadOffset: { offset },
            saveOffset: { offset = $0 }, markCompleted: { done = true },
            shouldPause: { chunks >= 2 },
            analyzeChunk: { _, _ in chunks += 1 },
            finalRefresh: { XCTFail("Should not refresh"); return true },
            interChunkDelay: .zero)
        XCTAssertEqual(outcome, .paused)
        XCTAssertEqual(offset, 30)
        XCTAssertFalse(done)
    }

    func testCancellationDoesNotAdvanceOrComplete() async {
        var offset = 0
        var done = false
        var gate: CheckedContinuation<Void, Never>?
        let task = Task { @MainActor in
            await HistoricalMigrationDriver.run(
                historyDays: 90, chunkDays: 30,
                isCompleted: { done }, loadOffset: { offset },
                saveOffset: { offset = $0 }, markCompleted: { done = true },
                shouldPause: { false },
                analyzeChunk: { _, _ in await withCheckedContinuation { gate = $0 } },
                finalRefresh: { XCTFail("Should not refresh"); return true },
                interChunkDelay: .zero)
        }
        while gate == nil { await Task.yield() }
        task.cancel()
        gate?.resume()
        gate = nil
        XCTAssertEqual(await task.value, .cancelled)
        XCTAssertEqual(offset, 0)
        XCTAssertFalse(done)
    }

    func testFinalRefreshFailureDoesNotSetCompletionMarker() async {
        var offset = 30
        var done = false
        let outcome = await HistoricalMigrationDriver.run(
            historyDays: 30, chunkDays: 30,
            isCompleted: { done }, loadOffset: { offset },
            saveOffset: { offset = $0 }, markCompleted: { done = true },
            shouldPause: { false },
            analyzeChunk: { _, _ in XCTFail("Should not re-analyze") },
            finalRefresh: { false },
            interChunkDelay: .zero)
        XCTAssertEqual(outcome, .finalRefreshFailed)
        XCTAssertFalse(done)
    }

    func testSuccessfulFinalRefreshCommitsOnce() async {
        var offset = 30
        var done = false
        var refreshes = 0
        let outcome = await HistoricalMigrationDriver.run(
            historyDays: 30, chunkDays: 30,
            isCompleted: { done }, loadOffset: { offset },
            saveOffset: { offset = $0 }, markCompleted: { done = true },
            shouldPause: { false },
            analyzeChunk: { _, _ in XCTFail("Should not re-analyze") },
            finalRefresh: { refreshes += 1; return true },
            interChunkDelay: .zero)
        XCTAssertEqual(outcome, .completed)
        XCTAssertEqual(refreshes, 1)
        XCTAssertTrue(done)
    }

    func testCancellationErrorFromChunkReturnsCancelled() async {
        var offset = 0
        var done = false
        let outcome = await HistoricalMigrationDriver.run(
            historyDays: 90, chunkDays: 30,
            isCompleted: { done }, loadOffset: { offset },
            saveOffset: { offset = $0 }, markCompleted: { done = true },
            shouldPause: { false },
            analyzeChunk: { _, _ in throw CancellationError() },
            finalRefresh: { XCTFail("Should not refresh"); return true },
            interChunkDelay: .zero)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(offset, 0)
        XCTAssertFalse(done)
    }
}
