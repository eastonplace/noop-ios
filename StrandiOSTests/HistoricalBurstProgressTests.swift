import XCTest
@testable import NOOP

final class HistoricalBurstProgressTests: XCTestCase {
    func testAutoContinuedSessionResetKeepsProgressMonotonic() {
        var progress = HistoricalBurstProgress()

        XCTAssertEqual(progress.record(sessionCount: 0, at: 0), 0)
        XCTAssertEqual(progress.record(sessionCount: 5, at: 1), 5)
        XCTAssertEqual(progress.record(sessionCount: 0, at: 2), 5)
        XCTAssertEqual(progress.record(sessionCount: 1, at: 3), 6)
        XCTAssertEqual(progress.record(sessionCount: 4, at: 4), 9)
    }

    func testDurableBurstPublicationResetsTheNextSync() {
        var progress = HistoricalBurstProgress()
        _ = progress.record(sessionCount: 7, at: 1)
        _ = progress.record(sessionCount: 0, at: 2)
        _ = progress.record(sessionCount: 3, at: 3)

        progress.markFinalized()

        XCTAssertEqual(progress.record(sessionCount: 0, at: 4), 0)
        XCTAssertEqual(progress.record(sessionCount: 2, at: 5), 2)
    }

    func testLongGapSeparatesEmptyPeriodicBurstsWithoutPublicationEdge() {
        var progress = HistoricalBurstProgress()
        _ = progress.record(sessionCount: 4, at: 0)
        _ = progress.record(sessionCount: 0, at: 1)
        XCTAssertEqual(progress.record(sessionCount: 2, at: 2), 6)

        let later = HistoricalBurstProgress.newBurstGapSeconds + 3
        XCTAssertEqual(progress.record(sessionCount: 0, at: later), 0)
        XCTAssertEqual(progress.record(sessionCount: 1, at: later + 1), 1)
    }

    @MainActor
    func testLiveStatePublishesCumulativeCountThroughExistingUISurface() {
        let live = LiveState()

        live.syncChunksThisSession = 0
        live.syncChunksThisSession = 5
        live.syncChunksThisSession = 0
        live.syncChunksThisSession = 2
        XCTAssertEqual(live.syncChunksThisSession, 7)

        live.backfillDataAvailableAt = 100
        live.syncChunksThisSession = 0
        XCTAssertEqual(live.syncChunksThisSession, 0)
    }
}
