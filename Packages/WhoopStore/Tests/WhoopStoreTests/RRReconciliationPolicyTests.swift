import XCTest
import GRDB
import WhoopProtocol
@testable import WhoopStore

/// These tests use the real GRDB connection, production migrations, and production
/// query dispatch. They can also run with the exact policy source dependency closure.
final class RRReconciliationPolicyTests: XCTestCase {
    private func database() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE pairedDevice(id TEXT PRIMARY KEY, model TEXT, brand TEXT);
                CREATE TABLE hrSample(deviceId TEXT, ts INTEGER, bpm INTEGER, PRIMARY KEY(deviceId,ts));
                CREATE TABLE rrInterval(
                    deviceId TEXT NOT NULL, ts INTEGER NOT NULL, rrMs INTEGER NOT NULL,
                    seq INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL DEFAULT 'legacy',
                    sourceOrdinal INTEGER, tsSuspect INTEGER,
                    PRIMARY KEY(deviceId,ts,rrMs,seq));
                CREATE INDEX idx_rrInterval_source_order
                    ON rrInterval(deviceId,source,ts,sourceOrdinal,rrMs);
                """)
        }
        return queue
    }

    private func add(_ db: Database, _ ts: Int, _ value: Int, _ source: RRSource,
                     device: String = "strap", ordinal: Int = 0, suspect: Int? = nil) throws {
        try db.execute(sql: """
            INSERT INTO rrInterval(deviceId,ts,rrMs,seq,source,sourceOrdinal,tsSuspect)
            VALUES (?,?,?,?,?,?,?)
            """, arguments: [device, ts, value, ordinal, source.rawValue, ordinal, suspect])
    }

    func testWHOOP4SelectsOneTrainPerFullHourBeforeLimit() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO pairedDevice VALUES ('strap','WHOOP 4.0','WHOOP')")
            try add(db, 50, 800, .whoop4Historical)
            try add(db, 100, 810, .whoop4Standard)
            // History outside the exact slice still owns this complete UTC hour.
            XCTAssertTrue(try RRReadPolicy.read(db: db, deviceId: "strap", from: 100, to: 110, limit: 5).isEmpty)
            for ordinal in 0..<8 { try add(db, 3700, 820, .whoop4Realtime, ordinal: ordinal) }
            try add(db, 3699, 830, .whoop4Standard)
            let rows = try RRReadPolicy.read(db: db, deviceId: "strap", from: 3600, to: 3800, limit: 5)
            XCTAssertEqual(rows.map(\.rrMs), Array(repeating: 820, count: 5))
            XCTAssertEqual(rows.map(\.sourceOrdinal), [0, 1, 2, 3, 4])
            XCTAssertTrue(rows.allSatisfy { $0.source == .whoop4Realtime })
        }
    }

    func testSuspectHistoryAllowsGoodFallbackForBothFamilies() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO pairedDevice VALUES ('strap','4.0','WHOOP')")
            try add(db, 100, 800, .whoop4Historical, suspect: 1)
            try add(db, 101, 810, .whoop4Standard)
            XCTAssertEqual(try RRReadPolicy.read(db: db, deviceId: "strap", from: 0, to: 200, limit: 5).map(\.rrMs), [810])
            try db.execute(sql: "UPDATE pairedDevice SET model='5.0'")
            try add(db, 102, 500, .whoop5Historical, suspect: 1)
            try add(db, 103, 820, .whoop5Standard)
            XCTAssertEqual(try RRReadPolicy.read(db: db, deviceId: "strap", from: 0, to: 200, limit: 5).map(\.rrMs), [820])
        }
    }

    func testKnownFamilyAndBrandCannotBeOverriddenByForeignTags() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO pairedDevice VALUES ('strap','4.0','WHOOP')")
            try add(db, 100, 800, .whoop4Historical)
            try add(db, 101, 810, .whoop5Historical)
            XCTAssertEqual(try RRReadPolicy.read(db: db, deviceId: "strap", from: 0, to: 200, limit: 5).map(\.rrMs), [800])
            try db.execute(sql: "UPDATE pairedDevice SET model='5.0',brand='Other'")
            XCTAssertEqual(try RRReadPolicy.scoringFamily(db: db, deviceId: "strap"), .other)
            XCTAssertEqual(try RRReadPolicy.read(db: db, deviceId: "strap", from: 0, to: 200, limit: 5).count, 2)
            try db.execute(sql: "UPDATE pairedDevice SET model='unrecognized',brand='WHOOP'")
            // Preserve the target's WHOOP 5 preference for ambiguous unregistered imports.
            XCTAssertEqual(try RRReadPolicy.scoringFamily(db: db, deviceId: "strap"), .whoop5)
        }
    }

    func testUnknownOwnerUsesOnlyItsOwnWireEvidence() throws {
        let queue = try database()
        try queue.write { db in
            try add(db, 100, 800, .whoop4Historical, device: "other")
            try add(db, 101, 810, .legacy)
            XCTAssertEqual(try RRReadPolicy.scoringFamily(db: db, deviceId: "strap"), .other)
            try add(db, 20000, 820, .whoop4Realtime)
            XCTAssertEqual(try RRReadPolicy.scoringFamily(db: db, deviceId: "strap"), .whoop4)
            let rows = try RRReadPolicy.read(db: db, deviceId: "strap", from: 0, to: 200, limit: 5)
            XCTAssertEqual(rows.map(\.rrMs), [810])
        }
    }

    func testFillAnnotationHandlesHRThatArrivesAfterRRAndIsIdempotent() throws {
        let queue = try database()
        try queue.write { db in
            try add(db, 100, 500, .whoop5Historical)
            try RRQualityMigration.markKnownFill(in: db,
                streams: Streams(rr: [RRInterval(ts: 100, rrMs: 500, source: .whoop5Historical)]), deviceId: "strap")
            XCTAssertNil(try Int.fetchOne(db, sql: "SELECT tsSuspect FROM rrInterval"))
            try db.execute(sql: "INSERT INTO hrSample VALUES ('strap',100,80)")
            let lateHR = Streams(hr: [HRSample(ts: 100, bpm: 80)])
            try RRQualityMigration.markKnownFill(in: db, streams: lateHR, deviceId: "strap")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT tsSuspect FROM rrInterval"), 1)
            try RRQualityMigration.markKnownFill(in: db, streams: lateHR, deviceId: "strap")
            XCTAssertEqual(db.changesCount, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval"), 1)
        }
    }

    func testFillRuleLeavesOneHundredBPMAndUncorroboratedBeats() throws {
        let queue = try database()
        try queue.write { db in
            try add(db, 100, 500, .whoop5Standard)
            try add(db, 101, 500, .whoop5Historical)
            try add(db, 102, 500, .whoop4Historical)
            try db.execute(sql: "INSERT INTO hrSample VALUES ('strap',100,100),('strap',102,70)")
            try db.execute(sql: RRQualityMigration.whoop5RrFillMigrationSQL)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rrInterval WHERE tsSuspect=1"), 0)
        }
    }

    func testForwardMigrationPreservesNaturalKeyAndNumericProvenance() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE hrSample(deviceId TEXT,ts INTEGER,bpm INTEGER,PRIMARY KEY(deviceId,ts));
                CREATE TABLE rrInterval(deviceId TEXT,ts INTEGER,rrMs INTEGER,seq INTEGER,
                    srcChannel INTEGER,ord INTEGER,PRIMARY KEY(deviceId,ts,rrMs,seq));
                INSERT INTO rrInterval VALUES
                  ('strap',8,800,0,8,2),('strap',9,800,0,9,3),('strap',10,800,0,10,4),
                  ('strap',11,500,0,5,5),('strap',12,820,0,NULL,6);
                INSERT INTO hrSample VALUES ('strap',11,80);
                """)
        }
        var migrator = DatabaseMigrator()
        RRSourceMigration.register(on: &migrator)
        RRQualityMigration.register(on: &migrator)
        try migrator.migrate(queue)
        try migrator.migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try db.primaryKey("rrInterval").columns, ["deviceId", "ts", "rrMs", "seq"])
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM rrInterval ORDER BY ts")
            XCTAssertEqual(rows.count, 5)
            XCTAssertEqual(rows.map { $0["source"] as String },
                           ["whoop4_historical", "whoop4_realtime", "whoop4_standard_2a37", "whoop5_historical", "legacy"])
            XCTAssertEqual(rows.map { $0["sourceOrdinal"] as Int }, [2, 3, 4, 5, 6])
            XCTAssertEqual(rows[3]["tsSuspect"] as Int?, 1)
            XCTAssertNil(rows[4]["tsSuspect"] as Int?)
        }
    }

    func testExistingQualityMarksAndNamedSourcesSurviveMigration() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "ALTER TABLE rrInterval ADD COLUMN srcChannel INTEGER")
            try add(db, 100, 500, .whoop5Historical, suspect: 0)
            try add(db, 101, 810, .whoop4Realtime, suspect: 1)
            try db.execute(sql: "UPDATE rrInterval SET srcChannel=8")
            try db.execute(sql: "INSERT INTO hrSample VALUES ('strap',100,80)")
        }
        var migrator = DatabaseMigrator()
        RRQualityMigration.register(on: &migrator)
        try migrator.migrate(queue)
        try queue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT source,tsSuspect FROM rrInterval ORDER BY ts")
            XCTAssertEqual(rows.map { $0["source"] as String }, ["whoop5_historical", "whoop4_realtime"])
            XCTAssertEqual(rows.map { $0["tsSuspect"] as Int }, [0, 1])
        }
    }

    func testWHOOP4ConflictPreferenceMatchesReadPreference() {
        XCTAssertGreaterThan(RRReadPolicy.priority(for: .whoop4Historical), RRReadPolicy.priority(for: .whoop4Realtime))
        XCTAssertGreaterThan(RRReadPolicy.priority(for: .whoop4Realtime), RRReadPolicy.priority(for: .whoop4Standard))
        XCTAssertGreaterThan(RRReadPolicy.priority(for: .whoop4Standard), RRReadPolicy.priority(for: .legacy))
        XCTAssertEqual([8, 9, 10].map(RRSource.legacyChannel), [.whoop4Historical, .whoop4Realtime, .whoop4Standard])
    }

    func testWitnessTracksSourceQualityBoundaryHourAndOutsideWindowFamily() throws {
        let queue = try database()
        try queue.write { db in
            try add(db, 100, 800, .legacy)
            let legacy = try RRScoringFingerprint.read(db: db, deviceId: "strap", from: 100, to: 200)
            try add(db, 20000, 810, .whoop4Realtime)
            let classified = try RRScoringFingerprint.read(db: db, deviceId: "strap", from: 100, to: 200)
            XCTAssertNotEqual(legacy, classified)
            try add(db, 50, 820, .whoop4Historical)
            let boundary = try RRScoringFingerprint.read(db: db, deviceId: "strap", from: 100, to: 200)
            XCTAssertNotEqual(classified, boundary)
            try db.execute(sql: "UPDATE rrInterval SET tsSuspect=1 WHERE ts=50")
            let flagged = try RRScoringFingerprint.read(db: db, deviceId: "strap", from: 100, to: 200)
            XCTAssertNotEqual(boundary, flagged)
            try db.execute(sql: "UPDATE rrInterval SET sourceOrdinal=2 WHERE ts=50")
            let reordered = try RRScoringFingerprint.read(db: db, deviceId: "strap", from: 100, to: 200)
            XCTAssertNotEqual(flagged, reordered)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hrSample"), 0)
        }
    }

    func testOtherFamilyPreservesPreviouslyMarkedRawValues() throws {
        let queue = try database()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO pairedDevice VALUES ('strap','Ring','Oura')")
            try add(db, 100, 800, .ouraGreenQuality, suspect: 1)
            try add(db, 101, 810, .ouraSpO2)
            let rows = try RRReadPolicy.read(db: db, deviceId: "strap", from: 0, to: 200, limit: 10)
            XCTAssertEqual(rows.map(\.rrMs), [800])
        }
    }
}
