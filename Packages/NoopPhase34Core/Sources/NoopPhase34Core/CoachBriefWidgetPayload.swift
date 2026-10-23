import Foundation

/// A completed, explicitly generated daily brief. The extension only renders this bounded value;
/// generation, consent checks and health-record access belong to the foreground app.
public struct CoachBriefWidgetPayload: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case morning, evening }
    public static let maximumTextBytes = 1_600
    public let version: Int
    public let epoch: UInt64
    public let contextID: String
    public let generation: Int64
    public let logicalDay: String
    public let generatedAt: Date
    public let kind: Kind
    public let text: String
    /// These are the verified values captured with the brief, not live measurements.
    public let recovery: Int?
    public let strain: Double?
    public let sleepMinutes: Int?

    public init?(epoch: UInt64, contextID: String, generation: Int64, logicalDay: String,
                 generatedAt: Date, kind: Kind, text: String, recovery: Int? = nil,
                 strain: Double? = nil, sleepMinutes: Int? = nil) {
        self.version = 1
        self.epoch = epoch; self.contextID = contextID; self.generation = generation
        self.logicalDay = logicalDay; self.generatedAt = generatedAt; self.kind = kind
        self.text = Self.bounded(text.trimmingCharacters(in: .whitespacesAndNewlines))
        self.recovery = recovery; self.strain = strain; self.sleepMinutes = sleepMinutes
        guard isValid else { return nil }
    }

    /// Generation is provenance, not a requirement to match every later same-day health publication.
    /// Epoch/context changes, day rollover, malformed persisted data or clock anomalies hide the brief.
    public func isDisplayable(epoch: UInt64, contextID: String, logicalDay: String, now: Date) -> Bool {
        let age = now.timeIntervalSince(generatedAt)
        return isValid && self.epoch == epoch && self.contextID == contextID && self.logicalDay == logicalDay
            && age.isFinite && age >= -60 && age <= 26 * 3_600
    }

    private var isValid: Bool {
        version == 1 && epoch > 0 && generation > 0 && !contextID.isEmpty && contextID.utf8.count <= 2_048
            && logicalDay.count == 10 && generatedAt.timeIntervalSince1970.isFinite
            && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.utf8.count <= Self.maximumTextBytes
            && (recovery.map { (0...100).contains($0) } ?? true)
            && (strain.map { $0.isFinite && (0...21).contains($0) } ?? true)
            && (sleepMinutes.map { (0...1_440).contains($0) } ?? true)
    }

    private static func bounded(_ input: String) -> String {
        guard input.utf8.count > maximumTextBytes else { return input }
        var result = ""
        var bytes = 0
        for scalar in input.unicodeScalars {
            guard bytes + scalar.utf8.count <= maximumTextBytes else { break }
            result.unicodeScalars.append(scalar)
            bytes += scalar.utf8.count
        }
        return result
    }
}
