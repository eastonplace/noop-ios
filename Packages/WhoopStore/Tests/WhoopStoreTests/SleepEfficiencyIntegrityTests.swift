import GRDB
import XCTest
@testable import WhoopStore

final class SleepEfficiencyIntegrityTests: XCTestCase {
    private func session(
        start: Int,
        efficiency: Double?,
        stages: String? = #"[{"start":1000,"end":4600,"stage":"light"}]"#,
        edited: Bool = false
    ) -> CachedSleepSession {
        CachedSleepSession(
            startTs: start,
            endTs: start + 3_600,
            efficiency: efficiency,
            restingHr: 52,
            avgHrv: 61,
            stagesJSON: stages,
            userEdited: edited)
    }

    private func daily(day: String, efficiency: Double?) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: 300,
            efficiency: efficiency,
            deepMin: 60,
            remMin: 70,
            lightMin: 170,
            disturbances: 2,
            restingHr: 52,
            avgHrv: 61,
            recovery: nil,
            strain: nil,
            exerciseCount: nil)
    }

    private func dailyOverride(day: String, start: Int, efficiency: Double?) -> SleepRecoveryDailyOverride {
        SleepRecoveryDailyOverride(
            day: day,
            sessionStartTs: start,
            totalSleepMin: 300,
            efficiency: efficiency,
            deepMin: 60,
            remMin: 70,
            lightMin: 170,
            disturbances: 2,
            restingHr: 52,
            avgHrv: 61,
            recovery: nil,
            restScore: 80,
            updatedAt: 10_000)
    }

    private func audit(id: String, start: Int, end: Int) -> SleepRecoveryAuditRecord {
        SleepRecoveryAuditRecord(
            id: id,
            source: "manual_window",
            requestedStartTs: start,
            requestedEndTs: end,
            outcome: "complete",
            confidence: 0.8,
            reason: "bounded_reanalysis",
            resultStartTs: start,
            resultEndTs: end,
            stagesAvailable: true,
            restingHr: 52,
            avgHrv: 61,
            algorithmVersion: "sleep-window-recovery-v1",
            createdAt: 10_000,
            updatedAt: 10_000)
    }

    func testFutureStoreWritesNormalizePlaceholderAndImpossibleEfficiencies() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "efficiency-integrity"
        let starts = [100_000, 110_000, 120_000, 130_000, 140_000]

        _ = try await store.upsertSleepSessions([
            session(start: starts[0], efficiency: 0),
            session(start: starts[1], efficiency: -0.1),
            session(start: starts[2], efficiency: 101),
            session(start: starts[3], efficiency: 0.88),
            session(start: starts[4], efficiency: 88),
        ], deviceId: device)
        _ = try await store.upsertDailyMetrics([
            daily(day: "2026-07-21", efficiency: 0),
            daily(day: "2026-07-22", efficiency: -1),
            daily(day: "2026-07-23", efficiency: 101),
            daily(day: "2026-07-24", efficiency: 0.88),
            daily(day: "2026-07-25", efficiency: 88),
        ], deviceId: device)

        let sessions = try await store.sleepSessions(
            deviceId: device, from: 0, to: 1_000_000, limit: 20)
        let sessionEfficiency = Dictionary(
            uniqueKeysWithValues: sessions.map { ($0.startTs, $0.efficiency) })
        XCTAssertNil(sessionEfficiency[starts[0]] ?? nil)
        XCTAssertNil(sessionEfficiency[starts[1]] ?? nil)
        XCTAssertNil(sessionEfficiency[starts[2]] ?? nil)
        XCTAssertEqual(sessionEfficiency[starts[3]] ?? nil, 0.88)
        XCTAssertEqual(sessionEfficiency[starts[4]] ?? nil, 88)

        let days = try await store.dailyMetrics(
            deviceId: device, from: "2026-07-21", to: "2026-07-25")
        let dailyEfficiency = Dictionary(
            uniqueKeysWithValues: days.map { ($0.day, $0.efficiency) })
        XCTAssertNil(dailyEfficiency["2026-07-21"] ?? nil)
        XCTAssertNil(dailyEfficiency["2026-07-22"] ?? nil)
        XCTAssertNil(dailyEfficiency["2026-07-23"] ?? nil)
        XCTAssertEqual(dailyEfficiency["2026-07-24"] ?? nil, 0.88)
        XCTAssertEqual(dailyEfficiency["2026-07-25"] ?? nil, 88)
    }

    func testEditingBoundsOrStagesClearsEfficiencyFromTheOldShape() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "efficiency-edit"
        let start = 100_000
        let originalStages = #"[{"start":100000,"end":103600,"stage":"light"}]"#
        let editedStages = #"[{"start":100300,"end":103300,"stage":"deep"}]"#

        _ = try await store.upsertSleepSessions([
            session(start: start, efficiency: 0.9, stages: originalStages)
        ], deviceId: device)
        _ = try await store.applySleepEdit(
            deviceId: device,
            detectedStartTs: start,
            newStartTs: start + 300,
            newEndTs: start + 3_300,
            stagesJSON: editedStages)

        var rows = try await store.sleepSessions(
            deviceId: device, from: 0, to: 1_000_000, limit: 10)
        var saved = try XCTUnwrap(rows.first)
        XCTAssertNil(saved.efficiency,
                     "the old denominator must not survive a user-edited sleep shape")

        // A later stage-only self-heal also invalidates any prior stored ratio. The UI can derive from the
        // newly persisted stages until analytics writes a fresh authoritative value.
        _ = try await store.upsertSleepSessions([
            session(start: start + 10_000, efficiency: 0.91, stages: originalStages, edited: true)
        ], deviceId: device)
        _ = try await store.updateSleepStages(
            deviceId: device,
            detectedStartTs: start + 10_000,
            stagesJSON: editedStages)
        rows = try await store.sleepSessions(
            deviceId: device, from: start + 10_000, to: start + 10_000, limit: 10)
        saved = try XCTUnwrap(rows.first)
        XCTAssertNil(saved.efficiency)
    }

    func testAtomicManualRecoveryKeepsFreshValidEfficiency() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "efficiency-recovery"
        let start = 200_000
        let oldStages = #"[{"start":200000,"end":203600,"stage":"light"}]"#
        let freshStages = #"[{"start":200000,"end":203600,"stage":"deep"}]"#

        _ = try await store.upsertSleepSessions([
            session(start: start, efficiency: 0.9, stages: oldStages, edited: true)
        ], deviceId: device)
        let recovered = session(
            start: start,
            efficiency: 0.75,
            stages: freshStages,
            edited: true)
        _ = try await store.replaceWithManualSleepRecovery(
            recovered,
            deviceId: device,
            audit: audit(id: "fresh-efficiency", start: start, end: start + 3_600))

        let rows = try await store.sleepSessions(
            deviceId: device, from: start, to: start, limit: 10)
        let saved = try XCTUnwrap(rows.first)
        XCTAssertEqual(saved.efficiency, 0.75,
                       "an atomic reanalysis that supplies a distinct fresh value must retain it")
        XCTAssertEqual(saved.stagesJSON, freshStages)
    }

    func testManualRecoveryNormalizesInvalidSessionOverrideAndDailyEfficiency() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "efficiency-recovery-placeholder"
        let start = 300_000
        let day = "2026-07-26"
        let recovered = session(start: start, efficiency: 0, edited: true)

        _ = try await store.replaceWithManualSleepRecovery(
            recovered,
            deviceId: device,
            audit: audit(id: "placeholder-efficiency", start: start, end: start + 3_600),
            dailyOverride: dailyOverride(day: day, start: start, efficiency: 0),
            daily: daily(day: day, efficiency: 0))

        let sessions = try await store.sleepSessions(
            deviceId: device, from: start, to: start, limit: 10)
        XCTAssertNil(try XCTUnwrap(sessions.first).efficiency)

        let dailyRows = try await store.dailyMetrics(deviceId: device, from: day, to: day)
        XCTAssertNil(try XCTUnwrap(dailyRows.first).efficiency)

        let persistedOverride = try await store.sleepRecoveryDailyOverride(
            deviceId: device,
            sessionStartTs: start)
        XCTAssertNil(try XCTUnwrap(persistedOverride).efficiency)
    }

    func testMigrationHealsLegacyRowsAndInstallsDurableGuards() async throws {
        let dbQueue = try DatabaseQueue()
        try WhoopStore.makeMigrator().migrate(dbQueue)
        try WhoopStore.makeSleepRecoveryMigrator().migrate(
            dbQueue,
            upTo: "sleep-window-recovery-charge-context-v1")

        try await dbQueue.write { db in
            try db.execute(sql: """
                INSERT INTO sleepSession
                    (deviceId, startTs, endTs, efficiency, userEdited)
                VALUES
                    ('legacy', 1000, 5000, 0, 0),
                    ('legacy', 6000, 10000, 0.9, 0),
                    ('legacy', 11000, 15000, 90, 0),
                    ('legacy', 16000, 20000, 101, 0)
                """)
            try db.execute(sql: """
                INSERT INTO dailyMetric
                    (deviceId, day, totalSleepMin, efficiency)
                VALUES
                    ('legacy', '2026-07-20', 300, 0),
                    ('legacy', '2026-07-21', 300, 0.9),
                    ('legacy', '2026-07-22', 300, 90),
                    ('legacy', '2026-07-23', 300, 101)
                """)
            try db.execute(sql: """
                INSERT INTO sleepRecoveryDailyOverride
                    (deviceId, day, sessionStartTs, totalSleepMin, efficiency, updatedAt)
                VALUES
                    ('legacy', '2026-07-20', 1000, 300, 0, 10000),
                    ('legacy', '2026-07-21', 6000, 300, 0.9, 10000),
                    ('legacy', '2026-07-22', 11000, 300, 90, 10000),
                    ('legacy', '2026-07-23', 16000, 300, 101, 10000)
                """)
        }

        try WhoopStore.makeSleepRecoveryMigrator().migrate(dbQueue)

        try await dbQueue.read { db in
            XCTAssertNil(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 1000"))
            XCTAssertEqual(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 6000"), 0.9)
            XCTAssertEqual(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 11000"), 90)
            XCTAssertNil(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM sleepSession WHERE startTs = 16000"))

            XCTAssertNil(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-07-20'"))
            XCTAssertNil(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM dailyMetric WHERE day = '2026-07-23'"))
            XCTAssertNil(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM sleepRecoveryDailyOverride WHERE day = '2026-07-20'"))
            XCTAssertNil(try Double.fetchOne(
                db, sql: "SELECT efficiency FROM sleepRecoveryDailyOverride WHERE day = '2026-07-23'"))

            XCTAssertEqual(
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = ?",
                    arguments: ["sleep-efficiency-integrity-v1"]),
                1)
            let triggerCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'trigger' AND name LIKE '%efficiency_integrity%'
                """)
            XCTAssertEqual(triggerCount, 6)
        }
    }
}
