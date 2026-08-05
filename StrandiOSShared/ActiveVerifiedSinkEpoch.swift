import Foundation

public struct ActiveVerifiedSinkEpochRecord: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let contextId: String?

    public init(epoch: UInt64, contextId: String?) {
        self.epoch = epoch
        self.contextId = contextId
    }
}

public struct VerifiedSinkGenerationRecord: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let contextId: String
    public let generation: Int64

    public init(epoch: UInt64, contextId: String, generation: Int64) {
        self.epoch = epoch
        self.contextId = contextId
        self.generation = generation
    }
}

public struct VerifiedSinkToken: Codable, Equatable, Sendable {
    public let epoch: UInt64
    public let contextId: String

    public init(epoch: UInt64, contextId: String) {
        self.epoch = epoch
        self.contextId = contextId
    }
}

public enum VerifiedSinkCommitResult: Equatable, Sendable {
    case published
    case alreadyCurrent
    case superseded
    case failed
}

/// One App Group epoch gates the Widget and Live Activity sinks. Context-only keys cannot reject an old task
/// that resumes after a source transition and happens to carry a reused context identifier.
public enum ActiveVerifiedSinkEpochStore {
    public static let activeKey = "noop.external-sink.active-epoch.v1"
    public static let widgetGenerationKey = "noop.widget.verified-generation.v2"
    public static let liveActivityGenerationKey = "noop.live-activity.verified-generation.v2"
    public static let widgetLiveOverlayKey = "noop.widget.live-overlay.v1"
    private static let lock = NSLock()

    public static func beginTransition(defaults: UserDefaults) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        let current = decode(ActiveVerifiedSinkEpochRecord.self, defaults.data(forKey: activeKey))
        let (next, overflow) = (current?.epoch ?? 0).addingReportingOverflow(1)
        guard !overflow else { return nil }
        let record = ActiveVerifiedSinkEpochRecord(epoch: next, contextId: nil)
        guard writeAndVerify(record, defaults: defaults, key: activeKey) else { return nil }
        return next
    }

    public static func activate(
        contextId: String,
        epoch: UInt64,
        defaults: UserDefaults
    ) -> VerifiedSinkToken? {
        guard !contextId.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let current = decode(
            ActiveVerifiedSinkEpochRecord.self,
            defaults.data(forKey: activeKey)
        ), current.epoch == epoch, current.contextId == nil else { return nil }
        let next = ActiveVerifiedSinkEpochRecord(epoch: epoch, contextId: contextId)
        guard writeAndVerify(next, defaults: defaults, key: activeKey) else { return nil }
        return VerifiedSinkToken(epoch: epoch, contextId: contextId)
    }

    public static func activeToken(defaults: UserDefaults) -> VerifiedSinkToken? {
        lock.lock()
        defer { lock.unlock() }
        guard let active = decode(
            ActiveVerifiedSinkEpochRecord.self,
            defaults.data(forKey: activeKey)
        ), let contextId = active.contextId else { return nil }
        return VerifiedSinkToken(epoch: active.epoch, contextId: contextId)
    }

    /// Re-read the active epoch and generation under the sink lock immediately before the payload write. The
    /// payload closure must write and read back the O(1) core blob only.
    public static func commitIfCurrent(
        token: VerifiedSinkToken,
        generation: Int64,
        defaults: UserDefaults,
        generationKey: String,
        writeAndReadBackPayload: (UserDefaults) -> Bool
    ) -> VerifiedSinkCommitResult {
        guard generation > 0 else { return .superseded }
        lock.lock()
        defer { lock.unlock() }
        guard let active = decode(
            ActiveVerifiedSinkEpochRecord.self,
            defaults.data(forKey: activeKey)
        ), active.epoch == token.epoch, active.contextId == token.contextId else {
            return .superseded
        }

        let existing = decode(
            VerifiedSinkGenerationRecord.self,
            defaults.data(forKey: generationKey)
        )
        if let existing {
            if existing.epoch > token.epoch { return .superseded }
            if existing.epoch == token.epoch {
                guard existing.contextId == token.contextId else { return .superseded }
                if generation < existing.generation { return .superseded }
            }
        }

        guard writeAndReadBackPayload(defaults) else { return .failed }
        let next = VerifiedSinkGenerationRecord(
            epoch: token.epoch,
            contextId: token.contextId,
            generation: generation
        )
        guard writeAndVerify(next, defaults: defaults, key: generationKey) else { return .failed }
        if existing == next { return .alreadyCurrent }
        return .published
    }

    public static func clearLegacyKeys(defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: "noop.widget.verified-projection-generation")
        defaults.removeObject(forKey: "noop.live-activity.verified-projection-generation")
    }

    /// The live lane has its own payload. It may update only while the exact verified epoch/context/generation
    /// remains active; it never mutates the durable verified snapshot.
    public static func commitLiveOverlayIfCurrent(
        token: VerifiedSinkToken,
        generation: Int64,
        defaults: UserDefaults,
        overlay: WidgetLiveOverlay
    ) -> Bool {
        guard generation > 0,
              overlay.epoch == token.epoch,
              overlay.contextId == token.contextId,
              overlay.generation == generation else { return false }
        lock.lock()
        defer { lock.unlock() }
        guard let active = decode(
            ActiveVerifiedSinkEpochRecord.self,
            defaults.data(forKey: activeKey)
        ), active.epoch == token.epoch, active.contextId == token.contextId else {
            return false
        }
        guard let data = try? JSONEncoder().encode(overlay) else { return false }
        defaults.set(data, forKey: widgetLiveOverlayKey)
        guard let stored = defaults.data(forKey: widgetLiveOverlayKey),
              let decoded = try? JSONDecoder().decode(WidgetLiveOverlay.self, from: stored),
              decoded == overlay else { return false }
        let reread = decode(ActiveVerifiedSinkEpochRecord.self, defaults.data(forKey: activeKey))
        return reread?.epoch == token.epoch && reread?.contextId == token.contextId
    }

    private static func writeAndVerify<T: Codable & Equatable>(
        _ value: T,
        defaults: UserDefaults,
        key: String
    ) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        defaults.set(data, forKey: key)
        guard let stored = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(T.self, from: stored) else { return false }
        return decoded == value
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
