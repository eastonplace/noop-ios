// Add to StrandiOSShared (or another target shared by the iOS app and widget model).

import Foundation

public struct VerifiedProjectionGenerationRecord: Codable, Equatable, Sendable {
    public let contextId: String
    public let generation: Int64
}

public enum VerifiedProjectionGenerationWriteResult: Equatable, Sendable {
    case published
    case alreadyCurrent
    case superseded
    case failed
}

public enum VerifiedProjectionGenerationStore {
    private static let lock = NSLock()

    public static func acceptsAndRecord(
        contextId: String,
        generation: Int64,
        defaults: UserDefaults,
        key: String
    ) -> Bool {
        let result = commitIfAccepted(
            contextId: contextId,
            generation: generation,
            expectedActiveContextId: nil,
            defaults: defaults,
            key: key,
            write: {
                true
            }
        )
        return result == .published || result == .alreadyCurrent
    }

    /// Compare the incoming identity to the identity persisted at the actual
    /// sink boundary. The record is written only after `write` succeeds.
    public static func commitIfAccepted(
        contextId: String,
        generation: Int64,
        expectedActiveContextId: String?,
        defaults: UserDefaults,
        key: String,
        write: () -> Bool
    ) -> VerifiedProjectionGenerationWriteResult {
        guard !contextId.isEmpty, generation > 0 else { return .superseded }
        if let expectedActiveContextId, expectedActiveContextId != contextId {
            return .superseded
        }
        lock.lock()
        defer { lock.unlock() }
        let decoder = JSONDecoder()
        let existing = defaults.data(forKey: key).flatMap {
            try? decoder.decode(VerifiedProjectionGenerationRecord.self, from: $0)
        }
        if let existing {
            if existing.contextId != contextId { return .superseded }
            if generation < existing.generation { return .superseded }
        }
        guard write() else { return .failed }
        let next = VerifiedProjectionGenerationRecord(contextId: contextId, generation: generation)
        guard let data = try? JSONEncoder().encode(next) else { return .failed }
        defaults.set(data, forKey: key)
        if existing?.contextId == contextId, existing?.generation == generation {
            return .alreadyCurrent
        }
        return .published
    }

    public static func clear(defaults: UserDefaults, key: String) {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: key)
    }
}
