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

    func testSchemaCreatesSleepRecoveryAuditTableAndIndexes() async throws {
        let store = try await WhoopStore.inMemory()
        XCTAssertEqual(WhoopStoreInfo.schemaVersion, 31)
        XCTAssertTrue(try await store.tableNames().contains("sleepRecoveryAttempt"))

        let columns = Set(try await store.columnNamesForTest(table: "sleepRecoveryAttempt"))
        XCTAssertTrue([
            "id", "deviceId", "source", "requestedStartTs", "requestedEndTs",
            "outcome", "confidence", "reason", "resultStartTs", "resultEndTs",
            "stagesAvailable", "restingHr", "avgHrv", "algorithmVersion",
            "createdAt", "updatedAt",
        ].allSatisfy(columns.contains))

        let indexes = try await store.indexNamesForTest(table: "sleepRecoveryAttempt")
        XCTAssertTrue(indexes.contains("idx_sleepRecoveryAttempt_device_updated"))
        XCTAssertTrue(indexes.contains("idx_sleepRecoveryAttempt_device_window"))
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
        XCTAssertEqual(
            try await store.sleepSessions(deviceId: device, from: 0, to: 10_000, limit: 10).count,
            1)
        XCTAssertEqual(try await store.sleepRecoveryAttempts(deviceId: device).count, 1)
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
        XCTAssertEqual(
            try await store.sleepSessions(deviceId: device, from: 0, to: 10_000, limit: 10),
            [existing])

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

        let saved = try XCTUnwrap(
            try await store.sleepSessions(deviceId: device, from: 0, to: 10_000, limit: 10).first)
        XCTAssertNil(saved.stagesJSON)
        XCTAssertNil(saved.efficiency)
        XCTAssertEqual(saved.restingHr, 49)
        XCTAssertEqual(saved.avgHrv, 57)
        XCTAssertEqual(try await store.sleepRecoveryAttempts(deviceId: device).first?.outcome, "partial")
    }
}
