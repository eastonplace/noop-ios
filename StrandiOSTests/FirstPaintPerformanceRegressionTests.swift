import XCTest
import WhoopStore
@testable import NOOP

@MainActor
final class FirstPaintPerformanceRegressionTests: XCTestCase {
    private let canonical = "my-whoop"

    private func makeRepo() async throws -> (Repository, WhoopStore) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: canonical, mac: nil, name: "WHOOP")
        let repo = Repository(deviceId: canonical)
        repo.setStoreForTesting(store)
        return (repo, store)
    }

    func testExactSourceSeriesBatchMatchesSequentialExactSourceReads() async throws {
        let (repo, store) = try await makeRepo()
        let source = XiaomiImporter.deviceId
        let keys = ["steps", "rhr", "stress"]
        let points = [
            MetricPoint(day: "2026-08-27", key: "steps", value: 8_100),
            MetricPoint(day: "2026-08-28", key: "steps", value: 9_200),
            MetricPoint(day: "2026-08-27", key: "rhr", value: 51),
            MetricPoint(day: "2026-08-28", key: "stress", value: 34),
        ]
        _ = try await store.upsertMetricSeries(points, deviceId: source)

        let batch = await repo.exactSourceSeriesBatch(
            keys: keys,
            source: source,
            fullHistory: true
        )

        for key in keys {
            let sequential = await repo.series(key: key, source: source, fullHistory: true)
            XCTAssertEqual(
                batch[key, default: []].map { "\($0.day)|\($0.value)" },
                sequential.map { "\($0.day)|\($0.value)" },
                "batched exact-source reads must preserve the existing series contract for \(key)"
            )
        }
    }

    func testXiaomiSameStateLoadUsesCacheAndExplicitInvalidationReReads() async throws {
        let (repo, store) = try await makeRepo()
        let source = XiaomiImporter.deviceId
        let keys = ["steps", "rhr"]
        _ = try await store.upsertMetricSeries([
            MetricPoint(day: "2026-08-28", key: "steps", value: 9_500),
            MetricPoint(day: "2026-08-28", key: "rhr", value: 50),
        ], deviceId: source)

        let first = await repo.performXiaomiBandLoad(
            seriesKeys: keys,
            source: source,
            allowCache: true
        )
        XCTAssertEqual(repo.loadFireCounts["xiaomi"], 1)
        XCTAssertEqual(first.series["steps"]?.last?.value, 9_500)

        let second = await repo.performXiaomiBandLoad(
            seriesKeys: keys,
            source: source,
            allowCache: true
        )
        XCTAssertEqual(repo.loadFireCounts["xiaomi"], 1,
                       "same-state navigation must restore the completed Mi Band snapshot")
        XCTAssertEqual(second.series["steps"]?.last?.value, first.series["steps"]?.last?.value)

        repo.xiaomiCache = nil
        repo.xiaomiLoadedSeq = -1

        _ = await repo.performXiaomiBandLoad(
            seriesKeys: keys,
            source: source,
            allowCache: true
        )
        XCTAssertEqual(repo.loadFireCounts["xiaomi"], 2,
                       "import invalidation must force the next Mi Band load back to the store")
    }

    func testExactWorkoutWindowMatchesBroadReadWithinTheSameWindow() async throws {
        let (repo, store) = try await makeRepo()
        let now = Int(Date().timeIntervalSince1970)
        let targetStart = now - (2 * 86_400)
        let target = WorkoutRow(
            startTs: targetStart,
            endTs: targetStart + 2_400,
            sport: "Run",
            source: "manual",
            durationS: 2_400,
            energyKcal: 320,
            avgHr: 142,
            maxHr: 169,
            strain: 11.2,
            distanceM: 6_000,
            zonesJSON: nil,
            notes: nil
        )
        let outside = WorkoutRow(
            startTs: now - (20 * 86_400),
            endTs: now - (20 * 86_400) + 1_800,
            sport: "Cycling",
            source: "manual",
            durationS: 1_800,
            energyKcal: 250,
            avgHr: 130,
            maxHr: 160,
            strain: 8.0,
            distanceM: nil,
            zonesJSON: nil,
            notes: nil
        )
        _ = try await store.upsertWorkouts([target, outside], deviceId: canonical)

        let lo = targetStart - 60
        let hi = target.endTs + 60
        let exact = await repo.workoutRows(from: lo, to: hi, reconcileHR: false)
        let broad = await repo.workoutRows(days: 4_000, reconcileHR: false)
            .filter { $0.startTs >= lo && $0.startTs < hi }

        XCTAssertEqual(exact.map(\.startTs), broad.map(\.startTs))
        XCTAssertEqual(exact.map(\.sport), broad.map(\.sport))
        XCTAssertEqual(exact.map(\.startTs), [target.startTs],
                       "detail/day first paint must not require unrelated workout history")
    }

    func testAppleHealthHeavyLoadCountsOnlyAppleHealthWorkouts() async throws {
        let (repo, store) = try await makeRepo()
        let now = Int(Date().timeIntervalSince1970)
        let apple = WorkoutRow(
            startTs: now - 7_200,
            endTs: now - 5_400,
            sport: "Walking",
            source: WorkoutSource.appleHealthSource,
            durationS: 1_800,
            energyKcal: 180,
            avgHr: 112,
            maxHr: 132,
            strain: 5.0,
            distanceM: 2_000,
            zonesJSON: nil,
            notes: nil
        )
        let strap = WorkoutRow(
            startTs: now - 14_400,
            endTs: now - 12_600,
            sport: "Run",
            source: "whoop",
            durationS: 1_800,
            energyKcal: 300,
            avgHr: 145,
            maxHr: 171,
            strain: 10.0,
            distanceM: 5_000,
            zonesJSON: nil,
            notes: nil
        )
        _ = try await store.upsertWorkouts([apple], deviceId: Repository.appleHealthSource)
        _ = try await store.upsertWorkouts([strap], deviceId: canonical)

        let snapshot = await repo.performAppleHealthLoad(seriesKeys: [], allowCache: false)
        XCTAssertEqual(snapshot.workoutCount, 1,
                       "the optimized count must preserve the Apple Health page's source-only meaning")
    }
}
