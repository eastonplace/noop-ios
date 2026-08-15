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
/// BLEManager owns transport and feeds only current-generation evidence into this value. The ATT write
/// result and COMMAND_RESPONSE are independent facts because CoreBluetooth does not order those delegates.
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
    private var proofResponseConfirmed = false

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
        resetAttemptEvidence()
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
        guard id == sessionID, state == .standardOnly else { return false }
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
            failCurrentAttempt()
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
        guard requiredProtectedNotifications.contains(characteristicID) else { return false }
        guard enabled else {
            failCurrentAttempt()
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
        proofResponseConfirmed = false
        state = .protocolProofPending
        return true
    }

    public mutating func confirmProtocolProofWrite(sessionID: Whoop5SecureSessionID, succeeded: Bool) -> Bool {
        guard id == sessionID, state == .protocolProofPending else { return false }
        guard succeeded else {
            failCurrentAttempt()
            return false
        }
        proofWriteConfirmed = true
        _ = resolveProtocolProofIfReady()
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
              pendingProofSequence == requestSequence,
              command == getHelloCommand,
              integrityValid else { return false }
        guard result == successResult else {
            failCurrentAttempt()
            return false
        }
        proofResponseConfirmed = true
        return resolveProtocolProofIfReady()
    }

    public mutating func fail(sessionID: Whoop5SecureSessionID) {
        guard id == sessionID else { return }
        failCurrentAttempt()
    }

    public mutating func disconnect() {
        state = .disconnected
        id = nil
        resetAttemptEvidence()
    }

    public func authorizesProprietaryCommand(sessionID: Whoop5SecureSessionID) -> Bool {
        id == sessionID && state == .secureReady
    }

    private mutating func resolveProtocolProofIfReady() -> Bool {
        guard state == .protocolProofPending,
              proofWriteConfirmed,
              proofResponseConfirmed else { return false }
        pendingProofSequence = nil
        state = .secureReady
        return true
    }

    private mutating func failCurrentAttempt() {
        state = .failed
        pendingProofSequence = nil
        proofWriteConfirmed = false
        proofResponseConfirmed = false
    }

    private mutating func resetAttemptEvidence() {
        pendingProofSequence = nil
        requiredProtectedNotifications.removeAll()
        confirmedProtectedNotifications.removeAll()
        discoveredCommandCharacteristic = false
        discoveryComplete = false
        proofWriteConfirmed = false
        proofResponseConfirmed = false
    }
}

public enum Whoop5SecureRecoveryDecision: Equatable, Sendable {
    case reconnect(afterSeconds: Int, attempt: Int, maximumAutomaticAttempts: Int)
    case pauseStandardOnly(failures: Int)
}

/// Cross-connection recovery ownership for one WHOOP 5/MG secure session. A physical BLE connection is
/// not a recovery success; only current-session protocol proof or an explicit user action clears the series.
public struct Whoop5SecureRecoveryTracker: Equatable, Sendable {
    public let retryDelaysSeconds: [Int]

    public private(set) var peripheralID: UUID?
    public private(set) var consecutiveFailures = 0
    public private(set) var isPaused = false

    public init(retryDelaysSeconds: [Int] = [3, 6, 12, 24, 60]) {
        let normalized = retryDelaysSeconds.map { max(0, $0) }
        self.retryDelaysSeconds = normalized.isEmpty ? [3] : normalized
    }

    public mutating func recordFailure(peripheralID: UUID) -> Whoop5SecureRecoveryDecision {
        if self.peripheralID != peripheralID {
            reset()
            self.peripheralID = peripheralID
        }
        guard !isPaused else { return .pauseStandardOnly(failures: consecutiveFailures) }

        consecutiveFailures += 1
        guard consecutiveFailures <= retryDelaysSeconds.count else {
            isPaused = true
            return .pauseStandardOnly(failures: consecutiveFailures)
        }
        return .reconnect(
            afterSeconds: retryDelaysSeconds[consecutiveFailures - 1],
            attempt: consecutiveFailures,
            maximumAutomaticAttempts: retryDelaysSeconds.count)
    }

    public mutating func markSecureReady(peripheralID: UUID) {
        guard self.peripheralID == nil || self.peripheralID == peripheralID else { return }
        reset()
    }

    public mutating func explicitRetry(peripheralID: UUID? = nil) {
        reset()
        self.peripheralID = peripheralID
    }

    public mutating func reset() {
        peripheralID = nil
        consecutiveFailures = 0
        isPaused = false
    }
}

public enum Whoop5ProtectedFrameAdmission: Equatable, Sendable {
    case protocolProofOnly
    case dropInvalid
    case routeCurrentSession

    public static func evaluate(secureReady: Bool, integrityValid: Bool) -> Self {
        guard secureReady else { return .protocolProofOnly }
        return integrityValid ? .routeCurrentSession : .dropInvalid
    }
}

public enum Whoop5DiscoveryContract {
    public static func hasRequiredService(
        discoveredServiceIDs: Set<String>,
        requiredServiceID: String
    ) -> Bool {
        discoveredServiceIDs.contains(requiredServiceID.lowercased())
    }

    public static func hasRequiredCharacteristics(
        commandFound: Bool,
        discoveredNotificationIDs: Set<String>,
        requiredNotificationIDs: Set<String>
    ) -> Bool {
        commandFound && discoveredNotificationIDs == requiredNotificationIDs
    }
}

public enum Whoop5R22ResponseOutcome: Equatable, Sendable {
    case ignored
    case accepted(flag: String)
    case rejected(flag: String, result: UInt8)
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
        acceptedFlags.remove(flag)
        rejectedFlags.remove(flag)
        pendingByRequestSequence = pendingByRequestSequence.filter { $0.value != flag }
        pendingByRequestSequence[requestSequence] = flag
    }

    public mutating func discard(requestSequence: UInt8) {
        pendingByRequestSequence.removeValue(forKey: requestSequence)
    }

    public mutating func acceptResponse(
        command: UInt8,
        requestSequence: UInt8,
        result: UInt8,
        integrityValid: Bool,
        sessionID: Whoop5SecureSessionID,
        setConfigCommand: UInt8 = 120,
        successResult: UInt8 = 1
    ) -> Whoop5R22ResponseOutcome {
        guard self.sessionID == sessionID,
              command == setConfigCommand,
              integrityValid,
              let flag = pendingByRequestSequence.removeValue(forKey: requestSequence) else { return .ignored }
        if result == successResult {
            rejectedFlags.remove(flag)
            acceptedFlags.insert(flag)
            return .accepted(flag: flag)
        }
        acceptedFlags.remove(flag)
        rejectedFlags.insert(flag)
        return .rejected(flag: flag, result: result)
    }
}
