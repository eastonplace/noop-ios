import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
@testable import NOOP

/// #797: a HUGE import (3000+ days, 1700+ workouts) must NOT drive O(n) per-refresh / per-first-paint
/// work. Today first paint reads a BOUNDED window (the visible day's HR, a bounded workouts window), not
/// the whole history. These stress tests seed a worst-case history and assert the first-paint reads stay
/// bounded, independent of how deep the history is.
final class HugeImportFirstPaintStressTests: XCTestCase {

    private let dev = "my-whoop"

    /// Seed ~3000 days of daily rows + ~1700 workouts spread across them, plus a dense HR day for "today".
    /// Returns the store and last seeded HR timestamp. One anchor pins every row across suspended writes.
    /// Kept lean (no raw streams except the one visible day) so the seed itself is fast.
    @MainActor
    private func seedHugeHistory(anchor: Date, calendar: Calendar) async throws
        -> (store: WhoopStore, latestHRTimestamp: Int) {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")

        let now = Int(anchor.timeIntervalSince1970)

        // ~3000 daily rows, one per day going back ~8 years.
        var dailies: [DailyMetric] = []
        dailies.reserveCapacity(3_200)
        for back in 0..<3_100 {
            guard let d = calendar.date(byAdding: .day, value: -back, to: anchor) else { continue }
            let key = Repository.localDayKey(d, calendar: calendar)
            dailies.append(DailyMetric(day: key, totalSleepMin: 420, efficiency: 0.9, deepMin: 90,
                                       remMin: 100, lightMin: 230, disturbances: 1, restingHr: 52,
                                       avgHrv: 70, recovery: 60, strain: 8, exerciseCount: 0,
                                       spo2Pct: nil, skinTempDevC: nil, respRateBpm: 14,
                                       steps: nil, activeKcalEst: nil))
        }
        _ = try await store.upsertDailyMetrics(dailies, deviceId: dev)

        // ~1700 workouts spread across the history (one every ~1.8 days).
        var workouts: [WorkoutRow] = []
        workouts.reserveCapacity(1_800)
        for i in 0..<1_700 {
            let startTs = now - i * 86_400 * 18 / 10   // every 1.8 days
            workouts.append(WorkoutRow(startTs: startTs, endTs: startTs + 1_800, sport: "Run",
                                       source: "manual", durationS: 1_800, energyKcal: 300,
                                       avgHr: 140, maxHr: 165, strain: 12, distanceM: 5_000,
                                       zonesJSON: nil, notes: nil))
        }
        _ = try await store.upsertWorkouts(workouts, deviceId: dev)

        // One dense HR day for "today", the only raw stream the Today HR trend reads on first paint.
        let todayBase = now - 3_600
        let hr = (0..<3_600).map { HRSample(ts: todayBase + $0, bpm: 65) }
        try await store.insert(Streams(hr: hr), deviceId: dev)
        return (store, try XCTUnwrap(hr.last).ts)
    }

    /// The BOUNDED first-paint workouts read (`firstPaintWindowDays`) returns only the recent window's
    /// workouts, a small fraction of the 1700 total, so first paint never sorts the whole history.
    @MainActor
    func testFirstPaintWorkoutWindowIsBounded() async throws {
        let anchor = Date()
        let history = try await seedHugeHistory(anchor: anchor, calendar: .current)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(history.store)

        // The bounded read WorkoutsView issues on first paint.
        let bounded = await repo.workoutRows(days: WorkoutsView.firstPaintWindowDays)
        // 400-day window at one workout / 1.8 days ≈ 222 workouts, far below the full 1700.
        XCTAssertLessThan(bounded.count, 400, "first-paint workouts read must be a bounded window, not the whole history")
        XCTAssertGreaterThan(bounded.count, 0, "the bounded window still surfaces recent sessions")

        // Sanity: the full read returns the whole (much larger) history, so the bound is doing real work.
        let full = await repo.workoutRows(days: 4_000)
        XCTAssertGreaterThan(full.count, bounded.count * 3,
                             "the unbounded read is materially larger, proving the first-paint window bounds the cost")
        XCTAssertGreaterThan(full.count, 1_500)
    }

    /// Today's HR-trend first-paint read is a single visible-day window: it returns ~one day of points
    /// REGARDLESS of the 3000-day / 1700-workout history behind it, first-paint cost is bounded by the
    /// window, not the import depth.
    @MainActor
    func testTodayHrFirstPaintReadIsBoundedByWindow() async throws {
        let anchor = Date()
        let calendar = Calendar.current
        let history = try await seedHugeHistory(anchor: anchor, calendar: calendar)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(history.store)

        let now = Int(anchor.timeIntervalSince1970)
        let dayStart = Int(calendar.startOfDay(for: Repository.logicalDay(anchor, calendar: calendar)).timeIntervalSince1970)
        // The Today HR trend reads 5-minute buckets over the logical day → at most ~288 bucket points,
        // never the thousands of raw rows and never anything that scales with the 3000-day history.
        let buckets = await repo.hrBuckets(from: dayStart, to: now, bucketSeconds: 300)
        XCTAssertGreaterThan(buckets.count, 0, "today has data so the trend is non-empty")
        XCTAssertLessThanOrEqual(buckets.count, 24 * 12 + 2, "a day of 5-min buckets is bounded (~288), independent of history depth")
    }

    /// `latestDataDayStart` (the auto-land lookup) is one indexed `MAX(ts)` read, it does NOT load or sort
    /// the history. With 3000 days seeded it still resolves the most-recent HR day cheaply.
    @MainActor
    func testLatestDataLookupResolvesWithoutLoadingHistory() async throws {
        let calendar = Calendar.current
        for (hour, expectedDay) in [(3, 21), (4, 22)] {
            let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 22,
                                                                          hour: hour, minute: 30)))
            let history = try await seedHugeHistory(anchor: anchor, calendar: calendar)
            let repo = Repository(deviceId: dev)
            repo.setStoreForTesting(history.store)
            let latest = await repo.latestDataDayStart()
            XCTAssertNotNil(latest, "the latest-data lookup must resolve over a deep history")
            // MAX(ts) identifies the last sample, not the first sample of an hour that can straddle 04:00.
            let lastSample = Date(timeIntervalSince1970: TimeInterval(history.latestHRTimestamp))
            let midnight = calendar.startOfDay(for: lastSample)
            let dayOffset = calendar.component(.hour, from: lastSample) < 4 ? -1 : 0
            let expected = try XCTUnwrap(calendar.date(byAdding: .day, value: dayOffset, to: midnight))
            let explicitDay = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: expectedDay)))
            XCTAssertEqual(expected, explicitDay, "the fixture covers both sides of the 04:00 logical-day rollover")
            XCTAssertEqual(latest, expected)
        }
    }
}
