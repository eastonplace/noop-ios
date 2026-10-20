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

    func testWearStartsUnknownDespiteDefaultWornValue() {
        let live = LiveState()
        let snapshot = DeviceCommandCenterLiveSnapshot(live: live)

        XCTAssertTrue(live.worn)
        XCTAssertFalse(snapshot.value.wearStateKnown)
    }

    func testOnlyWristTelemetryEstablishesWearAndDisconnectClearsIt() {
        let live = LiveState()
        live.connected = true
        let snapshot = DeviceCommandCenterLiveSnapshot(live: live)
        var publications = 0
        let cancellable = snapshot.objectWillChange.sink { publications += 1 }

        live.heartRate = 126
        live.lastEvent = "DOUBLE_TAP(1)"
        XCTAssertEqual(publications, 0)
        XCTAssertFalse(snapshot.value.wearStateKnown)

        live.lastEvent = "WRIST_ON(2)"
        XCTAssertTrue(snapshot.value.wearStateKnown)
        XCTAssertEqual(publications, 1)

        live.lastEvent = "BATTERY_LEVEL(3)"
        live.heartRate = 128
        XCTAssertTrue(snapshot.value.wearStateKnown)
        XCTAssertEqual(publications, 1)

        live.connected = false
        XCTAssertFalse(snapshot.value.wearStateKnown)
        withExtendedLifetime(cancellable) {}
    }
    func testCachedWristEventFromEarlierConnectionDoesNotEstablishWear() {
        let live = LiveState()
        live.connected = true
        live.lastEvent = "WRIST_ON(2)"
        live.connected = false
        live.clearBiometrics()
        live.connected = true
        let snapshot = DeviceCommandCenterLiveSnapshot(live: live)
        var publications = 0
        let cancellable = snapshot.objectWillChange.sink { publications += 1 }

        XCTAssertEqual(live.lastEvent, "WRIST_ON(2)")
        XCTAssertFalse(snapshot.value.wearStateKnown)
        live.lastEvent = "DOUBLE_TAP(1)"
        live.heartRate = 132
        XCTAssertFalse(snapshot.value.wearStateKnown)
        XCTAssertEqual(publications, 0)

        live.lastEvent = "WRIST_OFF(3)"
        XCTAssertTrue(snapshot.value.wearStateKnown)
        live.connected = false
        XCTAssertFalse(snapshot.value.wearStateKnown)
        live.lastEvent = "WRIST_ON(2)"
        XCTAssertFalse(snapshot.value.wearStateKnown)
        withExtendedLifetime(cancellable) {}
    }

}
