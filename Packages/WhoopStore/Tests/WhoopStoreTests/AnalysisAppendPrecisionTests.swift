import Foundation
import GRDB
import SQLite3
import XCTest
import WhoopProtocol
@testable import WhoopStore

final class AnalysisAppendPrecisionTests: XCTestCase {
    private let midnight = 1_772_323_200
    private let tables = ["hrSample", "rrInterval", "gravitySample"]

    private func key(_ witness: AnalysisInputWitness, from: Int, to: Int,
                     tables: [String]? = nil) -> String {
        witness.dayScanSignature(tables: tables ?? self.tables, from: from, to: to)
    }

    private func append(_ store: WhoopStore, table: String, ts: Int, owner: String = "append-a") async throws {
        var streams = Streams()
        switch table {
        case "hrSample": streams.hr = [HRSample(ts: ts, bpm: 55)]
        case "rrInterval": streams.rr = [RRInterval(ts: ts, rrMs: 900)]
        case "gravitySample": streams.gravity = [GravitySample(ts: ts, x: 0.1, y: 0, z: 1)]
        default: XCTFail("unexpected fixture family")
        }
        _ = try await store.insert(streams, deviceId: owner)
    }

    func testTrustedAppendsOnlyInvalidateIntersectingHoursAcrossAllSources() async throws {
        for table in tables {
            let store = try await WhoopStore.inMemory()
            let before = try await store.analysisInputWitness()
            try await append(store, table: table, ts: midnight + 17 * 3_600, owner: "another-source")
            let after = try await store.analysisInputWitness()
            XCTAssertEqual(key(before, from: midnight - 30 * 3_600, to: midnight),
                           key(after, from: midnight - 30 * 3_600, to: midnight), table)
            XCTAssertNotEqual(key(before, from: midnight - 30 * 3_600, to: midnight + 86_399),
                              key(after, from: midnight - 30 * 3_600, to: midnight + 86_399), table)
            XCTAssertNotEqual(before.signature(tables: [table]), after.signature(tables: [table]),
                              "the whole-pass idle fence remains table-wide")
            try await store.close()
        }
    }

    func testInclusiveBoundariesAndDSTFractionalWindowsNeverMissAnAppend() async throws {
        let cases = [("UTC", "2026-03-08T12:00:00Z"),
                     ("America/New_York", "2026-03-08T12:00:00Z"),
                     ("America/New_York", "2026-11-01T12:00:00Z"),
                     ("Asia/Kathmandu", "2026-03-08T12:00:00Z"),
                     ("Australia/Lord_Howe", "2026-10-04T12:00:00Z")]
        for (zone, isoDate) in cases {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            let reference = try XCTUnwrap(ISO8601DateFormatter().date(from: isoDate))
            let startDate = calendar.startOfDay(for: reference)
            let endDate = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: startDate))
            let from = Int(startDate.timeIntervalSince1970) - 30 * 3_600
            let to = Int(endDate.timeIntervalSince1970)
            for table in tables {
                for timestamp in [from, to] {
                    let store = try await WhoopStore.inMemory()
                    let before = try await store.analysisInputWitness()
                    try await append(store, table: table, ts: timestamp)
                    let after = try await store.analysisInputWitness()
                    XCTAssertNotEqual(key(before, from: from, to: to), key(after, from: from, to: to),
                                      "\(zone) \(table) inclusive boundary \(timestamp)")
                    try await store.close()
                }
                let store = try await WhoopStore.inMemory()
                let before = try await store.analysisInputWitness()
                try await append(store, table: table, ts: to + 3_600)
                let after = try await store.analysisInputWitness()
                XCTAssertEqual(key(before, from: from, to: to), key(after, from: from, to: to),
                               "\(zone) \(table) later nonintersecting hour")
                try await store.close()
            }
        }
        for table in tables {
            let store = try await WhoopStore.inMemory()
            let before = try await store.analysisInputWitness()
            try await append(store, table: table, ts: 0)
            let outside = try await store.analysisInputWitness()
            XCTAssertEqual(key(before, from: -3_600, to: -1), key(outside, from: -3_600, to: -1),
                           "negative timestamps must floor to the prior UTC hour")
            try await append(store, table: table, ts: -1)
            let inside = try await store.analysisInputWitness()
            XCTAssertNotEqual(key(outside, from: -3_600, to: -1), key(inside, from: -3_600, to: -1))
            try await store.close()
        }
    }

    func testRepairsDeletesUnknownSQLAndOtherFamiliesRemainGlobal() async throws {
        let midnight = self.midnight
        let updates = ["hrSample": "bpm=75", "rrInterval": "tsSuspect=1", "gravitySample": "x=2"]
        for table in tables {
            let store = try await WhoopStore.inMemory()
            try await append(store, table: table, ts: midnight + 17 * 3_600)
            let before = try await store.analysisInputWitness()
            try await store.registryWriter.write { db in
                try db.execute(sql: "UPDATE \(table) SET \(updates[table]!)")
            }
            let repaired = try await store.analysisInputWitness()
            XCTAssertNotEqual(key(before, from: midnight - 3_600, to: midnight),
                              key(repaired, from: midnight - 3_600, to: midnight), table)
            try await store.registryWriter.write { db in try db.execute(sql: "DELETE FROM \(table)") }
            let deleted = try await store.analysisInputWitness()
            XCTAssertNotEqual(key(repaired, from: midnight - 3_600, to: midnight),
                              key(deleted, from: midnight - 3_600, to: midnight), table)
            try await store.close()
        }
        let store = try await WhoopStore.inMemory()
        let before = try await store.analysisInputWitness()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('unknown',?,55)",
                           arguments: [midnight + 17 * 3_600])
        }
        let unknown = try await store.analysisInputWitness()
        XCTAssertNotEqual(key(before, from: midnight - 3_600, to: midnight),
                          key(unknown, from: midnight - 3_600, to: midnight))
        _ = try await store.insert(Streams(steps: [StepSample(ts: midnight + 17 * 3_600, counter: 10)]), deviceId: "raw")
        let steps = try await store.analysisInputWitness()
        XCTAssertNotEqual(key(unknown, from: midnight - 3_600, to: midnight, tables: tables + ["stepSample"]),
                          key(steps, from: midnight - 3_600, to: midnight, tables: tables + ["stepSample"]))
        try await store.registryWriter.write { db in try db.notifyChanges(in: .fullDatabase) }
        let notified = try await store.analysisInputWitness()
        XCTAssertNotEqual(key(steps, from: midnight - 3_600, to: midnight),
                          key(notified, from: midnight - 3_600, to: midnight))
        try await store.close()
    }

    func testRRProvenanceAndHRCorroboratedQualityUpdatesCannotBeClassifiedAsAppends() async throws {
        for quality in [false, true] {
            let store = try await WhoopStore.inMemory()
            let ts = midnight + 17 * 3_600
            _ = try await store.insert(Streams(rr: [RRInterval(ts: ts, rrMs: quality ? 500 : 900,
                source: quality ? .whoop5Standard : .legacy)]), deviceId: "raw")
            let before = try await store.analysisInputWitness()
            if quality {
                _ = try await store.insert(Streams(hr: [HRSample(ts: ts, bpm: 55)]), deviceId: "raw")
            } else {
                _ = try await store.insert(Streams(rr: [RRInterval(ts: ts, rrMs: 900, source: .whoop5Standard)]), deviceId: "raw")
            }
            let after = try await store.analysisInputWitness()
            XCTAssertNotEqual(key(before, from: midnight - 3_600, to: midnight),
                              key(after, from: midnight - 3_600, to: midnight), "RR repair quality=\(quality)")
            try await store.close()
        }
    }

    func testPendingRowsAndRetainedHoursHaveOneSharedBoundedCap() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.analysisInputWitness()
        let future = midnight + 17 * 3_600
        var streams = Streams()
        streams.hr = (0..<2_048).map { HRSample(ts: future + $0, bpm: 130) }
        streams.rr = (0..<2_049).map { RRInterval(ts: future + $0, rrMs: 900) }
        _ = try await store.insert(streams, deviceId: "raw")
        let overflow = try await store.analysisInputWitness()
        XCTAssertNotEqual(key(before, from: midnight - 3_600, to: midnight),
                          key(overflow, from: midnight - 3_600, to: midnight), "the shared pending cap must fall back globally")
        try await store.close()

        let retained = try await WhoopStore.inMemory()
        for batch in 0..<4 {
            let count = batch == 3 ? 1_023 : 1_024
            let rows = (0..<count).map { HRSample(ts: future + (batch * 1_024 + $0) * 3_600, bpm: 130) }
            _ = try await retained.insert(Streams(hr: rows), deviceId: "raw")
        }
        let full = try await retained.analysisInputWitness()
        XCTAssertEqual(full.appendRevisions.count, 4_095)
        // One new gravity hour PLUS its motion-day bucket exceeds the combined budget, although
        // each dictionary on its own would still fit. Clearing motion must advance its own fence.
        try await append(retained, table: "gravitySample", ts: future + 4_095 * 3_600)
        let over = try await retained.analysisInputWitness()
        XCTAssertLessThanOrEqual(over.appendRevisions.count + over.gravityRevisions.count, 4_096,
                                 "hour and motion precision share one fixed state budget")
        XCTAssertNotEqual(key(full, from: midnight - 3_600, to: midnight),
                          key(over, from: midnight - 3_600, to: midnight), "retained-hour overflow must not drop the new mutation")
        XCTAssertNotEqual(full.motionSignature(deviceId: "append-a", from: midnight, to: midnight + 86_399),
                          over.motionSignature(deviceId: "append-a", from: midnight, to: midnight + 86_399),
                          "clearing the shared motion state must advance its global fence")
        try await retained.close()
    }

    func testUnsafeAppendSchemasAndImplicitReplacementFallBackGlobally() async throws {
        let midnight = self.midnight
        for variant in ["unique", "generated-rowid", "foreign-key", "trigger", "temp-trigger", "temp-shadow"] {
            let store = try await WhoopStore.inMemory()
            try await store.registryWriter.write { db in
                switch variant {
                case "unique": try db.execute(sql: "CREATE UNIQUE INDEX witnessExtraHR ON hrSample(bpm)")
                case "generated-rowid": try db.execute(sql: "ALTER TABLE hrSample ADD COLUMN rowid INTEGER GENERATED ALWAYS AS (ts) VIRTUAL")
                case "foreign-key": try db.execute(sql: "ALTER TABLE hrSample ADD COLUMN witnessParent TEXT REFERENCES device(id)")
                case "trigger": try db.execute(sql: "CREATE TRIGGER witnessHR AFTER INSERT ON hrSample BEGIN SELECT 1; END")
                case "temp-trigger": try db.execute(sql: "CREATE TEMP TRIGGER witnessHR AFTER INSERT ON main.hrSample BEGIN SELECT 1; END")
                default: try db.execute(sql: "CREATE TEMP TABLE hrSample(deviceId TEXT,ts INTEGER,bpm INTEGER,PRIMARY KEY(deviceId,ts))")
                }
            }
            let before = try await store.analysisInputWitness()
            try await append(store, table: "hrSample", ts: midnight + 17 * 3_600)
            let after = try await store.analysisInputWitness()
            XCTAssertNotEqual(key(before, from: midnight - 3_600, to: midnight),
                              key(after, from: midnight - 3_600, to: midnight), variant)
            try await store.close()
        }
        let store = try await WhoopStore.inMemory()
        try await append(store, table: "hrSample", ts: midnight - 1)
        let before = try await store.analysisInputWitness()
        try await store.registryWriter.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO hrSample(rowid,deviceId,ts,bpm) VALUES(1,'raw',?,75)",
                           arguments: [midnight + 17 * 3_600])
        }
        let replaced = try await store.analysisInputWitness()
        XCTAssertNotEqual(key(before, from: midnight - 3_600, to: midnight),
                          key(replaced, from: midnight - 3_600, to: midnight))
        try await store.close()
    }

    func testForeignWriterAndRollbackKeepTheirGlobalFences() async throws {
        let midnight = self.midnight
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("noop-append-\(UUID()).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let store = try await WhoopStore(path: path)
        let before = try await store.analysisInputWitness()
        let foreign = try DatabaseQueue(path: path)
        try await foreign.write { [midnight = midnight] db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('foreign',?,55)",
                           arguments: [midnight + 17 * 3_600])
        }
        let external = try await store.analysisInputWitness()
        XCTAssertNotEqual(key(before, from: midnight - 3_600, to: midnight),
                          key(external, from: midnight - 3_600, to: midnight))
        enum Stop: Error { case expected }
        do {
            try await store.registryWriter.write { db in
                try db.execute(sql: "UPDATE hrSample SET bpm=75")
                throw Stop.expected
            }
            XCTFail("expected fixture rollback")
        } catch Stop.expected {}
        let rolledBack = try await store.analysisInputWitness()
        XCTAssertEqual(key(external, from: midnight - 3_600, to: midnight),
                       key(rolledBack, from: midnight - 3_600, to: midnight))
        try foreign.close()
        try await store.close()
    }
}
