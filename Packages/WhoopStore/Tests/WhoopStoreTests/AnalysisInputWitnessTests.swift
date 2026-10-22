import Foundation
import GRDB
import SQLite3
import XCTest
@testable import WhoopStore
import WhoopProtocol

final class AnalysisInputWitnessTests: XCTestCase {
    private func write(_ store: WhoopStore, _ block: (Database) throws -> Void) throws {
        try store.registryWriter.write(block)
    }

    func testEveryRawFamilyAndSameKeyRepairsMoveTheWitness() async throws {
        let store = try await WhoopStore.inMemory()
        let rows: [(String, String, String)] = [
            ("hrSample", "bpm", "55"), ("rrInterval", "seq,rrMs,source", "0,1000,'legacy'"),
            ("respSample", "raw", "16"), ("gravitySample", "x,y,z", "0,0,1"),
            ("stepSample", "counter", "10"), ("skinTempSample", "raw", "1300"),
            ("spo2Sample", "red,ir", "100,200"), ("event", "kind,payloadJSON", "'WRIST_OFF','{}'"),
            ("sleepStateSample", "state", "1"), ("ppgHrSample", "bpm,conf", "55,0.9")
        ]
        for (table, columns, values) in rows {
            let before = try await store.analysisInputWitness()
            try write(store) { db in
                try db.execute(sql: "INSERT INTO \(table)(deviceId,ts,\(columns)) VALUES('witness-a',1000,\(values))")
            }
            let after = try await store.analysisInputWitness()
            XCTAssertNotEqual(before.signature(tables: [table]), after.signature(tables: [table]), table)
        }
        let before = try await store.analysisInputWitness()
        try write(store) { db in
            try db.execute(sql: "UPDATE hrSample SET bpm=65")
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect=1")
            try db.execute(sql: "UPDATE stepSample SET activityClass=2")
            try db.execute(sql: "UPDATE event SET payloadJSON='{\"repaired\":true}'")
        }
        let after = try await store.analysisInputWitness()
        for table in ["hrSample", "rrInterval", "stepSample", "event"] {
            XCTAssertNotEqual(before.signature(tables: [table]), after.signature(tables: [table]), table)
        }
        try await store.close()
    }

    func testNoOpTransactionAndRollbackCannotAdvanceCommittedInputs() async throws {
        let store = try await WhoopStore.inMemory()
        try write(store) { db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('witness-a',1000,55)")
        }
        let before = try await store.analysisInputWitness()
        try write(store) { db in try db.execute(sql: "UPDATE hrSample SET bpm=65 WHERE 0") }
        let noOp = try await store.analysisInputWitness()
        XCTAssertEqual(before, noOp)
        enum Rollback: Error { case expected }
        XCTAssertThrowsError(try write(store) { db in
            try db.execute(sql: "UPDATE hrSample SET bpm=65")
            throw Rollback.expected
        })
        let rolledBack = try await store.analysisInputWitness()
        XCTAssertEqual(before, rolledBack)
        try await store.close()
    }

    func testUnobservedMixedDirectSQLAndWithoutRowIDInvalidateAllDependencies() async throws {
        let store = try await WhoopStore.inMemory()
        try write(store) { db in
            try db.execute(sql: "CREATE TABLE witnessWithoutRowID(k TEXT PRIMARY KEY,v INTEGER) WITHOUT ROWID")
        }
        let before = try await store.analysisInputWitness()
        try write(store) { db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('witness-a',1000,55)")
            XCTAssertEqual(sqlite3_exec(db.sqliteConnection, "INSERT INTO witnessWithoutRowID VALUES('a',1)", nil, nil, nil), SQLITE_OK)
        }
        let mixed = try await store.analysisInputWitness()
        XCTAssertNotEqual(before.signature(tables: ["respSample"]), mixed.signature(tables: ["respSample"]),
                          "the unobserved write must invalidate even untouched dependency sets")
        try write(store) { db in
            XCTAssertEqual(sqlite3_exec(db.sqliteConnection, "UPDATE hrSample SET bpm=65", nil, nil, nil), SQLITE_OK)
        }
        let direct = try await store.analysisInputWitness()
        XCTAssertNotEqual(mixed.signature(tables: ["respSample"]), direct.signature(tables: ["respSample"]))
        try write(store) { db in
            try db.execute(sql: "SAVEPOINT witness")
            try db.execute(sql: "UPDATE hrSample SET bpm=75")
            try db.execute(sql: "ROLLBACK TO witness")
            try db.execute(sql: "RELEASE witness")
        }
        let savepoint = try await store.analysisInputWitness()
        XCTAssertNotEqual(direct.signature(tables: ["respSample"]), savepoint.signature(tables: ["respSample"]),
                          "a partial rollback may conservatively invalidate globally")
        try write(store) { db in try db.notifyChanges(in: .fullDatabase) }
        let notified = try await store.analysisInputWitness()
        XCTAssertNotEqual(savepoint.signature(tables: ["respSample"]), notified.signature(tables: ["respSample"]))
        try await store.close()
    }

    func testReplaceAndSchemaMutationCannotReuseOldInputs() async throws {
        let store = try await WhoopStore.inMemory()
        try write(store) { db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('witness-a',1000,55)")
        }
        let before = try await store.analysisInputWitness()
        try write(store) { db in
            try db.execute(sql: "INSERT OR REPLACE INTO hrSample(deviceId,ts,bpm) VALUES('witness-a',1000,65)")
        }
        let replaced = try await store.analysisInputWitness()
        XCTAssertNotEqual(before.signature(tables: ["hrSample"]), replaced.signature(tables: ["hrSample"]))
        try write(store) { db in try db.execute(sql: "CREATE TABLE witnessAdded(k INTEGER)") }
        let schema = try await store.analysisInputWitness()
        XCTAssertNotEqual(replaced.signature(tables: ["respSample"]), schema.signature(tables: ["respSample"]))
        try await store.close()
    }

    func testSharedHandlesForeignWriterAndReopenHaveCompleteGenerationFences() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("noop-analysis-witness-\(UUID()).sqlite").path
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }
        let first = try await WhoopStore(path: path)
        let sibling = try await WhoopStore(path: path)
        let before = try await first.analysisInputWitness()
        let siblingBefore = try await sibling.analysisInputWitness()
        XCTAssertEqual(before, siblingBefore, "same pool means the same RAM generation")
        try write(sibling) { db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('witness-a',1000,55)")
        }
        let own = try await first.analysisInputWitness()
        XCTAssertNotEqual(before.signature(tables: ["hrSample"]), own.signature(tables: ["hrSample"]))
        XCTAssertEqual(before.signature(tables: ["respSample"]), own.signature(tables: ["respSample"]),
                       "own commits must not masquerade as a foreign global fence")
        let outside = try DatabaseQueue(path: path)
        try await outside.write { db in try db.execute(sql: "UPDATE hrSample SET bpm=65") }
        let foreign = try await first.analysisInputWitness()
        XCTAssertNotEqual(own.signature(tables: ["respSample"]), foreign.signature(tables: ["respSample"]),
                          "a foreign commit invalidates every dependency set")
        try outside.close()
        try await first.close()
        let reopened = try await WhoopStore(path: path)
        let fresh = try await reopened.analysisInputWitness()
        XCTAssertNotEqual(foreign.signature(tables: []), fresh.signature(tables: []),
                          "reopen/restore must not inherit the old in-memory generation")
        try await reopened.close()
    }

    func testNormalGravityInsertInvalidatesOnlyItsOwnerAndDayButRepairsAreGlobal() async throws {
        let store = try await WhoopStore.inMemory()
        let day = 20_520 * 86_400
        func motion(_ witness: AnalysisInputWitness, _ owner: String, _ from: Int) -> String {
            witness.motionSignature(deviceId: owner, from: from, to: from + 86_399)
        }
        var stream = Streams()
        stream.gravity = [GravitySample(ts: day + 10, x: 0, y: 0, z: 1)]
        let before = try await store.analysisInputWitness()
        _ = try await store.insert(stream, deviceId: "witness-a")
        let inserted = try await store.analysisInputWitness()
        XCTAssertNotEqual(motion(before, "witness-a", day), motion(inserted, "witness-a", day))
        XCTAssertEqual(motion(before, "witness-a", day - 86_400), motion(inserted, "witness-a", day - 86_400))
        XCTAssertEqual(motion(before, "witness-b", day), motion(inserted, "witness-b", day))
        _ = try await store.insert(stream, deviceId: "witness-a")
        let unchanged = try await store.analysisInputWitness()
        XCTAssertEqual(inserted, unchanged, "the actual ingestion upsert is a no-op when values match")
        try write(store) { db in try db.execute(sql: "UPDATE gravitySample SET x=2 WHERE deviceId='witness-a'") }
        let repaired = try await store.analysisInputWitness()
        XCTAssertNotEqual(motion(unchanged, "witness-a", day), motion(repaired, "witness-a", day))
        XCTAssertNotEqual(motion(unchanged, "witness-a", day - 86_400), motion(repaired, "witness-a", day - 86_400))
        try write(store) { db in try db.execute(sql: "DELETE FROM gravitySample") }
        let deleted = try await store.analysisInputWitness()
        XCTAssertNotEqual(motion(repaired, "witness-a", day), motion(deleted, "witness-a", day))
        try await store.close()
    }

    func testGravityRegionOverflowAndPhysicalChangeInvalidateConservatively() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.analysisInputWitness()
        var stream = Streams()
        stream.gravity = (0..<4_097).map { GravitySample(ts: $0, x: 0, y: 0, z: 1) }
        _ = try await store.insert(stream, deviceId: "witness-a")
        let overflow = try await store.analysisInputWitness()
        XCTAssertNotEqual(before.motionSignature(deviceId: "witness-a", from: 86_400, to: 172_799),
                          overflow.motionSignature(deviceId: "witness-a", from: 86_400, to: 172_799))
        try write(store) { db in try db.execute(sql: "UPDATE pairedDevice SET peripheralId='replacement'") }
        let physical = try await store.analysisInputWitness()
        XCTAssertNotEqual(overflow.motionSignature(deviceId: "witness-a", from: 86_400, to: 172_799),
                          physical.motionSignature(deviceId: "witness-a", from: 86_400, to: 172_799))
        try await store.close()
    }

    func testExplicitRowIDReplacementAndGravityTriggersInvalidateOldMotionDays() async throws {
        for triggered in [false, true] {
            let store = try await WhoopStore.inMemory()
            let day = 20_520 * 86_400
            _ = try await store.insert(Streams(gravity: [GravitySample(ts: day + 10, x: 0, y: 0, z: 1)]),
                                       deviceId: "witness-a")
            if triggered {
                try write(store) { db in
                    try db.execute(sql: """
                        CREATE TRIGGER witnessGravityReplacement AFTER INSERT ON gravitySample
                        WHEN NEW.ts = \(day + 86_410) BEGIN
                          INSERT OR REPLACE INTO gravitySample(rowid,deviceId,ts,x,y,z)
                          VALUES((SELECT rowid FROM gravitySample WHERE ts=\(day + 10)),
                                 'witness-a',\(day + 172_810),0,0,1);
                        END
                        """)
                }
            }
            let before = try await store.analysisInputWitness()
            if triggered {
                _ = try await store.insert(Streams(gravity: [GravitySample(ts: day + 86_410, x: 0, y: 0, z: 1)]),
                                           deviceId: "witness-a")
            } else {
                try write(store) { db in
                    try db.execute(sql: """
                        INSERT OR REPLACE INTO gravitySample(rowid,deviceId,ts,x,y,z)
                        VALUES((SELECT rowid FROM gravitySample WHERE ts=\(day + 10)),
                               'witness-a',\(day + 86_410),0,0,1)
                        """)
                }
            }
            let after = try await store.analysisInputWitness()
            XCTAssertNotEqual(before.motionSignature(deviceId: "witness-a", from: day, to: day + 86_399),
                              after.motionSignature(deviceId: "witness-a", from: day, to: day + 86_399),
                              "the old day was implicitly deleted (triggered=\(triggered))")
            try await store.close()
        }
    }

    func testShadowRowIDSchemaCannotMisattributeAnInsertedGravityDay() async throws {
        for generated in [false, true] {
            let store = try await WhoopStore.inMemory()
            let day = 20_520 * 86_400
            _ = try await store.insert(Streams(gravity: [GravitySample(ts: day + 10, x: 0, y: 0, z: 1)]),
                                       deviceId: "witness-a")
            try write(store) { db in
                if generated {
                    try db.execute(sql: "ALTER TABLE gravitySample ADD COLUMN rowid INTEGER GENERATED ALWAYS AS (CASE WHEN ts < \(day + 86_400) THEN 2 END) VIRTUAL")
                } else {
                    try db.execute(sql: "ALTER TABLE gravitySample ADD COLUMN rowid INTEGER")
                    try db.execute(sql: "UPDATE gravitySample SET rowid=2")
                }
            }
            let before = try await store.analysisInputWitness()
            _ = try await store.insert(Streams(gravity: [GravitySample(ts: day + 86_410, x: 0, y: 0, z: 1)]),
                                       deviceId: "witness-a")
            let after = try await store.analysisInputWitness()
            XCTAssertNotEqual(before.motionSignature(deviceId: "witness-a", from: day + 86_400, to: day + 172_799),
                              after.motionSignature(deviceId: "witness-a", from: day + 86_400, to: day + 172_799),
                              "a column named rowid must not redirect classification (generated=\(generated))")
            try await store.close()
        }
    }

    func testCaseRenamedTablesStillAdvanceCanonicalDependencies() async throws {
        let store = try await WhoopStore.inMemory()
        try write(store) { db in
            try db.execute(sql: "ALTER TABLE hrSample RENAME TO witnessRenamedHR")
            try db.execute(sql: "ALTER TABLE witnessRenamedHR RENAME TO HRSAMPLE")
        }
        let before = try await store.analysisInputWitness()
        try write(store) { db in
            try db.execute(sql: "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('witness-a',1000,55)")
        }
        let after = try await store.analysisInputWitness()
        XCTAssertNotEqual(before.signature(tables: ["hrSample"]), after.signature(tables: ["hrSample"]),
                          "SQLite table identifiers are case insensitive after a schema rename")
        try await store.close()
    }

    func testLaterRollbackCannotAcknowledgeAnEarlierUnobservedCommit() async throws {
        let store = try await WhoopStore.inMemory()
        let before = try await store.analysisInputWitness()
        try await store.registryWriter.writeWithoutTransaction { db in
            XCTAssertEqual(sqlite3_exec(db.sqliteConnection,
                "INSERT INTO hrSample(deviceId,ts,bpm) VALUES('witness-a',1000,55)", nil, nil, nil), SQLITE_OK)
        }
        enum Rollback: Error { case expected }
        XCTAssertThrowsError(try write(store) { db in
            try db.execute(sql: "UPDATE hrSample SET bpm=65")
            throw Rollback.expected
        })
        let after = try await store.analysisInputWitness()
        XCTAssertNotEqual(before.signature(tables: ["hrSample"]), after.signature(tables: ["hrSample"]),
                          "rollback must not acknowledge a previously committed raw-SQL mutation")
        try await store.close()
    }
}
