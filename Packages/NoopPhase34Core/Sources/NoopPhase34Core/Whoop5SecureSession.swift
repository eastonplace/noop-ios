import Foundation

public enum Whoop5SecureSessionState: String, Codable, Equatable, Sendable {
    case disconnected
    case standardOnly
    case clientHelloPending
    case protectedNotificationsPending
    case protocolProofPending
    case secureReady
    case failed
}

public struct Whoop5SecureSessionID: Codable, Equatable, Hashable, Sendable {
    public let peripheralID: UUID
    public let connectGeneration: Int
    public let attemptEpoch: UInt64

    public init(peripheralID: UUID, connectGeneration: Int, attemptEpoch: UInt64) {
        self.peripheralID = peripheralID
        self.connectGeneration = connectGeneration
        self.attemptEpoch = attemptEpoch
    }
}

/// The bounded WHOOP 5/MG authorization state. It deliberately knows nothing about CoreBluetooth;
/// BLEManager owns transport and feeds only current-generation evidence into this value.
public struct Whoop5SecureSession: Codable, Equatable, Sendable {
    public private(set) var state: Whoop5SecureSessionState = .disconnected
    public private(set) var id: Whoop5SecureSessionID?
    public private(set) var pendingProofSequence: UInt8?
    public private(set) var requiredProtectedNotifications: Set<String> = []
    public private(set) var confirmedProtectedNotifications: Set<String> = []

    private var nextAttemptEpoch: UInt64 = 0
    private var discoveredCommandCharacteristic = false
    private var discoveryComplete = false
    private var proofWriteConfirmed = false

    public init() {}

    /// Publishes one new physical connection generation. Restored links use this same unverified path.
    @discardableResult
    public mutating func acceptConnection(peripheralID: UUID, connectGeneration: Int) -> Whoop5SecureSessionID {
        nextAttemptEpoch &+= 1
        let newID = Whoop5SecureSessionID(
            peripheralID: peripheralID,
            connectGeneration: connectGeneration,
            attemptEpoch: nextAttemptEpoch
        )
        id = newID
        state = .standardOnly
        pendingProofSequence = nil
        requiredProtectedNotifications.removeAll()
        confirmedProtectedNotifications.removeAll()
        discoveredCommandCharacteristic = false
        discoveryComplete = false
        proofWriteConfirmed = false
        return newID
    }

    /// A duplicate service refresh for the same accepted generation preserves the active attempt.
    public mutating func refresh(peripheralID: UUID, connectGeneration: Int) {
        guard id?.peripheralID == peripheralID, id?.connectGeneration == connectGeneration else { return }
    }

    public mutating func collectProtectedCharacteristics(
        commandCharacteristicFound: Bool,
        requiredNotificationIDs: Set<String>,
        discoveryComplete: Bool,
        sessionID: Whoop5SecureSessionID
    ) -> Bool {
        guard id == sessionID, state != .failed, state != .disconnected else { return false }
        discoveredCommandCharacteristic = discoveredCommandCharacteristic || commandCharacteristicFound
        requiredProtectedNotifications.formUnion(requiredNotificationIDs)
        self.discoveryComplete = self.discoveryComplete || discoveryComplete
        guard state == .standardOnly, discoveredCommandCharacteristic, self.discoveryComplete else { return false }
        state = .clientHelloPending
        return true
    }

    public mutating func confirmClientHello(sessionID: Whoop5SecureSessionID, succeeded: Bool) -> Bool {
        guard id == sessionID, state == .clientHelloPending else { return false }
        guard succeeded else {
            state = .failed
            return false
        }
        state = .protectedNotificationsPending
        return true
    }

    public mutating func confirmProtectedNotification(
        _ characteristicID: String,
        enabled: Bool,
        sessionID: Whoop5SecureSessionID
    ) -> Bool {
        guard id == sessionID, state == .protectedNotificationsPending else { return false }
        guard enabled, requiredProtectedNotifications.contains(characteristicID) else {
            if requiredProtectedNotifications.contains(characteristicID) { state = .failed }
            return false
        }
        confirmedProtectedNotifications.insert(characteristicID)
        return confirmedProtectedNotifications == requiredProtectedNotifications
    }

    public mutating func beginProtocolProof(sequence: UInt8, sessionID: Whoop5SecureSessionID) -> Bool {
        guard id == sessionID,
              state == .protectedNotificationsPending,
              confirmedProtectedNotifications == requiredProtectedNotifications else { return false }
        pendingProofSequence = sequence
        proofWriteConfirmed = false
        state = .protocolProofPending
        return true
    }

    public mutating func confirmProtocolProofWrite(sessionID: Whoop5SecureSessionID, succeeded: Bool) -> Bool {
        guard id == sessionID, state == .protocolProofPending else { return false }
        guard succeeded else {
            state = .failed
            return false
        }
        proofWriteConfirmed = true
        return true
    }

    public mutating func acceptProtocolProofResponse(
        command: UInt8,
        requestSequence: UInt8,
        result: UInt8,
        integrityValid: Bool,
        sessionID: Whoop5SecureSessionID,
        getHelloCommand: UInt8 = 145,
        successResult: UInt8 = 1
    ) -> Bool {
        guard id == sessionID,
              state == .protocolProofPending,
              proofWriteConfirmed,
              pendingProofSequence == requestSequence,
              command == getHelloCommand,
              result == successResult,
              integrityValid else { return false }
        pendingProofSequence = nil
        state = .secureReady
        return true
    }

    public mutating func fail(sessionID: Whoop5SecureSessionID) {
        guard id == sessionID else { return }
        state = .failed
        pendingProofSequence = nil
        proofWriteConfirmed = false
    }

    public mutating func disconnect() {
        state = .disconnected
        id = nil
        pendingProofSequence = nil
        requiredProtectedNotifications.removeAll()
        confirmedProtectedNotifications.removeAll()
        discoveredCommandCharacteristic = false
        discoveryComplete = false
        proofWriteConfirmed = false
    }

    public func authorizesProprietaryCommand(sessionID: Whoop5SecureSessionID) -> Bool {
        id == sessionID && state == .secureReady
    }
}

public struct Whoop5R22Attempt: Codable, Equatable, Sendable {
    public let sessionID: Whoop5SecureSessionID
    public private(set) var pendingByRequestSequence: [UInt8: String] = [:]
    public private(set) var acceptedFlags: Set<String> = []
    public private(set) var rejectedFlags: Set<String> = []

    public init(sessionID: Whoop5SecureSessionID) {
        self.sessionID = sessionID
    }

    public mutating func track(flag: String, requestSequence: UInt8) {
        pendingByRequestSequence[requestSequence] = flag
    }

    @discardableResult
    public mutating func acceptResponse(
        command: UInt8,
        requestSequence: UInt8,
        result: UInt8,
        integrityValid: Bool,
        sessionID: Whoop5SecureSessionID,
        setConfigCommand: UInt8 = 120,
        successResult: UInt8 = 1
    ) -> Bool {
        guard self.sessionID == sessionID,
              command == setConfigCommand,
              integrityValid,
              let flag = pendingByRequestSequence.removeValue(forKey: requestSequence) else { return false }
        if result == successResult {
            acceptedFlags.insert(flag)
            return true
        }
        rejectedFlags.insert(flag)
        return false
    }
}
