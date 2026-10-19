import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

/// Perf 3: the body-clock estimate's 14-day hourly HR profile is cached per logical day and rebuilt at most hourly,
/// and only when newer heart rate has arrived. The pooled profile and the fit stay exactly what they were.
final class CircadianInputsCacheTests: XCTestCase {
    private let t0 = 1_780_000_000
    private let sources = ["my-whoop"]

    private func cache(newest: Int? = 1_779_999_000, inputs: CircadianPhaseInputs? = nil) -> CircadianInputsCache {
        CircadianInputsCache(logicalDay: "2026-06-01", timeZoneOffsetSeconds: -18_000, sourceIds: sources,
                             computedAt: t0, newestHeartRateTs: newest, inputs: inputs)
    }

    private func verdict(_ cache: CircadianInputsCache, day: String = "2026-06-01", tz: Int = -18_000,
                         sources: [String]? = nil, at now: Int) -> CircadianInputsCache.Verdict {
        cache.verdict(logicalDay: day, timeZoneOffsetSeconds: tz, sourceIds: sources ?? self.sources, now: now)
    }

    func testWithinAnHourOnTheSameDayZoneAndSourcesTheProfileIsReused() {
        let c = cache()
        XCTAssertEqual(verdict(c, at: t0), .reuse)
        XCTAssertEqual(verdict(c, at: t0 + 900), .reuse)
        XCTAssertEqual(verdict(c, at: t0 + 3_599), .reuse)
    }

    func testAnHourOldProfileIsRebuiltOnlyIfNewerHeartRateArrived() {
        let c = cache()
        XCTAssertEqual(verdict(c, at: t0 + 3_600), .rebuildIfNewerHeartRate)
        XCTAssertEqual(verdict(c, at: t0 + 5 * 3_600), .rebuildIfNewerHeartRate)
    }

    func testANewLogicalDayZoneOrSourceSetRebuildsAtOnce() {
        let c = cache()
        XCTAssertEqual(verdict(c, day: "2026-06-02", at: t0 + 60), .rebuild)
        XCTAssertEqual(verdict(c, tz: 3_600, at: t0 + 60), .rebuild)
        XCTAssertEqual(verdict(c, sources: ["my-whoop", "whoop-2"], at: t0 + 60), .rebuild)
    }

    func testAClockThatMovedBackwardsRebuilds() {
        XCTAssertEqual(verdict(cache(), at: t0 - 1), .rebuild)
    }

    func testOnlyHeartRateNewerThanTheCachedReadCountsAsNew() {
        let c = cache(newest: 1_779_999_000)
        XCTAssertFalse(c.hasNewerHeartRate(nil))
        XCTAssertFalse(c.hasNewerHeartRate(1_779_999_000))
        XCTAssertFalse(c.hasNewerHeartRate(1_779_990_000))
        XCTAssertTrue(c.hasNewerHeartRate(1_779_999_001))
        // A read made with no heart rate at all is superseded by the first row that appears.
        XCTAssertTrue(cache(newest: nil).hasNewerHeartRate(1))
        XCTAssertFalse(cache(newest: nil).hasNewerHeartRate(nil))
    }

    // MARK: The pooled profile

    /// What `computeCircadianPhase` computed inline before the cache, kept here as the reference.
    private func reference(_ buckets: [HRBucket], tz: Int) -> (bins: [CircadianEngine.ActivityBin], days: Int)? {
        guard buckets.count >= 24 else { return nil }
        var sums = [Double](repeating: 0, count: 24)
        var counts = [Int](repeating: 0, count: 24)
        var daySet = Set<Int>()
        for b in buckets {
            let local = b.ts + tz
            let hour = (local % 86_400 + 86_400) % 86_400 / 3_600
            sums[hour] += b.bpm; counts[hour] += 1
            daySet.insert(local / 86_400)
        }
        let bins: [CircadianEngine.ActivityBin] = (0..<24).compactMap { h in
            counts[h] > 0 ? CircadianEngine.ActivityBin(hour: Double(h), activity: sums[h] / Double(counts[h])) : nil
        }
        guard bins.count >= 6 else { return nil }
        return (bins, daySet.count)
    }

    private func buckets(days: Int, hours: ClosedRange<Int> = 0...23) -> [HRBucket] {
        let start = (1_780_000_000 / 86_400) * 86_400
        return (0..<days).flatMap { day in
            hours.map { hour in
                HRBucket(ts: start + day * 86_400 + hour * 3_600,
                         bpm: 58 + 17 * sin(Double(hour - 9) / 24 * 2 * .pi) + Double((day * 7 + hour) % 5) * 0.37)
            }
        }
    }

    func testThePooledProfileIsTheOneTheInlineCodeBuilt() throws {
        for tz in [0, -18_000, 19_800, 43_200] {
            let input = buckets(days: 14)
            let made = try XCTUnwrap(CircadianPhaseInputs.make(from: input, timeZoneOffsetSeconds: tz))
            let expected = try XCTUnwrap(reference(input, tz: tz))
            XCTAssertEqual(made.bins, expected.bins, "tz \(tz)")
            XCTAssertEqual(made.daysObserved, expected.days, "tz \(tz)")
            // And the fit over the cached profile is the fit over the inline one.
            XCTAssertEqual(
                CircadianEngine.estimatePhase(bins: made.bins, daysObserved: made.daysObserved, habitualWakeHour: 6.5),
                CircadianEngine.estimatePhase(bins: expected.bins, daysObserved: expected.days, habitualWakeHour: 6.5))
        }
    }

    func testTooLittleHeartRateHasNoProfile() {
        XCTAssertNil(CircadianPhaseInputs.make(from: Array(buckets(days: 1).dropLast()), timeZoneOffsetSeconds: 0))
        XCTAssertNil(CircadianPhaseInputs.make(from: [], timeZoneOffsetSeconds: 0))
        // 24+ buckets, but over fewer than six distinct local hours.
        XCTAssertNil(CircadianPhaseInputs.make(from: buckets(days: 8, hours: 0...2), timeZoneOffsetSeconds: 0))
        XCTAssertNil(reference(buckets(days: 8, hours: 0...2), tz: 0))
    }
}
