import Combine
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

    @MainActor
    func testAutoContinuationResetDoesNotEmitAVisibleZero() {
        let live = LiveState()
        var publications = 0
        let cancellable = live.objectWillChange.sink { publications += 1 }

        live.syncChunksThisSession = 5
        XCTAssertEqual(live.syncChunksThisSession, 5)
        XCTAssertEqual(publications, 1)

        // BLEManager begins the next auto-continued session by assigning its local count (zero). The public
        // cumulative count and publisher must stay unchanged—no brief Home/Sleep reset before the next ACK.
        live.syncChunksThisSession = 0
        XCTAssertEqual(live.syncChunksThisSession, 5)
        XCTAssertEqual(publications, 1)

        live.syncChunksThisSession = 1
        XCTAssertEqual(live.syncChunksThisSession, 6)
        XCTAssertEqual(publications, 2)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testPersistedPassProgressDoesNotRequireBurstFinalization() {
        let live = LiveState()
        let progress = HistoricalSyncPassProgress(rowsPersisted: 120, passNumber: 1,
                                                  latestFrontierUnix: 1_000, publishedAt: 10)

        live.publishHistoricalSyncProgress(progress)

        XCTAssertEqual(live.historicalSyncPassProgress, progress)
        XCTAssertNil(live.backfillDataAvailableAt)
    }

    @MainActor
    func testBurstFinalizationPublishesDurableEdgeThenClearsPassProgress() {
        let live = LiveState()
        let progress = HistoricalSyncPassProgress(rowsPersisted: 120, passNumber: 1,
                                                  latestFrontierUnix: 1_000, publishedAt: 10)
        live.publishHistoricalSyncProgress(progress)

        live.finalizeHistoricalSyncBurst(at: 20)

        XCTAssertEqual(live.backfillDataAvailableAt, 20)
        XCTAssertNil(live.historicalSyncPassProgress)
    }

    @MainActor
    func testDisconnectClearsPassProgress() {
        let live = LiveState()
        live.publishHistoricalSyncProgress(
            HistoricalSyncPassProgress(rowsPersisted: 120, passNumber: 1,
                                       latestFrontierUnix: 1_000, publishedAt: 10))

        live.markDisconnected()

        XCTAssertNil(live.historicalSyncPassProgress)
    }
}
