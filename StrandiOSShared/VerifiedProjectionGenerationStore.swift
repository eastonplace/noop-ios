// Add to StrandiOSShared (or another target shared by the iOS app and widget model).

import Foundation

public struct VerifiedProjectionGenerationRecord: Codable, Equatable, Sendable {
    public let contextId: String
    public let generation: Int64
}

public enum VerifiedProjectionGenerationStore {
    private static let lock = NSLock()

    public static func acceptsAndRecord(
        contextId: String,
        generation: Int64,
        defaults: UserDefaults,
        key: String
    ) -> Bool {
        guard !contextId.isEmpty, generation > 0 else { return false }
        lock.lock()
        defer { lock.unlock() }
        let decoder = JSONDecoder()
        let existing = defaults.data(forKey: key).flatMap {
            try? decoder.decode(VerifiedProjectionGenerationRecord.self, from: $0)
        }
        if let existing, existing.contextId == contextId, generation < existing.generation {
            return false
        }
        let next = VerifiedProjectionGenerationRecord(contextId: contextId, generation: generation)
        guard let data = try? JSONEncoder().encode(next) else { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
