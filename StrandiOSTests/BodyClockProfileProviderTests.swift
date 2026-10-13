import XCTest
import StrandAnalytics
import WhoopStore
@testable import NOOP

/// The body-clock profile is cached so the 15-minute tick does not re-read 14 days of heart rate. The cache must
/// never outlive a change to the heart rate it covers: a delete, an archive, a restore, a backfill and an import all
/// change it without moving the newest timestamp, and a future-stamped record must not pin the frontier.
@MainActor
final class BodyClockProfileProviderTests: XCTestCase {
    private let day = (1_780_000_000 / 86_400) * 86_400
    private let logicalDay = "2026-06-01"

    /// A fake store: counts the bucket reads, serves a mutable set of stamped rows, and answers the frontier the way
    /// the store does (the newest row at or before the bound).
    @MainActor
    private final class FakeStore {
        var sources = ["my-whoop"]
        var rowTimestamps: [Int] = []
        var bucketReads = 0
        var frontierReads = 0
        var frontierBounds: [Int] = []
        /// Held open by a test to pause a build between its reads.
        var bucketGate: CheckedContinuation<Void, Never>?
        var pauseBuckets = false
        var makeBuckets: (Int, Int) -> [HRBucket]

        init(makeBuckets: @escaping (Int, Int) -> [HRBucket]) { self.makeBuckets = makeBuckets }

        var reads: BodyClockProfileProvider.Reads {
            BodyClockProfileProvider.Reads(
                sourceIds: { [self] in sources },
                newestHeartRate: { [self] bound in
                    frontierReads += 1
                    frontierBounds.append(bound)
                    return rowTimestamps.filter { $0 <= bound }.max()
                },
                buckets: { [self] from, to in
                    bucketReads += 1
                    if pauseBuckets { await withCheckedContinuation { bucketGate = $0 } }
                    return makeBuckets(from, to)
                })
        }
    }

    /// 14 days of hourly buckets with a day/night swing, every hour populated.
    private func fourteenDays(_ from: Int, _ to: Int) -> [HRBucket] {
        stride(from: (from / 3_600) * 3_600, through: to, by: 3_600).map { ts in
            let hour = (ts % 86_400) / 3_600
            return HRBucket(ts: ts, bpm: 58 + 17 * sin(Double(hour - 9) / 24 * 2 * .pi))
        }
    }

    private func store(rows: [Int] = []) -> FakeStore {
        let fake = FakeStore(makeBuckets: { [self] from, to in fourteenDays(from, to) })
        fake.rowTimestamps = rows
        return fake
    }

    private func inputs(_ provider: BodyClockProfileProvider, _ fake: FakeStore, at now: Int,
                        reuse: Bool = true) async -> CircadianPhaseInputs? {
        await provider.inputs(now: now, timeZoneOffsetSeconds: 0, logicalDay: logicalDay,
                              reuseWithinTheHour: reuse, reads: fake.reads)
    }

    func testTheCadenceTickReusesTheProfileWithinTheHour() async {
        let now = day + 40_000
        let fake = store(rows: [now - 60])
        let provider = BodyClockProfileProvider()
        let first = await inputs(provider, fake, at: now)
        let second = await inputs(provider, fake, at: now + 900)
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(fake.bucketReads, 1, "the second call within the hour is answered from the cache")
    }

    /// Deleting a strap's data (or archiving it, selecting another, restoring a backup, importing history) leaves the
    /// newest timestamp where it was or moves it backwards. Without an invalidation the cache serves a body clock
    /// derived from the deleted heart rate until the next 04:00.
    func testInvalidatingDropsTheCachedProfileEvenWithinTheHour() async {
        let now = day + 40_000
        let fake = store(rows: [now - 60])
        let provider = BodyClockProfileProvider()
        _ = await inputs(provider, fake, at: now)
        XCTAssertEqual(fake.bucketReads, 1)

        fake.rowTimestamps = []            // the strap's rows are deleted
        fake.makeBuckets = { _, _ in [] }
        provider.invalidate()
        let afterDelete = await inputs(provider, fake, at: now + 300)
        XCTAssertEqual(fake.bucketReads, 2, "the invalidated cache is not reused")
        XCTAssertNil(afterDelete, "and the profile no longer comes from the deleted rows")

        let again = await inputs(provider, fake, at: now + 600)
        XCTAssertNil(again)
        XCTAssertEqual(fake.bucketReads, 3, "a short read is not cached")
    }

    /// A backfill burst or a user refresh must not read a profile built before the data landed.
    func testEveryTriggerButTheCadenceTickRebuilds() async {
        let now = day + 40_000
        let fake = store(rows: [now - 60])
        let provider = BodyClockProfileProvider()
        _ = await inputs(provider, fake, at: now)
        _ = await inputs(provider, fake, at: now + 600, reuse: false)
        XCTAssertEqual(fake.bucketReads, 2, "a backfill burst rebuilds within the hour")
        // The rebuilt profile is the new cache for the next cadence tick.
        _ = await inputs(provider, fake, at: now + 1_200, reuse: true)
        XCTAssertEqual(fake.bucketReads, 2)
    }

    /// A build that was already reading when the data changed holds the old rows; it must not become the cache.
    func testABuildInFlightWhenTheCacheIsInvalidatedDoesNotRepopulateIt() async {
        let now = day + 40_000
        let fake = store(rows: [now - 60])
        let provider = BodyClockProfileProvider()
        fake.pauseBuckets = true
        let build = Task { @MainActor in await self.inputs(provider, fake, at: now) }
        while fake.bucketGate == nil { await Task.yield() }
        provider.invalidate()              // the delete lands while the old read is open
        fake.pauseBuckets = false
        fake.bucketGate?.resume()
        _ = await build.value
        let next = await inputs(provider, fake, at: now + 60)
        XCTAssertNotNil(next)
        XCTAssertEqual(fake.bucketReads, 2, "the stale build left nothing behind: the next call reads again")
    }

    /// A record stamped a day ahead (the wandering-clock margin) used to pin the frontier at that future time, so real
    /// new heart rate never counted as newer. The frontier is read at or before `now`.
    func testAFutureStampedRowDoesNotPinTheFrontier() async {
        let now = day + 40_000
        let fake = store(rows: [now - 60, now + 80_000])
        let provider = BodyClockProfileProvider()
        _ = await inputs(provider, fake, at: now)
        XCTAssertEqual(fake.frontierBounds, [now], "the frontier is asked for the window the buckets read")

        // Two hours later real heart rate has arrived. The future row would have hidden it.
        fake.rowTimestamps.append(now + 7_000)
        _ = await inputs(provider, fake, at: now + 7_200)
        XCTAssertEqual(fake.bucketReads, 2, "newer heart rate rebuilds the hour-old profile")
    }

    func testAnHourOldProfileWithNoNewerHeartRateIsKept() async {
        let now = day + 40_000
        let fake = store(rows: [now - 60])
        let provider = BodyClockProfileProvider()
        _ = await inputs(provider, fake, at: now)
        _ = await inputs(provider, fake, at: now + 7_200)
        XCTAssertEqual(fake.bucketReads, 1)
        XCTAssertEqual(fake.frontierReads, 2, "one read at the build, one frontier check")
    }
}
