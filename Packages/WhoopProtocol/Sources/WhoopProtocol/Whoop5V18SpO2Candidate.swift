import Foundation

/// Diagnostic classification of WHOOP 5.0 historical-v18 byte 82.
///
/// RyanBR NOOP v9.1 carries this byte as a contested, decompile-supported SpO₂ candidate. Cross-device
/// evidence remains split, so NOOP iOS deliberately exposes only a protocol diagnostic. This value must
/// never populate `spo2Pct`, HealthKit, Recovery, illness detection, or a user-facing oxygen measurement.
public enum Whoop5V18SpO2Candidate: Equatable, Sendable {
    case absent
    case percentage(Int)
    case saturationSentinel(UInt8)
    case diagnosticCode(UInt8)

    public static let frameOffset = 82

    public static func decode(frame: [UInt8]) -> Self? {
        guard frame.indices.contains(frameOffset) else { return nil }
        return decode(raw: frame[frameOffset])
    }

    public static func decode(raw: UInt8) -> Self {
        switch raw {
        case 0:
            return .absent
        case 70...100:
            return .percentage(Int(raw))
        case _ where raw & 0x80 != 0:
            return .saturationSentinel(raw)
        default:
            return .diagnosticCode(raw)
        }
    }

    /// Convenience for diagnostic correlation tools. It intentionally returns nil for sentinels/codes.
    public var candidatePercentage: Int? {
        guard case .percentage(let value) = self else { return nil }
        return value
    }
}
