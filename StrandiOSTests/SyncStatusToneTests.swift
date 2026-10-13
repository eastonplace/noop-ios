import XCTest
@testable import NOOP

/// Mint says good or live, so the Sync line is only mint when a sync just worked.
final class SyncStatusToneTests: XCTestCase {
    private let now: TimeInterval = 1_791_842_400
    private let day: TimeInterval = 86_400

    private func status(success: Bool = false, failure: Bool = false) -> HistoricalSyncStatus {
        HistoricalSyncStatus(primary: "x", savedHistory: nil, isCurrentSuccess: success, isFailure: failure)
    }

    func testOnlyAFreshSyncIsGood() {
        XCTAssertEqual(SyncStatusTone.of(status(success: true), newestHistoryAt: now - 60, now: now), .good)
    }

    func testAnOfflineStrapWithRecentHistoryIsQuiet() {
        XCTAssertEqual(SyncStatusTone.of(status(), newestHistoryAt: now - day, now: now), .quiet)
        XCTAssertEqual(SyncStatusTone.of(status(), newestHistoryAt: now - 2 * day, now: now), .quiet)
    }

    func testHistoryOlderThanTwoDaysNeedsAttention() {
        XCTAssertEqual(SyncStatusTone.of(status(), newestHistoryAt: now - 2 * day - 1, now: now), .attention)
        XCTAssertEqual(SyncStatusTone.of(status(), newestHistoryAt: now - 400 * day, now: now), .attention)
    }

    func testNeverSyncedIsQuietNotAlarming() {
        XCTAssertEqual(SyncStatusTone.of(status(), newestHistoryAt: nil, now: now), .quiet)
    }

    func testAFailureNeedsAttentionWhateverTheHistory() {
        XCTAssertEqual(SyncStatusTone.of(status(failure: true), newestHistoryAt: now, now: now), .attention)
        XCTAssertEqual(SyncStatusTone.of(status(failure: true), newestHistoryAt: nil, now: now), .attention)
    }
}
