import Foundation

public struct VerifiedWidgetEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let epoch: UInt64
    public let contextId: String
    public let generation: Int64
    public let snapshot: WidgetSnapshot

    public init(
        epoch: UInt64,
        contextId: String,
        generation: Int64,
        snapshot: WidgetSnapshot
    ) throws {
        guard epoch > 0, !contextId.isEmpty, generation > 0,
              snapshot.verifiedContextId == contextId,
              snapshot.verifiedProjectionGeneration == generation else {
            throw VerifiedWidgetEnvelopeError.invalidEnvelope
        }
        version = Self.currentVersion
        self.epoch = epoch
        self.contextId = contextId
        self.generation = generation
        self.snapshot = snapshot
    }

    private enum CodingKeys: String, CodingKey {
        case version, epoch, contextId, generation, snapshot
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        let epoch = try container.decode(UInt64.self, forKey: .epoch)
        let contextId = try container.decode(String.self, forKey: .contextId)
        let generation = try container.decode(Int64.self, forKey: .generation)
        let snapshot = try container.decode(WidgetSnapshot.self, forKey: .snapshot)
        guard version == Self.currentVersion, epoch > 0,
              !contextId.isEmpty, generation > 0,
              snapshot.verifiedContextId == contextId,
              snapshot.verifiedProjectionGeneration == generation else {
            throw VerifiedWidgetEnvelopeError.invalidEnvelope
        }
        self.version = version
        self.epoch = epoch
        self.contextId = contextId
        self.generation = generation
        self.snapshot = snapshot
    }
}

public enum VerifiedWidgetEnvelopeError: Error, Equatable, Sendable {
    case invalidEnvelope
    case superseded
    case writeFailed
}

public enum VerifiedWidgetEnvelopeStore {
    public static let storageKey = "noop.widget.verified-envelope.v1"
    private static let lock = NSLock()

    public static func load(defaults: UserDefaults) -> VerifiedWidgetEnvelope? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(VerifiedWidgetEnvelope.self, from: data)
    }

    /// Return the immutable verified envelope only when its epoch/context is the
    /// App Group's current active sink identity. A crashed/no-active transition
    /// therefore fails closed instead of continuing to display an old source.
    public static func rawActiveEnvelope(defaults: UserDefaults) -> VerifiedWidgetEnvelope? {
        guard let envelope = load(defaults: defaults),
              let active = ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults),
              active.epoch == envelope.epoch,
              active.contextId == envelope.contextId else {
            return nil
        }
        return envelope
    }

    public static func loadForDisplay(defaults: UserDefaults) -> WidgetSnapshot? {
        guard let envelope = rawActiveEnvelope(defaults: defaults) else { return nil }
        var snapshot = envelope.snapshot
        guard let overlayData = defaults.data(
            forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey
        ),
        let overlay = try? JSONDecoder().decode(
            WidgetLiveOverlay.self,
            from: overlayData
        ),
        overlay.epoch == envelope.epoch,
        overlay.contextId == envelope.contextId,
        overlay.generation == envelope.generation else {
            return snapshot
        }
        snapshot.bpm = overlay.bpm
        snapshot.batteryPct = overlay.batteryPct
        snapshot.bonded = overlay.bonded
        snapshot.hrSparkline = overlay.hrSparkline
        snapshot.updated = overlay.updated
        return snapshot
    }

    /// One payload, one UserDefaults key, one read-back. The generation fence can
    /// no longer lag behind a successfully-written Widget snapshot.
    public static func commit(
        token: VerifiedSinkToken,
        generation: Int64,
        snapshot: WidgetSnapshot,
        defaults: UserDefaults
    ) -> VerifiedProjectionGenerationWriteResult {
        lock.lock()
        defer { lock.unlock() }

        guard ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults) == token else {
            return .superseded
        }
        if let existing = load(defaults: defaults) {
            guard existing.epoch == token.epoch,
                  existing.contextId == token.contextId else {
                return .superseded
            }
            if generation < existing.generation { return .superseded }
            if generation == existing.generation,
               existing.snapshot.hasSameRenderedContent(as: snapshot) {
                return .alreadyCurrent
            }
        }

        guard let envelope = try? VerifiedWidgetEnvelope(
            epoch: token.epoch,
            contextId: token.contextId,
            generation: generation,
            snapshot: snapshot
        ),
        let payload = try? JSONEncoder().encode(envelope) else {
            return .failed
        }
        defaults.set(payload, forKey: storageKey)
        guard load(defaults: defaults) == envelope,
              ActiveVerifiedSinkEpochStore.activeToken(defaults: defaults) == token else {
            return .failed
        }
        return .published
    }

    public static func clear(defaults: UserDefaults) {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: ActiveVerifiedSinkEpochStore.widgetLiveOverlayKey)
    }
}
