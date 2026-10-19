import XCTest
import GRDB
@testable import WhoopStore

/// Storage and apply for Strength Strain. The combine is injected, so every test uses a transparent fake:
/// `min(100, hr + 2 * muscularLoad)`.
final class LiftStrainStoreTests: XCTestCase {

    // MARK: Fixtures

    private let owner = "my-whoop"
    private let canonical = "my-whoop-noop"
    private let sport = "Strength Training"
    private let dayA = "2026-07-17"
    private let dayB = "2026-07-18"
    private let startA = 1_784_300_000
    private let startB = 1_784_390_000
    private let combine: LiftStrainCombine = { h, m in min(100, h + 2 * m) }

    /// A stored `(strain, strainVersion)` compared by bit pattern, so a one-ulp drift fails.
    private struct Pair: Equatable, CustomStringConvertible {
        let bits: UInt64?
        let version: Int?
        init(_ strain: Double?, _ version: Int?) { bits = strain?.bitPattern; self.version = version }
        var description: String { "(\(bits.map { Double(bitPattern: $0).description } ?? "nil"), \(version.map(String.init) ?? "nil"))" }
    }

    private func computed(_ id: String, start: Int, day: String? = nil, load: Double = 10, volume: Double = 100,
                          version: Int = 1, isDefaultBodyweight: Bool = false, sport: String? = nil) -> LiftStrainComputed {
        LiftStrainComputed(
            liftSessionId: id, workoutStartTs: start, workoutSport: sport ?? self.sport, dayKey: day ?? dayA,
            formulaVersion: version, bodyweightKg: 80, bodyweightIsDefault: isDefaultBodyweight,
            dose: 50, volume: volume, muscularLoad: load, workingSets: 9, warmupSets: 2, countedSets: 9,
            skippedJSON: "[]", unmappedSets: 0)
    }

    private func workout(_ start: Int, strain: Double?, version: Int?, sport: String? = nil) -> WorkoutRow {
        WorkoutRow(startTs: start, endTs: start + 3_600, sport: sport ?? self.sport, source: "manual",
                   durationS: 3_600, energyKcal: 250, avgHr: 120, maxHr: 150, strain: strain, distanceM: nil,
                   zonesJSON: nil, notes: nil, strainVersion: version)
    }

    private func day(_ key: String, strain: Double?, version: Int?) -> DailyMetric {
        DailyMetric(day: key, totalSleepMin: 420, efficiency: 0.9, deepMin: 80, remMin: 90, lightMin: 250,
                    disturbances: 3, restingHr: 52, avgHrv: 61, recovery: 70, strain: strain, exerciseCount: 1,
                    steps: 9_000, activeKcalEst: 400, strainVersion: version)
    }

    private func newStore() async throws -> WhoopStore { try await WhoopStore.inMemory() }

    private func apply(_ store: WhoopStore, now: Int = 1_000) async throws -> LiftStrainApplyResult {
        try await store.applyLiftStrain(canonicalComputedDeviceId: canonical, now: now, combine: combine)
    }

    private func workoutPair(_ store: WhoopStore, _ start: Int, device: String? = nil) async throws -> Pair? {
        let deviceId = device ?? owner
        let row = try await store.registryWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT strain, strainVersion FROM workout WHERE deviceId = ? AND startTs = ?",
                             arguments: [deviceId, start])
        }
        return row.map { Pair($0["strain"], $0["strainVersion"]) }
    }

    private func dayPair(_ store: WhoopStore, _ dayKey: String, device: String? = nil) async throws -> Pair? {
        let deviceId = device ?? canonical
        let row = try await store.registryWriter.read { db in
            try Row.fetchOne(db, sql: "SELECT strain, strainVersion FROM dailyMetric WHERE deviceId = ? AND day = ?",
                             arguments: [deviceId, dayKey])
        }
        return row.map { Pair($0["strain"], $0["strainVersion"]) }
    }

    private func liftRow(_ store: WhoopStore, _ id: String, device: String? = nil) async throws -> LiftStrainRow? {
        let rows = try await store.liftStrainRows(deviceId: device ?? owner, liftSessionIds: [id])
        return rows.first
    }

    private func rows(_ store: WhoopStore, _ sql: String, _ arguments: StatementArguments = []) async throws -> [Row] {
        try await store.registryWriter.read { db in try Row.fetchAll(db, sql: sql, arguments: arguments) }
    }

    private func exec(_ store: WhoopStore, _ sql: String, _ arguments: StatementArguments = []) async throws {
        try await store.registryWriter.write { db in try db.execute(sql: sql, arguments: arguments) }
    }

    /// A full dump of the tracking tables, to prove an idle apply writes nothing (not even `updatedAt`).
    private func trackingDump(_ store: WhoopStore) async throws -> [String] {
        var out: [String] = []
        for table in ["liftStrain", "liftStrainTarget", "liftStrainJob", "liftStrainControl"] {
            for r in try await rows(store, "SELECT * FROM \(table) ORDER BY 1, 2, 3") {
                out.append("\(table): " + r.columnNames.map { "\($0)=\((r[$0] as DatabaseValue).description)" }.joined(separator: ","))
            }
        }
        return out
    }

    /// One lift on day A: workout (30, v2), canonical day (40, v2), computed load 10 -> 50 and 60.
    private func seedBasicLift(_ store: WhoopStore, id: String = "L1", load: Double = 10) async throws {
        try await store.upsertWorkouts([workout(startA, strain: 30, version: 2)], deviceId: owner)
        try await store.upsertDailyMetrics([day(dayA, strain: 40, version: 2)], deviceId: canonical)
        try await store.upsertLiftStrainComputed(
            deviceId: owner, rows: [computed(id, start: startA, load: load)], now: 500)
    }

    // MARK: Migration

    func testMigrationV59OnV58Database() async throws {
        let dbq = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbq, upTo: StoreIndexHygieneMigration.identifier)
        let tables = ["liftStrain", "liftStrainTarget", "liftStrainJob", "liftStrainControl"]
        try await dbq.read { db in
            for table in tables { XCTAssertFalse(try db.tableExists(table), "\(table) must not exist at v58") }
        }

        try WhoopStore.makeMigrator().migrate(dbq)

        try await dbq.read { db in
            for table in tables {
                XCTAssertTrue(try db.tableExists(table), table)
                XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)"), 0,
                               "\(table) must be empty: the migration is schema-only")
            }
            let strain = Set(try db.columns(in: "liftStrain").map(\.name))
            for column in ["deviceId", "liftSessionId", "workoutStartTs", "workoutSport", "dayKey", "formulaVersion",
                           "bodyweightKg", "bodyweightIsDefault", "dose", "volume", "muscularLoad", "workingSets",
                           "warmupSets", "countedSets", "skippedJSON", "unmappedSets", "hrOnlyStrain",
                           "combinedStrain", "appliedMuscularLoad", "state", "computedAt", "updatedAt"] {
                XCTAssertTrue(strain.contains(column), "liftStrain.\(column)")
            }
            XCTAssertEqual(try db.primaryKey("liftStrain").columns, ["deviceId", "liftSessionId"])
            XCTAssertEqual(try db.primaryKey("liftStrainTarget").columns, ["deviceId", "kind", "keyTs", "keyText"])
            XCTAssertTrue(try db.columns(in: "liftStrainJob").map(\.name).contains("refreshedAt"))
            XCTAssertFalse(try db.columns(in: "liftStrainControl").map(\.name).contains("deviceId"))
            let indexes = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
            for index in ["liftStrain_workout", "liftStrain_day", "liftStrain_state", "liftStrainTarget_day"] {
                XCTAssertTrue(indexes.contains(index), index)
            }
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                                            arguments: [LiftStrainMigration.identifier]), 1)
            XCTAssertEqual(LiftStrainMigration.identifier, "v59-lift-strain")
        }
    }

    // MARK: Upsert

    func testUpsertComputedTouchesOnlyComputedColumns() async throws {
        let store = try await newStore()
        try await seedBasicLift(store)
        _ = try await apply(store, now: 600)
        let applied = try await liftRow(store, "L1")
        let before = try XCTUnwrap(applied)
        XCTAssertEqual(before.state, .applied)

        try await store.upsertLiftStrainComputed(
            deviceId: owner, rows: [computed("L1", start: startA, load: 12, volume: 150)], now: 700)

        let afterRow = try await liftRow(store, "L1")
        let after = try XCTUnwrap(afterRow)
        XCTAssertEqual(after.muscularLoad, 12)
        XCTAssertEqual(after.volume, 150)
        XCTAssertEqual(after.computedAt, 700)
        // The apply's columns are untouched by an upsert.
        XCTAssertEqual(after.state, before.state)
        XCTAssertEqual(after.hrOnlyStrain, before.hrOnlyStrain)
        XCTAssertEqual(after.combinedStrain, before.combinedStrain)
        XCTAssertEqual(after.appliedMuscularLoad, before.appliedMuscularLoad)
    }

    func testUpsertComputedRerunWritesNothing() async throws {
        let store = try await newStore()
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [computed("L1", start: startA)], now: 100)
        let first = try await trackingDump(store)
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [computed("L1", start: startA)], now: 900)
        let second = try await trackingDump(store)
        XCTAssertEqual(first, second, "re-upserting identical computed columns must not even touch updatedAt")
        let row = try await liftRow(store, "L1")
        XCTAssertEqual(row?.state, .pending)
    }

    // MARK: Apply

    func testApplyCombinesWorkoutAndDay() async throws {
        let store = try await newStore()
        try await seedBasicLift(store)

        let r = try await apply(store)

        let w = try await workoutPair(store, startA)
        let d = try await dayPair(store, dayA)
        XCTAssertEqual(w, Pair(50, 2))
        XCTAssertEqual(d, Pair(60, 2))
        XCTAssertEqual(r.workoutWrites, 1)
        XCTAssertEqual(r.dayWrites, 1)
        XCTAssertEqual(r.applied, 1)
        let rowValue = try await liftRow(store, "L1")
        let row = try XCTUnwrap(rowValue)
        XCTAssertEqual(row.state, .applied)
        XCTAssertEqual(row.hrOnlyStrain, 30)
        XCTAssertEqual(row.combinedStrain, 50)
        XCTAssertEqual(row.appliedMuscularLoad, 10)
        let targets = try await rows(store, "SELECT * FROM liftStrainTarget ORDER BY kind")
        XCTAssertEqual(targets.count, 2)
        let dayTarget = targets[0], workoutTarget = targets[1]
        XCTAssertEqual(dayTarget["kind"] as String, "day")
        XCTAssertEqual(dayTarget["deviceId"] as String, canonical)
        XCTAssertEqual(dayTarget["hrOnlyStrain"] as Double, 40)
        XCTAssertEqual(dayTarget["writtenStrain"] as Double, 60)
        XCTAssertEqual(workoutTarget["kind"] as String, "workout")
        XCTAssertEqual(workoutTarget["origStrain"] as Double, 30)
        XCTAssertEqual(workoutTarget["origStrainVersion"] as Int, 2)
        XCTAssertEqual(workoutTarget["writtenStrain"] as Double, 50)
    }

    func testApplyIsIdempotent() async throws {
        let store = try await newStore()
        try await seedBasicLift(store)
        _ = try await apply(store, now: 1_000)
        let dump = try await trackingDump(store)

        let second = try await apply(store, now: 9_000)

        XCTAssertEqual(second.workoutWrites, 0)
        XCTAssertEqual(second.dayWrites, 0)
        let after = try await trackingDump(store)
        XCTAssertEqual(dump, after, "an idle apply must not touch a single tracking row")
    }

    func testFreshHRRescoreRebases() async throws {
        let store = try await newStore()
        try await seedBasicLift(store)
        _ = try await apply(store)

        // The heart-rate path rescores the workout; the stored v2 value is replaced by the new HR-only 35.
        try await store.upsertWorkouts([workout(startA, strain: 35, version: 2)], deviceId: owner)
        let stored = try await workoutPair(store, startA)
        XCTAssertEqual(stored, Pair(35, 2))

        let r = try await apply(store, now: 2_000)

        XCTAssertEqual(r.workoutWrites, 1)
        let w = try await workoutPair(store, startA)
        XCTAssertEqual(w, Pair(55, 2), "combine(35, 10) on top of the fresh heart-rate value")
        let row = try await liftRow(store, "L1")
        XCTAssertEqual(row?.hrOnlyStrain, 35)
        let again = try await apply(store, now: 3_000)
        XCTAssertEqual(again.workoutWrites + again.dayWrites, 0)
    }

    func testNoV2StrainMeansNotScoredAndDayIgnoresIt() async throws {
        let store = try await newStore()
        try await store.upsertWorkouts([workout(startA, strain: nil, version: nil)], deviceId: owner)
        try await store.upsertDailyMetrics([day(dayA, strain: 40, version: 2)], deviceId: canonical)
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [computed("L1", start: startA)], now: 500)

        let r = try await apply(store)

        XCTAssertEqual(r.notScored, 1)
        XCTAssertEqual(r.workoutWrites + r.dayWrites, 0)
        let row = try await liftRow(store, "L1")
        XCTAssertEqual(row?.state, .notScored)
        XCTAssertEqual(row?.appliedMuscularLoad, 0)
        let w = try await workoutPair(store, startA)
        let d = try await dayPair(store, dayA)
        XCTAssertEqual(w, Pair(nil, nil), "no heart-rate score, no muscular load for the workout")
        XCTAssertEqual(d, Pair(40, 2), "and none for its day")
        let dayTargets = try await rows(store, "SELECT * FROM liftStrainTarget WHERE kind = 'day'")
        XCTAssertTrue(dayTargets.isEmpty, "the day must not even be snapshotted")

        // Heart rate arrives later: the provisional row is picked up on the next apply.
        try await store.upsertWorkouts([workout(startA, strain: 30, version: 2)], deviceId: owner)
        let later = try await apply(store, now: 2_000)
        XCTAssertEqual(later.applied, 1)
        let wLater = try await workoutPair(store, startA)
        let dLater = try await dayPair(store, dayA)
        XCTAssertEqual(wLater, Pair(50, 2))
        XCTAssertEqual(dLater, Pair(60, 2))
        let rowLater = try await liftRow(store, "L1")
        XCTAssertEqual(rowLater?.state, .applied)
    }

    func testSecondApplyOverNotScoredRowsMakesZeroWrites() async throws {
        let store = try await newStore()
        // Legacy-scored and unscored lifts, far from any rescore window: they stay notScored for good.
        try await store.upsertWorkouts([workout(startA, strain: 33.3, version: nil),
                                        workout(startA + 7_200, strain: nil, version: nil)], deviceId: owner)
        try await store.upsertDailyMetrics([day(dayA, strain: 40, version: 2)], deviceId: canonical)
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [
            computed("L1", start: startA), computed("L2", start: startA + 7_200)], now: 500)
        let first = try await apply(store, now: 1_000)
        XCTAssertEqual(first.notScored, 2)
        let dump = try await trackingDump(store)

        let second = try await apply(store, now: 5_000)

        XCTAssertEqual(second.rowsVisited, 0, "an idle notScored row is not even visited")
        XCTAssertEqual(second.workoutWrites + second.dayWrites, 0)
        let after = try await trackingDump(store)
        XCTAssertEqual(dump, after)
    }

    func testDeletedWorkoutDetachesAndLeavesDay() async throws {
        let store = try await newStore()
        try await seedBasicLift(store)
        _ = try await apply(store)
        let combinedDay = try await dayPair(store, dayA)
        XCTAssertEqual(combinedDay, Pair(60, 2))

        try await store.deleteWorkouts(deviceId: owner, sport: sport, from: startA, to: startA)
        let r = try await apply(store, now: 2_000)

        XCTAssertEqual(r.detached, 1)
        let row = try await liftRow(store, "L1")
        XCTAssertEqual(row?.state, .detached)
        XCTAssertEqual(row?.appliedMuscularLoad, 0)
        XCTAssertNil(row?.combinedStrain)
        let d = try await dayPair(store, dayA)
        XCTAssertEqual(d, Pair(40, 2), "the day goes back to its heart-rate value, bit for bit")
        let loads = try await store.liftStrainAppliedLoads(dayKey: dayA)
        XCTAssertTrue(loads.isEmpty)
    }

    func testRekeyManualWorkoutWritesHROnlyAndDetaches() async throws {
        let store = try await newStore()
        try await seedBasicLift(store)
        _ = try await apply(store)
        let combined = try await workoutPair(store, startA)
        XCTAssertEqual(combined, Pair(50, 2))

        let newStart = startA + 7_200
        try await store.rekeyManualWorkout(
            deviceId: owner,
            old: workout(startA, strain: 50, version: 2),
            new: workout(newStart, strain: 50, version: 2))

        let oldRow = try await workoutPair(store, startA)
        let newRow = try await workoutPair(store, newStart)
        XCTAssertNil(oldRow, "the old key is gone")
        XCTAssertEqual(newRow, Pair(30, 2), "logged sets never stay in an HR-labelled value")
        let oldTargets = try await rows(store, """
            SELECT 1 FROM liftStrainTarget WHERE kind = 'workout' AND keyTs = ?
            """, [startA])
        XCTAssertTrue(oldTargets.isEmpty)
        let row = try await liftRow(store, "L1")
        XCTAssertEqual(row?.state, .detached)
        XCTAssertEqual(row?.appliedMuscularLoad, 0)
        XCTAssertNil(row?.combinedStrain)
    }

    func testRekeyOfAnUnrelatedWorkoutIsThePlainDeleteAndUpsert() async throws {
        let store = try await newStore()
        try await store.upsertWorkouts([workout(startA, strain: 12, version: 2, sport: "Run")], deviceId: owner)
        try await store.rekeyManualWorkout(
            deviceId: owner,
            old: workout(startA, strain: 12, version: 2, sport: "Run"),
            new: workout(startA + 600, strain: 12, version: 2, sport: "Run"))
        let oldRow = try await workoutPair(store, startA)
        let newRow = try await workoutPair(store, startA + 600)
        XCTAssertNil(oldRow)
        XCTAssertEqual(newRow, Pair(12, 2))
        let targets = try await rows(store, "SELECT 1 FROM liftStrainTarget")
        XCTAssertTrue(targets.isEmpty)
    }

    func testRekeySettlesBothDaysInTheSameTransaction() async throws {
        // A6. Lift 1 starts on day A, lift 2 is already applied on day B.
        for settleInTransaction in [true, false] {
            let store = try await newStore()
            try await store.upsertWorkouts([workout(startA, strain: 30, version: 2),
                                            workout(startB, strain: 20, version: 2)], deviceId: owner)
            try await store.upsertDailyMetrics([day(dayA, strain: 40.123456789, version: 2),
                                                day(dayB, strain: 50, version: 2)], deviceId: canonical)
            try await store.upsertLiftStrainComputed(deviceId: owner, rows: [
                computed("L1", start: startA, day: dayA, load: 10),
                computed("L2", start: startB, day: dayB, load: 5)], now: 500)
            _ = try await apply(store)
            let before = try await dayPair(store, dayA)
            XCTAssertEqual(before, Pair(min(100, 40.123456789 + 20), 2))
            let dayBBefore = try await dayPair(store, dayB)
            XCTAssertEqual(dayBBefore, Pair(60, 2))

            // Lift 1's workout is moved onto day B by the Workouts tab.
            let newStart = startB + 3_600
            let settle = LiftStrainRekeySettle(
                canonicalComputedDeviceId: canonical, newDayKey: dayB, oldDayKey: dayA, now: 2_000, combine: combine)
            try await store.rekeyManualWorkout(
                deviceId: owner,
                old: workout(startA, strain: 50, version: 2),
                new: workout(newStart, strain: 50, version: 2),
                settle: settleInTransaction ? settle : nil)

            if !settleInTransaction {
                let unsettled = try await dayPair(store, dayA)
                XCTAssertEqual(unsettled, before, "without a settle the old day waits for the next apply")
                _ = try await apply(store, now: 3_000)
            }

            let oldDay = try await dayPair(store, dayA)
            XCTAssertEqual(oldDay, Pair(40.123456789, 2), "the old day returns to its heart-rate value bit-identically")
            let newDay = try await dayPair(store, dayB)
            XCTAssertEqual(newDay, Pair(60, 2), "the new day is settled with the load that is attached to it")
            let moved = try await workoutPair(store, newStart)
            XCTAssertEqual(moved, Pair(30, 2))
            let l1 = try await liftRow(store, "L1")
            XCTAssertEqual(l1?.state, .detached)
            // Everything is settled: another apply changes nothing at all.
            let dump = try await trackingDump(store)
            let again = try await apply(store, now: 4_000)
            XCTAssertEqual(again.workoutWrites + again.dayWrites, 0)
            let dumpAfter = try await trackingDump(store)
            XCTAssertEqual(dump, dumpAfter, settleInTransaction ? "settled in the rekey transaction" : "settled by one apply")
        }
    }

    func testOnlyStrainColumnsChange() async throws {
        let store = try await newStore()
        // Targeted rows plus bystanders: another day, a non-lift workout, a sleep session and metric series.
        let secondLiftStart = startB + 9_000
        try await store.upsertWorkouts([
            workout(startA, strain: 30, version: 2),
            workout(secondLiftStart, strain: 18, version: 2),
            workout(startB, strain: 11, version: 2, sport: "Run"),
        ], deviceId: owner)
        try await store.upsertDailyMetrics([
            day(dayA, strain: 40, version: 2), day(dayB, strain: 25, version: 2),
        ], deviceId: canonical)
        try await store.upsertDailyMetrics([day(dayA, strain: 33, version: nil)], deviceId: owner)
        try await store.upsertSleepSessions([
            CachedSleepSession(startTs: startA - 30_000, endTs: startA - 2_000, efficiency: 0.9, restingHr: 50,
                               avgHrv: 60, stagesJSON: nil)], deviceId: owner)
        try await store.upsertMetricSeries([MetricPoint(day: dayA, key: "restingHr", value: 51)], deviceId: owner)

        typealias Snapshot = [String: [[String: DatabaseValue]]]
        func snapshot() async throws -> Snapshot {
            try await store.registryWriter.read { db in
                var out: Snapshot = [:]
                for table in ["dailyMetric", "workout", "sleepSession", "metricSeries"] {
                    out[table] = try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY 1, 2, 3").map { row in
                        Dictionary(uniqueKeysWithValues: row.columnNames.map { ($0, row[$0] as DatabaseValue) })
                    }
                }
                return out
            }
        }
        func text(_ value: DatabaseValue?) -> String {
            guard let value else { return "?" }
            return String.fromDatabaseValue(value) ?? Int.fromDatabaseValue(value).map(String.init) ?? "?"
        }
        /// Rows of `a` and `b` line up one to one. Only `strain` / `strainVersion` of the `targeted` rows may differ.
        func assertOnlyStrainDiffers(_ a: Snapshot, _ b: Snapshot, targeted: Set<String>, _ label: String,
                                     line: UInt = #line) {
            for (table, before) in a {
                let after = b[table] ?? []
                XCTAssertEqual(before.count, after.count, "\(label): \(table) row count", line: line)
                for (x, y) in zip(before, after) {
                    let changed = Set(x.keys.filter { x[$0] != y[$0] })
                    let key = "\(table)|\(text(x["deviceId"]))|\(text(x["day"] ?? x["startTs"]))"
                    if table == "dailyMetric" || table == "workout" {
                        XCTAssertTrue(changed.isSubset(of: ["strain", "strainVersion"]),
                                      "\(label): \(key) changed \(changed)", line: line)
                        if !targeted.contains(key) {
                            XCTAssertTrue(changed.isEmpty, "\(label): \(key) is not targeted but changed \(changed)", line: line)
                        }
                    } else {
                        XCTAssertTrue(changed.isEmpty, "\(label): \(key) must be untouched, changed \(changed)", line: line)
                    }
                }
            }
        }
        let firstWorkout = "workout|\(owner)|\(startA)"
        let secondWorkout = "workout|\(owner)|\(secondLiftStart)"
        let firstDay = "dailyMetric|\(canonical)|\(dayA)"
        let secondDay = "dailyMetric|\(canonical)|\(dayB)"

        let s0 = try await snapshot()

        // The live apply: lift 1 only.
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [computed("L1", start: startA)], now: 500)
        _ = try await apply(store)
        let s1 = try await snapshot()
        assertOnlyStrainDiffers(s0, s1, targeted: [firstWorkout, firstDay], "apply")
        XCTAssertNotEqual(s0["workout"], s1["workout"], "the apply must actually have written something")
        XCTAssertNotEqual(s0["dailyMetric"], s1["dailyMetric"])

        // A backfill chunk for lift 2. The Run workout is not a lift and must not move.
        try await store.startLiftStrainJob(jobKey: "job", deviceId: owner, formulaVersion: 1, upperDay: dayB, now: 600)
        let scope = try await store.liftStrainOwnerScope(deviceId: owner)
        _ = try await store.applyLiftStrainBackfillChunk(
            sourceOwner: scope, canonicalComputedDeviceId: canonical,
            chunk: LiftStrainChunkInput(
                rows: [computed("L2", start: secondLiftStart, day: dayB, load: 4)], dayKeys: [dayB], lastDay: dayB),
            jobKey: "job", now: 700, combine: combine)
        let s2 = try await snapshot()
        assertOnlyStrainDiffers(s1, s2, targeted: [secondWorkout, secondDay], "chunk")
        XCTAssertNotEqual(s1["workout"], s2["workout"])

        // The revert puts back exactly what was there before any of it, for every row and every column.
        _ = try await store.revertLiftStrain(reason: "test", now: 800)
        let s3 = try await snapshot()
        assertOnlyStrainDiffers(s2, s3, targeted: [firstWorkout, firstDay, secondWorkout, secondDay], "revert")
        XCTAssertEqual(s0, s3)
    }

    // MARK: Revert

    func testRevertRestoresOriginalBitsIncludingUnversionedAndLegacy() async throws {
        let store = try await newStore()
        let s1 = startA, s2 = startA + 10_000, s3 = startA + 20_000
        // W1 has no score at all, W2 a legacy unversioned score, W3 a v2 score.
        try await store.upsertWorkouts([
            workout(s1, strain: nil, version: nil),
            workout(s2, strain: 33.3, version: nil),
            workout(s3, strain: 47.6, version: 2),
        ], deviceId: owner)
        // Days: nil, legacy and v2, one per lift day.
        let days = ["2026-07-17", "2026-07-18", "2026-07-19"]
        try await store.upsertDailyMetrics([
            day(days[0], strain: nil, version: nil),
            day(days[1], strain: 22.2, version: nil),
            day(days[2], strain: 51.7, version: 2),
        ], deviceId: canonical)
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [
            computed("L1", start: s1, day: days[0]), computed("L2", start: s2, day: days[1]),
            computed("L3", start: s3, day: days[2])], now: 500)
        _ = try await apply(store)
        // The heart-rate path later scores W2 with the very same bits, now as v2: it becomes combinable.
        try await exec(store, "UPDATE workout SET strainVersion = 2 WHERE deviceId = ? AND startTs = ?", [owner, s2])
        _ = try await apply(store, now: 2_000)
        let w2Combined = try await workoutPair(store, s2)
        XCTAssertEqual(w2Combined, Pair(33.3 + 20, 2))
        let w3Combined = try await workoutPair(store, s3)
        XCTAssertEqual(w3Combined, Pair(47.6 + 20, 2))

        _ = try await store.revertLiftStrain(reason: "test", now: 3_000)

        let r1 = try await workoutPair(store, s1)
        let r2 = try await workoutPair(store, s2)
        let r3 = try await workoutPair(store, s3)
        XCTAssertEqual(r1, Pair(nil, nil))
        XCTAssertEqual(r2, Pair(33.3, nil), "bit-equal heart-rate value: the original unversioned pair comes back")
        XCTAssertEqual(r3, Pair(47.6, 2))
        let d0 = try await dayPair(store, days[0])
        let d1 = try await dayPair(store, days[1])
        let d2 = try await dayPair(store, days[2])
        XCTAssertEqual(d0, Pair(nil, nil))
        XCTAssertEqual(d1, Pair(22.2, nil))
        XCTAssertEqual(d2, Pair(51.7, 2))
        let disabled = try await store.liftStrainDisabled()
        XCTAssertTrue(disabled)
        let states = try await rows(store, "SELECT DISTINCT state FROM liftStrain")
        XCTAssertEqual(states.map { $0["state"] as String }, ["pending"])
    }

    func testRevertKeepsFreshHR() async throws {
        let store = try await newStore()
        try await seedBasicLift(store)
        _ = try await apply(store)
        // New heart-rate data rewrites the workout after the apply.
        try await store.upsertWorkouts([workout(startA, strain: 36, version: 2)], deviceId: owner)

        _ = try await store.revertLiftStrain(reason: "test", now: 3_000)

        let w = try await workoutPair(store, startA)
        let d = try await dayPair(store, dayA)
        XCTAssertEqual(w, Pair(36, 2), "a value the heart-rate path rewrote is not ours to restore")
        XCTAssertEqual(d, Pair(40, 2), "the untouched combined day is restored")
    }

    func testRevertWithNilHRNeverWritesAVersion2Null() async throws {
        let store = try await newStore()
        try await store.upsertWorkouts([workout(startA, strain: nil, version: nil)], deviceId: owner)
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [computed("L1", start: startA)], now: 500)
        _ = try await apply(store)
        // Simulate the state the old rule mishandled: our combined value is stored but the heart-rate value
        // behind it is gone (the strap's heart rate was later dropped).
        try await exec(store, "UPDATE workout SET strain = 55, strainVersion = 2 WHERE deviceId = ? AND startTs = ?", [owner, startA])
        try await exec(store, """
            UPDATE liftStrainTarget SET hrOnlyStrain = NULL, writtenStrain = 55, writtenStrainVersion = 2
            WHERE kind = 'workout'
            """)

        _ = try await store.revertLiftStrain(reason: "test", now: 3_000)

        let w = try await workoutPair(store, startA)
        XCTAssertEqual(w, Pair(nil, nil), "never (nil, 2): that is not a valid prior state")
    }

    func testDisabledAppliesZeroAndReenableReruns() async throws {
        let store = try await newStore()
        try await seedBasicLift(store)
        _ = try await apply(store)
        _ = try await store.revertLiftStrain(reason: "kill switch", now: 3_000)
        let disabledAfterRevert = try await store.liftStrainDisabled()
        XCTAssertTrue(disabledAfterRevert)
        let wReverted = try await workoutPair(store, startA)
        XCTAssertEqual(wReverted, Pair(30, 2))

        // A lift saved while disabled applies a load of 0.
        try await store.upsertWorkouts([workout(startB, strain: 20, version: 2)], deviceId: owner)
        try await store.upsertDailyMetrics([day(dayB, strain: 50, version: 2)], deviceId: canonical)
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [computed("L2", start: startB, day: dayB, load: 5)], now: 3_500)
        _ = try await apply(store, now: 4_000)
        let w1 = try await workoutPair(store, startA)
        let w2 = try await workoutPair(store, startB)
        let d1 = try await dayPair(store, dayA)
        let d2 = try await dayPair(store, dayB)
        XCTAssertEqual(w1, Pair(30, 2))
        XCTAssertEqual(w2, Pair(20, 2))
        XCTAssertEqual(d1, Pair(40, 2))
        XCTAssertEqual(d2, Pair(50, 2))
        let l2 = try await liftRow(store, "L2")
        XCTAssertEqual(l2?.state, .applied)
        XCTAssertEqual(l2?.appliedMuscularLoad, 0)
        let idle = try await apply(store, now: 4_500)
        XCTAssertEqual(idle.rowsVisited, 0, "disabled rows are not revisited forever")

        try await store.enableLiftStrain(now: 5_000)
        let enabled = try await store.liftStrainDisabled()
        XCTAssertFalse(enabled)
        let jobs = try await rows(store, "SELECT 1 FROM liftStrainJob")
        XCTAssertTrue(jobs.isEmpty)
        _ = try await apply(store, now: 6_000)

        let e1 = try await workoutPair(store, startA)
        let e2 = try await workoutPair(store, startB)
        let ed1 = try await dayPair(store, dayA)
        let ed2 = try await dayPair(store, dayB)
        XCTAssertEqual(e1, Pair(50, 2))
        XCTAssertEqual(e2, Pair(30, 2))
        XCTAssertEqual(ed1, Pair(60, 2))
        XCTAssertEqual(ed2, Pair(60, 2))
    }

    // MARK: Backfill

    func testChunkRollsBackOnOwnerMismatch() async throws {
        let store = try await newStore()
        try await store.upsertWorkouts([workout(startA, strain: 30, version: 2)], deviceId: owner)
        try await store.upsertDailyMetrics([day(dayA, strain: 40, version: 2)], deviceId: canonical)
        try await store.startLiftStrainJob(jobKey: "job", deviceId: owner, formulaVersion: 1, upperDay: dayB, now: 100)
        let stale = HistoricalCursorScope(deviceId: owner, lineage: "a-lineage-from-before-a-purge", cursorEpoch: 41)

        do {
            _ = try await store.applyLiftStrainBackfillChunk(
                sourceOwner: stale, canonicalComputedDeviceId: canonical,
                chunk: LiftStrainChunkInput(rows: [computed("L1", start: startA)], dayKeys: [dayA], lastDay: dayA),
                jobKey: "job", now: 200, combine: combine)
            XCTFail("a stale owner token must reject the chunk")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerChanged(deviceId: owner))
        }

        let liftRows = try await rows(store, "SELECT 1 FROM liftStrain")
        let targets = try await rows(store, "SELECT 1 FROM liftStrainTarget")
        XCTAssertTrue(liftRows.isEmpty)
        XCTAssertTrue(targets.isEmpty)
        let w = try await workoutPair(store, startA)
        let d = try await dayPair(store, dayA)
        XCTAssertEqual(w, Pair(30, 2))
        XCTAssertEqual(d, Pair(40, 2))
        let job = try await store.liftStrainJob(jobKey: "job")
        XCTAssertNil(job?.cursorDay)
        XCTAssertEqual(job?.state, .running)
    }

    func testBackfillChunkAppliesAdvancesCursorAndRerunWritesNothing() async throws {
        let store = try await newStore()
        try await store.upsertWorkouts([workout(startA, strain: 30, version: 2),
                                        workout(startB, strain: 20, version: 2)], deviceId: owner)
        try await store.upsertDailyMetrics([day(dayA, strain: 40, version: 2), day(dayB, strain: 50, version: 2)],
                                           deviceId: canonical)
        try await store.startLiftStrainJob(jobKey: "job", deviceId: owner, formulaVersion: 1, upperDay: dayB, now: 100)
        let scope = try await store.liftStrainOwnerScope(deviceId: owner)
        let chunk = LiftStrainChunkInput(
            rows: [computed("L1", start: startA, day: dayA, load: 10), computed("L2", start: startB, day: dayB, load: 5)],
            dayKeys: [dayA, dayB], lastDay: dayB)

        let r = try await store.applyLiftStrainBackfillChunk(
            sourceOwner: scope, canonicalComputedDeviceId: canonical, chunk: chunk, jobKey: "job", now: 200, combine: combine)

        XCTAssertEqual(r.workoutWrites, 2)
        XCTAssertEqual(r.dayWrites, 2)
        let w1 = try await workoutPair(store, startA)
        let w2 = try await workoutPair(store, startB)
        let d1 = try await dayPair(store, dayA)
        let d2 = try await dayPair(store, dayB)
        XCTAssertEqual(w1, Pair(50, 2))
        XCTAssertEqual(w2, Pair(30, 2))
        XCTAssertEqual(d1, Pair(60, 2))
        XCTAssertEqual(d2, Pair(60, 2))
        let job = try await store.liftStrainJob(jobKey: "job")
        XCTAssertEqual(job?.cursorDay, dayB)
        XCTAssertEqual(job?.liftsApplied, 2)
        XCTAssertEqual(job?.daysApplied, 2)

        // A killed app re-runs the same chunk: nothing at all is written.
        let dump = try await trackingDump(store)
        let again = try await store.applyLiftStrainBackfillChunk(
            sourceOwner: scope, canonicalComputedDeviceId: canonical, chunk: chunk, jobKey: "job", now: 900, combine: combine)
        XCTAssertEqual(again.workoutWrites + again.dayWrites, 0)
        let dumpAfter = try await trackingDump(store)
        XCTAssertEqual(dump.filter { !$0.hasPrefix("liftStrainJob") }, dumpAfter.filter { !$0.hasPrefix("liftStrainJob") })

        let completed = try await store.completeLiftStrainJob(jobKey: "job", now: 1_000)
        XCTAssertTrue(completed)
        try await store.markLiftStrainJobsRefreshed(jobKeys: ["job"], now: 1_100)
        let done = try await store.liftStrainJob(jobKey: "job")
        XCTAssertEqual(done?.state, .complete)
        XCTAssertEqual(done?.completedAt, 1_000)
        XCTAssertEqual(done?.refreshedAt, 1_100)
    }

    func testCompleteJobIsConditionalOnRunning() async throws {
        let store = try await newStore()
        try await store.startLiftStrainJob(jobKey: "a", deviceId: owner, formulaVersion: 1, upperDay: dayB, now: 1)
        try await store.startLiftStrainJob(jobKey: "b", deviceId: owner, formulaVersion: 1, upperDay: dayB, now: 1)
        let first = try await store.completeLiftStrainJob(jobKey: "a", now: 10)
        let second = try await store.completeLiftStrainJob(jobKey: "a", now: 20)
        XCTAssertTrue(first)
        XCTAssertFalse(second, "two runners cannot double-complete")
        let a = try await store.liftStrainJob(jobKey: "a")
        XCTAssertEqual(a?.completedAt, 10)

        // Revert turns every job reverted; a reverted job can never be completed or marked refreshed.
        _ = try await store.revertLiftStrain(reason: "test", now: 30)
        let completeB = try await store.completeLiftStrainJob(jobKey: "b", now: 40)
        XCTAssertFalse(completeB)
        try await store.markLiftStrainJobsRefreshed(jobKeys: ["a", "b"], now: 50)
        let aAfter = try await store.liftStrainJob(jobKey: "a")
        let bAfter = try await store.liftStrainJob(jobKey: "b")
        XCTAssertEqual(aAfter?.state, .reverted)
        XCTAssertEqual(bAfter?.state, .reverted)
        XCTAssertNil(aAfter?.refreshedAt)
        XCTAssertNil(bAfter?.refreshedAt)
    }

    func testRefreshedMarkOnlyTouchesCompleteJobs() async throws {
        let store = try await newStore()
        try await store.startLiftStrainJob(jobKey: "done", deviceId: owner, formulaVersion: 1, upperDay: dayB, now: 1)
        try await store.startLiftStrainJob(jobKey: "running", deviceId: owner, formulaVersion: 1, upperDay: dayB, now: 1)
        _ = try await store.completeLiftStrainJob(jobKey: "done", now: 2)
        try await store.markLiftStrainJobsRefreshed(jobKeys: ["done", "running"], now: 3)
        let done = try await store.liftStrainJob(jobKey: "done")
        let running = try await store.liftStrainJob(jobKey: "running")
        XCTAssertEqual(done?.refreshedAt, 3)
        XCTAssertNil(running?.refreshedAt)
    }

    func testJobKeyPerVersionAndOwner() async throws {
        let store = try await newStore()
        let keys = [("strength-strain-backfill-v1:my-whoop", "my-whoop", 1),
                    ("strength-strain-backfill-v1:whoop-abc", "whoop-abc", 1),
                    ("strength-strain-backfill-v2:my-whoop", "my-whoop", 2)]
        for (key, device, version) in keys {
            try await store.startLiftStrainJob(jobKey: key, deviceId: device, formulaVersion: version, upperDay: dayB, now: 1)
        }
        let all = try await rows(store, "SELECT jobKey FROM liftStrainJob ORDER BY jobKey")
        XCTAssertEqual(all.count, 3)
        _ = try await store.completeLiftStrainJob(jobKey: keys[0].0, now: 5)
        // Starting an existing key again does not reset it (INSERT OR IGNORE).
        try await store.startLiftStrainJob(jobKey: keys[0].0, deviceId: "my-whoop", formulaVersion: 1, upperDay: dayB, now: 9)
        let v1 = try await store.liftStrainJob(jobKey: keys[0].0)
        let other = try await store.liftStrainJob(jobKey: keys[1].0)
        let v2 = try await store.liftStrainJob(jobKey: keys[2].0)
        XCTAssertEqual(v1?.state, .complete)
        XCTAssertEqual(other?.state, .running)
        XCTAssertEqual(v2?.state, .running)
        XCTAssertEqual(v2?.formulaVersion, 2)
        XCTAssertEqual(other?.deviceId, "whoop-abc")
    }

    // MARK: Save path

    private func receiptPayload(owner: String, start: Int, id: String = "receipt-session")
        -> (LiftSessionRow, LiftSetRow, WorkoutRow) {
        let session = LiftSessionRow(
            id: id, deviceId: owner, startTs: start, endTs: start + 600, sport: sport,
            programId: nil, programName: "Upper A", sessionRpe: nil, note: nil)
        let set = LiftSetRow(
            id: "\(id)-set", deviceId: owner, sessionId: session.id, ord: 0, exercise: "Bench press",
            primaryMuscle: .chest, secondaryMuscles: [.triceps], setIndex: 1, weightKg: 80, reps: 8, rpe: 8,
            isWarmup: false, startTs: start, endTs: start + 60, restSec: 120, note: nil)
        return (session, set, workout(start, strain: nil, version: nil))
    }

    func testSaveReceiptLiftStateWritesLiftStrainInSameTransaction() async throws {
        let store = try await newStore()
        let scope = try await store.receiptLiftSourceOwner(deviceId: owner)
        let (session, set, row) = receiptPayload(owner: owner, start: startA)
        let wanted = computed(session.id, start: startA)
        let stray = computed("not-in-this-save", start: startA + 5)

        try await store.saveReceiptLiftStateAndWorkout(
            sourceOwner: scope, data: Data("env".utf8), sessions: [session], sets: [set], workouts: [row],
            liftStrain: [wanted, stray])

        let saved = try await store.liftStrainRows(deviceId: owner, liftSessionIds: [session.id, "not-in-this-save"])
        XCTAssertEqual(saved.map(\.liftSessionId), [session.id], "only rows for sessions in this save are stored")
        XCTAssertEqual(saved.first?.state, .pending)
        XCTAssertEqual(saved.first?.muscularLoad, 10)

        // The legacy device-id variant carries them too.
        let (session2, set2, row2) = receiptPayload(owner: owner, start: startB, id: "legacy-session")
        try await store.saveReceiptLiftStateAndWorkout(
            deviceId: owner, data: Data("env2".utf8), sessions: [session2], sets: [set2], workouts: [row2],
            liftStrain: [computed(session2.id, start: startB, day: dayB)])
        let legacy = try await store.liftStrainRows(deviceId: owner, liftSessionIds: [session2.id])
        XCTAssertEqual(legacy.count, 1)
        XCTAssertEqual(legacy.first?.dayKey, dayB)
    }

    func testRejectedSaveLeavesNoLiftStrainRows() async throws {
        let store = try await newStore()
        let stale = HistoricalCursorScope(deviceId: owner, lineage: "stale-lineage", cursorEpoch: 7)
        let (session, set, row) = receiptPayload(owner: owner, start: startA)

        do {
            try await store.saveReceiptLiftStateAndWorkout(
                sourceOwner: stale, data: Data("env".utf8), sessions: [session], sets: [set], workouts: [row],
                liftStrain: [computed(session.id, start: startA)])
            XCTFail("a stale owner must reject the save")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerChanged(deviceId: owner))
        }

        let strain = try await rows(store, "SELECT 1 FROM liftStrain")
        let envelope = try await rows(store, "SELECT 1 FROM liftReceiptState")
        let workouts = try await rows(store, "SELECT 1 FROM workout")
        XCTAssertTrue(strain.isEmpty)
        XCTAssertTrue(envelope.isEmpty)
        XCTAssertTrue(workouts.isEmpty)
    }

    // MARK: Days

    func testDaysWithoutLiftsAreNeverTouched() async throws {
        let store = try await newStore()
        try await seedBasicLift(store)
        try await store.upsertDailyMetrics([day(dayB, strain: 25.5, version: 2), day("2026-07-19", strain: 61, version: nil)],
                                           deviceId: canonical)
        try await store.upsertDailyMetrics([day(dayA, strain: 71, version: 2)], deviceId: "someone-else-noop")
        let before = try await rows(store, "SELECT * FROM dailyMetric WHERE NOT (deviceId = ? AND day = ?) ORDER BY 1, 2", [canonical, dayA])

        _ = try await apply(store)

        let after = try await rows(store, "SELECT * FROM dailyMetric WHERE NOT (deviceId = ? AND day = ?) ORDER BY 1, 2", [canonical, dayA])
        XCTAssertEqual(before.map { $0.description }, after.map { $0.description })
        let targets = try await rows(store, "SELECT deviceId, keyText FROM liftStrainTarget WHERE kind = 'day'")
        XCTAssertEqual(targets.map { $0["keyText"] as String }, [dayA])
        XCTAssertEqual(targets.map { $0["deviceId"] as String }, [canonical])
    }

    func testRepairedOwnerLiftSettlesCanonicalDay() async throws {
        // DS-R2-2. After a remove and re-add the lift owner is "whoop-abc"; the dashboard can pick the day from
        // "my-whoop-noop" (the primary engine) or "whoop-abc-noop" (a transient engine), so both are settled.
        let store = try await newStore()
        let repaired = "whoop-abc"
        try await store.upsertWorkouts([workout(startA, strain: 30, version: 2)], deviceId: repaired)
        try await store.upsertDailyMetrics([day(dayA, strain: 40, version: 2)], deviceId: canonical)
        try await store.upsertDailyMetrics([day(dayA, strain: 41, version: 2)], deviceId: "whoop-abc-noop")
        try await store.upsertLiftStrainComputed(deviceId: repaired, rows: [computed("L1", start: startA)], now: 500)

        let r = try await apply(store)

        XCTAssertEqual(r.applied, 1)
        let lift = try await liftRow(store, "L1", device: repaired)
        XCTAssertEqual(lift?.state, .applied)
        let primary = try await dayPair(store, dayA)
        let transient = try await dayPair(store, dayA, device: "whoop-abc-noop")
        XCTAssertEqual(primary, Pair(60, 2))
        XCTAssertEqual(transient, Pair(61, 2))
        let targetIds = try await rows(store, "SELECT deviceId FROM liftStrainTarget WHERE kind = 'day' ORDER BY deviceId")
        XCTAssertEqual(targetIds.map { $0["deviceId"] as String }, [canonical, "whoop-abc-noop"].sorted())

        // The transient engine later rewrites the primary day HR-only; the next apply heals it.
        try await store.upsertDailyMetrics([day(dayA, strain: 45, version: 2)], deviceId: canonical)
        let healed = try await apply(store, now: 2_000)
        XCTAssertEqual(healed.dayWrites, 1)
        let primaryAfter = try await dayPair(store, dayA)
        XCTAssertEqual(primaryAfter, Pair(65, 2))
    }

    func testDayLoadSumsAcrossOwners() async throws {
        let store = try await newStore()
        try await store.upsertWorkouts([workout(startA, strain: 30, version: 2)], deviceId: owner)
        try await store.upsertWorkouts([workout(startA + 7_200, strain: 20, version: 2)], deviceId: "whoop-abc")
        try await store.upsertDailyMetrics([day(dayA, strain: 40, version: 2)], deviceId: canonical)
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [computed("L1", start: startA, load: 10)], now: 500)
        try await store.upsertLiftStrainComputed(deviceId: "whoop-abc", rows: [computed("L2", start: startA + 7_200, load: 5)], now: 500)

        _ = try await apply(store)

        let d = try await dayPair(store, dayA)
        XCTAssertEqual(d, Pair(40 + 2 * 15, 2), "M_day is per user: 10 + 5, not per owner")
        let loads = try await store.liftStrainAppliedLoads(dayKey: dayA)
        XCTAssertEqual(loads.map(\.muscularLoad), [10, 5])
        XCTAssertEqual(loads.map(\.deviceId), [owner, "whoop-abc"])
        XCTAssertEqual(loads.first?.workoutEndTs, startA + 3_600)
    }

    func testAppliedLoadsDropAWorkoutRewrittenSinceTheApply() async throws {
        let store = try await newStore()
        try await seedBasicLift(store)
        _ = try await apply(store)
        let before = try await store.liftStrainAppliedLoads(dayKey: dayA)
        XCTAssertEqual(before.count, 1)

        try await store.upsertWorkouts([workout(startA, strain: 35, version: 2)], deviceId: owner)

        let after = try await store.liftStrainAppliedLoads(dayKey: dayA)
        XCTAssertTrue(after.isEmpty, "a reader must not add a muscular load to a value that no longer holds it")
    }

    func testOrphanSweepRestoresCanonicalDayAfterOwnerDataIsDeleted() async throws {
        // A5. A lift saved under a re-paired owner combines into the canonical day; the owner's data is then
        // deleted. Nothing visits the canonical day target, so without the sweep it would keep the lift forever.
        let store = try await newStore()
        let repaired = "whoop-abc"
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: repaired, brand: "WHOOP", model: "WHOOP", sourceKind: .liveBLE,
                                      capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        let scope = try await store.receiptLiftSourceOwner(deviceId: repaired)
        let (session, set, row) = receiptPayload(owner: repaired, start: startA)
        try await store.saveReceiptLiftStateAndWorkout(
            sourceOwner: scope, data: Data("env".utf8), sessions: [session], sets: [set], workouts: [row],
            liftStrain: [computed(session.id, start: startA, load: 9)])
        try await store.upsertWorkouts([workout(startA, strain: 30.7654321, version: 2)], deviceId: repaired)
        try await store.upsertDailyMetrics([day(dayA, strain: 40.123456789, version: 2)], deviceId: canonical)
        _ = try await apply(store)
        let combinedDay = try await dayPair(store, dayA)
        XCTAssertEqual(combinedDay, Pair(40.123456789 + 18, 2))

        try await store.deleteAllData(deviceId: repaired)
        try await store.deleteAllData(deviceId: repaired + "-noop")
        let strainRows = try await rows(store, "SELECT 1 FROM liftStrain")
        XCTAssertTrue(strainRows.isEmpty, "the owner's lift rows went with the owner")

        let r = try await apply(store, now: 2_000)

        XCTAssertEqual(r.dayWrites, 1)
        let restored = try await dayPair(store, dayA)
        XCTAssertEqual(restored, Pair(40.123456789, 2), "bit-identical to the heart-rate value")
        let again = try await apply(store, now: 3_000)
        XCTAssertEqual(again.workoutWrites + again.dayWrites, 0)
    }

    func testTargetsRecordTheRowsFormulaVersion() async throws {
        let store = try await newStore()
        try await store.upsertWorkouts([workout(startA, strain: 30, version: 2)], deviceId: owner)
        try await store.upsertDailyMetrics([day(dayA, strain: 40, version: 2)], deviceId: canonical)
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [computed("L1", start: startA, version: 7)], now: 500)
        _ = try await apply(store)
        let versions = try await rows(store, "SELECT kind, formulaVersion FROM liftStrainTarget ORDER BY kind")
        XCTAssertEqual(versions.map { $0["formulaVersion"] as Int }, [7, 7], "not a hard-coded 1")
    }

    func testLiftStrainRowPrefersTheRequestedOwner() async throws {
        let store = try await newStore()
        try await store.upsertLiftStrainComputed(deviceId: "whoop-abc", rows: [computed("X", start: startA)], now: 1)
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [computed("Y", start: startA)], now: 1)
        let preferred = try await store.liftStrainRow(workoutStartTs: startA, sport: sport, preferredDeviceId: owner)
        let other = try await store.liftStrainRow(workoutStartTs: startA, sport: sport, preferredDeviceId: "whoop-abc")
        let none = try await store.liftStrainRow(workoutStartTs: startA + 1, sport: sport, preferredDeviceId: owner)
        XCTAssertEqual(preferred?.liftSessionId, "Y")
        XCTAssertEqual(other?.liftSessionId, "X")
        XCTAssertNil(none)
    }

    func testBodyweightsAreReadBackPerSession() async throws {
        let store = try await newStore()
        try await store.upsertLiftStrainComputed(deviceId: owner, rows: [
            computed("A", start: startA, isDefaultBodyweight: true), computed("B", start: startB)], now: 1)
        let all = try await store.liftStrainBodyweights(deviceId: owner)
        let one = try await store.liftStrainBodyweights(deviceId: owner, liftSessionIds: ["B", "missing"])
        let none = try await store.liftStrainBodyweights(deviceId: owner, liftSessionIds: [])
        XCTAssertEqual(all["A"], LiftStrainFrozenBodyweight(kg: 80, isDefault: true))
        XCTAssertEqual(all["B"], LiftStrainFrozenBodyweight(kg: 80, isDefault: false))
        XCTAssertEqual(Array(one.keys), ["B"])
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: Owners

    func testArchivedOwnerScopeAdmittedDeletingRejected() async throws {
        let store = try await newStore()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        for id in ["whoop-old", "whoop-del", "whoop-purged"] {
            try registry.add(PairedDevice(id: id, brand: "WHOOP", model: "WHOOP", sourceKind: .liveBLE,
                                          capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        }
        try registry.archive("whoop-old")

        // Archived: admitted for the rescore, still rejected for a save.
        let scope = try await store.liftStrainOwnerScope(deviceId: "whoop-old")
        XCTAssertEqual(scope.deviceId, "whoop-old")
        do {
            _ = try await store.receiptLiftSourceOwner(deviceId: "whoop-old")
            XCTFail("the save-side owner must still reject an archived device")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerArchived(deviceId: "whoop-old"))
        }
        do {
            try await store.saveReceiptLiftStateAndWorkout(
                deviceId: "whoop-old", data: Data("x".utf8), sessions: [], sets: [], workouts: [])
            XCTFail("the default save must still reject an archived device")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerArchived(deviceId: "whoop-old"))
        }

        // Missing.
        do {
            _ = try await store.liftStrainOwnerScope(deviceId: "nobody")
            XCTFail("a missing owner must throw")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerUnavailable(deviceId: "nobody"))
        }

        // Deleting.
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO sourceTransitionJournal (
                    transitionId, version, mutationKind, sourceDeviceId,
                    contributorIdsJSON, transitionScope, historicalEpoch,
                    externalEpoch, sinkEpoch, stage, createdAt, updatedAt
                ) VALUES (?, ?, 'deleteData', ?, ?, 'targetOnly', ?, ?, ?, 'prepared', ?, ?)
                """, arguments: ["t-del", 2, "whoop-del", Data("[\"whoop-del\"]".utf8), 1, 1, 1, 1, 1])
        }
        do {
            _ = try await store.liftStrainOwnerScope(deviceId: "whoop-del")
            XCTFail("a deleting owner must throw")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerDeleting(deviceId: "whoop-del"))
        }

        // Purged.
        let purgedScope = try await store.receiptLiftSourceOwner(deviceId: "whoop-purged")
        let databaseId = try await store.registryWriter.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM todayHealthSnapshotDatabase LIMIT 1")!
        }
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                INSERT INTO historicalReceiptScopeLifecycle (
                    databaseInstanceId, deviceId, lineage, cursorEpoch, trimScope,
                    state, closedThroughGeneration, reason, updatedAt
                ) VALUES (?, ?, ?, ?, ?, 'discarded', 0, ?, ?)
                """, arguments: [databaseId, "whoop-purged", purgedScope.lineage, purgedScope.cursorEpoch,
                                 HistoricalCursorScope.defaultTrimScope, "test-purge", 1])
        }
        do {
            _ = try await store.liftStrainOwnerScope(deviceId: "whoop-purged")
            XCTFail("a purged owner must throw")
        } catch let error as LiftReceiptStateError {
            XCTAssertEqual(error, .ownerPurged(deviceId: "whoop-purged"))
        }
    }

    func testOwnerIdsListEveryEnvelopeInStableOrder() async throws {
        let store = try await newStore()
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(id: "zz", brand: "WHOOP", model: "WHOOP", sourceKind: .liveBLE,
                                      capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        let none = try await store.liftStrainOwnerIds()
        XCTAssertTrue(none.isEmpty)
        try await store.saveReceiptLiftState(deviceId: "zz", data: Data("1".utf8))
        try await store.saveReceiptLiftState(deviceId: owner, data: Data("2".utf8))
        let ids = try await store.liftStrainOwnerIds()
        XCTAssertEqual(ids, [owner, "zz"])
    }

    // MARK: Overlay and DailyMetric helper

    func testFitnessAgeOverlayReplacesOnlyWrittenStrain() {
        let targets = [
            LiftStrainDayTarget(deviceId: "my-whoop-noop", dayKey: "2026-07-17", hrOnlyStrain: 40, writtenStrain: 60, writtenStrainVersion: 2),
            LiftStrainDayTarget(deviceId: "my-whoop-noop", dayKey: "2026-07-19", hrOnlyStrain: 10, writtenStrain: 30, writtenStrainVersion: 2),
        ]
        let days = [
            day("2026-07-16", strain: 60, version: 2),     // no target
            day("2026-07-17", strain: 60, version: 2),     // IS the written value
            day("2026-07-18", strain: 60, version: nil),   // imported: same number, no target
            day("2026-07-19", strain: 31, version: 2),     // has a target, but the value was rewritten since
        ]

        let out = LiftStrainFitnessAgeOverlay.hrOnly(days: days, targets: targets)

        XCTAssertEqual(out.map(\.strain), [60, 40, 60, 31])
        XCTAssertEqual(out[1], days[1].replacingStrain(40))
        XCTAssertEqual(out[0], days[0])
        XCTAssertEqual(out[2], days[2])
        XCTAssertEqual(out[3], days[3])
        XCTAssertEqual(LiftStrainFitnessAgeOverlay.hrOnly(days: days, targets: []), days)
        // Same number but a different version is not ours.
        let wrongVersion = [day("2026-07-17", strain: 60, version: nil)]
        XCTAssertEqual(LiftStrainFitnessAgeOverlay.hrOnly(days: wrongVersion, targets: targets), wrongVersion)
    }

    func testReplacingStrainCopiesEveryOtherField() {
        let original = DailyMetric(
            day: "2026-07-17", totalSleepMin: 1, efficiency: 2, deepMin: 3, remMin: 4, lightMin: 5, disturbances: 6,
            restingHr: 7, avgHrv: 8, recovery: 9, strain: 10, exerciseCount: 11, spo2Pct: 12, skinTempDevC: 13,
            respRateBpm: 14, steps: 15, activeKcalEst: 16, spo2Red: 17, spo2Ir: 18, strainVersion: 2)
        let replaced = original.replacingStrain(99)
        XCTAssertEqual(replaced.strain, 99)
        XCTAssertEqual(replaced, DailyMetric(
            day: "2026-07-17", totalSleepMin: 1, efficiency: 2, deepMin: 3, remMin: 4, lightMin: 5, disturbances: 6,
            restingHr: 7, avgHrv: 8, recovery: 9, strain: 99, exerciseCount: 11, spo2Pct: 12, skinTempDevC: 13,
            respRateBpm: 14, steps: 15, activeKcalEst: 16, spo2Red: 17, spo2Ir: 18, strainVersion: 2))
        XCTAssertNil(original.replacingStrain(nil).strain)
        XCTAssertEqual(original.replacingStrain(10), original)
    }
}
