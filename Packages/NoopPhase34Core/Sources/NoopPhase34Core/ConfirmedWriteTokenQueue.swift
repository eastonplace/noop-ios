import Foundation

public struct ConfirmedWriteToken<Payload: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    public let id: UUID
    public let peripheralId: UUID
    public let characteristicId: String
    /// Process-local identity assigned when this exact CBCharacteristic instance is admitted.
    /// The UUID string alone is insufficient after CoreBluetooth reconnects to the same peripheral.
    public let characteristicGeneration: UUID
    public let connectionGeneration: Int
    public let enqueuedAt: Date
    public let payload: Payload?

    public init(
        id: UUID = UUID(),
        peripheralId: UUID,
        characteristicId: String,
        characteristicGeneration: UUID,
        connectionGeneration: Int,
        enqueuedAt: Date,
        payload: Payload? = nil
    ) {
        self.id = id
        self.peripheralId = peripheralId
        self.characteristicId = characteristicId
        self.characteristicGeneration = characteristicGeneration
        self.connectionGeneration = connectionGeneration
        self.enqueuedAt = enqueuedAt
        self.payload = payload
    }
}

public enum ConfirmedWriteConsumption<Payload: Codable & Equatable & Sendable>: Equatable, Sendable {
    case noMatch
    case current(ConfirmedWriteToken<Payload>)
    case stale(ConfirmedWriteToken<Payload>)
}

/// CoreBluetooth does not identify which `.withResponse` write a callback belongs to. The caller assigns one
/// generation to each retained characteristic object and supplies that generation for both the write and its
/// callback. The queue consumes the exact FIFO token before checking the active connection. A late callback
/// can retire only its own old-characteristic token and can never swallow a callback from a replacement link.
public struct ConfirmedWriteTokenQueue<Payload: Codable & Equatable & Sendable>: Sendable {
    private var tokens: [ConfirmedWriteToken<Payload>] = []

    public init() {}

    public var count: Int { tokens.count }

    public mutating func append(_ token: ConfirmedWriteToken<Payload>) {
        tokens.append(token)
    }

    public mutating func consume(
        peripheralId: UUID,
        characteristicId: String,
        characteristicGeneration: UUID,
        currentPeripheralId: UUID?,
        currentCharacteristicGeneration: UUID?,
        currentConnectionGeneration: Int
    ) -> ConfirmedWriteConsumption<Payload> {
        guard let index = tokens.firstIndex(where: {
            $0.peripheralId == peripheralId
                && $0.characteristicId == characteristicId
                && $0.characteristicGeneration == characteristicGeneration
        }) else {
            return .noMatch
        }
        let token = tokens.remove(at: index)
        let isCurrent = token.peripheralId == currentPeripheralId
            && token.characteristicGeneration == currentCharacteristicGeneration
            && token.connectionGeneration == currentConnectionGeneration
        return isCurrent ? .current(token) : .stale(token)
    }

    @discardableResult
    public mutating func prune(olderThan cutoff: Date) -> [ConfirmedWriteToken<Payload>] {
        let removed = tokens.filter { $0.enqueuedAt < cutoff }
        tokens.removeAll { $0.enqueuedAt < cutoff }
        return removed
    }

    /// Safe for a permanently forgotten peripheral. A normal reconnect to the same peripheral must retain
    /// old-characteristic tokens until callback or timeout, because the old UUID can be reused.
    @discardableResult
    public mutating func removeAll(peripheralId: UUID) -> [ConfirmedWriteToken<Payload>] {
        let removed = tokens.filter { $0.peripheralId == peripheralId }
        tokens.removeAll { $0.peripheralId == peripheralId }
        return removed
    }
}
