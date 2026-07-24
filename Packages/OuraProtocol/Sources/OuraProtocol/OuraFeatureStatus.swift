import Foundation

/// A decoded `0x2F/0x21` feature-status read reply: the ring's own report of feature mode, status,
/// state, and subscription. This is diagnostic only—never scored, persisted, or used to enable a feature.
public struct OuraFeatureStatus: Equatable, Sendable, Codable {
    public let feature: Int
    public let mode: Int
    public let status: Int
    public let state: Int
    public let subscription: Int

    public init(feature: Int, mode: Int, status: Int, state: Int, subscription: Int) {
        self.feature = feature
        self.mode = mode
        self.status = status
        self.state = state
        self.subscription = subscription
    }
}

public extension OuraCommands {
    /// Real-steps feature id. The offline ring may report this as server-subscription gated.
    static var featureRealSteps: UInt8 { 0x0b }

    /// Read the SpO₂ feature status. `0x20` is the read verb; this never sends the `0x22` enable verb.
    static func spo2ReadStatus() -> OuraCommand {
        OuraCommand(label: "spo2_status", bytes: [0x2f, 0x02, 0x20, featureSpO2])
    }

    /// Read the real-steps feature status. Read-only diagnostic; it cannot enable server-gated output.
    static func realStepsReadStatus() -> OuraCommand {
        OuraCommand(label: "realsteps_status", bytes: [0x2f, 0x02, 0x20, featureRealSteps])
    }
}

public extension OuraDecoders {
    /// Decode the five bytes following secure sub-op `0x21`. A short body fails closed.
    static func decodeFeatureStatus(_ subBody: [UInt8]) -> OuraFeatureStatus? {
        guard subBody.count >= 5 else { return nil }
        return OuraFeatureStatus(
            feature: Int(subBody[0]),
            mode: Int(subBody[1]),
            status: Int(subBody[2]),
            state: Int(subBody[3]),
            subscription: Int(subBody[4])
        )
    }
}

/// Pure routing helper for transports adopting the v9.1 read-only diagnostic. Daytime-HR feature `0x02`
/// remains part of the existing live-HR enable triplet and therefore is not surfaced as a diagnostic.
public enum OuraFeatureStatusProbe {
    public static func diagnosticStatus(from frame: OuraSecureFrame) -> OuraFeatureStatus? {
        guard frame.subop == 0x21,
              let status = OuraDecoders.decodeFeatureStatus(frame.subBody),
              status.feature != Int(OuraCommands.featureDaytimeHR)
        else { return nil }
        return status
    }
}
