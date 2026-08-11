import Foundation

/// Canonical replay identity for one durable historical payload.
///
/// WHOOP may change HISTORY_START and HISTORY_END envelope bytes when it retries the same flash cursor.
/// Those transport-session bytes remain receipt evidence, but they are not content identity. Ordered data
/// frames remain byte-exact and order-sensitive.
public struct HistoricalFingerprintV3Payload: Codable, Equatable, Sendable {
    public static let version = 3

    public let version: Int
    public let deviceLineage: String
    public let cursorEpoch: Int
    public let trimScope: String
    public let trim: UInt32
    public let orderedFrames: [Data]

    public init(
        deviceLineage: String,
        cursorEpoch: Int,
        trimScope: String,
        trim: UInt32,
        orderedFrames: [Data]
    ) throws {
        guard !deviceLineage.isEmpty, cursorEpoch >= 0, !trimScope.isEmpty else {
            throw HistoricalFingerprintError.invalidInput
        }
        self.version = Self.version
        self.deviceLineage = deviceLineage
        self.cursorEpoch = cursorEpoch
        self.trimScope = trimScope
        self.trim = trim
        self.orderedFrames = orderedFrames
    }

    public func canonicalData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
