import XCTest
import GRDB
import WhoopProtocol
import OuraProtocol
@testable import WhoopStore

final class RRSourcePolicyTests: XCTestCase {
    func testWholeWindowSelectsHistoryBeforeLimitAndPreservesEqualBeats() async throws {
        let store = try await WhoopStore.inMemory()
        let duplicateTransport = (0..<30).map { RRInterval(ts: $0, rrMs: 879, source: .whoop5Realtime) }
        let historical = (0..<8).map { RRInterval(ts: 100, rrMs: 900, sourceOrdinal: $0, source: .whoop5Historical) }
        let standard = [RRInterval(ts: 99, rrMs: 901, source: .whoop5Standard)]
        _ = try await store.insert(Streams(rr: duplicateTransport + standard + historical), deviceId: "test")
        let rows = try await store.rrIntervals(deviceId: "test", from: 0, to: 200, limit: 5)
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.rrMs), Array(repeating: 900, count: 5))
        XCTAssertTrue(rows.allSatisfy { $0.source == .whoop5Historical })
        let snapshot = try await store.analysisDayBundle(deviceId: "test", from: 0, to: 200, limit: 5)
        XCTAssertEqual(snapshot.rr, rows)
    }

    func testRealtimeOnlyIsRetainedButNotScoredAndStandardIsFallback() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 1, rrMs: 800, source: .whoop5Realtime)]), deviceId: "test")
        let unavailable = try await store.rrIntervals(deviceId: "test", from: 0, to: 10, limit: 10)
        XCTAssertTrue(unavailable.isEmpty)
        _ = try await store.insert(Streams(rr: [RRInterval(ts: 2, rrMs: 801, source: .whoop5Standard)]), deviceId: "test")
        let rows = try await store.rrIntervals(deviceId: "test", from: 0, to: 10, limit: 10)
        XCTAssertEqual(rows.map(\.rrMs), [801])
    }

    func testOuraChannelIsStoredAndRedTrainDoesNotReachScoring() async throws {
        let store = try await WhoopStore.inMemory()
        let events: [OuraEvent] = [
            .ibi(OuraIBI(ringTimestamp: 1, ibiMs: 800, channel: .spo2Ibi)),
            .ibi(OuraIBI(ringTimestamp: 1, ibiMs: 803, channel: .greenQuality)),
            .ibi(OuraIBI(ringTimestamp: 1, ibiMs: 803, channel: .greenQuality))
        ]
        let streams = OuraStreamMapping.streams(from: events, at: 100)
        XCTAssertEqual(streams.rr.map(\.source), [.ouraSpO2, .ouraGreenQuality, .ouraGreenQuality])
        _ = try await store.insert(streams, deviceId: "ring")
        let rows = try await store.rrIntervals(deviceId: "ring", from: 0, to: 200, limit: 20)
        XCTAssertEqual(rows.map(\.rrMs), [803, 803])
    }

    func testKnownFamilyCannotBeOverriddenByForeignTags() {
        XCTAssertFalse(RRReadPolicy.strictWhoop5(model: "WHOOP 4.0", brand: "WHOOP", tagged: true))
        XCTAssertFalse(RRReadPolicy.strictWhoop5(model: "WHOOP 5.0", brand: "Oura", tagged: true))
        XCTAssertTrue(RRReadPolicy.strictWhoop5(model: "5.0 MG", brand: "WHOOP", tagged: false))
        XCTAssertFalse(RRReadPolicy.strictWhoop5(model: "WHOOP", brand: "WHOOP", tagged: false))
    }

    func testNumericChannelMigrationPreservesPrimaryKeyAndOrdinal() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE rrInterval(deviceId TEXT, ts INTEGER, rrMs INTEGER, seq INTEGER, srcChannel INTEGER, ord INTEGER, PRIMARY KEY(deviceId, ts, rrMs, seq))")
            for channel in 1...7 {
                try db.execute(sql: "INSERT INTO rrInterval VALUES ('test', ?, 800, 0, ?, ?)", arguments: [channel, channel, channel + 2])
            }
        }
        var migrator = DatabaseMigrator()
        RRSourceMigration.register(on: &migrator)
        try migrator.migrate(queue)
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT source, sourceOrdinal FROM rrInterval ORDER BY ts")
            XCTAssertEqual(rows.map { $0["source"] as String }, (1...7).map { RRSource.legacyChannel($0).rawValue })
            XCTAssertEqual(rows.map { $0["sourceOrdinal"] as Int }, Array(3...9))
            XCTAssertEqual(try db.primaryKey("rrInterval").columns, ["deviceId", "ts", "rrMs", "seq"])
        }
    }
}
