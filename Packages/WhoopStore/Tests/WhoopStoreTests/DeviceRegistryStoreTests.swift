import XCTest
import GRDB
@testable import WhoopStore

final class DeviceRegistryStoreTests: XCTestCase {
    private func makeDB() throws -> DatabaseQueue {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq)   // applies through the current schema, seeds 'my-whoop' active
        return dbq
    }

    func testSeededWhoopIsActive() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let devices = try store.all()
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.id, "my-whoop")
        XCTAssertEqual(try store.activeDeviceId(), "my-whoop")
    }

    func testSetActiveEnforcesSingleActive() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.add(PairedDevice(id: "polar-1", brand: "Polar", model: "H10", sourceKind: .liveBLE,
                                   capabilities: [.hr, .hrv], status: .paired, addedAt: 1, lastSeenAt: 1))
        try store.setActive("polar-1")
        XCTAssertEqual(try store.activeDeviceId(), "polar-1")
        let statuses = Dictionary(uniqueKeysWithValues: try store.all().map { ($0.id, $0.status) })
        XCTAssertEqual(statuses["polar-1"], .active)
        XCTAssertEqual(statuses["my-whoop"], .paired)   // the previously-active device was demoted
        XCTAssertEqual(try store.all().filter { $0.status == .active }.count, 1)  // I1
    }

    func testArchiveKeepsRowAndClearsActive() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.archive("my-whoop")
        XCTAssertEqual(try store.all().first?.status, .archived)   // I4: row kept
        XCTAssertNil(try store.activeDeviceId())
    }

    func testSeededWhoopHasNilPeripheralId() throws {
        // v16 applies cleanly: the seeded my-whoop row exists with peripheralId nil (it connects to
        // "any WHOOP" today; it adopts its peripheral id later).
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let seeded = try store.all().first
        XCTAssertEqual(seeded?.id, "my-whoop")
        XCTAssertNil(seeded?.peripheralId)
    }

    func testPeripheralIdRoundTripsThroughAddAndAll() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let pid = "8E1A2B3C-4D5E-6F70-8192-A3B4C5D6E7F8"
        try store.add(PairedDevice(id: "whoop-\(pid)", brand: "WHOOP", model: "WHOOP 5.0",
                                   peripheralId: pid, sourceKind: .liveBLE,
                                   capabilities: [.hr, .hrv], status: .paired, addedAt: 10, lastSeenAt: 10))
        let fetched = try store.all().first { $0.id == "whoop-\(pid)" }
        XCTAssertEqual(fetched?.peripheralId, pid)
    }

    func testSetPeripheralIdUpdatesIt() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        XCTAssertNil(try store.all().first { $0.id == "my-whoop" }?.peripheralId)
        let pid = "11111111-2222-3333-4444-555555555555"
        try store.setPeripheralId("my-whoop", peripheralId: pid)
        XCTAssertEqual(try store.all().first { $0.id == "my-whoop" }?.peripheralId, pid)
        // passing nil un-adopts it
        try store.setPeripheralId("my-whoop", peripheralId: nil)
        XCTAssertNil(try store.all().first { $0.id == "my-whoop" }?.peripheralId)
    }

    func testHistoryLineageAndEpochFenceReplacementAndDelete() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let initialLineage = try XCTUnwrap(store.historyLineage(for: "my-whoop"))
        XCTAssertEqual(try store.historyCursorEpoch(for: "my-whoop"), 0)

        try store.setPeripheralId("my-whoop", peripheralId: "peripheral-a")
        let firstPeripheralLineage = try XCTUnwrap(store.historyLineage(for: "my-whoop"))
        XCTAssertNotEqual(firstPeripheralLineage, initialLineage)
        XCTAssertEqual(try store.historyCursorEpoch(for: "my-whoop"), 1)

        // Re-adopting the same physical peripheral is a metadata-stable update.
        try store.setPeripheralId("my-whoop", peripheralId: "peripheral-a")
        XCTAssertEqual(try store.historyLineage(for: "my-whoop"), firstPeripheralLineage)
        XCTAssertEqual(try store.historyCursorEpoch(for: "my-whoop"), 1)

        try store.setPeripheralId("my-whoop", peripheralId: "peripheral-b")
        let replacementLineage = try XCTUnwrap(store.historyLineage(for: "my-whoop"))
        XCTAssertNotEqual(replacementLineage, firstPeripheralLineage)
        XCTAssertEqual(try store.historyCursorEpoch(for: "my-whoop"), 2)

        try store.setPeripheralId("my-whoop", peripheralId: nil)
        let clearedLineage = try XCTUnwrap(store.historyLineage(for: "my-whoop"))
        XCTAssertNotEqual(clearedLineage, replacementLineage)
        XCTAssertEqual(try store.historyCursorEpoch(for: "my-whoop"), 3)

        try store.setPeripheralId("my-whoop", peripheralId: "peripheral-c")
        let readoptedLineage = try XCTUnwrap(store.historyLineage(for: "my-whoop"))
        XCTAssertNotEqual(readoptedLineage, clearedLineage)
        XCTAssertEqual(try store.historyCursorEpoch(for: "my-whoop"), 4)

        try store.deleteAllData(deviceId: "my-whoop")
        XCTAssertNotEqual(try store.historyLineage(for: "my-whoop"), readoptedLineage)
        XCTAssertEqual(try store.historyCursorEpoch(for: "my-whoop"), 5)
    }

    func testUpsertFencesFirstPeripheralAdoptionAndKeepsSamePeripheralStable() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let id = "upsert-whoop"
        try store.add(PairedDevice(
            id: id, brand: "WHOOP", model: "WHOOP 5.0", peripheralId: nil,
            sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1
        ))
        let legacyLineage = try XCTUnwrap(store.historyLineage(for: id))
        XCTAssertEqual(try store.historyCursorEpoch(for: id), 0)

        // Registering the first physical peripheral must fence history from the legacy no-identity row.
        try store.add(PairedDevice(
            id: id, brand: "WHOOP", model: "WHOOP 5.0", peripheralId: "peripheral-a",
            sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 2
        ))
        let firstPeripheralLineage = try XCTUnwrap(store.historyLineage(for: id))
        XCTAssertNotEqual(firstPeripheralLineage, legacyLineage)
        XCTAssertEqual(try store.historyCursorEpoch(for: id), 1)

        // A metadata refresh for the same physical peripheral preserves the fence.
        try store.add(PairedDevice(
            id: id, brand: "WHOOP", model: "WHOOP 5.0 / MG", peripheralId: "peripheral-a",
            sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 3
        ))
        XCTAssertEqual(try store.historyLineage(for: id), firstPeripheralLineage)
        XCTAssertEqual(try store.historyCursorEpoch(for: id), 1)

        // Replacing the adopted peripheral advances both parts of the history fence.
        try store.add(PairedDevice(
            id: id, brand: "WHOOP", model: "WHOOP 5.0 / MG", peripheralId: "peripheral-b",
            sourceKind: .liveBLE, capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 4
        ))
        XCTAssertNotEqual(try store.historyLineage(for: id), firstPeripheralLineage)
        XCTAssertEqual(try store.historyCursorEpoch(for: id), 2)
    }

    func testDeviceForPeripheralIdFindsIt() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        let pid = "ABCDEF01-2345-6789-ABCD-EF0123456789"
        XCTAssertNil(try store.device(forPeripheralId: pid))   // none adopted yet
        try store.setPeripheralId("my-whoop", peripheralId: pid)
        XCTAssertEqual(try store.device(forPeripheralId: pid)?.id, "my-whoop")
        XCTAssertNil(try store.device(forPeripheralId: "no-such-peripheral"))
    }

    func testGenericWhoopModelRepairIsAtomicAndNeverOverwritesSpecificModels() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        XCTAssertEqual(try store.all().first?.model, "WHOOP")

        XCTAssertTrue(try store.setModelIfGenericWhoop("my-whoop", model: "WHOOP 5.0 / MG"))
        XCTAssertEqual(try store.all().first?.model, "WHOOP 5.0 / MG")

        XCTAssertFalse(try store.setModelIfGenericWhoop("my-whoop", model: "WHOOP 4.0"))
        XCTAssertEqual(try store.all().first?.model, "WHOOP 5.0 / MG")
        XCTAssertFalse(try store.setModelIfGenericWhoop("missing", model: "WHOOP 4.0"))
    }

    // ah-delete (#616): deleteAllData(deviceId: "apple-health") clears every row stored under the
    // Apple-Health source across the deviceId-keyed tables, while leaving another device's rows untouched.
    func testDeleteAllDataClearsOnlyTheTargetDevicesRows() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)

        // Seed apple-health + my-whoop rows in two device-scoped tables (appleDaily + metricSeries).
        try dbq.write { db in
            for dev in ["apple-health", "my-whoop"] {
                try db.execute(sql: "INSERT INTO appleDaily (deviceId, day, steps) VALUES (?, ?, ?)",
                               arguments: [dev, "2026-06-15", 1234])
                try db.execute(sql: "INSERT INTO metricSeries (deviceId, day, key, value) VALUES (?, ?, ?, ?)",
                               arguments: [dev, "2026-06-15", "steps", 1234.0])
            }
        }

        func count(_ table: String, _ deviceId: String) throws -> Int {
            try dbq.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE deviceId = ?",
                                 arguments: [deviceId]) ?? 0
            }
        }

        // Both devices start with a row in each table.
        XCTAssertEqual(try count("appleDaily", "apple-health"), 1)
        XCTAssertEqual(try count("metricSeries", "apple-health"), 1)
        XCTAssertEqual(try count("appleDaily", "my-whoop"), 1)

        try store.deleteAllData(deviceId: "apple-health")

        // The apple-health rows are gone everywhere; my-whoop's rows survive.
        XCTAssertEqual(try count("appleDaily", "apple-health"), 0)
        XCTAssertEqual(try count("metricSeries", "apple-health"), 0)
        XCTAssertEqual(try count("appleDaily", "my-whoop"), 1)
        XCTAssertEqual(try count("metricSeries", "my-whoop"), 1)

        // The registry row itself is never touched by a delete-data op (the seeded my-whoop remains).
        XCTAssertEqual(try store.all().count, 1)
        XCTAssertEqual(try store.activeDeviceId(), "my-whoop")
    }

    func testDeleteAllDataClearsOnlyTheTargetDeviceCheckpointRows() throws {
        let dbq = try makeDB()
        let store = DeviceRegistryStore(dbQueue: dbq)

        try dbq.write { db in
            for (deviceId, consumerId, lineage) in [
                ("apple-health", "analysis", "lineage-a"),
                ("apple-health", "recovery", "lineage-a"),
                ("my-whoop", "analysis", "lineage-b"),
            ] {
                try db.execute(sql: """
                    INSERT INTO historicalAnalysisCheckpoint
                        (databaseInstanceId, consumerId, deviceId, lineage, cursorEpoch, trimScope)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: ["test-database", consumerId, deviceId, lineage, 0, "all"])
            }
        }

        func countCheckpointRows(for deviceId: String) throws -> Int {
            try dbq.read { db in
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM historicalAnalysisCheckpoint WHERE deviceId = ?",
                    arguments: [deviceId]
                ) ?? 0
            }
        }

        XCTAssertEqual(try countCheckpointRows(for: "apple-health"), 2)
        XCTAssertEqual(try countCheckpointRows(for: "my-whoop"), 1)

        try store.deleteAllData(deviceId: "apple-health")

        XCTAssertEqual(try countCheckpointRows(for: "apple-health"), 0)
        XCTAssertEqual(try countCheckpointRows(for: "my-whoop"), 1)
    }

    // Regression guard (audit finding): every table with a `deviceId` column MUST appear in
    // `deviceScopedTables`, or `deleteAllData` silently leaves that device's rows behind — a privacy
    // defect for a delete-means-gone app. Enumerate the live schema and fail if any deviceId-keyed table
    // is uncovered, so a future migration that adds one can't reintroduce the gap.
    func testDeviceScopedTablesCoversEveryDeviceIdKeyedTable() throws {
        let dbq = try makeDB()
        let uncovered = try dbq.read { db -> [String] in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'grdb_%'
            """)
            var missing: [String] = []
            for table in tables {
                let cols = try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))")
                let hasDeviceId = cols.contains { ($0["name"] as String?) == "deviceId" }
                if hasDeviceId && !DeviceRegistryStore.deviceScopedTables.contains(table) {
                    missing.append(table)
                }
            }
            return missing
        }
        XCTAssertTrue(uncovered.isEmpty,
                      "deviceId-keyed tables missing from deviceScopedTables (deleteAllData would skip them): \(uncovered)")
    }

    // Strength Strain: its three per-device tables are wiped with the device, and the one global switch is not.
    func testLiftStrainTablesAreDeviceScopedAndTheControlRowSurvivesDeleteAllData() throws {
        let dbq = try makeDB()
        for table in ["liftStrain", "liftStrainTarget", "liftStrainJob"] {
            XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains(table), table)
        }
        XCTAssertFalse(DeviceRegistryStore.deviceScopedTables.contains("liftStrainControl"))
        try dbq.read { db in
            XCTAssertFalse(try db.columns(in: "liftStrainControl").map(\.name).contains("deviceId"))
        }

        try dbq.write { db in
            for device in ["whoop-abc", "my-whoop"] {
                try db.execute(sql: """
                    INSERT INTO liftStrain (deviceId, liftSessionId, workoutStartTs, workoutSport, dayKey, formulaVersion,
                        bodyweightKg, dose, volume, muscularLoad, workingSets, warmupSets, countedSets, skippedJSON,
                        unmappedSets, computedAt, updatedAt)
                    VALUES (?, 'L1', 1784300000, 'Strength Training', '2026-07-17', 1, 80, 50, 100, 10, 9, 2, 9, '{}', 0, 1, 1)
                    """, arguments: [device])
                try db.execute(sql: """
                    INSERT INTO liftStrainTarget (deviceId, kind, keyTs, keyText, formulaVersion, snapshotAt, updatedAt)
                    VALUES (?, 'workout', 1784300000, 'Strength Training', 1, 1, 1)
                    """, arguments: [device])
                try db.execute(sql: """
                    INSERT INTO liftStrainJob (jobKey, deviceId, formulaVersion, state, upperDay, startedAt)
                    VALUES (?, ?, 1, 'running', '2026-07-18', 1)
                    """, arguments: ["job-\(device)", device])
            }
            try db.execute(sql: """
                INSERT INTO liftStrainControl (scope, disabled, reason, updatedAt) VALUES ('global', 1, 'test', 1)
                """)
        }

        try DeviceRegistryStore(dbQueue: dbq).deleteAllData(deviceId: "whoop-abc")

        try dbq.read { db in
            for table in ["liftStrain", "liftStrainTarget", "liftStrainJob"] {
                XCTAssertEqual(try String.fetchAll(db, sql: "SELECT deviceId FROM \(table)"), ["my-whoop"], table)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT disabled FROM liftStrainControl WHERE scope = 'global'"), 1)
        }
        try DeviceRegistryStore(dbQueue: dbq).deleteAllData(deviceId: "my-whoop")
        try dbq.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftStrain"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM liftStrainControl"), 1,
                           "the kill switch is not a device's data")
        }
    }

    func testDayOwnershipUpsertAndRead() throws {
        let store = DeviceRegistryStore(dbQueue: try makeDB())
        try store.setDayOwner(day: "2026-06-15", deviceId: "my-whoop", locked: true)
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.deviceId, "my-whoop")
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.locked, true)
        XCTAssertNil(try store.dayOwner("2000-01-01"))
        // upsert: re-writing the same day replaces the owner + locked flag (no duplicate row)
        try store.setDayOwner(day: "2026-06-15", deviceId: "polar-1", locked: false)
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.deviceId, "polar-1")
        XCTAssertEqual(try store.dayOwner("2026-06-15")?.locked, false)
    }
}

/// Counts committed write transactions on the writer connection, empty ones included.
private final class CommitCounter: TransactionObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var commits: Int { lock.withLock { count } }

    func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { true }
    func databaseDidChange(with event: DatabaseEvent) {}
    func databaseDidCommit(_ db: Database) { lock.withLock { count += 1 } }
    func databaseDidRollback(_ db: Database) {}
}

/// CC-4: an unchanged peripheral id is answered from a pool reader and never opens a write transaction, so a
/// main-actor caller can't wait behind a backfill commit holding the single writer.
final class DeviceRegistryStoreWriteAvoidanceTests: XCTestCase {
    private var path = ""

    override func setUp() {
        super.setUp()
        path = NSTemporaryDirectory() + "registry-writes-\(UUID().uuidString).sqlite"
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
        super.tearDown()
    }

    private func makePool() throws -> (DatabasePool, CommitCounter) {
        let pool = try DatabasePool(path: path)
        try WhoopStore.makeMigrator().migrate(pool)
        let counter = CommitCounter()
        pool.add(transactionObserver: counter, extent: .databaseLifetime)
        return (pool, counter)
    }

    func testUnchangedPeripheralIdPerformsNoWrite() throws {
        let (pool, counter) = try makePool()
        let store = DeviceRegistryStore(dbQueue: pool)
        XCTAssertTrue(try store.setPeripheralId("my-whoop", peripheralId: "peripheral-a"))
        XCTAssertEqual(counter.commits, 1)

        XCTAssertFalse(try store.setPeripheralId("my-whoop", peripheralId: "peripheral-a"))
        XCTAssertEqual(counter.commits, 1, "the no-change call opened a write transaction")

        XCTAssertTrue(try store.setPeripheralId("my-whoop", peripheralId: "peripheral-b"))
        XCTAssertEqual(counter.commits, 2)
    }

    func testAsyncVariantsWriteOnlyOnChange() async throws {
        let (pool, counter) = try makePool()
        let store = DeviceRegistryStore(dbQueue: pool)
        let lineage = try store.historyLineage(for: "my-whoop")

        let adopted = try await store.setPeripheralIdAsync("my-whoop", peripheralId: "peripheral-a")
        let repeated = try await store.setPeripheralIdAsync("my-whoop", peripheralId: "peripheral-a")
        XCTAssertTrue(adopted)
        XCTAssertFalse(repeated)
        XCTAssertEqual(counter.commits, 1)
        XCTAssertNotEqual(try store.historyLineage(for: "my-whoop"), lineage, "adoption starts a new lineage")

        try await store.addAsync(PairedDevice(id: "polar-1", brand: "Polar", model: "H10", sourceKind: .liveBLE,
                                              capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        try await store.setActiveAsync("polar-1")
        try await store.renameAsync("polar-1", nickname: "Chest")
        XCTAssertEqual(try store.activeDeviceId(), "polar-1")
        XCTAssertEqual(try store.all().first { $0.id == "polar-1" }?.nickname, "Chest")
        XCTAssertEqual(try store.all().filter { $0.status == .active }.count, 1)
        do {
            try await store.setActiveAsync("missing")
            XCTFail("an unknown device must not be promoted")
        } catch DeviceLifecycleStoreError.unknownDevice {}
    }
}
