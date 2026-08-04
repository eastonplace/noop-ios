import Foundation

/// Canonical, immutable replay identity. Derived timestamps and raw-retention policy are intentionally absent:
/// the same received bytes must remain the same commit after a parser update, clock repair, or setting change.
public struct HistoricalFingerprintV2Payload: Codable, Equatable, Sendable {
    public static let version = 2

    public let version: Int
    public let deviceLineage: String
    public let cursorEpoch: Int
    public let trimScope: String
    public let trim: UInt32
    public let orderedFrames: [Data]
    public let protocolMetadata: Data
    public let historyEndFrame: Data

    public init(
        deviceLineage: String,
        cursorEpoch: Int,
        trimScope: String,
        trim: UInt32,
        orderedFrames: [Data],
        protocolMetadata: Data,
        historyEndFrame: Data
    ) throws {
        guard !deviceLineage.isEmpty, cursorEpoch >= 0, !trimScope.isEmpty, !historyEndFrame.isEmpty else {
            throw HistoricalFingerprintError.invalidInput
        }
        self.version = Self.version
        self.deviceLineage = deviceLineage
        self.cursorEpoch = cursorEpoch
        self.trimScope = trimScope
        self.trim = trim
        self.orderedFrames = orderedFrames
        self.protocolMetadata = protocolMetadata
        self.historyEndFrame = historyEndFrame
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum HistoricalFingerprintError: Error, Equatable, Sendable {
    case invalidInput
}
