import Foundation
import Testing
@testable import NoopPhase34Core

@Test func explicitRetryArmsPeripheralWithoutInventingFailure() {
    let peripheral = UUID()
    var tracker = Whoop5SecureRecoveryTracker(retryDelaysSeconds: [0])

    tracker.explicitRetry(peripheralID: peripheral)

    #expect(tracker.peripheralID == peripheral)
    #expect(tracker.consecutiveFailures == 0)
    #expect(!tracker.isPaused)
}

@Test func unrelatedSecureReadyDoesNotClearTheActiveFailureSeries() {
    let activePeripheral = UUID()
    var tracker = Whoop5SecureRecoveryTracker(retryDelaysSeconds: [0])
    _ = tracker.recordFailure(peripheralID: activePeripheral)

    tracker.markSecureReady(peripheralID: UUID())

    #expect(tracker.peripheralID == activePeripheral)
    #expect(tracker.consecutiveFailures == 1)
    #expect(!tracker.isPaused)
}

@Test func differentPeripheralLeavesPausedStateAsAFreshFirstAttempt() {
    let firstPeripheral = UUID()
    let secondPeripheral = UUID()
    var tracker = Whoop5SecureRecoveryTracker(retryDelaysSeconds: [0])
    _ = tracker.recordFailure(peripheralID: firstPeripheral)
    _ = tracker.recordFailure(peripheralID: firstPeripheral)
    #expect(tracker.isPaused)

    let decision = tracker.recordFailure(peripheralID: secondPeripheral)

    #expect(decision == .reconnect(afterSeconds: 0, attempt: 1, maximumAutomaticAttempts: 1))
    #expect(tracker.peripheralID == secondPeripheral)
    #expect(tracker.consecutiveFailures == 1)
    #expect(!tracker.isPaused)
}
