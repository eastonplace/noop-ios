import XCTest
import WhoopProtocol
import WhoopStore
@testable import NOOP

final class HealthKitWritebackPlannerTests: XCTestCase {
    func testActiveDeviceHeartRateWinsAndActiveOnlyDataIsWritten() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "whoop-new-uuid", mac: nil, name: nil)
        try await store.upsertDevice(id: "my-whoop", mac: nil, name: nil)
        _ = try await store.insert(Streams(hr: [
            HRSample(ts: 120, bpm: 72),
            HRSample(ts: 180, bpm: 74),
        ]), deviceId: "whoop-new-uuid")
        _ = try await store.insert(Streams(hr: [
            HRSample(ts: 120, bpm: 51),
        ]), deviceId: "my-whoop")

        let rows = try await HealthKitWritebackPlanner.heartRateBuckets(
            store: store,
            importedIds: ["whoop-new-uuid", "my-whoop"],
            fromById: ["whoop-new-uuid": 0, "my-whoop": 0],
            to: 300
        )

        XCTAssertEqual(rows.map(\.sourceId), ["whoop-new-uuid", "whoop-new-uuid"])
        XCTAssertEqual(rows.map { Int($0.bucket.bpm) }, [72, 74])
    }

    func testPlannerPropagatesDatabaseReadFailure() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.close()

        do {
            _ = try await HealthKitWritebackPlanner.heartRateBuckets(
                store: store, importedIds: ["my-whoop"],
                fromById: ["my-whoop": 0], to: 300)
            XCTFail("A closed database must not become an empty successful writeback")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
}
