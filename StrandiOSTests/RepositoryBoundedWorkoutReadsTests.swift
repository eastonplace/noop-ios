import XCTest
import WhoopProtocol
import WhoopStore
@testable import NOOP

/// DL-06 (store half): Today's bounded reads keep every source, dedup and dismissal rule of `workoutRows()`
/// while reading and reconciling only what is shown.
@MainActor
final class RepositoryBoundedWorkoutReadsTests: XCTestCase {
    private func workout(daysAgo: Double, minutes: Int = 45, sport: String = "running",
                         source: String) -> WorkoutRow {
        let start = Int(Date().timeIntervalSince1970 - daysAgo * 86_400)
        return WorkoutRow(startTs: start, endTs: start + minutes * 60, sport: sport, source: source,
                          durationS: Double(minutes * 60), energyKcal: 300, avgHr: 140, maxHr: 170,
                          strain: nil, distanceM: nil, zonesJSON: nil, notes: nil)
    }

    private func seededRepository() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        let strap = [0.5, 3, 10, 45, 200, 900].map { workout(daysAgo: $0, source: "whoop") }
        // A same-activity Apple Health twin of the newest strap workout collapses into one entry.
        let apple = [workout(daysAgo: 0.5, source: "apple-health"), workout(daysAgo: 20, source: "apple-health")]
        try await store.upsertWorkouts(strap, deviceId: Repository.whoopSource)
        try await store.upsertWorkouts(apple, deviceId: Repository.appleHealthSource)
        return (repository, store)
    }

    func testRecentWorkoutsMatchTheHeadOfTheFullList() async throws {
        let (repository, _) = try await seededRepository()
        let full = await repository.workoutRows(reconcileHR: false)
        XCTAssertEqual(full.count, 7, "the twin collapsed")
        for limit in [1, 3, 5, 7, 20] {
            let recent = await repository.recentWorkouts(limit: limit, reconcileHR: false)
            XCTAssertEqual(recent.map(\.startTs), Array(full.prefix(limit)).map(\.startTs), "limit \(limit)")
            XCTAssertEqual(recent.map(\.source), Array(full.prefix(limit)).map(\.source), "limit \(limit)")
        }
    }

    func testCountAndDayReadsAgreeWithTheFullList() async throws {
        let (repository, store) = try await seededRepository()
        let full = await repository.workoutRows(reconcileHR: false)
        let count = await repository.workoutCount()
        XCTAssertEqual(count, full.count)

        let tenDaysAgo = Date(timeIntervalSince1970: Date().timeIntervalSince1970 - 10 * 86_400)
        let day = await repository.workouts(forDay: tenDaysAgo, reconcileHR: false)
        let dayStart = Calendar.current.startOfDay(for: tenDaysAgo)
        let expected = full.filter {
            let start = Date(timeIntervalSince1970: TimeInterval($0.startTs))
            return start >= dayStart && start < dayStart.addingTimeInterval(86_400)
        }
        XCTAssertEqual(day.map(\.startTs), expected.map(\.startTs))
        XCTAssertEqual(day.count, 1)

        try await store.upsertSleepSessions(
            [CachedSleepSession(startTs: 1_000, endTs: 9_000, efficiency: 0.9, restingHr: 50, avgHrv: 60,
                                stagesJSON: "[]")],
            deviceId: "xiaomi-band")
        let sleeps = await repository.sleepSessionCount(deviceId: "xiaomi-band")
        XCTAssertEqual(sleeps, 1)
    }

    /// Perf: Today passes `reconcileLimit: 6`. The head must come back byte-identical to a full reconcile
    /// (same rows, same order, same Avg/Max HR), the tail must pass through unreconciled, and the HR reads
    /// must stop at the limit instead of covering every eligible row.
    func testReconcileLimitMatchesTheHeadOfAFullReconcileAndLeavesTheTailVerbatim() async throws {
        let store = try await WhoopStore.inMemory()
        let repository = Repository(deviceId: Repository.whoopSource)
        repository.setStoreForTesting(store)
        // Imported rows with no Avg HR are reconcile-eligible; the strap trace covers every window.
        let now = Int(Date().timeIntervalSince1970)
        var rows: [WorkoutRow] = []
        var hr: [HRSample] = []
        for i in 0..<8 {
            let start = now - (i + 1) * 86_400
            rows.append(WorkoutRow(startTs: start, endTs: start + 600, sport: "running", source: "apple-health",
                                   durationS: 600, energyKcal: 100, avgHr: nil, maxHr: nil, strain: nil,
                                   distanceM: nil, zonesJSON: nil, notes: nil))
            for t in 0..<600 { hr.append(HRSample(ts: start + t, bpm: 100 + i)) }
        }
        try await store.upsertWorkouts(rows, deviceId: Repository.appleHealthSource)
        _ = try await store.insert(Streams(hr: hr), deviceId: Repository.whoopSource)

        let full = await repository.workoutRows()
        XCTAssertEqual(full.count, 8)
        XCTAssertTrue(full.allSatisfy { $0.avgHr != nil }, "a full pass reconciles every eligible row")

        let limit = 3
        let bounded = await repository.workoutRows(reconcileLimit: limit)
        XCTAssertEqual(bounded.map(\.startTs), full.map(\.startTs), "same rows, same order")
        XCTAssertEqual(Array(bounded.prefix(limit)), Array(full.prefix(limit)), "head is byte-identical")
        XCTAssertTrue(bounded.dropFirst(limit).allSatisfy { $0.avgHr == nil }, "tail is not reconciled")

        let unreconciled = await repository.workoutRows(reconcileHR: false)
        XCTAssertEqual(Array(bounded.dropFirst(limit)), Array(unreconciled.dropFirst(limit)))
    }
}
