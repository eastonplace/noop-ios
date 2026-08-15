import Foundation
import Testing
@testable import NoopPhase34Core

private let protectedNotifications: Set<String> = ["fd4b0003", "fd4b0004", "fd4b0005"]

private func makeProofPending() -> (Whoop5SecureSession, Whoop5SecureSessionID) {
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
    let proofWriteConfirmed = session.confirmProtocolProofWrite(sessionID: id, succeeded: true)
    #expect(proofWriteConfirmed)
    return (session, id)
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

@Test(arguments: [
    (144 as UInt8, 42 as UInt8, 1 as UInt8, true),
    (145 as UInt8, 43 as UInt8, 1 as UInt8, true),
    (145 as UInt8, 42 as UInt8, 0 as UInt8, true),
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
    #expect(!wrongCommand)
    #expect(success)
    #expect(!rejection)
    #expect(attempt.acceptedFlags == ["a"])
    #expect(attempt.rejectedFlags == ["b"])
    #expect(session.state == .protocolProofPending)
}
