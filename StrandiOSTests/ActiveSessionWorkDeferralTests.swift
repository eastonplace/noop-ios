import XCTest
@testable import NOOP

/// Pins how post-sync refresh work is parked while a run or lift is active and replayed afterwards (the
/// `NOOP.cpu_resource_fatal` fix): coalescing, ordering, and that nothing is dropped. Uses a toy watermark so
/// the policy is exercised without the BLE layer.
final class ActiveSessionWorkDeferralTests: XCTestCase {
    private struct Mark: MergeableWatermark {
        var generations: [String: Int]
        init(_ generations: [String: Int]) { self.generations = generations }
        func merged(with newer: Mark) -> Mark {
            Mark(generations.merging(newer.generations) { max($0, $1) })
        }
    }

    private typealias Work = DeferredSessionWork<Mark>

    // MARK: Idle

    func testIdleRunsEverythingImmediatelyAndParksNothing() {
        var work = Work()
        XCTAssertTrue(work.admitBurst(Mark(["a": 1]), sessionActive: false))
        XCTAssertTrue(work.admitBurst(nil, sessionActive: false))
        XCTAssertTrue(work.admitPipelineSignal(sessionActive: false))
        XCTAssertFalse(work.hasPending)
        XCTAssertTrue(work.drain(sessionActive: false).isEmpty)
    }

    // MARK: Parking

    func testAnActiveSessionParksABurstAndDrainWaitsForItToEnd() {
        var work = Work()
        XCTAssertFalse(work.admitBurst(Mark(["a": 1]), sessionActive: true))
        XCTAssertTrue(work.hasPending)

        XCTAssertTrue(work.drain(sessionActive: true).isEmpty)
        XCTAssertTrue(work.hasPending)

        XCTAssertEqual(work.drain(sessionActive: false), [.burstRefresh(Mark(["a": 1]))])
        XCTAssertFalse(work.hasPending)
    }

    func testReceiptBurstsCoalesceIntoTheUnionWithTheNewestGenerationPerScope() {
        var work = Work()
        _ = work.admitBurst(Mark(["a": 1, "b": 5]), sessionActive: true)
        _ = work.admitBurst(Mark(["a": 4]), sessionActive: true)
        _ = work.admitBurst(Mark(["c": 2, "b": 3]), sessionActive: true)

        XCTAssertEqual(
            work.drain(sessionActive: false),
            [.burstRefresh(Mark(["a": 4, "b": 5, "c": 2]))])
    }

    func testHealOnlyBurstsCoalesceAndStaySeparateFromReceiptBursts() {
        var work = Work()
        _ = work.admitBurst(nil, sessionActive: true)
        _ = work.admitBurst(Mark(["a": 1]), sessionActive: true)
        _ = work.admitBurst(nil, sessionActive: true)

        // Receipt route first, then the heal-only route; each exactly once.
        XCTAssertEqual(
            work.drain(sessionActive: false),
            [.burstRefresh(Mark(["a": 1])), .burstRefresh(nil)])
    }

    func testDrainClearsEverythingSoReplayHappensOnce() {
        var work = Work()
        _ = work.admitBurst(Mark(["a": 1]), sessionActive: true)
        XCTAssertEqual(work.drain(sessionActive: false).count, 1)
        XCTAssertTrue(work.drain(sessionActive: false).isEmpty)
    }

    // MARK: Pipeline signals

    func testAParkedPipelineSignalReplaysAloneWhenNoBurstWasParked() {
        var work = Work()
        XCTAssertFalse(work.admitPipelineSignal(sessionActive: true))
        _ = work.admitPipelineSignal(sessionActive: true)
        XCTAssertEqual(work.drain(sessionActive: false), [.pipelineSignal])
    }

    func testABurstRefreshAlreadySignalsThePipelineSoTheSignalIsNotReplayedTwice() {
        var work = Work()
        _ = work.admitPipelineSignal(sessionActive: true)
        _ = work.admitBurst(Mark(["a": 1]), sessionActive: true)
        XCTAssertEqual(work.drain(sessionActive: false), [.burstRefresh(Mark(["a": 1]))])
        XCTAssertFalse(work.hasPending)
    }

    // MARK: Session boundaries

    func testWorkAdmittedAfterTheSessionEndsRunsImmediately() {
        var work = Work()
        _ = work.admitBurst(Mark(["a": 1]), sessionActive: true)
        _ = work.drain(sessionActive: false)
        XCTAssertTrue(work.admitBurst(Mark(["a": 2]), sessionActive: false))
        XCTAssertFalse(work.hasPending)
    }

    func testASecondSessionParksAgainWithoutLeakingTheFirst() {
        var work = Work()
        _ = work.admitBurst(Mark(["a": 1]), sessionActive: true)
        _ = work.drain(sessionActive: false)
        _ = work.admitBurst(Mark(["b": 2]), sessionActive: true)
        XCTAssertEqual(work.drain(sessionActive: false), [.burstRefresh(Mark(["b": 2]))])
    }

    // MARK: Predicates

    @MainActor
    func testTheBackgroundTaskGateFollowsWhateverTheAppWiredIn() {
        // The test host is the real app, which wires this at launch; put it back afterwards.
        let wired = ActiveSessionGate.isActive
        defer { ActiveSessionGate.isActive = wired }

        ActiveSessionGate.isActive = { true }
        XCTAssertTrue(ActiveSessionGate.isActive())
        ActiveSessionGate.isActive = { false }
        XCTAssertFalse(ActiveSessionGate.isActive())
        XCTAssertGreaterThan(ActiveSessionGate.retryDelay, 0)
    }

    func testASessionIsActiveForEitherARunOrALift() {
        XCTAssertFalse(ActiveSessionWorkPolicy.isSessionActive(hasActiveWorkout: false, hasActiveLift: false))
        XCTAssertTrue(ActiveSessionWorkPolicy.isSessionActive(hasActiveWorkout: true, hasActiveLift: false))
        XCTAssertTrue(ActiveSessionWorkPolicy.isSessionActive(hasActiveWorkout: false, hasActiveLift: true))
        XCTAssertTrue(ActiveSessionWorkPolicy.isSessionActive(hasActiveWorkout: true, hasActiveLift: true))
    }

    func testOffScreenDeferralNeedsBothAnActiveSessionAndAnInactiveApp() {
        XCTAssertTrue(ActiveSessionWorkPolicy.shouldDeferWhileOffScreen(sessionActive: true, appIsActive: false))
        XCTAssertFalse(ActiveSessionWorkPolicy.shouldDeferWhileOffScreen(sessionActive: true, appIsActive: true))
        XCTAssertFalse(ActiveSessionWorkPolicy.shouldDeferWhileOffScreen(sessionActive: false, appIsActive: false))
        XCTAssertFalse(ActiveSessionWorkPolicy.shouldDeferWhileOffScreen(sessionActive: false, appIsActive: true))
    }
}
