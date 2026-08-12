import Combine
import XCTest
@testable import NOOP

@MainActor
final class DeviceCommandCenterLiveSnapshotTests: XCTestCase {
    func testPublishesSelectedChangesButIgnoresUnrelatedAndDuplicateLiveValues() {
        let live = LiveState()
        let snapshot = DeviceCommandCenterLiveSnapshot(live: live)
        var publicationCount = 0
        let cancellable = snapshot.objectWillChange.sink { publicationCount += 1 }

        live.heartRate = 142
        XCTAssertEqual(publicationCount, 0)

        live.connected = true
        XCTAssertEqual(snapshot.value.connected, true)
        XCTAssertEqual(publicationCount, 1)

        live.connected = true
        XCTAssertEqual(publicationCount, 1)

        withExtendedLifetime(cancellable) {}
    }

    func testTracksManuallyPublishedChunkCountAndDurablePassReceipt() {
        let live = LiveState()
        let snapshot = DeviceCommandCenterLiveSnapshot(live: live)

        live.syncChunksThisSession = 4
        XCTAssertEqual(snapshot.value.syncChunksThisSession, 4)

        let progress = HistoricalSyncPassProgress(
            rowsPersisted: 412,
            passNumber: 3,
            latestFrontierUnix: 1_753_824_120,
            publishedAt: 1_753_824_121)
        live.publishHistoricalSyncProgress(progress)

        XCTAssertEqual(snapshot.value.historicalSyncPassProgress, progress)
    }
}
