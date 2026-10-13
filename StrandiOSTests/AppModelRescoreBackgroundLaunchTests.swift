#if targetEnvironment(simulator)
import XCTest
import WhoopProtocol
import WhoopStore
@testable import NOOP

/// A process iOS launches in the background (the history-rescore processing task, Bluetooth restoration) gets no
/// scene-phase edge, so AppModel's `applicationIsActive` keeps its initial `true`. The processing-task entry used to
/// gate on that flag alone, so on a cold launch it returned without running a chunk, re-armed the request and failed,
/// on every wake, until the owner opened and left the app in that same process.
@MainActor
final class AppModelRescoreBackgroundLaunchTests: XCTestCase {
    private var v3Key: String { IntelligenceEngine.effortRescoreDurableProgressKey }

    /// Three days of regular heart rate ending now, so the migration has history to rescore in one chunk.
    private func storeWithRecentHistory() async throws -> WhoopStore {
        let store = try await WhoopStore.inMemory()
        let now = Int(Date().timeIntervalSince1970)
        var streams = Streams()
        for ts in stride(from: now - 3 * 86_400, to: now - 600, by: 60) {
            streams.hr.append(HRSample(ts: ts, bpm: 58 + ts % 9))
            streams.gravity.append(GravitySample(ts: ts, x: 0, y: 0, z: 1))
        }
        _ = try await store.insert(streams, deviceId: Repository.whoopSource)
        return store
    }

    /// A model as a background launch leaves it: the store open and loaded, no scene edge ever delivered.
    private func coldBackgroundModel(_ store: WhoopStore) -> AppModel {
        let model = AppModel()
        model.repo.setStoreForTesting(store)
        model.repo.loaded = true
        model.isGenuinelyBackground = { true }
        model.isLowPowerModeEnabled = { false }
        return model
    }

    private func withRescoreDefaultsReset(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let keys = [IntelligenceEngine.effortRescoreFlagKey, IntelligenceEngine.effortRescoreOffsetKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        for key in keys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    func testAColdBackgroundLaunchRunsAChunkThroughTheProcessingTaskEntry() async throws {
        try await withRescoreDefaultsReset {
            let store = try await storeWithRecentHistory()
            let model = coldBackgroundModel(store)
            let pendingBefore = await model.effortRescoreIsPending()
            XCTAssertTrue(pendingBefore)

            await model.runEffortRescoreForBackgroundTask(maxChunks: 1)

            let v3 = try await store.durableMigrationProgress(key: v3Key)
            XCTAssertEqual(v3?.state, .complete, "three days of history are one chunk, and the chunk ran")
        }
    }

    /// The flag's initial value stays: a model that is in the foreground (UIApplication says so) still does nothing.
    func testAForegroundModelDoesNotRunAChunkThroughTheProcessingTaskEntry() async throws {
        try await withRescoreDefaultsReset {
            let store = try await storeWithRecentHistory()
            let model = coldBackgroundModel(store)
            model.isGenuinelyBackground = { false }

            await model.runEffortRescoreForBackgroundTask(maxChunks: 1)

            let v3 = try await store.durableMigrationProgress(key: v3Key)
            XCTAssertNotEqual(v3?.state, .complete)
            XCTAssertEqual(v3?.nextOffset ?? 0, 0)
        }
    }

    func testLowPowerModeSkipsTheProcessingTaskRescore() async throws {
        try await withRescoreDefaultsReset {
            let store = try await storeWithRecentHistory()
            let model = coldBackgroundModel(store)
            model.isLowPowerModeEnabled = { true }

            await model.runEffortRescoreForBackgroundTask(maxChunks: 1)

            let v3 = try await store.durableMigrationProgress(key: v3Key)
            XCTAssertNotEqual(v3?.state, .complete)
        }
    }

    /// An import (or a strap backfill, or a workout) still stops the processing-task rescore.
    func testABackfillStopsTheProcessingTaskRescore() async throws {
        try await withRescoreDefaultsReset {
            let store = try await storeWithRecentHistory()
            let model = coldBackgroundModel(store)
            model.live.backfilling = true

            await model.runEffortRescoreForBackgroundTask(maxChunks: 1)

            let v3 = try await store.durableMigrationProgress(key: v3Key)
            XCTAssertNotEqual(v3?.state, .complete)
        }
    }
}
#endif
