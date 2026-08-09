import XCTest
import GRDB
import NoopPhase34Core
@testable import WhoopStore

private func maintenanceScope(
    store: WhoopStore,
    deviceId: String
) async throws -> HistoricalAnalysisScope {
    let databaseInstanceId = try await store.databaseInstanceId()
    let cursor = try await store.historicalCursorScope(deviceId: deviceId)
    return try HistoricalAnalysisScope(
        databaseInstanceId: databaseInstanceId,
        sourceId: deviceId,
        deviceId: deviceId,
        deviceLineageId: cursor.lineage,
        cursorEpoch: cursor.cursorEpoch,
        trimScope: cursor.trimScope)
}

final class MaintenanceSourceLifecycleTests: XCTestCase {
    func testNoActiveSourceDurablyCancelsBroadRepairInsteadOfPublishing() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let registry = DeviceRegistryStore(dbQueue: writer)
        let sourceA = "my-whoop"
        let scopeA = try await maintenanceScope(store: store, deviceId: sourceA)

        try await store.enqueueFullHistoryRepairMaintenance(
            scope: scopeA,
            throughReceiptGeneration: 1,
            reason: "legacy_receipt_v1",
            recordedTimeZoneIdentifier: "UTC")
        _ = try await store.commitSourceLifecycleMutation(
            .archive(
                deviceId: sourceA,
                replacementActiveId: nil,
                consumerId: "maintenance-test"))

        XCTAssertNil(try registry.activeDeviceId())
        let result = try await writer.read { db -> (String?, String?, String?) in
            let row = try Row.fetchOne(db, sql: """
                SELECT state, leaseOwner, lastErrorCode
                FROM historicalMaintenanceWork
                WHERE deviceId = ? AND lineage = ?
                """, arguments: [sourceA, scopeA.deviceLineageId])
            return (row?["state"], row?["leaseOwner"], row?["lastErrorCode"])
        }
        XCTAssertEqual(result.0, "quarantined")
        XCTAssertNil(result.1)
        XCTAssertEqual(result.2, "source_archived")
        let noActiveLease = try await store.leaseNextFullHistoryRepair(owner: "no-active-test")
        XCTAssertNil(noActiveLease)
    }

    func testActiveBArchivedACancelsAAndKeepsBEligible() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let registry = DeviceRegistryStore(dbQueue: writer)
        let sourceA = "my-whoop"
        let sourceB = "source-b"
        let scopeA = try await maintenanceScope(store: store, deviceId: sourceA)
        try await store.enqueueFullHistoryRepairMaintenance(
            scope: scopeA,
            throughReceiptGeneration: 1,
            reason: "legacy_receipt_v1",
            recordedTimeZoneIdentifier: "UTC")
        try registry.add(PairedDevice(
            id: sourceB,
            brand: "Polar",
            model: "H10",
            sourceKind: .liveBLE,
            capabilities: [.hr, .hrv],
            status: .paired,
            addedAt: 2,
            lastSeenAt: 2))

        _ = try await store.commitSourceLifecycleMutation(.selectExisting(deviceId: sourceB))
        _ = try await store.commitSourceLifecycleMutation(
            .archive(
                deviceId: sourceA,
                replacementActiveId: sourceB,
                consumerId: "maintenance-test"))

        XCTAssertEqual(try registry.activeDeviceId(), sourceB)
        XCTAssertEqual(try registry.all().first { $0.id == sourceA }?.status, .archived)
        let cancelledA = try await writer.read { db -> (String?, String?) in
            let row = try Row.fetchOne(db, sql: """
                SELECT state, lastErrorCode FROM historicalMaintenanceWork
                WHERE deviceId = ? AND lineage = ?
                """, arguments: [sourceA, scopeA.deviceLineageId])
            return (row?["state"], row?["lastErrorCode"])
        }
        XCTAssertEqual(cancelledA.0, "quarantined")
        XCTAssertEqual(cancelledA.1, "source_deactivated")

        let scopeB = try await maintenanceScope(store: store, deviceId: sourceB)
        try await store.enqueueFullHistoryRepairMaintenance(
            scope: scopeB,
            throughReceiptGeneration: 2,
            reason: "timestamp_heal_without_exact_days",
            recordedTimeZoneIdentifier: "UTC")
        let leasedB = try await store.leaseNextFullHistoryRepair(
            owner: "active-b-test",
            scope: HistoricalCursorScope(
                deviceId: sourceB,
                lineage: scopeB.deviceLineageId,
                cursorEpoch: scopeB.cursorEpoch,
                trimScope: scopeB.trimScope))
        XCTAssertEqual(leasedB?.scope.deviceId, sourceB)
        XCTAssertEqual(leasedB?.scope.deviceLineageId, scopeB.deviceLineageId)
    }

    func testTargetOnlyDeleteRejectsLateMaintenanceAndExactReenqueue() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let registry = DeviceRegistryStore(dbQueue: writer)
        let sourceA = "my-whoop"
        let sourceB = "source-b"
        let oldScopeA = try await maintenanceScope(store: store, deviceId: sourceA)
        try await store.enqueueFullHistoryRepairMaintenance(
            scope: oldScopeA,
            throughReceiptGeneration: 1,
            reason: "legacy_receipt_v1",
            recordedTimeZoneIdentifier: "UTC")
        try registry.add(PairedDevice(
            id: sourceB,
            brand: "Polar",
            model: "H10",
            sourceKind: .liveBLE,
            capabilities: [.hr, .hrv],
            status: .paired,
            addedAt: 2,
            lastSeenAt: 2))
        _ = try await store.commitSourceLifecycleMutation(.selectExisting(deviceId: sourceB))
        XCTAssertEqual(try registry.activeDeviceId(), sourceB)

        _ = try await store.commitSourceLifecycleMutation(
            .deleteData(deviceId: sourceA, consumerId: "maintenance-delete-test"))

        let day = try CivilDay(key: "2026-08-08")
        let lateExact = try HistoricalAnalysisWork(
            scope: oldScopeA,
            firstReceiptGeneration: 1,
            lastReceiptGeneration: 1,
            minimumTs: 1_775_779_200,
            maximumTs: 1_775_865_599,
            affectedDays: [day],
            kind: .exactDays,
            recordedTimeZoneIdentifier: "UTC",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        do {
            _ = try await store.enqueueHistoricalAnalysisWork(lateExact, priority: 20)
            XCTFail("deleted scope accepted stale exact work")
        } catch HistoricalWorkStoreError.discardedScope {
            // Expected. The discarded lifecycle tombstone is the durable race fence.
        }

        try await store.enqueueFullHistoryRepairMaintenance(
            scope: oldScopeA,
            throughReceiptGeneration: 2,
            reason: "stale_after_delete",
            recordedTimeZoneIdentifier: "UTC")
        let staleRows = try await writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM historicalMaintenanceWork
                WHERE deviceId = ? AND lineage = ?
                """, arguments: [sourceA, oldScopeA.deviceLineageId]) ?? 0
        }
        XCTAssertEqual(staleRows, 0)
        XCTAssertEqual(try registry.activeDeviceId(), sourceB)
    }

    func testMissingSourceCannotCreateOrphanBroadRepair() async throws {
        let store = try await WhoopStore.inMemory()
        let writer = await store.dbWriter
        let databaseInstanceId = try await store.databaseInstanceId()
        let missingScope = try HistoricalAnalysisScope(
            databaseInstanceId: databaseInstanceId,
            sourceId: "missing-source",
            deviceId: "missing-source",
            deviceLineageId: "missing-lineage",
            cursorEpoch: 0,
            trimScope: "historical")

        try await store.enqueueFullHistoryRepairMaintenance(
            scope: missingScope,
            throughReceiptGeneration: 1,
            reason: "stale_missing_source",
            recordedTimeZoneIdentifier: "UTC")

        let rowCount = try await writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM historicalMaintenanceWork
                WHERE deviceId = ? AND lineage = ?
                """, arguments: [missingScope.deviceId, missingScope.deviceLineageId]) ?? 0
        }
        XCTAssertEqual(rowCount, 0)
    }
}
