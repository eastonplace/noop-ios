import XCTest
import GRDB
@testable import WhoopStore

final class SleepSessionUndoTransactionTests: XCTestCase {
    private let owner = "my-whoop-noop"
    private let day = "2026-10-20"

    private func session(start: Int = 1_000, end: Int = 29_800,
                         adjusted: Int? = nil, edited: Bool = true) -> CachedSleepSession {
        CachedSleepSession(startTs: start, endTs: end, efficiency: 0.875, restingHr: 52,
                           avgHrv: 61, stagesJSON: "{\"awake\":60,\"light\":260,\"deep\":70,\"rem\":90}",
                           userEdited: edited, startTsAdjusted: adjusted)
    }

    private func daily(strain: Double = 25, steps: Int = 5_000) -> DailyMetric {
        DailyMetric(day: day, totalSleepMin: 420, efficiency: 0.875, deepMin: 70,
                    remMin: 90, lightMin: 260, disturbances: 3, restingHr: 52, avgHrv: 61,
                    recovery: 78, strain: strain, exerciseCount: 1, spo2Pct: 97,
                    skinTempDevC: 0.2, respRateBpm: 14, steps: steps, activeKcalEst: 350,
                    spo2Red: 42, spo2Ir: 43, strainVersion: 2)
    }

    private func recovery(sessionStart: Int = 1_000) -> SleepRecoveryDailyOverride {
        SleepRecoveryDailyOverride(day: day, sessionStartTs: sessionStart,
            totalSleepMin: 420, efficiency: 0.875, deepMin: 70, remMin: 90, lightMin: 260,
            disturbances: 3, restingHr: 52, avgHrv: 61, recovery: 78, restScore: 88,
            chargeWeightedSumWithoutSleep: 0.72, chargeWeightWithoutSleep: 0.85,
            chargeBaselineUsable: true, sleepNeedHours: 8.2, sleepConsistency: 0.91,
            updatedAt: 10_000)
    }

    private func seedRecovered(_ store: WhoopStore) async throws {
        _ = try await store.upsertSleepSessions([session()], deviceId: owner)
        _ = try await store.persistSessionMotion(deviceId: owner, sessionStart: 1_000,
                                                  motionEpochs: [0.1, 0.2, 0.3])
        _ = try await store.persistSessionSleepState(deviceId: owner, sessionStart: 1_000,
                                                      states: [1, 2, 3])
        _ = try await store.persistSleepRecoveryDailyOverride(recovery(), daily: daily(), deviceId: owner)
    }

    /// Deletion triggers clear the protected daily fields. Undo restores that evidence and its
    /// baseline context while retaining activity updated after the deletion.
    func testRecoveredSleepUndoRestoresProtectedDailyFields() async throws {
        let store = try await WhoopStore.inMemory()
        try await seedRecovered(store)
        let deleted = try await store.snapshotAndDeleteSleepSession(deviceIds: [owner], startTs: 1_000)
        let snapshot = try XCTUnwrap(deleted)
        try await store.registryWriter.write { db in
            try db.execute(sql: "UPDATE dailyMetric SET strain = 63, steps = 9000, exerciseCount = 2")
        }

        let result = try await store.restoreDeletedSleepSession(snapshot)

        let restoredOverride = try await store.sleepRecoveryDailyOverride(deviceId: owner, sessionStartTs: 1_000)
        let restoredDays = try await store.dailyMetrics(deviceId: owner, from: day, to: day)
        let restoredRest = try await store.metricSeries(deviceId: owner, key: "sleep_performance", from: day, to: day)
        let restoredMotion = try await store.sessionMotion(deviceId: owner, sessionStart: 1_000)
        let restoredState = try await store.sessionSleepState(deviceId: owner, sessionStart: 1_000)
        XCTAssertEqual(result, .restored)
        XCTAssertEqual(restoredOverride, recovery())
        XCTAssertEqual(restoredDays.first?.recovery, 78)
        XCTAssertEqual(restoredDays.first?.totalSleepMin, 420)
        XCTAssertEqual(restoredDays.first?.strain, 63)
        XCTAssertEqual(restoredDays.first?.steps, 9_000)
        XCTAssertEqual(restoredDays.first?.exerciseCount, 2)
        XCTAssertEqual(restoredDays.first?.activeKcalEst, 350)
        XCTAssertEqual(restoredDays.first?.spo2Pct, 97)
        XCTAssertEqual(restoredRest.first?.value, 88)
        XCTAssertEqual(restoredMotion, [0.1, 0.2, 0.3])
        XCTAssertEqual(restoredState, [1, 2, 3])
    }

    func testSnapshotUsesImmutableKeyAfterOnsetMovedAndKeepsOwnerPriority() async throws {
        let store = try await WhoopStore.inMemory()
        let shifted = session(adjusted: 3_400)
        _ = try await store.upsertSleepSessions([shifted], deviceId: owner)
        _ = try await store.upsertSleepSessions([session(end: 25_000)], deviceId: "whoop-readded-noop")

        let snapshot = try await store.sleepSessionSnapshot(
            deviceIds: [owner, "whoop-readded-noop", "my-whoop"], startTs: 1_000)

        XCTAssertEqual(snapshot?.session, shifted)
        XCTAssertEqual(snapshot?.ownerDeviceId, owner)
    }

    func testDeletionFailureRollsBackSessionAndProtectedDailyFields() async throws {
        let store = try await WhoopStore.inMemory()
        try await seedRecovered(store)
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_sleep_cleanup BEFORE DELETE ON metricSeries
                BEGIN SELECT RAISE(ABORT, 'injected cleanup failure'); END
                """)
        }
        do {
            _ = try await store.snapshotAndDeleteSleepSession(deviceIds: [owner], startTs: 1_000)
            XCTFail("a failed cleanup must roll the complete deletion back")
        } catch {}

        let saved = try await store.sleepSessionSnapshot(deviceIds: [owner], startTs: 1_000)
        let dailyRows = try await store.dailyMetrics(deviceId: owner, from: day, to: day)
        XCTAssertEqual(saved?.session, session())
        XCTAssertEqual(saved?.recoveryOverride, recovery())
        XCTAssertEqual(saved?.motion, [0.1, 0.2, 0.3])
        XCTAssertEqual(dailyRows.first?.recovery, 78)
    }

    func testRestoreFailureRollsBackSessionAuxiliaryAndRecoveryWrites() async throws {
        let store = try await WhoopStore.inMemory()
        try await seedRecovered(store)
        let deleted = try await store.snapshotAndDeleteSleepSession(deviceIds: [owner], startTs: 1_000)
        let snapshot = try XCTUnwrap(deleted)
        try await store.registryWriter.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_sleep_restore BEFORE INSERT ON metricSeries
                BEGIN SELECT RAISE(ABORT, 'injected restoration failure'); END
                """)
        }
        do {
            _ = try await store.restoreDeletedSleepSession(snapshot)
            XCTFail("a failed Rest write must not leave a partial restored session")
        } catch {}

        let saved = try await store.sleepSessionSnapshot(deviceIds: [owner], startTs: 1_000)
        let restoredOverride = try await store.sleepRecoveryDailyOverride(deviceId: owner, sessionStartTs: 1_000)
        let dailyRows = try await store.dailyMetrics(deviceId: owner, from: day, to: day)
        XCTAssertNil(saved)
        XCTAssertNil(restoredOverride)
        XCTAssertNil(dailyRows.first?.recovery)
        XCTAssertEqual(dailyRows.first?.strain, 25)
    }

    func testRestoreRefusesToOverwriteNewerSameKeySession() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([session()], deviceId: owner)
        let deleted = try await store.snapshotAndDeleteSleepSession(deviceIds: [owner], startTs: 1_000)
        let snapshot = try XCTUnwrap(deleted)
        let newer = session(end: 25_000, adjusted: 2_000)
        _ = try await store.upsertSleepSessions([newer], deviceId: owner)

        let result = try await store.restoreDeletedSleepSession(snapshot)

        let saved = try await store.sleepSessionSnapshot(deviceIds: [owner], startTs: 1_000)
        XCTAssertEqual(result, .conflict)
        XCTAssertEqual(saved?.session, newer)
    }

    func testRestoreRefusesToReplaceAnotherRecoveryOnTheSameDay() async throws {
        let store = try await WhoopStore.inMemory()
        try await seedRecovered(store)
        let deleted = try await store.snapshotAndDeleteSleepSession(deviceIds: [owner], startTs: 1_000)
        let snapshot = try XCTUnwrap(deleted)
        _ = try await store.upsertSleepSessions([session(start: 40_000, end: 68_800)], deviceId: owner)
        _ = try await store.persistSleepRecoveryDailyOverride(
            recovery(sessionStart: 40_000), daily: daily(strain: 40), deviceId: owner)

        let result = try await store.restoreDeletedSleepSession(snapshot)

        let oldRow = try await store.sleepSessionSnapshot(deviceIds: [owner], startTs: 1_000)
        let newer = try await store.sleepRecoveryDailyOverride(deviceId: owner, sessionStartTs: 40_000)
        XCTAssertEqual(result, .conflict)
        XCTAssertNil(oldRow)
        XCTAssertEqual(newer, recovery(sessionStart: 40_000))
    }

    func testUndoSnapshotCannotBeAppliedToAReplacementDatabase() async throws {
        let originalStore = try await WhoopStore.inMemory()
        _ = try await originalStore.upsertSleepSessions([session()], deviceId: owner)
        let deleted = try await originalStore.snapshotAndDeleteSleepSession(deviceIds: [owner], startTs: 1_000)
        let snapshot = try XCTUnwrap(deleted)
        let replacementStore = try await WhoopStore.inMemory()

        let result = try await replacementStore.restoreDeletedSleepSession(snapshot)

        let saved = try await replacementStore.sleepSessionSnapshot(deviceIds: [owner], startTs: 1_000)
        XCTAssertEqual(result, .conflict)
        XCTAssertNil(saved)
    }

    func testMissingDeletionReturnsNoUndoSnapshot() async throws {
        let store = try await WhoopStore.inMemory()
        let snapshot = try await store.snapshotAndDeleteSleepSession(deviceIds: [owner], startTs: 1_000)
        XCTAssertNil(snapshot)
    }

    func testEditDoesNotOverwriteAChangedSessionAfterStaging() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([session()], deviceId: owner)
        let read = try await store.sleepSessionSnapshot(deviceIds: [owner], startTs: 1_000)
        let snapshot = try XCTUnwrap(read)
        _ = try await store.applySleepEdit(deviceId: owner, detectedStartTs: 1_000,
                                           newStartTs: 3_000, newEndTs: 25_000, stagesJSON: "[]")

        let changed = try await store.applySleepEdit(to: snapshot, newStartTs: 2_000,
                                                     newEndTs: 28_000, stagesJSON: "{}")

        let saved = try await store.sleepSessionSnapshot(deviceIds: [owner], startTs: 1_000)
        XCTAssertFalse(changed)
        XCTAssertEqual(saved?.session.effectiveStartTs, 3_000)
        XCTAssertEqual(saved?.session.endTs, 25_000)
        XCTAssertEqual(saved?.session.stagesJSON, "[]")
    }

    func testEditDoesNotInvalidateRecoveryAddedWhileStaging() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.upsertSleepSessions([session()], deviceId: owner)
        let read = try await store.sleepSessionSnapshot(deviceIds: [owner], startTs: 1_000)
        let snapshot = try XCTUnwrap(read)
        _ = try await store.persistSleepRecoveryDailyOverride(recovery(), daily: daily(), deviceId: owner)

        let changed = try await store.applySleepEdit(to: snapshot, newStartTs: 2_000,
                                                     newEndTs: 28_000, stagesJSON: "{}")

        let saved = try await store.sleepSessionSnapshot(deviceIds: [owner], startTs: 1_000)
        XCTAssertFalse(changed)
        XCTAssertEqual(saved?.session, session())
        XCTAssertEqual(saved?.recoveryOverride, recovery())
    }
}
