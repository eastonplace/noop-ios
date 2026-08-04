import Foundation
import Testing
@testable import NoopPhase34Core

private struct Ack: Codable, Equatable, Sendable { let trim: Int }

@Test func staleCallbackConsumesOnlyItsCharacteristicGeneration() {
    let peripheral = UUID()
    let oldCharacteristic = UUID()
    let currentCharacteristic = UUID()
    var queue = ConfirmedWriteTokenQueue<Ack>()
    queue.append(ConfirmedWriteToken(
        peripheralId: peripheral,
        characteristicId: "cmd",
        characteristicGeneration: oldCharacteristic,
        connectionGeneration: 1,
        enqueuedAt: Date(),
        payload: Ack(trim: 1)
    ))
    queue.append(ConfirmedWriteToken(
        peripheralId: peripheral,
        characteristicId: "cmd",
        characteristicGeneration: currentCharacteristic,
        connectionGeneration: 2,
        enqueuedAt: Date(),
        payload: Ack(trim: 2)
    ))

    let stale = queue.consume(
        peripheralId: peripheral,
        characteristicId: "cmd",
        characteristicGeneration: oldCharacteristic,
        currentPeripheralId: peripheral,
        currentCharacteristicGeneration: currentCharacteristic,
        currentConnectionGeneration: 2
    )
    guard case .stale(let token) = stale else {
        Issue.record("Expected stale token")
        return
    }
    #expect(token.payload?.trim == 1)
    #expect(queue.count == 1)

    let current = queue.consume(
        peripheralId: peripheral,
        characteristicId: "cmd",
        characteristicGeneration: currentCharacteristic,
        currentPeripheralId: peripheral,
        currentCharacteristicGeneration: currentCharacteristic,
        currentConnectionGeneration: 2
    )
    guard case .current(let token) = current else {
        Issue.record("Expected current token")
        return
    }
    #expect(token.payload?.trim == 2)
    #expect(queue.count == 0)
}

@Test func newCallbackCannotConsumeUnreturnedOldToken() {
    let peripheral = UUID()
    let oldCharacteristic = UUID()
    let currentCharacteristic = UUID()
    var queue = ConfirmedWriteTokenQueue<Ack>()
    queue.append(ConfirmedWriteToken(
        peripheralId: peripheral,
        characteristicId: "cmd",
        characteristicGeneration: oldCharacteristic,
        connectionGeneration: 1,
        enqueuedAt: Date(),
        payload: Ack(trim: 1)
    ))
    queue.append(ConfirmedWriteToken(
        peripheralId: peripheral,
        characteristicId: "cmd",
        characteristicGeneration: currentCharacteristic,
        connectionGeneration: 2,
        enqueuedAt: Date(),
        payload: Ack(trim: 2)
    ))

    let result = queue.consume(
        peripheralId: peripheral,
        characteristicId: "cmd",
        characteristicGeneration: currentCharacteristic,
        currentPeripheralId: peripheral,
        currentCharacteristicGeneration: currentCharacteristic,
        currentConnectionGeneration: 2
    )
    guard case .current(let token) = result else {
        Issue.record("Expected the current characteristic token")
        return
    }
    #expect(token.payload?.trim == 2)
    #expect(queue.count == 1)
}
