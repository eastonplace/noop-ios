import XCTest
import Combine
@testable import Strand

final class DesignLabStatePresentationTests: XCTestCase {
    func testSleepUndoDismissalCancelsExistingOwnerTask() {
        let task = Task<Void, Never> {
            _ = try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
        var ownerTask: Task<Void, Never>? = task

        SleepUndoTaskControl.cancelAndClear(&ownerTask)

        XCTAssertTrue(task.isCancelled)
        XCTAssertNil(ownerTask)
    }

    func testLiveVitalPresentationUsesArrivalFreshnessAndOnlyLivePulses() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(
            LiveVitalPresentation.resolve(isConnected: false, lastHRArrival: now, now: now),
            .offline
        )
        XCTAssertEqual(
            LiveVitalPresentation.resolve(isConnected: true, lastHRArrival: nil, now: now),
            .waiting
        )
        XCTAssertEqual(
            LiveVitalPresentation.resolve(
                isConnected: true,
                lastHRArrival: now.addingTimeInterval(-LiveVitalPresentation.staleAfter),
                now: now
            ),
            .live
        )
        XCTAssertEqual(
            LiveVitalPresentation.resolve(
                isConnected: true,
                lastHRArrival: now.addingTimeInterval(-LiveVitalPresentation.staleAfter - 0.001),
                now: now
            ),
            .stale
        )

        XCTAssertTrue(LiveVitalPresentation.live.pulsing)
        XCTAssertFalse(LiveVitalPresentation.waiting.pulsing)
        XCTAssertFalse(LiveVitalPresentation.stale.pulsing)
        XCTAssertFalse(LiveVitalPresentation.offline.pulsing)
    }

    func testLiveVitalArrivalPolicyIgnoresCachedReplayButKeepsRepeatedPackets() {
        let source = CurrentValueSubject<Int?, Never>(72)
        var received: [Int?] = []
        let subscription = LiveVitalArrivalPolicy
            .newArrivals(from: source)
            .sink { received.append($0) }

        XCTAssertTrue(received.isEmpty)
        source.send(72)
        source.send(72)
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.compactMap { $0 }, [72, 72])
        withExtendedLifetime(subscription) {}
    }

    func testOperationFailureKeepsExactMessageAndRetryGrammar() {
        let exact = "Backup failed - re-pick the folder and try again."
        let failure = PaperOperationPresentation(
            title: "Backup problem",
            message: exact,
            phase: .failed
        )
        let running = PaperOperationPresentation(
            title: "Backing up",
            message: "Saving a backup to your folder.",
            phase: .running
        )

        XCTAssertEqual(failure.message, exact)
        XCTAssertTrue(failure.showsRetry)
        XCTAssertTrue(failure.remainsVisibleUntilOwnerChangesState)
        XCTAssertFalse(running.showsRetry)
        XCTAssertFalse(running.remainsVisibleUntilOwnerChangesState)
    }
}
