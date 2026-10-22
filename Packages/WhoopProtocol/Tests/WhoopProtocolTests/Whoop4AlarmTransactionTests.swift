import Foundation
import XCTest
@testable import WhoopProtocol

final class Whoop4AlarmTransactionTests: XCTestCase {
    private func make() -> Whoop4AlarmTransaction {
        .init(owner: .init(id: UUID(), peripheralID: UUID(), connectGeneration: 7),
              clockEpoch: 1_792_627_504, wakeEpoch: 1_792_666_800)
    }

    func testSerialWritesRequireTheirOwnAcknowledgementsAndExplicitReadbackDelay() throws {
        var transaction = make()
        let owner = transaction.owner
        for (index, step) in [Whoop4AlarmTransaction.Step.clock8, .clock9, .alarm9].enumerated() {
            let sequence = UInt8(index + 10)
            let write = try XCTUnwrap(transaction.issue(owner: owner, requestSequence: sequence))
            XCTAssertEqual(write.step, step)
            XCTAssertNil(transaction.issue(owner: owner, requestSequence: sequence + 1), "No overlapping writes")
            XCTAssertTrue(transaction.acknowledge(owner: owner, requestSequence: sequence, succeeded: true))
        }
        XCTAssertEqual(transaction.state, .waitingForReadbackDelay)
        XCTAssertNil(transaction.issue(owner: owner, requestSequence: 13), "GET must wait for settling delay")
        XCTAssertTrue(transaction.releaseReadback(owner: owner))
        let readback = try XCTUnwrap(transaction.issue(owner: owner, requestSequence: 13))
        XCTAssertEqual(readback.step, .readback)
        XCTAssertEqual(readback.command, .getAlarmTime)
        XCTAssertEqual(readback.payload, [0x01])
        XCTAssertTrue(transaction.acknowledge(owner: owner, requestSequence: 13, succeeded: true))
        XCTAssertEqual(transaction.state, .completed)
        XCTAssertNil(transaction.issue(owner: owner, requestSequence: 14))
    }

    func testWritesPreserveBothClockFormatsAndCapturedNineByteAlarm() throws {
        var transaction = make()
        let owner = transaction.owner
        for (sequence, expectedCommand, expectedPayload) in [
            (UInt8(1), WhoopCommand.setClock, WhoopCommand.setClockPayload(now: 1_792_627_504)),
            (UInt8(2), WhoopCommand.setClock, WhoopCommand.setClockPayloadLegacy(now: 1_792_627_504)),
            (UInt8(3), WhoopCommand.setAlarmTime, [0x01, 0xb0, 0xec, 0xd9, 0x6a, 0, 0, 0, 0])
        ] {
            let write = try XCTUnwrap(transaction.issue(owner: owner, requestSequence: sequence))
            XCTAssertEqual(write.command, expectedCommand)
            XCTAssertEqual(write.payload, expectedPayload)
            XCTAssertTrue(transaction.acknowledge(owner: owner, requestSequence: sequence, succeeded: true))
        }
    }

    func testWrongSequenceAndDuplicateAcknowledgementsCannotAdvance() throws {
        var transaction = make()
        let owner = transaction.owner
        XCTAssertFalse(transaction.acknowledge(owner: owner, requestSequence: 9, succeeded: true))
        _ = try XCTUnwrap(transaction.issue(owner: owner, requestSequence: 9))
        XCTAssertFalse(transaction.acknowledge(owner: owner, requestSequence: 10, succeeded: true))
        XCTAssertEqual(transaction.state, .awaitingAcknowledgement(.clock8, requestSequence: 9))
        XCTAssertTrue(transaction.acknowledge(owner: owner, requestSequence: 9, succeeded: true))
        XCTAssertFalse(transaction.acknowledge(owner: owner, requestSequence: 9, succeeded: true))
        XCTAssertEqual(transaction.state, .ready(.clock9))
    }

    func testEachOwnerFenceRejectsSupersededDeviceAndConnectionCallbacks() throws {
        var transaction = make()
        let owner = transaction.owner
        _ = try XCTUnwrap(transaction.issue(owner: owner, requestSequence: 1))
        let staleOwners: [Whoop4AlarmTransaction.Owner] = [
            .init(id: UUID(), peripheralID: owner.peripheralID, connectGeneration: owner.connectGeneration),
            .init(id: owner.id, peripheralID: UUID(), connectGeneration: owner.connectGeneration),
            .init(id: owner.id, peripheralID: owner.peripheralID, connectGeneration: owner.connectGeneration - 1)
        ]
        for stale in staleOwners {
            XCTAssertNil(transaction.issue(owner: stale, requestSequence: 2))
            XCTAssertFalse(transaction.acknowledge(owner: stale, requestSequence: 1, succeeded: true))
            XCTAssertFalse(transaction.timeout(owner: stale, requestSequence: 1))
            XCTAssertFalse(transaction.cancel(owner: stale))
            XCTAssertFalse(transaction.releaseReadback(owner: stale))
        }
        XCTAssertEqual(transaction.state, .awaitingAcknowledgement(.clock8, requestSequence: 1))
    }

    func testFailureAndTimeoutAbortWithoutIssuingLaterCommands() throws {
        for useTimeout in [false, true] {
            var transaction = make()
            let owner = transaction.owner
            _ = try XCTUnwrap(transaction.issue(owner: owner, requestSequence: 1))
            XCTAssertFalse(transaction.timeout(owner: owner, requestSequence: 2))
            if useTimeout {
                XCTAssertTrue(transaction.timeout(owner: owner, requestSequence: 1))
            } else {
                XCTAssertTrue(transaction.acknowledge(owner: owner, requestSequence: 1, succeeded: false))
            }
            XCTAssertEqual(transaction.state, .aborted)
            XCTAssertNil(transaction.issue(owner: owner, requestSequence: 2))
            XCTAssertFalse(transaction.acknowledge(owner: owner, requestSequence: 1, succeeded: true))
        }
    }

    func testCancellationDuringReadbackDelayPreventsDelayedWrite() throws {
        var transaction = make()
        let owner = transaction.owner
        for sequence in UInt8(1)...3 {
            _ = try XCTUnwrap(transaction.issue(owner: owner, requestSequence: sequence))
            XCTAssertTrue(transaction.acknowledge(owner: owner, requestSequence: sequence, succeeded: true))
        }
        XCTAssertTrue(transaction.cancel(owner: owner))
        XCTAssertFalse(transaction.releaseReadback(owner: owner))
        XCTAssertNil(transaction.issue(owner: owner, requestSequence: 4))
        XCTAssertEqual(transaction.state, .aborted)
    }

    func testSequenceCannotBeReusedWithinTransactionAfterGlobalWireSequenceWraps() throws {
        var transaction = make()
        let owner = transaction.owner
        _ = try XCTUnwrap(transaction.issue(owner: owner, requestSequence: 255))
        XCTAssertTrue(transaction.acknowledge(owner: owner, requestSequence: 255, succeeded: true))
        XCTAssertNil(transaction.issue(owner: owner, requestSequence: 255), "A delayed duplicate ACK must never match a later step")
        XCTAssertEqual(transaction.state, .ready(.clock9))
        _ = try XCTUnwrap(transaction.issue(owner: owner, requestSequence: 0))
        XCTAssertFalse(transaction.acknowledge(owner: owner, requestSequence: 255, succeeded: true))
        XCTAssertEqual(transaction.state, .awaitingAcknowledgement(.clock9, requestSequence: 0))
    }
}
