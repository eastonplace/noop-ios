import Foundation

/// Orders one WHOOP 4 alarm arm. Completion proves ATT delivery only; the caller must validate the
/// asynchronous alarm readback separately before claiming the strap is armed.
public struct Whoop4AlarmTransaction: Equatable, Sendable {
    public struct Owner: Equatable, Sendable {
        public let id: UUID
        public let peripheralID: UUID
        public let connectGeneration: Int

        public init(id: UUID = UUID(), peripheralID: UUID, connectGeneration: Int) {
            self.id = id
            self.peripheralID = peripheralID
            self.connectGeneration = connectGeneration
        }
    }

    public enum Step: Equatable, Sendable {
        case clock8, clock9, alarm9, readback
    }

    public enum State: Equatable, Sendable {
        case ready(Step)
        case awaitingAcknowledgement(Step, requestSequence: UInt8)
        case waitingForReadbackDelay
        case completed
        case aborted
    }

    public struct Write: Equatable, Sendable {
        public let step: Step
        public let command: WhoopCommand
        public let payload: [UInt8]
    }

    public let owner: Owner
    public private(set) var state: State = .ready(.clock8)
    private let clockEpoch: UInt32
    private let wakeEpoch: UInt32
    private var issuedSequences: Set<UInt8> = []

    public init(owner: Owner, clockEpoch: UInt32, wakeEpoch: UInt32) {
        self.owner = owner
        self.clockEpoch = clockEpoch
        self.wakeEpoch = wakeEpoch
    }

    /// Call immediately before issuing an ATT-confirmed write. A second write cannot be issued until
    /// its predecessor's exact callback arrives. The caller supplies the connection's wire sequence.
    public mutating func issue(owner: Owner, requestSequence: UInt8) -> Write? {
        guard owner == self.owner, case .ready(let step) = state,
              !issuedSequences.contains(requestSequence) else { return nil }
        let write: Write
        switch step {
        case .clock8:
            write = Write(step: step, command: .setClock, payload: WhoopCommand.setClockPayload(now: clockEpoch))
        case .clock9:
            write = Write(step: step, command: .setClock, payload: WhoopCommand.setClockPayloadLegacy(now: clockEpoch))
        case .alarm9:
            write = Write(step: step, command: .setAlarmTime, payload: WhoopCommand.setAlarmPayload(epochSec: wakeEpoch))
        case .readback:
            write = Write(step: step, command: .getAlarmTime, payload: [0x01])
        }
        issuedSequences.insert(requestSequence)
        state = .awaitingAcknowledgement(step, requestSequence: requestSequence)
        return write
    }

    /// Consumes only the issued operation's callback. ATT success is not protocol acceptance.
    @discardableResult
    public mutating func acknowledge(owner: Owner, requestSequence: UInt8, succeeded: Bool) -> Bool {
        guard owner == self.owner,
              case .awaitingAcknowledgement(let step, let expectedSequence) = state,
              requestSequence == expectedSequence else { return false }
        guard succeeded else { state = .aborted; return true }
        switch step {
        case .clock8: state = .ready(.clock9)
        case .clock9: state = .ready(.alarm9)
        case .alarm9: state = .waitingForReadbackDelay
        case .readback: state = .completed
        }
        return true
    }

    /// The caller owns the settling timer and must pass its captured owner when that timer fires.
    @discardableResult
    public mutating func releaseReadback(owner: Owner) -> Bool {
        guard owner == self.owner, state == .waitingForReadbackDelay else { return false }
        state = .ready(.readback)
        return true
    }

    @discardableResult
    public mutating func timeout(owner: Owner, requestSequence: UInt8) -> Bool {
        guard owner == self.owner,
              case .awaitingAcknowledgement(_, let expectedSequence) = state,
              requestSequence == expectedSequence else { return false }
        state = .aborted
        return true
    }

    @discardableResult
    public mutating func cancel(owner: Owner) -> Bool {
        guard owner == self.owner, state != .completed, state != .aborted else { return false }
        state = .aborted
        return true
    }
}
