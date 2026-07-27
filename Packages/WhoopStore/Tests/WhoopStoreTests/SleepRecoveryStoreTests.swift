import XCTest
@testable import WhoopStore

final class SleepRecoveryStoreTests: XCTestCase {
    private func session(
        start: Int,
        end: Int,
        edited: Bool,
        stages: String? = "[{\"start\":1000,\"end\":5000,\"stage\":\"light\"}]",
        restingHr: Int? = 52,
        avgHrv: Double? = 61
    ) -> CachedSleepSession {
        CachedSleepSession(
            startTs: start,
            endTs: end,
            efficiency: stages == nil ? nil : 0.86,
            restingHr: restingHr,
            avgHrv: avgHrv,
            stagesJSON: stages,
            userEdited: edited,
            startTsAdjusted: nil)
    }

    private func audit(
        id: String,
        start: Int,
        end: Int,
        outcome: String = "complete",
        stagesAvailable: Bool = true
    ) -> SleepRecoveryAuditRecord {
        SleepRecoveryAuditRecord(
            id: id,
            source: "manual_window",
            requestedStartTs: start,
            requestedEndTs: end,
            outcome: outcome,
            confidence: 0.82,
            reason: "bounded_reanalysis",
            resultStartTs: start,
            resultEndTs: end,
            stagesAvailable: stagesAvailable,
            restingHr: 52,
            avgHrv: 61,
            algorithmVersion: "sleep-window-recovery-v1",
            createdAt: 10_000,
            updatedAt: 10_000)
    }

    private func daily(
        day: String = "2026-07-26",
        sleep: Double? = 420,
        recovery: Double? = 77,
        strain: Double? = 21,
        steps: Int? = 5_000
    ) -> DailyMetric {
        DailyMetric(
            day: day,
            totalSleepMin: sleep,
            efficiency: sleep == nil ? nil : 0.88,
            deepMin: sleep == nil ? nil : 70,
            remMin: sleep == nil ? nil : 90,
            lightMin: sleep == nil ? nil : 260,
            disturbances: sleep == nil ? nil : 3,
            restingHr: sleep == nil ? nil : 50,
            avgHrv: sleep == nil ? nil : 64,
            recovery: recovery,
            strain: strain,
            exerciseCount: strain == nil ? nil : 1,
            steps: steps,
            strainVersion: strain == nil ? nil : 2)
    }

    private func dailyOverride(
        day: String = "2026-07-26",
        sessionStart: Int = 1_000,
        restScore: Double? = 88
    ) -> SleepRecoveryDailyOverride {
        SleepRecoveryDailyOverride(
            day: day,
            sessionStartTs: sessionStart,
            totalSleepMin: 420,
            efficiency: 0.88,
            deepMin: 70,
            remMin: 90,
            lightMin: 260,
            disturbances: 3,
            restingHr: 50,
            avgHrv: 64,
            recovery: 77,
            restScore: restScore,
            updatedAt: 10_000)
    }

    private func persistCompleteRecovery(
        store: WhoopStore,
        device: String = "my-whoop-noop",
        start: Int = 1_000,
        end: Int = 5_000
    ) async throws {
        _ = try await store.replaceWithManualSleepRecovery(
            session(start: start, end: end, edited: true),
            deviceId: device,
            audit: audit(id: "complete-\(start)", start: start, end: end),
            dailyOverride: dailyOverride(sessionStart: start),
            daily: daily())
    }

    func testFeatureMigrationCreatesRecoveryTablesAndIndexes() async throws {
        let store = try await WhoopStore.inMemory()
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 30)
        let tables = try await store.tableNames()
        XCTAssertTrue(tables.contains("sleepRecoveryAttempt"))
        XCTAssertTrue(tables.contains("sleepRecoveryDailyOverride"))

        let auditColumns = Set(try await store.columnNamesForTest(table: "sleepRecoveryAttempt"))
        XCTAssertTrue([
            "id", "deviceId", "source", "requestedStartTs", "requestedEndTs",
            "outcome", "confidence", "reason", "resultStartTs", "resultEndTs",
            "stagesAvailable", "restingHr", "avgHrv", "algorithmVersion",
            "createdAt", "updatedAt",
        ].allSatisfy(auditColumns.contains))

        let overrideColumns = Set(try await store.columnNamesForTest(table: "sleepRecoveryDailyOverride"))
        XCTAssertTrue([
            "deviceId", "day", "sessionStartTs", "totalSleepMin", "efficiency",
            "deepMin", "remMin", "lightMin", "disturbances", "restingHr",
            "avgHrv", "recovery", "restScore", "updatedAt",
        ].allSatisfy(overrideColumns.contains))

        let auditIndexes = try await store.indexNamesForTest(table: "sleepRecoveryAttempt")
        XCTAssertTrue(auditIndexes.contains("idx_sleepRecoveryAttempt_device_updated"))
        XCTAssertTrue(auditIndexes.contains("idx_sleepRecoveryAttempt_device_window"))
        let overrideIndexes = try await store.indexNamesForTest(table: "sleepRecoveryDailyOverride")
        XCTAssertTrue(overrideIndexes.contains("idx_sleepRecoveryDailyOverride_session"))
    }

    func testManualRecoveryAtomicallyReplacesOverlappingAutomaticSession() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "my-whoop-noop"
        try await store.upsertSleepSessions(
            [session(start: 1_000, end: 5_000, edited: false)],
            deviceId: device)

        let manual = session(start: 1_200, end: 4_800, edited: true)
        let result = try await store.replaceWithManualSleepRecovery(
            manual,
            deviceId: device,
            audit: audit(id: "replace", start: 1_200, end: 4_800))

        guard case .inserted(let removed) = result else {
            return XCTFail("expected a newly inserted manual session")
        }
        XCTAssertEqual(removed, 1)

        let rows = try await store.sleepSessions(deviceId: device, from: 0, to: 10_000, limit: 10)
        XCTAssertEqual(rows, [manual])
        let attempts = try await store.sleepRecoveryAttempts(deviceId: device)
        XCTAssertEqual(attempts.count, 1)
        XCTAssertEqual(attempts[0].outcome, "complete")
    }

    func testSameWindowReprocessingIsIdempotent() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "my-whoop-noop"
        let manual = session(start: 2_000, end: 7_000, edited: true)
        let record = audit(id: "same-window", start: 2_000, end: 7_000)

        _ = try await store.replaceWithManualSleepRecovery(manual, deviceId: device, audit: record)
        let second = try await store.replaceWithManualSleepRecovery(manual, deviceId: device, audit: record)

        guard case .updated(let removed) = second else {
            return XCTFail("expected the existing manual session to update in place")
        }
        XCTAssertEqual(removed, 0)
        let sessions = try await store.sleepSessions(deviceId: device, from: 0, to: 10_000, limit: 10)
        let attempts = try await store.sleepRecoveryAttempts(deviceId: device)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(attempts.count, 1)
    }

    func testOverlappingEditedSessionIsNeverSilentlyOverwritten() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "my-whoop-noop"
        let existing = session(start: 1_000, end: 5_000, edited: true)
        try await store.upsertSleepSessions([existing], deviceId: device)

        let candidate = session(start: 1_500, end: 4_500, edited: true)
        let result = try await store.replaceWithManualSleepRecovery(
            candidate,
            deviceId: device,
            audit: audit(id: "conflict", start: 1_500, end: 4_500))

        guard case .conflict(let conflicting) = result else {
            return XCTFail("expected an edited-overlap conflict")
        }
        XCTAssertEqual(conflicting, existing)
        let sessions = try await store.sleepSessions(deviceId: device, from: 0, to: 10_000, limit: 10)
        XCTAssertEqual(sessions, [existing])

        let attempts = try await store.sleepRecoveryAttempts(deviceId: device)
        XCTAssertEqual(attempts.first?.outcome, "overlap_conflict")
        XCTAssertEqual(attempts.first?.reason, "overlapping_user_edited_session")
    }

    func testPartialRecoveryPersistsVitalsWithoutInventingStages() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "my-whoop-noop"
        let partial = session(
            start: 3_000,
            end: 9_000,
            edited: true,
            stages: nil,
            restingHr: 49,
            avgHrv: 57)
        let record = SleepRecoveryAuditRecord(
            id: "partial",
            source: "manual_window",
            requestedStartTs: 3_000,
            requestedEndTs: 9_000,
            outcome: "partial",
            confidence: 0.58,
            reason: "sparse_motion",
            resultStartTs: 3_000,
            resultEndTs: 9_000,
            stagesAvailable: false,
            restingHr: 49,
            avgHrv: 57,
            algorithmVersion: "sleep-window-recovery-v1",
            createdAt: 10_000,
            updatedAt: 10_000)

        _ = try await store.replaceWithManualSleepRecovery(partial, deviceId: device, audit: record)

        let sessions = try await store.sleepSessions(deviceId: device, from: 0, to: 10_000, limit: 10)
        let saved = try XCTUnwrap(sessions.first)
        let attempts = try await store.sleepRecoveryAttempts(deviceId: device)
        XCTAssertNil(saved.stagesJSON)
        XCTAssertNil(saved.efficiency)
        XCTAssertEqual(saved.restingHr, 49)
        XCTAssertEqual(saved.avgHrv, 57)
        XCTAssertEqual(attempts.first?.outcome, "partial")
    }

    func testDailyOverrideSurvivesEngineUpsertsWhileActivityKeepsRefreshing() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "my-whoop-noop"
        try await persistCompleteRecovery(store: store, device: device)

        try await store.upsertDailyMetrics(
            [daily(sleep: 60, recovery: 5, strain: 43, steps: 11_000)],
            deviceId: device)
        try await store.upsertMetricSeries(
            [MetricPoint(day: "2026-07-26", key: "sleep_performance", value: 12)],
            deviceId: device)

        let dailyRows = try await store.dailyMetrics(
            deviceId: device, from: "2026-07-26", to: "2026-07-26")
        let row = try XCTUnwrap(dailyRows.first)
        XCTAssertEqual(row.totalSleepMin, 420)
        XCTAssertEqual(row.recovery, 77)
        XCTAssertEqual(row.strain, 43)
        XCTAssertEqual(row.steps, 11_000)

        let rest = try await store.metricSeries(
            deviceId: device, key: "sleep_performance",
            from: "2026-07-26", to: "2026-07-26")
        XCTAssertEqual(rest.first?.value, 88)
        let dailyOverrides = try await store.sleepRecoveryDailyOverrides(deviceId: device)
        XCTAssertEqual(dailyOverrides.count, 1)
    }

    func testDailyDeleteDuringReconcileCannotEraseRecoveredNight() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "my-whoop-noop"
        try await persistCompleteRecovery(store: store, device: device)

        _ = try await store.deleteDailyMetrics(
            deviceId: device, from: "2026-07-26", to: "2026-07-26")

        let rows = try await store.dailyMetrics(
            deviceId: device, from: "2026-07-26", to: "2026-07-26")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.totalSleepMin, 420)
        XCTAssertEqual(rows.first?.recovery, 77)
    }

    func testEditingRecoveredBoundsInvalidatesProtectedDerivedValues() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "my-whoop-noop"
        try await persistCompleteRecovery(store: store, device: device)

        _ = try await store.applySleepEdit(
            deviceId: device,
            detectedStartTs: 1_000,
            newStartTs: 1_100,
            newEndTs: 4_800,
            stagesJSON: "[{\"start\":1100,\"end\":4800,\"stage\":\"light\"}]")

        let dailyOverrides = try await store.sleepRecoveryDailyOverrides(deviceId: device)
        XCTAssertTrue(dailyOverrides.isEmpty)
        let dailyRows = try await store.dailyMetrics(
            deviceId: device, from: "2026-07-26", to: "2026-07-26")
        let row = try XCTUnwrap(dailyRows.first)
        XCTAssertNil(row.totalSleepMin)
        XCTAssertNil(row.restingHr)
        XCTAssertNil(row.avgHrv)
        XCTAssertNil(row.recovery)
        let rest = try await store.metricSeries(
            deviceId: device, key: "sleep_performance",
            from: "2026-07-26", to: "2026-07-26")
        XCTAssertTrue(rest.isEmpty)
    }

    func testDeletingRecoveredSessionClearsProtectedDerivedValues() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "my-whoop-noop"
        try await persistCompleteRecovery(store: store, device: device)

        _ = try await store.deleteSleepSession(deviceId: device, startTs: 1_000)

        let dailyOverrides = try await store.sleepRecoveryDailyOverrides(deviceId: device)
        XCTAssertTrue(dailyOverrides.isEmpty)
        let dailyRows = try await store.dailyMetrics(
            deviceId: device, from: "2026-07-26", to: "2026-07-26")
        let row = try XCTUnwrap(dailyRows.first)
        XCTAssertNil(row.totalSleepMin)
        XCTAssertNil(row.recovery)
        let rest = try await store.metricSeries(
            deviceId: device, key: "sleep_performance",
            from: "2026-07-26", to: "2026-07-26")
        XCTAssertTrue(rest.isEmpty)
    }

    func testDailyAndOverrideMustBeSuppliedTogether() async throws {
        let store = try await WhoopStore.inMemory()
        let device = "my-whoop-noop"
        do {
            _ = try await store.replaceWithManualSleepRecovery(
                session(start: 1_000, end: 5_000, edited: true),
                deviceId: device,
                audit: audit(id: "invalid-pair", start: 1_000, end: 5_000),
                dailyOverride: dailyOverride(),
                daily: nil)
            XCTFail("expected incomplete daily override to fail")
        } catch {
            XCTAssertEqual(error as? SleepRecoveryStoreError, .incompleteDailyOverride)
        }

        let sessions = try await store.sleepSessions(deviceId: device, from: 0, to: 10_000, limit: 10)
        let attempts = try await store.sleepRecoveryAttempts(deviceId: device)
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(attempts.isEmpty)
    }
}
