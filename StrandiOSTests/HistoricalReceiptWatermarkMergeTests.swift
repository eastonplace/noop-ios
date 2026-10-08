import XCTest
@testable import NOOP

/// The real watermark's merge, used when burst finalizations are parked during a workout, must keep every
/// source scope and the newest generation per scope.
final class HistoricalReceiptWatermarkMergeTests: XCTestCase {
    private func mark(_ device: String, _ generation: Int64, database: String = "db") -> HistoricalReceiptWatermark {
        HistoricalReceiptWatermark(
            databaseInstanceId: database,
            sourceIdentity: HistoricalReceiptWatermark.SourceIdentity(deviceId: device),
            throughGeneration: generation)
    }

    func testMergeKeepsTheNewestGenerationPerScope() {
        let merged = mark("a", 3).merged(with: mark("a", 7))
        XCTAssertEqual(merged.coordinates.map(\.throughGeneration), [7])
        // An older late arrival never lowers a scope.
        XCTAssertEqual(merged.merged(with: mark("a", 2)).coordinates.map(\.throughGeneration), [7])
    }

    func testMergeRetainsEveryDistinctSourceScope() {
        let merged = mark("a", 3).merged(with: mark("b", 9)).merged(with: mark("a", 5, database: "other"))
        XCTAssertEqual(merged.coordinates.count, 3)
        XCTAssertEqual(merged.throughGeneration, 9)
    }

    func testParkedBurstsReplayAsOneUnionedWatermark() {
        var work = DeferredSessionWork<HistoricalReceiptWatermark>()
        _ = work.admitBurst(mark("a", 3), sessionActive: true)
        _ = work.admitBurst(mark("b", 4), sessionActive: true)
        _ = work.admitBurst(mark("a", 8), sessionActive: true)

        let jobs = work.drain(sessionActive: false)
        XCTAssertEqual(jobs.count, 1)
        guard case let .burstRefresh(watermark?) = jobs[0] else { return XCTFail("expected a receipt refresh") }
        XCTAssertEqual(watermark.coordinates.map(\.throughGeneration).sorted(), [4, 8])
    }
}
