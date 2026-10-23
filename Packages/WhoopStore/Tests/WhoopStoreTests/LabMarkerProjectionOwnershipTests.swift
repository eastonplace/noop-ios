import XCTest
import GRDB
@testable import WhoopStore

final class LabMarkerProjectionOwnershipTests: XCTestCase {
    private func marker(_ id: String, device: String, time: Int, value: Double) -> LabMarkerRow {
        LabMarkerRow(id: id, deviceId: device, markerKey: "ldl", category: "bloodPanel",
                     day: "2026-06-01", takenAt: time, value: value, valueText: nil,
                     unit: "mmol/L", source: "manual", note: nil, referenceText: nil)
    }

    private func projected(_ store: WhoopStore) async throws -> [MetricPoint] {
        try await store.metricSeries(deviceId: WhoopStore.labBookSourceId, key: "ldl",
                                     from: "2026-06-01", to: "2026-06-01")
    }

    func testDeletingOnlyOwnerRemovesLabBookProjectionInSameStoreOperation() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertLabMarkers([marker("a", device: "my-whoop", time: 200, value: 3.4)])
        try await store.deleteAllData(deviceId: "my-whoop")
        let raw = try await store.labMarkers(deviceId: "my-whoop", markerKey: "ldl")
        let values = try await projected(store)
        XCTAssertTrue(raw.isEmpty)
        XCTAssertTrue(values.isEmpty, "The shared lab-book projection must not retain a deleted owner's private reading")
    }

    func testLifecyclePrivacyDeleteReprojectsTheSurvivingOwnersReading() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertLabMarkers([marker("other", device: "other-source", time: 100, value: 2.8)])
        try await store.upsertLabMarkers([marker("deleted", device: "my-whoop", time: 200, value: 3.4)])
        _ = try await store.commitSourceLifecycleMutation(.deleteData(deviceId: "my-whoop", consumerId: "lab-test"))
        let values = try await projected(store)
        XCTAssertEqual(values.map(\.value), [2.8], "Keep a surviving owner's evidence; never retain the deleted owner's value")
        let other = try await store.labMarkers(deviceId: "other-source", markerKey: "ldl")
        XCTAssertEqual(other.count, 1)
    }

    func testDeletingOneMarkerReprojectsAcrossOwnersRatherThanDroppingSharedCell() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertLabMarkers([marker("other", device: "other-source", time: 100, value: 2.8)])
        try await store.upsertLabMarkers([marker("deleted", device: "my-whoop", time: 200, value: 3.4)])
        _ = try await store.deleteLabMarker(id: "deleted")
        let values = try await projected(store)
        XCTAssertEqual(values.map(\.value), [2.8])
    }

    func testSharedProjectionUsesLatestNumericReadingAcrossOwners() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertLabMarkers([marker("later", device: "my-whoop", time: 200, value: 3.4)])
        try await store.upsertLabMarkers([marker("older", device: "other-source", time: 100, value: 2.8)])
        let values = try await projected(store)
        XCTAssertEqual(values.map(\.value), [3.4], "Writing an older reading from a different device must not replace the latest shared value")
    }
    func testChangedDayReprojectsOldAndNewCells() async throws {
        let store = try await WhoopStore.inMemory()
        let original = marker("a", device: "my-whoop", time: 200, value: 3.4)
        try await store.upsertLabMarkers([original])
        var moved = original
        moved.day = "2026-06-02"
        try await store.upsertLabMarkers([moved])
        let old = try await projected(store)
        let new = try await store.metricSeries(deviceId: WhoopStore.labBookSourceId, key: "ldl",
                                               from: "2026-06-02", to: "2026-06-02")
        XCTAssertTrue(old.isEmpty)
        XCTAssertEqual(new.map(\.value), [3.4])
    }

    func testBothPrivacyDeletionPathsRollbackRawRowsAndEpochWhenProjectionCleanupFails() async throws {
        for useLifecycle in [false, true] {
            let store = try await WhoopStore.inMemory()
            try await store.upsertLabMarkers([marker("a", device: "my-whoop", time: 200, value: 3.4)])
            let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
            let epoch = try registry.historyCursorEpoch(for: "my-whoop")
            try await store.registryWriter.write { db in
                try db.execute(sql: """
                    CREATE TRIGGER reject_lab_projection_delete BEFORE DELETE ON metricSeries
                    WHEN OLD.deviceId = 'lab-book'
                    BEGIN SELECT RAISE(ABORT, 'simulated lab projection failure'); END
                    """)
            }
            do {
                if useLifecycle {
                    _ = try await store.commitSourceLifecycleMutation(.deleteData(deviceId: "my-whoop", consumerId: "lab-test"))
                } else {
                    try await store.deleteAllData(deviceId: "my-whoop")
                }
                XCTFail("A projection cleanup failure must fail the whole privacy transaction")
            } catch {}
            let raw = try await store.labMarkers(deviceId: "my-whoop", markerKey: "ldl")
            XCTAssertEqual(raw.count, 1)
            XCTAssertEqual(try registry.historyCursorEpoch(for: "my-whoop"), epoch)
            let values = try await projected(store)
            XCTAssertEqual(values.map(\.value), [3.4])
        }
    }

}
