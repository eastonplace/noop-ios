import XCTest
import WhoopProtocol
@testable import WhoopStore

/// The steps estimate's per-day motion cache keys on `gravityFingerprint`: it must move on any insert or delete in the
/// window, stay still for rows outside it or under another device, and read no rows (an index-only answer).
final class GravityFingerprintTests: XCTestCase {
    private func samples(_ range: StrideTo<Int>) -> [GravitySample] {
        range.map { GravitySample(ts: $0, x: 0.1, y: 0.2, z: 0.9) }
    }

    func testAnEmptyWindowIsZeroZero() async throws {
        let store = try await WhoopStore.inMemory()
        let fingerprint = try await store.gravityFingerprint(deviceId: "d", from: 0, to: 1_000)
        XCTAssertEqual(fingerprint.count, 0)
        XCTAssertEqual(fingerprint.maxTs, 0)
    }

    func testCountsAndNewestTimestampInsideTheWindowOnly() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(gravity: samples(stride(from: 100, to: 200, by: 2))), deviceId: "d")
        _ = try await store.insert(Streams(gravity: samples(stride(from: 100, to: 300, by: 1))), deviceId: "other")
        let all = try await store.gravityFingerprint(deviceId: "d", from: 0, to: 1_000)
        XCTAssertEqual(all.count, 50)
        XCTAssertEqual(all.maxTs, 198)
        let inner = try await store.gravityFingerprint(deviceId: "d", from: 150, to: 160)
        XCTAssertEqual(inner.count, 6)
        XCTAssertEqual(inner.maxTs, 160)
        let none = try await store.gravityFingerprint(deviceId: "d", from: 500, to: 600)
        XCTAssertEqual(none.count, 0)
        XCTAssertEqual(none.maxTs, 0)
    }

    func testAnyInsertInTheWindowMovesTheFingerprint() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(gravity: samples(stride(from: 100, to: 200, by: 2))), deviceId: "d")
        let before = try await store.gravityFingerprint(deviceId: "d", from: 0, to: 1_000)
        // A late backfill into the middle of the window: maxTs is unchanged, the count is not.
        _ = try await store.insert(Streams(gravity: [GravitySample(ts: 151, x: 0, y: 0, z: 1)]), deviceId: "d")
        let backfilled = try await store.gravityFingerprint(deviceId: "d", from: 0, to: 1_000)
        XCTAssertEqual(backfilled.maxTs, before.maxTs)
        XCTAssertEqual(backfilled.count, before.count + 1)
        // A fresh append moves both.
        _ = try await store.insert(Streams(gravity: [GravitySample(ts: 400, x: 0, y: 0, z: 1)]), deviceId: "d")
        let appended = try await store.gravityFingerprint(deviceId: "d", from: 0, to: 1_000)
        XCTAssertEqual(appended.maxTs, 400)
        XCTAssertEqual(appended.count, before.count + 2)
    }
}
