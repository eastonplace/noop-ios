import Foundation
import Testing
@testable import NoopPhase34Core

private let protectedNotifications: Set<String> = ["fd4b0003", "fd4b0004", "fd4b0005", "fd4b0007"]

private func makeProtocolProofPending(confirmWrite: Bool = true) -> (Whoop5SecureSession, Whoop5SecureSessionID) {
    var session = Whoop5SecureSession()
    let id = session.acceptConnection(peripheralID: UUID(), connectGeneration: 1)
    let shouldSendHello = session.collectProtectedCharacteristics(
        commandCharacteristicFound: true,
        requiredNotificationIDs: protectedNotifications,
        discoveryComplete: true,
        sessionID: id
    )
    #expect(shouldSendHello)
    let helloConfirmed = session.confirmClientHello(sessionID: id, succeeded: true)
    #expect(helloConfirmed)
    for characteristic in protectedNotifications {
        _ = session.confirmProtectedNotification(characteristic, enabled: true, sessionID: id)
    }
    let proofStarted = session.beginProtocolProof(sequence: 42, sessionID: id)
    #expect(proofStarted)
    if confirmWrite {
        let proofWriteConfirmed = session.confirmProtocolProofWrite(sessionID: id, succeeded: true)
        #expect(proofWriteConfirmed)
    }
    return (session, id)
}

private func makeProofPending() -> (Whoop5SecureSession, Whoop5SecureSessionID) {
    makeProtocolProofPending()
}

@Test func acceptedConnectionClearsRetainedHandshakeState() {
    var session = Whoop5SecureSession()
    let first = session.acceptConnection(peripheralID: UUID(), connectGeneration: 1)
    _ = session.collectProtectedCharacteristics(
        commandCharacteristicFound: true,
        requiredNotificationIDs: protectedNotifications,
        discoveryComplete: true,
        sessionID: first
    )
    _ = session.confirmClientHello(sessionID: first, succeeded: true)

    let second = session.acceptConnection(peripheralID: UUID(), connectGeneration: 2)
    #expect(session.state == .standardOnly)
    #expect(session.id == second)
    #expect(session.pendingProofSequence == nil)
    #expect(session.confirmedProtectedNotifications.isEmpty)
}

@Test(arguments: [true, false])
func restoredPeripheralIsUnverified(wasConnected: Bool) {
    var session = Whoop5SecureSession()
    let id = session.acceptConnection(peripheralID: UUID(), connectGeneration: wasConnected ? 8 : 9)
    #expect(session.state == .standardOnly)
    #expect(!session.authorizesProprietaryCommand(sessionID: id))
}

@Test func duplicateRefreshAndDiscoveryCoalesceClientHello() {
    var session = Whoop5SecureSession()
    let peripheral = UUID()
    let id = session.acceptConnection(peripheralID: peripheral, connectGeneration: 3)
    session.refresh(peripheralID: peripheral, connectGeneration: 3)
    #expect(session.id == id)
    let firstDiscovery = session.collectProtectedCharacteristics(
        commandCharacteristicFound: true,
        requiredNotificationIDs: protectedNotifications,
        discoveryComplete: true,
        sessionID: id
    )
    #expect(firstDiscovery)
    let duplicateDiscovery = session.collectProtectedCharacteristics(
        commandCharacteristicFound: true,
        requiredNotificationIDs: protectedNotifications,
        discoveryComplete: true,
        sessionID: id
    )
    #expect(!duplicateDiscovery)
}

@Test func incompleteFD4BDiscoveryCannotStartClientHello() {
    var session = Whoop5SecureSession()
    let id = session.acceptConnection(peripheralID: UUID(), connectGeneration: 3)
    let shouldSendHello = session.collectProtectedCharacteristics(
        commandCharacteristicFound: true,
        requiredNotificationIDs: protectedNotifications,
        discoveryComplete: false,
        sessionID: id
    )
    #expect(!shouldSendHello)
    #expect(session.state == .standardOnly)
}

@Test func secureRecoveryBacksOffThenPauses() {
    var recovery = Whoop5SecureRecoveryTracker()
    let peripheral = UUID()
    let expected: [Whoop5SecureRecoveryDecision] = [
        .reconnect(afterSeconds: 3, attempt: 1, maximumAutomaticAttempts: 5),
        .reconnect(afterSeconds: 6, attempt: 2, maximumAutomaticAttempts: 5),
        .reconnect(afterSeconds: 12, attempt: 3, maximumAutomaticAttempts: 5),
        .reconnect(afterSeconds: 24, attempt: 4, maximumAutomaticAttempts: 5),
        .reconnect(afterSeconds: 60, attempt: 5, maximumAutomaticAttempts: 5),
        .pauseStandardOnly(failures: 6),
    ]

    for decision in expected {
        #expect(recovery.recordFailure(peripheralID: peripheral) == decision)
    }
    #expect(recovery.recordFailure(peripheralID: peripheral) == .pauseStandardOnly(failures: 6))
    #expect(recovery.isPaused)
}

@Test func physicalReconnectDoesNotResetSecureRecovery() {
    var recovery = Whoop5SecureRecoveryTracker()
    let peripheral = UUID()
    _ = recovery.recordFailure(peripheralID: peripheral)

    #expect(recovery.consecutiveFailures == 1)
    #expect(recovery.recordFailure(peripheralID: peripheral)
        == .reconnect(afterSeconds: 6, attempt: 2, maximumAutomaticAttempts: 5))
}

@Test func secureReadyAndExplicitRetryResetRecovery() {
    var recovery = Whoop5SecureRecoveryTracker(retryDelaysSeconds: [0])
    let peripheral = UUID()
    _ = recovery.recordFailure(peripheralID: peripheral)
    _ = recovery.recordFailure(peripheralID: peripheral)
    #expect(recovery.isPaused)

    recovery.markSecureReady(peripheralID: peripheral)
    #expect(recovery.consecutiveFailures == 0)
    #expect(!recovery.isPaused)

    _ = recovery.recordFailure(peripheralID: peripheral)
    _ = recovery.recordFailure(peripheralID: peripheral)
    recovery.explicitRetry(peripheralID: peripheral)
    #expect(recovery.consecutiveFailures == 0)
    #expect(!recovery.isPaused)
}

@Test func differentPeripheralStartsFreshSecureRecoverySeries() {
    var recovery = Whoop5SecureRecoveryTracker()
    let first = UUID()
    let second = UUID()
    _ = recovery.recordFailure(peripheralID: first)
    _ = recovery.recordFailure(peripheralID: first)

    #expect(recovery.recordFailure(peripheralID: second)
        == .reconnect(afterSeconds: 3, attempt: 1, maximumAutomaticAttempts: 5))
    #expect(recovery.peripheralID == second)
}

@Test func discoveryContractFailsClosedForMissingServiceOrCharacteristic() {
    #expect(!Whoop5DiscoveryContract.hasRequiredService(
        discoveredServiceIDs: ["180d", "180f"], requiredServiceID: "fd4b"))
    #expect(Whoop5DiscoveryContract.hasRequiredService(
        discoveredServiceIDs: ["fd4b"], requiredServiceID: "FD4B"))
    #expect(!Whoop5DiscoveryContract.hasRequiredCharacteristics(
        commandFound: false,
        discoveredNotificationIDs: protectedNotifications,
        requiredNotificationIDs: protectedNotifications))
    #expect(!Whoop5DiscoveryContract.hasRequiredCharacteristics(
        commandFound: true,
        discoveredNotificationIDs: protectedNotifications.subtracting(["fd4b0007"]),
        requiredNotificationIDs: protectedNotifications))
    #expect(Whoop5DiscoveryContract.hasRequiredCharacteristics(
        commandFound: true,
        discoveredNotificationIDs: protectedNotifications,
        requiredNotificationIDs: protectedNotifications))
}

@Test func protectedFramesRemainProofOnlyUntilSecureReady() {
    #expect(Whoop5ProtectedFrameAdmission.evaluate(
        secureReady: false, integrityValid: true) == .protocolProofOnly)
    #expect(Whoop5ProtectedFrameAdmission.evaluate(
        secureReady: true, integrityValid: false) == .dropInvalid)
    #expect(Whoop5ProtectedFrameAdmission.evaluate(
        secureReady: true, integrityValid: true) == .routeCurrentSession)
}

@Test func everyStaleProtectedFrameClassIsQuarantinedBeforeProof() {
    let staleProtectedFrameClasses = [
        "EVENT",
        "BATTERY_RESPONSE",
        "FIRMWARE_RESPONSE",
        "HAPTIC_COMMAND_RESPONSE",
        "HISTORICAL_DATA",
    ]

    for frameClass in staleProtectedFrameClasses {
        #expect(
            Whoop5ProtectedFrameAdmission.evaluate(
                secureReady: false,
                integrityValid: true) == .protocolProofOnly,
            "\(frameClass) must not reach telemetry, history, router, capture, or UI before proof")
    }
}

@Test func fullSecurePathRequiresOwnedStrictProof() {
    var (session, id) = makeProofPending()
    let accepted = session.acceptProtocolProofResponse(
        command: 145,
        requestSequence: 42,
        result: 1,
        integrityValid: true,
        sessionID: id
    )
    #expect(accepted)
    #expect(session.state == .secureReady)
    #expect(session.authorizesProprietaryCommand(sessionID: id))
}

@Test func protocolResponseBeforeATTStillCompletes() {
    var (session, id) = makeProtocolProofPending(confirmWrite: false)
    let responseCompleted = session.acceptProtocolProofResponse(
        command: 145, requestSequence: 42, result: 1,
        integrityValid: true, sessionID: id)
    #expect(!responseCompleted)
    #expect(session.state == .protocolProofPending)
    let writeAccepted = session.confirmProtocolProofWrite(sessionID: id, succeeded: true)
    #expect(writeAccepted)
    #expect(session.state == .secureReady)
}

@Test func ATTBeforeProtocolResponseStillCompletes() {
    var (session, id) = makeProtocolProofPending(confirmWrite: false)
    let writeAccepted = session.confirmProtocolProofWrite(sessionID: id, succeeded: true)
    #expect(writeAccepted)
    #expect(session.state == .protocolProofPending)
    let responseCompleted = session.acceptProtocolProofResponse(
        command: 145, requestSequence: 42, result: 1,
        integrityValid: true, sessionID: id)
    #expect(responseCompleted)
    #expect(session.state == .secureReady)
}

@Test(arguments: [
    (144 as UInt8, 42 as UInt8, 1 as UInt8, true),
    (145 as UInt8, 43 as UInt8, 1 as UInt8, true),
    (145 as UInt8, 42 as UInt8, 1 as UInt8, false),
])
func proofMismatchCannotAuthorize(command: UInt8, sequence: UInt8, result: UInt8, integrity: Bool) {
    var (session, id) = makeProofPending()
    let accepted = session.acceptProtocolProofResponse(
        command: command,
        requestSequence: sequence,
        result: result,
        integrityValid: integrity,
        sessionID: id
    )
    #expect(!accepted)
    #expect(session.state == .protocolProofPending)
}

@Test func matchedNegativeProofResultFailsImmediately() {
    var (session, id) = makeProtocolProofPending(confirmWrite: false)
    let responseCompleted = session.acceptProtocolProofResponse(
        command: 145, requestSequence: 42, result: 0,
        integrityValid: true, sessionID: id)
    #expect(!responseCompleted)
    #expect(session.state == .failed)
}

@Test func discoveryContractFreezesAfterHelloStarts() {
    var session = Whoop5SecureSession()
    let id = session.acceptConnection(peripheralID: UUID(), connectGeneration: 1)
    let first = session.collectProtectedCharacteristics(
        commandCharacteristicFound: true,
        requiredNotificationIDs: protectedNotifications,
        discoveryComplete: true,
        sessionID: id)
    #expect(first)
    let duplicate = session.collectProtectedCharacteristics(
        commandCharacteristicFound: true,
        requiredNotificationIDs: protectedNotifications.union(["unexpected"]),
        discoveryComplete: true,
        sessionID: id)
    #expect(!duplicate)
    #expect(!session.requiredProtectedNotifications.contains("unexpected"))
}

@Test func authenticationRefusalFailsClosedWithStandardFallback() {
    var session = Whoop5SecureSession()
    let id = session.acceptConnection(peripheralID: UUID(), connectGeneration: 1)
    _ = session.collectProtectedCharacteristics(
        commandCharacteristicFound: true,
        requiredNotificationIDs: protectedNotifications,
        discoveryComplete: true,
        sessionID: id
    )
    let accepted = session.confirmClientHello(sessionID: id, succeeded: false)
    #expect(!accepted)
    #expect(session.state == .failed)
    #expect(!session.authorizesProprietaryCommand(sessionID: id))
}

@Test func retainedDidBondAndConnectHandshakeCannotAuthorizeANewGeneration() {
    var (session, first) = makeProofPending()
    let firstAccepted = session.acceptProtocolProofResponse(
        command: 145,
        requestSequence: 42,
        result: 1,
        integrityValid: true,
        sessionID: first)
    #expect(firstAccepted)

    let second = session.acceptConnection(peripheralID: first.peripheralID, connectGeneration: 2)
    #expect(session.state == .standardOnly)
    #expect(!session.authorizesProprietaryCommand(sessionID: first))
    #expect(!session.authorizesProprietaryCommand(sessionID: second))
}

@Test func preBondHistoryBuzzAlarmAndR22RemainUnauthorizedWhileStandardHRCanRemainAvailable() {
    var session = Whoop5SecureSession()
    let id = session.acceptConnection(peripheralID: UUID(), connectGeneration: 1)
    #expect(session.state == .standardOnly)
    #expect(!session.authorizesProprietaryCommand(sessionID: id))
}

@Test func staleAttemptCannotAuthorizeReplacementConnection() {
    var (session, first) = makeProofPending()
    let second = session.acceptConnection(peripheralID: first.peripheralID, connectGeneration: 2)
    let accepted = session.acceptProtocolProofResponse(
        command: 145,
        requestSequence: 42,
        result: 1,
        integrityValid: true,
        sessionID: first
    )
    #expect(!accepted)
    #expect(session.state == .standardOnly)
    #expect(session.id == second)
}

@Test func r22CountsOnlyMatchedCurrentSessionSuccesses() {
    let (session, id) = makeProofPending()
    var attempt = Whoop5R22Attempt(sessionID: id)
    attempt.track(flag: "a", requestSequence: 10)
    attempt.track(flag: "b", requestSequence: 11)
    let wrongCommand = attempt.acceptResponse(command: 119, requestSequence: 10, result: 1, integrityValid: true, sessionID: id)
    let success = attempt.acceptResponse(command: 120, requestSequence: 10, result: 1, integrityValid: true, sessionID: id)
    let rejection = attempt.acceptResponse(command: 120, requestSequence: 11, result: 0, integrityValid: true, sessionID: id)
    #expect(wrongCommand == .ignored)
    #expect(success == .accepted(flag: "a"))
    #expect(rejection == .rejected(flag: "b", result: 0))
    #expect(attempt.acceptedFlags == ["a"])
    #expect(attempt.rejectedFlags == ["b"])
    #expect(session.state == .protocolProofPending)
}

@Test func r22UnmatchedResponseAfterRejectionRemainsIgnored() {
    let (_, id) = makeProofPending()
    var attempt = Whoop5R22Attempt(sessionID: id)
    attempt.track(flag: "x", requestSequence: 1)
    #expect(attempt.acceptResponse(
        command: 120, requestSequence: 1, result: 3,
        integrityValid: true, sessionID: id) == .rejected(flag: "x", result: 3))
    #expect(attempt.acceptResponse(
        command: 120, requestSequence: 99, result: 3,
        integrityValid: true, sessionID: id) == .ignored)
    attempt.track(flag: "x", requestSequence: 2)
    #expect(attempt.rejectedFlags.isEmpty)
    let retiredRetry = attempt.acceptResponse(
        command: 120, requestSequence: 1, result: 1,
        integrityValid: true, sessionID: id)
    #expect(retiredRetry == .ignored)
    #expect(attempt.acceptResponse(
        command: 120, requestSequence: 2, result: 1,
        integrityValid: true, sessionID: id) == .accepted(flag: "x"))
}
