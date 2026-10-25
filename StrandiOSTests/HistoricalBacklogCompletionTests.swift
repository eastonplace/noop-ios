import XCTest
@testable import NOOP

@MainActor
final class HistoricalBacklogCompletionTests: XCTestCase {
    private func debtAfter(complete: Bool, productive: Bool) -> Bool {
        let defaults = UserDefaults.standard
        let key = BLEManager.historicalBacklogRemainsKey
        let saved = defaults.object(forKey: key)
        defer {
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set(true, forKey: key)
        let manager = BLEManager(state: LiveState(), collector: nil, receiveBluetoothCallbacks: false)
        // A cached connection range is not part of the terminal proof. Only the pass
        // outcome can establish that an empty tail was actually completed.
        manager.finishHistoricalBacklogDecision(
            endedWithHistoryComplete: complete, freshSourceProgress: productive)
        return manager.historicalSyncBackgroundSnapshot(now: 50_000).backlogRemains
    }

    func testProductiveCappedPassCannotClearDebtUsingAnOldConnectionRange() {
        XCTAssertTrue(debtAfter(complete: false, productive: true))
    }

    func testProductiveCompletedPassKeepsDebtUntilAnEmptyTailIsObserved() {
        XCTAssertTrue(debtAfter(complete: true, productive: true))
    }

    func testInterruptedEmptyPassIsNotProofThatTheStrapIsCaughtUp() {
        XCTAssertTrue(debtAfter(complete: false, productive: false))
    }

    func testEmptyCompletedTailClearsDebt() {
        XCTAssertFalse(debtAfter(complete: true, productive: false))
    }

    func testUserDisconnectCancelsAutomaticRequestsWithoutDiscardingStoredDebt() {
        let defaults = UserDefaults.standard
        let key = BLEManager.historicalBacklogRemainsKey
        let saved = defaults.object(forKey: key)
        let manager = BLEManager(state: LiveState(), collector: nil, receiveBluetoothCallbacks: false)
        defer {
            manager.setHistoricalSyncBackgroundStateDidChange(nil)
            if let saved { defaults.set(saved, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        defaults.set(true, forKey: key)
        var plan: HistoricalSyncBackgroundSchedulingPolicy.Plan?
        manager.setHistoricalSyncBackgroundStateDidChange { [weak manager] in
            plan = manager?.historicalSyncBackgroundSnapshot(now: 50_000).plan
        }
        manager.disconnect()
        XCTAssertEqual(plan, .cancel, "User disconnect must cancel queued automatic work immediately")
        XCTAssertTrue(manager.historicalSyncBackgroundSnapshot(now: 50_000).backlogRemains,
                      "Cancellation must retain the stored debt for a later explicit reconnect")
    }

}
