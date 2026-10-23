import XCTest
import WhoopProtocol
import WhoopStore
@testable import NOOP

@MainActor
final class RepositoryWorkoutSuggestionTests: XCTestCase {
    private let dismissedKey = "workouts.autoDetectDismissed"

    private func withDetectionEnabled(_ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let enabled = defaults.object(forKey: PuffinExperiment.autoDetectWorkoutsKey)
        let dismissed = defaults.object(forKey: dismissedKey)
        defaults.set(true, forKey: PuffinExperiment.autoDetectWorkoutsKey)
        defaults.removeObject(forKey: dismissedKey)
        defer {
            defaults.set(enabled, forKey: PuffinExperiment.autoDetectWorkoutsKey)
            defaults.set(dismissed, forKey: dismissedKey)
        }
        try await body()
    }

    private func seed(_ store: WhoopStore, source: String, start: Int,
                      activityClass: Int? = nil) async throws {
        let hr = (0...1_237).map { HRSample(ts: start + $0, bpm: 145) }
        let steps = activityClass.map { cls in
            (0...1_237).map { StepSample(ts: start + $0, counter: $0 * 2, activityClass: cls) }
        } ?? []
        _ = try await store.insert(Streams(hr: hr, steps: steps), deviceId: source)
    }

    private func fixture(source: String = Repository.whoopSource,
                         activityClass: Int? = nil) async throws
        -> (Repository, WhoopStore, AutoWorkoutSuggestion, Date) {
        let store = try await WhoopStore.inMemory()
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(
            PairedDevice(id: source, brand: "WHOOP", model: "WHOOP", sourceKind: .liveBLE,
                         capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
        let repository = Repository(deviceId: source)
        repository.setStoreForTesting(store)
        repository.adoptActiveDeviceId(source)
        // This fixture represents a completed source handoff, without running dashboard publication.
        repository.verifiedExternalSurfaceFenced = false
        let now = Date()
        let start = Int(now.timeIntervalSince1970) - 7_200
        try await seed(store, source: source, start: start, activityClass: activityClass)
        let candidate = await repository.autoDetectedWorkoutSuggestion(now: now)
        return (repository, store, try XCTUnwrap(candidate), now)
    }

    private func history(sport: String, start: Int, source: String = "manual") -> [WorkoutRow] {
        (1...3).map { day in
            let timestamp = start - day * 86_400
            return WorkoutRow(startTs: timestamp, endTs: timestamp + 1_237, sport: sport,
                              source: source, durationS: 1_237, energyKcal: nil, avgHr: 140,
                              maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
        }
    }

    func testClassificationUsesMovementFromTheSameRawSource() async throws {
        try await withDetectionEnabled {
            let (repository, store, candidate, now) = try await fixture(source: "test-current-strap")
            let start = candidate.window.startSec
            let alienSteps = (0...1_237).map {
                StepSample(ts: start + $0, counter: $0 * 2, activityClass: 2)
            }
            _ = try await store.insert(Streams(steps: alienSteps), deviceId: Repository.whoopSource)
            let next = await repository.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertEqual(next?.sourceId, "test-current-strap")
            XCTAssertEqual(next?.prediction.sport, "Workout", "another source's movement was borrowed")
            _ = try await store.insert(Streams(steps: alienSteps), deviceId: "test-current-strap")
            let classified = await repository.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertEqual(classified?.prediction.sport, "Running")
        }
    }

    func testOnlySourceOwnedUserConfirmedHistoryTeachesTheSuggestion() async throws {
        try await withDetectionEnabled {
            let (repository, store, candidate, now) = try await fixture(source: "test-current-strap")
            let start = candidate.window.startSec
            try await store.upsertWorkouts(history(sport: "Cycling", start: start),
                                           deviceId: Repository.whoopSource)
            try await store.upsertWorkouts(history(sport: "Strength", start: start, source: "whoop"),
                                           deviceId: "test-current-strap")
            let unrelated = await repository.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertEqual(unrelated?.prediction.sport, "Workout")
            try await store.upsertWorkouts(history(sport: "Cycling", start: start),
                                           deviceId: "test-current-strap")
            let learned = await repository.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertEqual(learned?.prediction.sport, "Cycling")
            XCTAssertEqual(learned?.prediction.confidence, .possible)
            _ = try await store.deleteWorkouts(deviceId: "test-current-strap", sport: "Cycling",
                                               from: 0, to: start)
            let forgotten = await repository.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertEqual(forgotten?.prediction.sport, "Workout", "deleted corrections survived in a cache")
        }
    }

    func testSaveUsesChosenTypeExactBoundsAndTheCandidateOwner() async throws {
        try await withDetectionEnabled {
            let (repository, store, candidate, now) = try await fixture(source: "test-current-strap")
            let result = await repository.saveWorkoutSuggestion(candidate, type: "Strength", now: now)
            XCTAssertEqual(result, .saved)
            let rows = try await store.workouts(deviceId: "test-current-strap",
                                                from: candidate.window.startSec,
                                                to: candidate.window.endSec, limit: 10)
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(row.sport, "Strength")
            XCTAssertEqual(row.source, "manual")
            XCTAssertEqual(row.startTs, candidate.window.startSec)
            XCTAssertEqual(row.endTs, candidate.window.endSec, "minute display rounding truncated the saved window")
            XCTAssertEqual(row.durationS, 1_237)
            XCTAssertNil(row.energyKcal)
            XCTAssertNil(row.strain)
            XCTAssertNil(row.notes)
            XCTAssertTrue(repository.editedDayRescoreQueue.timestamps.contains(row.endTs))
            let canonical = try await store.workouts(deviceId: Repository.whoopSource, from: 0,
                                                     to: Int(now.timeIntervalSince1970), limit: 10)
            XCTAssertTrue(canonical.isEmpty)
            let afterSave = await repository.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertNil(afterSave)
            let secondSave = await repository.saveWorkoutSuggestion(candidate, type: "Cycling", now: now)
            XCTAssertEqual(secondSave, .alreadySaved)
        }
    }

    func testCanonicalHistoryCandidateIsSavedToItsOriginalOwnerAfterARePair() async throws {
        try await withDetectionEnabled {
            let (repository, store, _, now) = try await fixture()
            try DeviceRegistryStore(dbQueue: store.registryWriter).add(
                PairedDevice(id: "test-repaired-strap", brand: "WHOOP", model: "WHOOP", sourceKind: .liveBLE,
                             capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
            repository.adoptActiveDeviceId("test-repaired-strap")
            repository.verifiedExternalSurfaceFenced = false
            let next = await repository.autoDetectedWorkoutSuggestion(now: now)
            let candidate = try XCTUnwrap(next)
            XCTAssertEqual(candidate.sourceId, Repository.whoopSource)
            let saved = await repository.saveWorkoutSuggestion(candidate, type: "Walking", now: now)
            XCTAssertEqual(saved, .saved)
            let newSourceRows = try await store.workouts(deviceId: "test-repaired-strap", from: 0,
                                                         to: Int(now.timeIntervalSince1970), limit: 10)
            XCTAssertTrue(newSourceRows.isEmpty)
        }
    }

    func testExistingDismissalIsDurableAndTheToggleStillGatesDetection() async throws {
        try await withDetectionEnabled {
            let (repository, store, candidate, now) = try await fixture()
            XCTAssertTrue(repository.dismissWorkoutSuggestion(candidate))
            let afterDismiss = await repository.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertNil(afterDismiss)
            let reopened = Repository(deviceId: Repository.whoopSource)
            reopened.setStoreForTesting(store)
            let reopenedCandidate = await reopened.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertNil(reopenedCandidate)
            UserDefaults.standard.removeObject(forKey: dismissedKey)
            UserDefaults.standard.set(false, forKey: PuffinExperiment.autoDetectWorkoutsKey)
            let disabled = await repository.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertNil(disabled)
        }
    }

    func testNewImportedOverlapBlocksAStaleSuggestionSave() async throws {
        try await withDetectionEnabled {
            let (repository, store, candidate, now) = try await fixture()
            let w = candidate.window
            let imported = WorkoutRow(startTs: w.startSec - 100, endTs: w.endSec + 100, sport: "Running",
                                      source: "apple-health", durationS: 1_437, energyKcal: nil, avgHr: nil,
                                      maxHr: nil, strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
            try await store.upsertWorkouts([imported], deviceId: Repository.appleHealthSource)
            let result = await repository.saveWorkoutSuggestion(candidate, type: "Running", now: now)
            XCTAssertEqual(result, .alreadySaved)
            let rawRows = try await store.workouts(deviceId: Repository.whoopSource, from: 0,
                                                  to: Int(now.timeIntervalSince1970), limit: 10)
            XCTAssertTrue(rawRows.isEmpty)
        }
    }

    func testSourceChangeInvalidatesPendingSaveAndDismiss() async throws {
        try await withDetectionEnabled {
            let (repository, store, candidate, now) = try await fixture()
            repository.adoptActiveDeviceId("test-next-strap")
            let result = await repository.saveWorkoutSuggestion(candidate, type: "Running", now: now)
            XCTAssertEqual(result, .stale)
            XCTAssertFalse(repository.dismissWorkoutSuggestion(candidate))
            let rows = try await store.workouts(deviceId: Repository.whoopSource, from: 0,
                                               to: Int(now.timeIntervalSince1970), limit: 10)
            XCTAssertTrue(rows.isEmpty)
            XCTAssertNil(UserDefaults.standard.stringArray(forKey: dismissedKey))
        }
    }

    func testClosedStoreReportsFailureInsteadOfClaimingTheSaveSucceeded() async throws {
        try await withDetectionEnabled {
            let (repository, store, candidate, now) = try await fixture()
            try await store.close()
            let result = await repository.saveWorkoutSuggestion(candidate, type: "Running", now: now)
            XCTAssertEqual(result, .failed)
            XCTAssertTrue(repository.editedDayRescoreQueue.timestamps.isEmpty)
        }
    }

    func testAnAlreadyFencedSourceCannotAdmitReadSaveOrDismissWork() async throws {
        try await withDetectionEnabled {
            let (repository, store, candidate, now) = try await fixture()
            repository.verifiedExternalSurfaceFenced = true
            let blocked = await repository.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertNil(blocked, "a scan admitted after the fence captured the new epoch and read old rows")
            // Even a candidate carrying the current epoch is inadmissible while the fence remains shut.
            let currentEpoch = AutoWorkoutSuggestion(window: candidate.window, prediction: candidate.prediction,
                                                      sourceId: candidate.sourceId,
                                                      context: repository.workoutSuggestionContext,
                                                      databaseInstanceId: candidate.databaseInstanceId,
                                                      sourceOwner: candidate.sourceOwner)
            XCTAssertFalse(repository.isCurrentWorkoutSuggestion(currentEpoch))
            XCTAssertFalse(repository.dismissWorkoutSuggestion(currentEpoch))
            let saved = await repository.saveWorkoutSuggestion(currentEpoch, type: "Running", now: now)
            XCTAssertEqual(saved, .stale)
            let rows = try await store.workouts(deviceId: candidate.sourceId, from: 0,
                                               to: Int(now.timeIntervalSince1970), limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }

    func testUnavailableCanonicalOwnerDoesNotHideAnActiveSourceSuggestion() async throws {
        try await withDetectionEnabled {
            let (repository, store, candidate, now) = try await fixture(source: "test-current-strap")
            for mutation in ["UPDATE pairedDevice SET status = 'archived' WHERE id = 'my-whoop'",
                             "DELETE FROM pairedDevice WHERE id = 'my-whoop'"] {
                try await store.registryWriter.write { db in try db.execute(sql: mutation) }
                let refreshed = await repository.autoDetectedWorkoutSuggestion(now: now)
                XCTAssertEqual(refreshed?.sourceId, candidate.sourceId)
                XCTAssertEqual(refreshed?.sourceOwner, candidate.sourceOwner)
            }
        }
    }

    func testArchivedCanonicalHistoryIsNotOfferedAfterARePair() async throws {
        try await withDetectionEnabled {
            let (repository, store, _, now) = try await fixture()
            try DeviceRegistryStore(dbQueue: store.registryWriter).add(
                PairedDevice(id: "test-repaired-strap", brand: "WHOOP", model: "WHOOP", sourceKind: .liveBLE,
                             capabilities: [.hr], status: .paired, addedAt: 1, lastSeenAt: 1))
            repository.adoptActiveDeviceId("test-repaired-strap")
            repository.verifiedExternalSurfaceFenced = false
            try await store.registryWriter.write { db in
                try db.execute(sql: "UPDATE pairedDevice SET status = 'archived' WHERE id = 'my-whoop'")
            }
            let candidate = await repository.autoDetectedWorkoutSuggestion(now: now)
            XCTAssertNil(candidate, "archived raw history cannot admit a new manual suggestion")
        }
    }

    func testDurableOwnershipChangeRejectsSaveEvenWhenRepositoryContextHasNotChanged() async throws {
        try await withDetectionEnabled {
            let (repository, store, candidate, now) = try await fixture()
            try await store.registryWriter.write { db in
                try db.execute(sql: "UPDATE pairedDevice SET historyCursorEpoch = historyCursorEpoch + 1 WHERE id = ?",
                               arguments: [candidate.sourceId])
            }
            XCTAssertTrue(repository.isCurrentWorkoutSuggestion(candidate), "the main-actor precheck alone is insufficient")
            let result = await repository.saveWorkoutSuggestion(candidate, type: "Running", now: now)
            XCTAssertEqual(result, .stale)
            XCTAssertTrue(repository.editedDayRescoreQueue.timestamps.isEmpty)
            let rows = try await store.workouts(deviceId: candidate.sourceId, from: 0,
                                               to: Int(now.timeIntervalSince1970), limit: 10)
            XCTAssertTrue(rows.isEmpty)
        }
    }
}
