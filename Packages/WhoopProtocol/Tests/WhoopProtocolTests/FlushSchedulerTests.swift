import XCTest
import WhoopProtocol

/// BLE-11 / CC-6: one cadence flush at a time, a single coalesced follow-up, and bounded retry.
final class FlushSchedulerTests: XCTestCase {

    /// Frames arriving during a slow insert produce one follow-up flush, not one per frame.
    func testFramesDuringASlowInsertProduceOneFollowUp() {
        var scheduler = FlushScheduler()
        XCTAssertTrue(scheduler.request(now: 0))
        var started = 1
        for i in 1...200 where scheduler.request(now: TimeInterval(i) * 0.1) { started += 1 }
        XCTAssertEqual(started, 1, "the old code started a flush for every one of these frames")
        XCTAssertTrue(scheduler.finish(success: true, now: 20), "one follow-up for the frames that arrived")
        XCTAssertFalse(scheduler.finish(success: true, now: 21))
        XCTAssertFalse(scheduler.inFlight)
        XCTAssertTrue(scheduler.request(now: 22))
    }

    func testFailuresBackOffFiveTenThirtySixty() {
        var scheduler = FlushScheduler()
        var now: TimeInterval = 0
        for expected in [5.0, 10, 30, 60, 60] {
            XCTAssertTrue(scheduler.request(now: now))
            XCTAssertFalse(scheduler.finish(success: false, now: now), "a failure never loops immediately")
            XCTAssertFalse(scheduler.request(now: now + expected - 0.5), "still backing off")
            now += expected
        }
        XCTAssertEqual(scheduler.consecutiveFailures, 5)
        XCTAssertTrue(scheduler.request(now: now))
        XCTAssertFalse(scheduler.finish(success: true, now: now))
        XCTAssertEqual(scheduler.consecutiveFailures, 0)
        XCTAssertNil(scheduler.retryNotBefore)
        XCTAssertTrue(scheduler.request(now: now + 0.1), "success clears the backoff")
    }

    func testAFailedFlushDropsThePendingFollowUp() {
        var scheduler = FlushScheduler()
        XCTAssertTrue(scheduler.request(now: 0))
        XCTAssertFalse(scheduler.request(now: 1))
        XCTAssertFalse(scheduler.finish(success: false, now: 2))
        XCTAssertFalse(scheduler.needsFollowUp)
        XCTAssertFalse(scheduler.inFlight)
    }

    func testOverflowKeepsTheBufferWithinItsCap() {
        XCTAssertEqual(FlushScheduler.overflow(count: 10, cap: 4), 6)
        XCTAssertEqual(FlushScheduler.overflow(count: 3, cap: 4), 0)
        XCTAssertEqual(FlushScheduler.overflow(count: 3, cap: -1), 3)
    }
}
