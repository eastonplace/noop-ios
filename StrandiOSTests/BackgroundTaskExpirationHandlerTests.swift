import Foundation
import XCTest
@testable import NOOP

#if os(iOS)
/// Build 227 crashed 7/7 times with `_dispatch_assert_queue_fail` inside the BGTask registrar closures:
/// the `@MainActor` registrars passed `using: nil`, so iOS ran main-actor-inferred handlers on a worker
/// queue. The launch handlers now run on `BackgroundTaskLaunchPolicy.launchQueue`, and the expiration
/// handlers are `nonisolated` + `@Sendable`. `BGTaskScheduler.register` itself cannot be exercised once the
/// host app has finished launching, so these tests pin the pieces we can: the queue constant, and that each
/// registrar's expiration handler runs correctly when invoked from a global queue (a main-actor-inferred
/// closure would trap here) with its rearm-before-complete ordering intact.
final class BackgroundTaskExpirationHandlerTests: XCTestCase {
    func testLaunchHandlersAreDeliveredOnTheMainQueue() {
        XCTAssertTrue(BackgroundTaskLaunchPolicy.launchQueue === DispatchQueue.main)
    }

    func testScoringExpirationRunsOffMainAndRearmsBeforeCompleting() async {
        let log = ExpirationEventLog()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let handler = HistoricalScoringBackgroundTaskRegistrar.makeExpirationHandler(
                cancelWorker: { log.append("cancelWorker") },
                rearm: { log.append("rearm") },
                cancelDurableWork: { log.append("cancelDurableWork") },
                complete: { success in
                    log.append("complete:\(success)")
                    finished.resume()
                }
            )
            DispatchQueue.global().async { handler() }
        }
        XCTAssertEqual(log.values, ["cancelWorker", "rearm", "cancelDurableWork", "complete:false"])
    }

    func testHistoricalSyncExpirationRunsOffMainAndRearmsBeforeCompleting() async {
        let log = ExpirationEventLog()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let handler = HistoricalSyncBackgroundTaskRegistrar.makeExpirationHandler(
                cancelOperation: { log.append("cancelOperation") },
                rearm: { log.append("rearm") },
                complete: { success in
                    log.append("complete:\(success)")
                    finished.resume()
                }
            )
            DispatchQueue.global().async { handler() }
        }
        XCTAssertEqual(log.values, ["cancelOperation", "rearm", "complete:false"])
    }

    func testSmartAlarmExpirationRunsOffMainAndReportsExpired() async {
        let log = ExpirationEventLog()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let handler = SmartAlarmBackgroundTaskRegistrar.makeExpirationHandler(
                cancelOperation: { log.append("cancelOperation") },
                complete: { event in
                    log.append("complete:\(event)")
                    finished.resume()
                }
            )
            DispatchQueue.global().async { handler() }
        }
        XCTAssertEqual(log.values, ["cancelOperation", "complete:expired"])
    }

    func testPrivacyCleanupExpirationRunsOffMainAndRearmsBeforeCompleting() async {
        let log = ExpirationEventLog()
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            let handler = SourcePrivacyCleanupBackgroundTaskRegistrar.makeExpirationHandler(
                cancelOperation: { log.append("cancelOperation") },
                rearm: { log.append("rearm") },
                complete: { success in
                    log.append("complete:\(success)")
                    finished.resume()
                }
            )
            DispatchQueue.global().async { handler() }
        }
        XCTAssertEqual(log.values, ["cancelOperation", "rearm", "complete:false"])
    }
}

private final class ExpirationEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [String] {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
    }
}
#endif
