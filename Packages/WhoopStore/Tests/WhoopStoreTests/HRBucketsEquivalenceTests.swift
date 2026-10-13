import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// Perf 3: `hrBuckets` walks a bounded range bucket by bucket instead of grouping a UNION ALL of both HR tables
/// (about 1.2 M materialized rows for the 14-day body-clock read). Every bucket it returns must be identical,
/// down to the last bit of the mean and the weakest confidence, to what the grouped query returns.
final class HRBucketsEquivalenceTests: XCTestCase {
    /// Aligned to the hour (and to 2 h), so the fixture's hours are the 3,600 s buckets.
    private let base = 1_779_998_400
    private let device = "my-whoop"

    /// 6 h of fixture. Per 50 s cycle: measured seconds 0..<35, PPG seconds 30..<45 (so 30..<35 have both, 35..<45
    /// are PPG-only fallback seconds and 45..<50 have neither). Hour 2 is measured only, hour 4 is PPG only, and
    /// hour 5 has nothing. Another device's rows must never leak in.
    private func makeStore() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        var hr: [HRSample] = []
        var ppg: [PpgHrSample] = []
        var otherHr: [HRSample] = []
        for t in 0..<(6 * 3_600) {
            let hour = t / 3_600
            let ts = base + t
            let measuredHere: Bool
            let ppgHere: Bool
            switch hour {
            case 2: (measuredHere, ppgHere) = (true, false)
            case 4: (measuredHere, ppgHere) = (false, true)
            case 5: (measuredHere, ppgHere) = (false, false)
            default: (measuredHere, ppgHere) = (t % 50 < 35, (30..<45).contains(t % 50))
            }
            if measuredHere { hr.append(HRSample(ts: ts, bpm: 48 + (t * 7) % 53)) }
            if ppgHere {
                ppg.append(PpgHrSample(ts: ts, bpm: 55 + t % 13, conf: 0.4 + Double(t % 5) * 0.1))
            }
            if t % 7 == 0 { otherHr.append(HRSample(ts: ts, bpm: 200)) }
        }
        _ = try await store.insert(Streams(hr: hr, ppgHr: ppg), deviceId: device)
        _ = try await store.insert(Streams(hr: otherHr), deviceId: "other-strap")
        // The PPG estimate is a REAL in the table: give the fallback seconds fractional values.
        let writer = await store.dbWriter
        let id = device
        try await writer.write { db in
            try db.execute(sql: "UPDATE ppgHrSample SET bpm = bpm + 0.371 * (ts % 5) WHERE deviceId = ?",
                           arguments: [id])
        }
        return store
    }

    private func grouped(_ store: WhoopStore, from: Int, to: Int, bucket: Int) async throws -> [HRBucket] {
        let writer = await store.dbWriter
        let id = device
        return try await writer.read { db in
            try Row.fetchAll(db, sql: WhoopStore.hrBucketsGroupedSQL,
                             arguments: [bucket, bucket, id, from, to, id, from, to, bucket])
                .map { HRBucket(ts: $0["bucket"], bpm: $0["avgBpm"], conf: $0["minConf"] ?? 1.0) }
        }
    }

    private func assertSame(_ store: WhoopStore, from: Int, to: Int, bucket: Int,
                            file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await store.hrBuckets(deviceId: device, from: from, to: to, bucketSeconds: bucket)
        let expected = try await grouped(store, from: from, to: to, bucket: bucket)
        XCTAssertEqual(actual, expected, "from \(from - base) to \(to - base) bucket \(bucket)", file: file, line: line)
    }

    func testBucketWalkMatchesTheGroupedQueryAcrossSizesAndWindows() async throws {
        let store = try await makeStore()
        for bucket in [1, 7, 60, 300, 900, 3_600, 7_200, 100_000] {
            // Whole fixture, aligned and mid-bucket starts, a window inside one bucket, a single second, and a
            // window past the data.
            try await assertSame(store, from: base, to: base + 6 * 3_600, bucket: bucket)
            try await assertSame(store, from: base + 17, to: base + 5 * 3_600 - 3, bucket: bucket)
            try await assertSame(store, from: base + 1_234, to: base + 1_300, bucket: bucket)
            try await assertSame(store, from: base + 77, to: base + 77, bucket: bucket)
            try await assertSame(store, from: base + 7 * 3_600, to: base + 8 * 3_600, bucket: bucket)
        }
    }

    func testMeasuredOnlyPpgOnlyMixedAndEmptyHoursAreEachCovered() async throws {
        let store = try await makeStore()
        let hourly = try await store.hrBuckets(deviceId: device, from: base, to: base + 6 * 3_600, bucketSeconds: 3_600)
        let byHour = Dictionary(uniqueKeysWithValues: hourly.map { (($0.ts - base) / 3_600, $0) })
        XCTAssertEqual(byHour[2]?.conf, 1.0, "a measured-only hour reads as clean")
        XCTAssertLessThan(byHour[4]?.conf ?? 1.0, 1.0, "a PPG-only hour carries its weakest confidence")
        XCTAssertLessThan(byHour[0]?.conf ?? 1.0, 1.0, "a hour with PPG fallback seconds is weak")
        XCTAssertNotNil(byHour[3])
        XCTAssertNil(byHour[5], "an hour with no heart rate has no bucket")
    }

    func testAnotherDevicesRowsNeverReachABucket() async throws {
        let store = try await makeStore()
        let buckets = try await store.hrBuckets(deviceId: device, from: base, to: base + 6 * 3_600, bucketSeconds: 900)
        XCTAssertFalse(buckets.isEmpty)
        XCTAssertTrue(buckets.allSatisfy { $0.bpm < 150 })
    }

    func testNegativeWideAndReversedRangesKeepTheGroupedQuery() async throws {
        let store = try await makeStore()
        try await assertSame(store, from: -5_000, to: base + 3_600, bucket: 3_600)
        try await assertSame(store, from: 0, to: 2_000_000_000, bucket: 60)
        try await assertSame(store, from: base + 3_600, to: base, bucket: 300)
        let reversed = try await store.hrBuckets(deviceId: device, from: base + 3_600, to: base, bucketSeconds: 300)
        XCTAssertTrue(reversed.isEmpty)
    }

    func testBucketSizeBelowOneIsTreatedAsOneSecond() async throws {
        let store = try await makeStore()
        let zero = try await store.hrBuckets(deviceId: device, from: base, to: base + 200, bucketSeconds: 0)
        let one = try await store.hrBuckets(deviceId: device, from: base, to: base + 200, bucketSeconds: 1)
        XCTAssertEqual(zero, one)
    }

    /// The per-bucket statements search the `(deviceId, ts)` index: no table scan and no temp b-tree to group or sort.
    func testBucketStatementsSearchTheIndexWithoutATempTable() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        try await writer.read { db in
            func plan(_ sql: String, _ arguments: StatementArguments) throws -> String {
                try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN \(sql)", arguments: arguments)
                    .compactMap { $0["detail"] as String? }
                    .joined(separator: "\n")
            }
            let measured = try plan(WhoopStore.hrBucketMeasuredSQL, ["d", 0, 100])
            let presence = try plan(WhoopStore.hrBucketsPpgPresenceSQL, ["d", 0, 100])
            let fallback = try plan(WhoopStore.hrBucketFallbackCountSQL, ["d", 0, 100])
            for text in [measured, presence, fallback] {
                let scans = text.split(separator: "\n").filter { line in
                    // "SCAN CONSTANT ROW" is the one-row SELECT around an EXISTS, not a table.
                    line.hasPrefix("SCAN ") && !line.hasPrefix("SCAN CONSTANT ROW")
                }
                XCTAssertTrue(scans.isEmpty, "a table scan: \(text)")
                XCTAssertFalse(text.contains("TEMP B-TREE"), text)
                XCTAssertTrue(text.contains("SEARCH"), text)
            }
            XCTAssertTrue(measured.contains("hrSample USING"), measured)
            XCTAssertTrue(fallback.contains("ppgHrSample USING") || fallback.contains("SEARCH p USING"), fallback)
        }
    }
}
