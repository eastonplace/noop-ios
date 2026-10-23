import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

final class ReadTests: XCTestCase {
    private func seeded() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: "dev1", mac: nil, name: nil)
        try await store.upsertDevice(id: "other", mac: nil, name: nil)
        let s = Streams(
            hr: [HRSample(ts: 100, bpm: 60), HRSample(ts: 200, bpm: 61),
                 HRSample(ts: 300, bpm: 62)],
            rr: [RRInterval(ts: 100, rrMs: 800), RRInterval(ts: 100, rrMs: 820)],
            events: [WhoopEvent(ts: 150, kind: "BLE_CONNECTION_DOWN(12)",
                                payload: ["k": .int(9)])],
            battery: [BatterySample(ts: 120, soc: 88.0, mv: 3900)])
        _ = try await store.insert(s, deviceId: "dev1")
        // Decoy on another device — must never appear in dev1 reads.
        _ = try await store.insert(Streams(hr: [HRSample(ts: 200, bpm: 99)]), deviceId: "other")
        return store
    }

    func testHrSamplesRangeOrderLimitAndDeviceScope() async throws {
        let store = try await seeded()
        let all = try await store.hrSamples(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(all, [HRSample(ts: 100, bpm: 60), HRSample(ts: 200, bpm: 61),
                             HRSample(ts: 300, bpm: 62)])
        let windowed = try await store.hrSamples(deviceId: "dev1", from: 150, to: 250, limit: 100)
        XCTAssertEqual(windowed, [HRSample(ts: 200, bpm: 61)])     // inclusive range
        let limited = try await store.hrSamples(deviceId: "dev1", from: 0, to: 1000, limit: 2)
        XCTAssertEqual(limited.count, 2)                            // ascending, first 2
        XCTAssertEqual(limited.first?.ts, 100)
    }

    // #836 — the idle-tick gate's change-detector: (count, maxTs) scoped to the device + window, no rows.
    func testHrFingerprintCountMaxTsRangeAndDeviceScope() async throws {
        let store = try await seeded()
        // dev1 has hr ts 100/200/300 → full window is (count 3, maxTs 300).
        let full = try await store.hrFingerprint(deviceId: "dev1", from: 0, to: 1000)
        XCTAssertEqual(full.count, 3)
        XCTAssertEqual(full.maxTs, 300)
        // Inclusive sub-window [150,250] sees only ts 200 → (1, 200).
        let windowed = try await store.hrFingerprint(deviceId: "dev1", from: 150, to: 250)
        XCTAssertEqual(windowed.count, 1)
        XCTAssertEqual(windowed.maxTs, 200)
        // The decoy on "other" (single ts 200) is device-scoped, never folded into dev1.
        let other = try await store.hrFingerprint(deviceId: "other", from: 0, to: 1000)
        XCTAssertEqual(other.count, 1)
        XCTAssertEqual(other.maxTs, 200)
        // Empty window COALESCEs to (0, 0), never nil.
        let empty = try await store.hrFingerprint(deviceId: "dev1", from: 5000, to: 6000)
        XCTAssertEqual(empty.count, 0)
        XCTAssertEqual(empty.maxTs, 0)
    }

    func testHrFingerprintAndBoundsIncludePpgFallbackWithoutDoubleCountingMeasuredSeconds() async throws {
        let store = try await seeded()
        _ = try await store.insert(
            Streams(ppgHr: [
                PpgHrSample(ts: 50, bpm: 58, conf: 0.8),
                PpgHrSample(ts: 100, bpm: 99, conf: 0.8),
                PpgHrSample(ts: 400, bpm: 63, conf: 0.8),
            ]),
            deviceId: "dev1")

        let fingerprint = try await store.hrFingerprint(deviceId: "dev1", from: 0, to: 1_000)
        XCTAssertEqual(fingerprint.count, 5)
        XCTAssertEqual(fingerprint.maxTs, 400)
        let storedBounds = try await store.hrTimestampBounds(deviceId: "dev1")
        let bounds = try XCTUnwrap(storedBounds)
        XCTAssertEqual(bounds.earliest, 50)
        XCTAssertEqual(bounds.latest, 400)
        let missingBounds = try await store.hrTimestampBounds(deviceId: "missing")
        XCTAssertNil(missingBounds)
    }

    /// Review round 7 (2): only plausible beats count, PPG fills seconds with no measured row, and the cap bounds
    /// the count.
    func testPlausibleHrCountSkipsImplausibleBeatsAndStopsAtTheCap() async throws {
        let store = try await seeded()
        _ = try await store.insert(
            Streams(hr: [HRSample(ts: 400, bpm: 0), HRSample(ts: 500, bpm: 250), HRSample(ts: 600, bpm: 30),
                         HRSample(ts: 700, bpm: 240)],
                    ppgHr: [PpgHrSample(ts: 100, bpm: 99, conf: 0.8), PpgHrSample(ts: 800, bpm: 63, conf: 0.8)]),
            deviceId: "dev1")
        // Measured 60/61/62/30/240 plus the PPG second 800; ts 400 (0 bpm) and 500 (250 bpm) are not heart rates,
        // and the PPG row at 100 sits under a measured one.
        let all = try await store.plausibleHRCount(
            deviceId: "dev1", from: 0, to: 1_000, bpmRange: 30...240, cap: 100)
        XCTAssertEqual(all, 6)
        let capped = try await store.plausibleHRCount(
            deviceId: "dev1", from: 0, to: 1_000, bpmRange: 30...240, cap: 4)
        XCTAssertEqual(capped, 4)
        let windowed = try await store.plausibleHRCount(
            deviceId: "dev1", from: 150, to: 450, bpmRange: 30...240, cap: 100)
        XCTAssertEqual(windowed, 2)
        let other = try await store.plausibleHRCount(
            deviceId: "other", from: 0, to: 1_000, bpmRange: 30...240, cap: 100)
        XCTAssertEqual(other, 1)
    }

    func testPlausibleHrCountFiltersPpgFallbackByTheSameBpmRange() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(
            hr: [HRSample(ts: 10, bpm: 0), HRSample(ts: 20, bpm: 70)],
            ppgHr: [
                PpgHrSample(ts: 10, bpm: 65, conf: 0.8), // measured zero still owns this second
                PpgHrSample(ts: 20, bpm: 80, conf: 0.8), // measured second counts once
                PpgHrSample(ts: 40, bpm: 30, conf: 0.8),
                PpgHrSample(ts: 50, bpm: 240, conf: 0.8),
                PpgHrSample(ts: 60, bpm: 241, conf: 0.8),
                PpgHrSample(ts: 70, bpm: 0, conf: 0.8),
            ]), deviceId: "d")
        // The persisted column is REAL even though the current protocol model carries whole bpm.
        // Legacy/foreign rows must be checked in the same rounded domain as hrSamples.
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO ppgHrSample (deviceId, ts, bpm, conf) VALUES
                    ('d', 30, 29.4, 0.8), ('d', 80, 29.6, 0.8), ('d', 90, 240.4, 0.8)
                """)
        }
        let count = try await store.plausibleHRCount(
            deviceId: "d", from: 0, to: 100, bpmRange: 30...240, cap: 100)
        XCTAssertEqual(count, 5)
        let invalidOnly = try await store.plausibleHRCount(
            deviceId: "d", from: 60, to: 70, bpmRange: 30...240, cap: 1)
        XCTAssertEqual(invalidOnly, 0, "invalid fallback rows must not satisfy a coverage gate")
    }

    func testHrBucketsAveragePerBucketOrderedAndDeviceScoped() async throws {
        let store = try await seeded()
        // 200s buckets over dev1's ts 100/200/300 (bpm 60/61/62):
        //   ts100 → bucket 0   → mean 60
        //   ts200, ts300 → bucket 200 → mean (61+62)/2 = 61.5
        let buckets = try await store.hrBuckets(deviceId: "dev1", from: 0, to: 1000, bucketSeconds: 200)
        XCTAssertEqual(buckets, [HRBucket(ts: 0, bpm: 60), HRBucket(ts: 200, bpm: 61.5)])
        // The decoy on "other" (ts200, bpm99) must never bleed into dev1's bucket.
        let other = try await store.hrBuckets(deviceId: "other", from: 0, to: 1000, bucketSeconds: 200)
        XCTAssertEqual(other, [HRBucket(ts: 200, bpm: 99)])
    }

    func testRrIntervalsReturnsBothTiedRows() async throws {
        let store = try await seeded()
        let rr = try await store.rrIntervals(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(rr, [RRInterval(ts: 100, rrMs: 800), RRInterval(ts: 100, rrMs: 820)])
    }

    func testEventsDecodePayload() async throws {
        let store = try await seeded()
        let evs = try await store.events(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(evs, [WhoopEvent(ts: 150, kind: "BLE_CONNECTION_DOWN(12)",
                                        payload: ["k": .int(9)])])
    }

    func testBatterySamples() async throws {
        let store = try await seeded()
        let bat = try await store.batterySamples(deviceId: "dev1", from: 0, to: 1000, limit: 100)
        XCTAssertEqual(bat, [BatterySample(ts: 120, soc: 88.0, mv: 3900)])
    }

    func testStorageStats() async throws {
        let store = try await seeded()
        // Add one of each biometric stream so the count proves all 8 tables are summed.
        _ = try await store.insert(
            Streams(spo2: [SpO2Sample(ts: 400, red: 1, ir: 2)],
                    skinTemp: [SkinTempSample(ts: 400, raw: 930)],
                    resp: [RespSample(ts: 400, raw: 3073)],
                    gravity: [GravitySample(ts: 400, x: 0.1, y: 0.2, z: 0.3)]),
            deviceId: "dev1")
        try await store.enqueueRawBatch(
            RawBatchMeta(batchId: "b1", deviceId: "dev1",
                         clockRef: ClockRef(device: 0, wall: 0), capturedAt: 1,
                         startTs: 0, endTs: 0, frameCount: 1, byteSize: 4),
            frames: [[0xAA, 0x00, 0x01, 0x02]])
        let stats = try await store.storageStats()
        // dev1: 3 hr + 2 rr + 1 event + 1 battery + 1 spo2 + 1 skinTemp + 1 resp + 1 gravity = 11
        // other: 1 hr = 1 → 12 decoded rows across all 8 tables.
        XCTAssertEqual(stats.decodedRows, 12)
        XCTAssertEqual(stats.rawBatches, 1)
        XCTAssertEqual(stats.rawBytes, 4)
    }
}
