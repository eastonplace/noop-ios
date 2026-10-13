import XCTest
import WhoopProtocol

/// BLE-8: queued backfill frames carry the session/connection that admitted them, stale frames never reach
/// the Backfiller, and drain ownership is released only by the drainer that holds it.
final class BackfillDrainOwnershipTests: XCTestCase {

    /// The finding's scenario: a HISTORY_END queued under connection 3 is still in the old drainer's local
    /// batch when the link drops and a new session starts on connection 4. It must be dropped, never fed
    /// to the Backfiller (which would ACK it into the new session).
    func testStaleEndAfterReconnectIsDropped() {
        let oldSession = BackfillDrainToken(sessionGeneration: 7, connectGeneration: 3)
        let newSession = BackfillDrainToken(sessionGeneration: 8, connectGeneration: 4)
        XCTAssertFalse(BackfillDrainOwnership.shouldIngest(frame: oldSession, current: newSession, backfilling: true))
        XCTAssertTrue(BackfillDrainOwnership.shouldIngest(frame: newSession, current: newSession, backfilling: true))
    }

    func testSameConnectionReplacementSessionAlsoDropsOldFrames() {
        let first = BackfillDrainToken(sessionGeneration: 1, connectGeneration: 2)
        let replacement = BackfillDrainToken(sessionGeneration: 2, connectGeneration: 2)
        XCTAssertFalse(BackfillDrainOwnership.shouldIngest(frame: first, current: replacement, backfilling: true))
    }

    func testNothingIsIngestedAfterTeardownOrOutsideABackfill() {
        let token = BackfillDrainToken(sessionGeneration: 1, connectGeneration: 1)
        XCTAssertFalse(BackfillDrainOwnership.shouldIngest(frame: token, current: nil, backfilling: true),
                       "a torn-down admission owns nothing")
        XCTAssertFalse(BackfillDrainOwnership.shouldIngest(frame: token, current: token, backfilling: false))
    }

    /// A drainer suspended across a disconnect keeps ownership; a frame queued meanwhile does not start a
    /// second, concurrent drainer.
    func testOnlyOneDrainerAtATime() {
        var ownership = BackfillDrainOwnership()
        let first = ownership.claimIfIdle()
        XCTAssertNotNil(first)
        XCTAssertNil(ownership.claimIfIdle(), "a running drainer picks up newly queued frames itself")
        XCTAssertTrue(ownership.release(first!))
        let second = ownership.claimIfIdle()
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    /// The old Bool was cleared by whichever drainer exited last, even if another had started meanwhile.
    func testSupersededDrainerCannotReleaseANewerClaim() {
        var ownership = BackfillDrainOwnership()
        let first = ownership.claimIfIdle()!
        XCTAssertTrue(ownership.release(first))
        let second = ownership.claimIfIdle()!
        XCTAssertFalse(ownership.release(first), "an old drainer's late exit must not free the queue")
        XCTAssertEqual(ownership.activeDrainID, second)
    }
}
