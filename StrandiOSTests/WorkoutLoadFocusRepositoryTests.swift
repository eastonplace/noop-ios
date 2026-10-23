import XCTest
import GRDB
import StrandAnalytics
import WhoopProtocol
@testable import WhoopStore
@testable import NOOP

/// Real-store coverage for the bounded Load focus read. The after-read seam runs before admission,
/// so intervening mutations are deterministic and require no scheduler delays.
@MainActor
final class WorkoutLoadFocusRepositoryTests: XCTestCase {
    private let start = 1_800_000_000
    private let seconds = 120
    private var savedMaxHR: Any?
    private var savedPauses: Any?

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            savedMaxHR = UserDefaults.standard.object(forKey: "profile.hrMaxOverride")
            savedPauses = UserDefaults.standard.object(forKey: WorkoutPauseStore.defaultsKey)
            UserDefaults.standard.set(200, forKey: "profile.hrMaxOverride")
            UserDefaults.standard.removeObject(forKey: WorkoutPauseStore.defaultsKey)
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            UserDefaults.standard.set(savedMaxHR, forKey: "profile.hrMaxOverride")
            UserDefaults.standard.set(savedPauses, forKey: WorkoutPauseStore.defaultsKey)
        }
        try await super.tearDown()
    }

    private func samples(_ bpm: Int, range: Range<Int>? = nil) -> [HRSample] {
        (range ?? 0..<seconds).map { .init(ts: start + $0, bpm: bpm) }
    }

    private func seeded(_ bpm: Int = 110, sampleRange: Range<Int>? = nil) async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        let row = WorkoutRow(startTs: start, endTs: start + seconds, sport: "running", source: "manual",
            durationS: Double(seconds), energyKcal: nil, avgHr: nil, maxHr: nil, strain: nil,
            distanceM: nil, zonesJSON: nil, notes: nil)
        try await store.upsertWorkouts([row], deviceId: Repository.whoopSource)
        try await store.insert(Streams(hr: samples(bpm, range: sampleRange)), deviceId: Repository.whoopSource)
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        return (repository, store)
    }

    private func read(_ repository: Repository) async throws -> [LoadFocus.Workout] {
        try await repository.workoutLoadFocus(from: start, to: start + seconds, age: 30)
    }

    private func assertCancelled(_ repository: Repository, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await read(repository)
            XCTFail("An obsolete read must fail instead of publishing or caching a partial snapshot", file: file, line: line)
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
        XCTAssertTrue(repository.workoutZoneMemo.isEmpty, file: file, line: line)
    }

    func testUnchangedReadReusesZonesButSameKeyRepairAndDeletionInvalidateThem() async throws {
        let (repository, store) = try await seeded()
        let original = try await read(repository)
        let repeated = try await read(repository)
        XCTAssertEqual(repeated, original)
        XCTAssertNotNil(original.first?.zoneMinutes)
        XCTAssertEqual(repository.workoutFocusRawReadCountForTesting, 1, "Unchanged inputs should reuse bounded zone math")

        try await store.repairFocusHR(deviceID: Repository.whoopSource, bpm: 190)
        let repaired = try await read(repository)
        XCTAssertNotEqual(repaired, original, "A same-key SQL repair changes no workout timestamp or HRmax")
        XCTAssertEqual(repository.workoutFocusRawReadCountForTesting, 2)

        try await store.deleteFocusHR(deviceID: Repository.whoopSource)
        let deleted = try await read(repository)
        XCTAssertEqual(deleted.count, 1)
        XCTAssertNil(deleted.first?.zoneMinutes, "Missing HR must replace the former measured value")
    }

    func testLateBackfillAndPauseMetadataInvalidateTheSameWorkout() async throws {
        let (repository, store) = try await seeded(sampleRange: 0..<60)
        let before = try await read(repository)
        try await store.insert(Streams(hr: samples(190, range: 60..<seconds)), deviceId: Repository.whoopSource)
        let backfilled = try await read(repository)
        XCTAssertNotEqual(backfilled, before)

        WorkoutPauseStore.store(.init(intervals: [.init(start: Double(start + 60), end: Double(start + seconds))]),
            startTs: start, sport: "running")
        let paused = try await read(repository)
        XCTAssertNotEqual(paused, backfilled)
        XCTAssertEqual(repository.workoutFocusRawReadCountForTesting, 3)
    }

    func testActiveSourceAndStoreReplacementCannotReusePriorZones() async throws {
        let (repository, store) = try await seeded()
        let canonical = try await read(repository)
        try await store.insert(Streams(hr: samples(190)), deviceId: "replacement-strap")
        repository.adoptActiveDeviceId("replacement-strap")
        // This fixture models a completed handoff, as in the baseline read-precedence tests.
        XCTAssertTrue(repository.verifiedExternalSurfaceFenced)
        repository.verifiedExternalSurfaceFenced = false
        let active = try await read(repository)
        XCTAssertNotEqual(active, canonical)

        let (_, replacement) = try await seeded(150)
        repository.setStoreForTesting(replacement)
        let replaced = try await read(repository)
        XCTAssertNotEqual(replaced, active, "A new store with the same workout keys owns different raw inputs")
    }

    func testFenceRaisedAndClearedDuringRawReadStillRejectsTheOldSnapshot() async throws {
        let (repository, _) = try await seeded()
        repository.workoutFocusAfterRawReadForTesting = {
            repository.invalidateVerifiedExternalSurface()
            repository.verifiedExternalSurfaceFenced = false
        }
        await assertCancelled(repository)
    }

    func testSourceSwitchDuringRawReadRejectsTheOldSnapshot() async throws {
        let (repository, _) = try await seeded()
        repository.workoutFocusAfterRawReadForTesting = { repository.adoptActiveDeviceId("replacement-strap") }
        await assertCancelled(repository)
    }

    func testStoreReplacementDuringRawReadRejectsTheOldSnapshot() async throws {
        let (repository, _) = try await seeded()
        let replacement = try await WhoopStore.inMemory()
        repository.workoutFocusAfterRawReadForTesting = { repository.setStoreForTesting(replacement) }
        await assertCancelled(repository)
    }

    func testRawRepairDuringReadRejectsTheMixedInputSnapshot() async throws {
        let (repository, store) = try await seeded()
        repository.workoutFocusAfterRawReadForTesting = {
            do { try await store.repairFocusHR(deviceID: Repository.whoopSource, bpm: 190) }
            catch { XCTFail("Repair fixture failed: \(error)") }
        }
        await assertCancelled(repository)
        repository.workoutFocusAfterRawReadForTesting = nil
        let corrected = try await read(repository)
        XCTAssertNotNil(corrected.first?.zoneMinutes)
        XCTAssertEqual(repository.workoutFocusRawReadCountForTesting, 2, "Rejected reads cannot seed a stale cache hit")
    }

    func testCancelledAndFencedRequestsNeverReturnEmptySuccess() async throws {
        let (repository, _) = try await seeded()
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await read(repository)
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation must throw before any raw query")
        } catch is CancellationError {}
        XCTAssertEqual(repository.workoutFocusRawReadCountForTesting, 0)
        repository.invalidateVerifiedExternalSurface()
        await assertCancelled(repository)
        XCTAssertEqual(repository.workoutFocusRawReadCountForTesting, 0)
    }

    func testImplausibleHeartRateCannotCreateMeasuredLoad() async throws {
        let (repository, _) = try await seeded(255)
        let result = try await read(repository)
        XCTAssertEqual(result.count, 1)
        XCTAssertNil(result.first?.zoneMinutes)
    }
}

private extension WhoopStore {
    func repairFocusHR(deviceID: String, bpm: Int) throws {
        try syncWrite { db in
            try db.execute(sql: "UPDATE hrSample SET bpm = ? WHERE deviceId = ?", arguments: [bpm, deviceID])
        }
    }

    func deleteFocusHR(deviceID: String) throws {
        try syncWrite { db in
            try db.execute(sql: "DELETE FROM hrSample WHERE deviceId = ?", arguments: [deviceID])
        }
    }
}
