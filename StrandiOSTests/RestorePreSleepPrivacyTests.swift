import XCTest
import GRDB
import StrandAnalytics
import WhoopStore
@testable import NOOP

private actor RestoreAdmissionBarrier {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilReleased() async {
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { waiters.append(continuation) }
        }
    }

    func release() {
        guard !released else { return }
        released = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private actor RestoreIdentityReadBarrier {
    private var entered = false
    private var released = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { continuation in
            if released { continuation.resume() }
            else { releaseWaiter = continuation }
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiter = continuation
        }
    }

    func release() {
        guard !released else { return }
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class RestorePreSleepPrivacyTests: XCTestCase {
    private func withDisabledConsent<T>(_ operation: () async throws -> T) async rethrows -> T {
        let defaults = UserDefaults.standard
        let oldValue = defaults.object(forKey: PreSleepHeartRateFeedback.enabledKey)
        defaults.set(false, forKey: PreSleepHeartRateFeedback.enabledKey)
        defer {
            if let oldValue { defaults.set(oldValue, forKey: PreSleepHeartRateFeedback.enabledKey) }
            else { defaults.removeObject(forKey: PreSleepHeartRateFeedback.enabledKey) }
        }
        return try await operation()
    }

    private func makeStoreWithArchivedSource() async throws -> (WhoopStore, String) {
        let store = try await WhoopStore.inMemory()
        let archived = "whoop-restored-archived"
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        try registry.add(PairedDevice(
            id: Repository.whoopSource,
            brand: "WHOOP",
            model: "WHOOP 4.0",
            sourceKind: .historyBLE,
            capabilities: [.hr, .sleep],
            status: .active,
            addedAt: 1,
            lastSeenAt: 1
        ))
        try registry.add(PairedDevice(
            id: archived,
            brand: "WHOOP",
            model: "WHOOP 5.0",
            sourceKind: .historyBLE,
            capabilities: [.hr, .sleep],
            status: .archived,
            addedAt: 2,
            lastSeenAt: 2
        ))
        return (store, archived)
    }

    func testRestoreOpenScrubsCanonicalArchivedAndOrphanFeedbackBeforeRefresh() async throws {
        try await withDisabledConsent {
            let (store, archived) = try await makeStoreWithArchivedSource()
            let repository = Repository(deviceId: Repository.whoopSource)
            repository.setStoreForTesting(store)
            let day = "2026-09-03"
            let orphan = "orphan-noop"
            let points = PreSleepHeartRateFeedback.metricKeys.map {
                MetricPoint(day: day, key: $0, value: 64)
            }
            for source in [Repository.whoopSource + "-noop", archived + "-noop", orphan] {
                _ = try await store.upsertMetricSeries(points, deviceId: source)
            }
            _ = try await store.upsertMetricSeries([
                MetricPoint(day: day, key: "sleep_performance", value: 82)
            ], deviceId: orphan)

            try await repository.reopenStoreAfterRestore()

            for source in [Repository.whoopSource + "-noop", archived + "-noop", orphan] {
                for key in PreSleepHeartRateFeedback.metricKeys {
                    let rows = try await store.metricSeries(
                        deviceId: source, key: key, from: day, to: day
                    )
                    XCTAssertTrue(rows.isEmpty, "restored feedback survived for \(source) \(key)")
                }
            }
            let unrelated = try await store.metricSeries(
                deviceId: orphan, key: "sleep_performance", from: day, to: day
            )
            XCTAssertEqual(unrelated.map(\.value), [82])
        }
    }

    func testRestoreOpenScrubsWithoutRegistryEnumeration() async throws {
        try await withDisabledConsent {
            let (store, _) = try await makeStoreWithArchivedSource()
            let repository = Repository(deviceId: Repository.whoopSource)
            repository.setStoreForTesting(store)
            let day = "2026-09-03"
            let source = Repository.whoopSource + "-noop"
            _ = try await store.upsertMetricSeries([
                MetricPoint(day: day, key: PreSleepHeartRateFeedback.meanMetricKey, value: 64)
            ], deviceId: source)
            try await store.registryWriter.write { db in
                try db.execute(sql: "ALTER TABLE pairedDevice RENAME TO pairedDeviceUnavailable")
            }

            try await repository.reopenStoreAfterRestore()

            let retained = try await store.metricSeries(
                deviceId: source,
                key: PreSleepHeartRateFeedback.meanMetricKey,
                from: day,
                to: day
            )
            XCTAssertTrue(retained.isEmpty)
        }
    }

    func testRestoreAdmissionBlocksOrdinaryHandleUntilReplacementIsScrubbed() async throws {
        try await withDisabledConsent {
            let oldStore = try await WhoopStore.inMemory()
            let replacementStore = try await WhoopStore.inMemory()
            let oldDatabaseId = try await oldStore.databaseInstanceId()
            let replacementDatabaseId = try await replacementStore.databaseInstanceId()
            XCTAssertNotEqual(oldDatabaseId, replacementDatabaseId)

            let day = "2026-09-03"
            let orphan = "orphan-noop"
            _ = try await replacementStore.upsertMetricSeries([
                MetricPoint(
                    day: day,
                    key: PreSleepHeartRateFeedback.meanMetricKey,
                    value: 64
                )
            ], deviceId: orphan)

            let repository = Repository(deviceId: Repository.whoopSource)
            repository.setStoreForTesting(oldStore)
            try await repository.quiesceStoreForRestore()
            repository.setStoreForTesting(replacementStore)

            let barrier = RestoreAdmissionBarrier()
            let reopen = Task { @MainActor in
                await barrier.waitUntilReleased()
                try await repository.reopenStoreAfterRestore()
            }

            let blockedHandle = await repository.storeHandle()
            XCTAssertNil(blockedHandle)

            await barrier.release()
            try await reopen.value

            let admittedHandle = await repository.storeHandle()
            let admittedDatabaseId = try await admittedHandle?.databaseInstanceId()
            XCTAssertEqual(admittedDatabaseId, replacementDatabaseId)
            let scrubbed = try await replacementStore.metricSeries(
                deviceId: orphan,
                key: PreSleepHeartRateFeedback.meanMetricKey,
                from: day,
                to: day
            )
            XCTAssertTrue(scrubbed.isEmpty)
        }
    }

    func testRestoreQuiesceInvalidatesHandlePausedDuringDatabaseIdentityRead() async throws {
        try await withDisabledConsent {
            let oldStore = try await WhoopStore.inMemory()
            let replacementStore = try await WhoopStore.inMemory()
            let oldDatabaseId = try await oldStore.databaseInstanceId()
            let replacementDatabaseId = try await replacementStore.databaseInstanceId()
            XCTAssertNotEqual(oldDatabaseId, replacementDatabaseId)

            let repository = Repository(deviceId: Repository.whoopSource)
            repository.setStoreForTesting(oldStore)
            let barrier = RestoreIdentityReadBarrier()
            repository.todayHealthSnapshotDatabaseIdentityReadHook = {
                await barrier.wait()
            }

            let pendingHandle = Task { @MainActor in
                await repository.storeHandle()
            }
            await barrier.waitUntilEntered()

            try await repository.quiesceStoreForRestore()
            await barrier.release()

            let staleHandle = await pendingHandle.value
            XCTAssertNil(staleHandle)
            XCTAssertNil(repository.todayHealthSnapshotDatabaseIdentityForTesting())

            repository.todayHealthSnapshotDatabaseIdentityReadHook = nil
            repository.setStoreForTesting(replacementStore)
            try await repository.reopenStoreAfterRestore()

            let admittedHandle = await repository.storeHandle()
            let admittedDatabaseId = try await admittedHandle?.databaseInstanceId()
            XCTAssertEqual(admittedDatabaseId, replacementDatabaseId)
            XCTAssertEqual(
                repository.todayHealthSnapshotDatabaseIdentityForTesting(),
                replacementDatabaseId
            )
        }
    }
}
