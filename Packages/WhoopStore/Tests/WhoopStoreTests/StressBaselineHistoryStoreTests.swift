import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class StressBaselineHistoryStoreTests: XCTestCase {
    private let window = StressBaselineHourWindow(startTs: 100, endTs: 3_700)

    func testSourceUnionUsesActiveSecondAndMeasuredBeforePPG() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(
            hr: [.init(ts: 100, bpm: 60)],
            ppgHr: [.init(ts: 100, bpm: 110, conf: 1), .init(ts: 101, bpm: 70, conf: 1)]), deviceId: "active")
        _ = try await store.insert(Streams(hr: [
            .init(ts: 100, bpm: 120), .init(ts: 101, bpm: 120), .init(ts: 102, bpm: 80),
        ]), deviceId: "canonical")
        let result = try await store.stressBaselineHourSummaries(
            deviceIds: ["active", "canonical", "active"], windows: [window])
        XCTAssertEqual(result, [.init(startTs: 100, sampleCount: 3, meanHR: 70)])
        let reversed = try await store.stressBaselineHourSummaries(
            deviceIds: ["canonical", "active"], windows: [window])
        XCTAssertEqual(try XCTUnwrap(reversed.first).meanHR, 320.0 / 3, accuracy: 1e-9)
    }

    func testHalfOpenBoundsAndInvalidHeartRatesDoNotContribute() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(hr: [
            .init(ts: 99, bpm: 100), .init(ts: 100, bpm: 60), .init(ts: 101, bpm: 0),
            .init(ts: 102, bpm: 255), .init(ts: 3_699, bpm: 80), .init(ts: 3_700, bpm: 120),
        ]), deviceId: "active")
        let result = try await store.stressBaselineHourSummaries(deviceIds: ["active"], windows: [window])
        XCTAssertEqual(result, [.init(startTs: 100, sampleCount: 2, meanHR: 70)])
    }

    func testMultipleHourFragmentsAndQuotedSourceIDsUseBoundArguments() async throws {
        let store = try await WhoopStore.inMemory()
        let active = "active' strap"
        _ = try await store.insert(Streams(hr: [
            .init(ts: 100, bpm: 60), .init(ts: 3_699, bpm: 80),
            .init(ts: 3_700, bpm: 90), .init(ts: 7_299, bpm: 110),
        ]), deviceId: active)
        _ = try await store.insert(Streams(hr: [.init(ts: 100, bpm: 200)]), deviceId: "canonical")

        let result = try await store.stressBaselineHourSummaries(
            deviceIds: [active, "canonical"], windows: [
                window,
                .init(startTs: 3_700, endTs: 7_300),
                .init(startTs: 7_300, endTs: 10_900),
            ])
        XCTAssertEqual(result, [
            .init(startTs: 100, sampleCount: 2, meanHR: 70),
            .init(startTs: 3_700, sampleCount: 2, meanHR: 100),
        ])
    }

    func testInsertCorrectionAndDeletionAreReadWithoutAStaleHistoryCache() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(hr: [.init(ts: 100, bpm: 60), .init(ts: 101, bpm: 80)]), deviceId: "active")
        let original = try await store.stressBaselineHourSummaries(deviceIds: ["active"], windows: [window])
        try await store.correctStressHistoryForTest(bpm: 100, ts: 100)
        let corrected = try await store.stressBaselineHourSummaries(deviceIds: ["active"], windows: [window])
        XCTAssertEqual(corrected.first?.sampleCount, original.first?.sampleCount)
        XCTAssertEqual(corrected.first?.meanHR, 90)
        try await store.deleteStressHistoryForTest(ts: 100)
        let deleted = try await store.stressBaselineHourSummaries(deviceIds: ["active"], windows: [window])
        XCTAssertEqual(deleted.first?.sampleCount, 1)
        XCTAssertEqual(deleted.first?.meanHR, 80)
    }

    func testRejectsAnUnboundedOrOverlappingRead() async throws {
        let store = try await WhoopStore.inMemory()
        do {
            _ = try await store.stressBaselineHourSummaries(
                deviceIds: ["active"], windows: [.init(startTs: 0, endTs: 30 * 86_400)])
            XCTFail("An unbounded raw history read must be rejected")
        } catch StressBaselineHistoryReadError.invalidWindow {}
        do {
            _ = try await store.stressBaselineHourSummaries(deviceIds: ["active"], windows: [window, window])
            XCTFail("Overlapping hours would double-count samples")
        } catch StressBaselineHistoryReadError.invalidWindow {}
    }

    func testCancelledCallerStopsBeforeReadingHistory() async throws {
        let store = try await WhoopStore.inMemory()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.stressBaselineHourSummaries(
                deviceIds: ["active"], windows: [StressBaselineHourWindow(startTs: 100, endTs: 3_700)])
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled read must not be returned as missing history")
        } catch is CancellationError {}
    }
}

private extension WhoopStore {
    func correctStressHistoryForTest(bpm: Int, ts: Int) throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE hrSample SET bpm = ? WHERE deviceId = 'active' AND ts = ?", arguments: [bpm, ts])
        }
    }

    func deleteStressHistoryForTest(ts: Int) throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM hrSample WHERE deviceId = 'active' AND ts = ?", arguments: [ts])
        }
    }
}
